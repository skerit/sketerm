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
const clock = @import("util/clock.zig");

fn nextReconnectDelay(delay_ms: u32) u32 {
    return @min(delay_ms * 2, 30_000);
}

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
    /// Cleared when permanent pane teardown begins; transport loss leaves it
    /// set so already-committed local panel hydration can survive reconnect.
    panel_assets_live: std.atomic.Value(bool) = .{ .raw = true },
    /// Borrowed; nulled in deinit.
    terminal: ?*Terminal = null,
};

pub const Terminal = struct {
    pub const ConnectionState = enum { lost, reconnecting, retry_wait, unavailable, connected };

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
    /// Fired when the daemon reports a different foreground process
    /// for this session. UI uses it to re-render a title template
    /// that mentions `{{ PROGRAM }}`.
    on_program_changed: ?*const fn (ctx: ?*anyopaque, program: []const u8) void = null,
    on_clipboard_set: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
    /// OSC 52 read query (only fired when the screen allows reads).
    on_clipboard_get: ?*const fn (ctx: ?*anyopaque, selection: u8) void = null,
    /// Glyph Protocol `q` system-font coverage probe (see
    /// Screen.Sink.on_glyph_coverage). Answered synchronously from
    /// the pane's Atlas; unset = no system coverage.
    on_glyph_coverage: ?*const fn (ctx: ?*anyopaque, cp: u32) bool = null,
    /// Fires once at the end of a socket drain when events left
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
    /// Durable mux transport state; always delivered on the main thread.
    on_connection_state: ?*const fn (ctx: ?*anyopaque, state: ConnectionState, retry_seconds: u32) void = null,
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
    /// Attached-viewer count from the last control_state frame (the
    /// peer_info total counts panel-only clients too; this one is the
    /// number the daemon reports for the seat roster).
    peer_viewers: u32 = 0,
    /// Controller lease (control_state frames): does THIS client drive
    /// the session's Wayland seat? A forwarded app renders for every
    /// viewer, but only the controller's input reaches it. Seeded true
    /// so a pre-lease daemon (no control_state frames at all) behaves
    /// exactly as before.
    has_control: bool = true,
    /// Label of whoever holds the lease when we don't ("" = nobody).
    control_holder: [32]u8 = undefined,
    control_holder_len: usize = 0,
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
    /// Cast-playback state (play_state frames from a cast session).
    /// `st.markers` is valid only for the duration of the callback.
    on_play_state: ?*const fn (ctx: ?*anyopaque, st: PlayState) void = null,
    /// GTK-main-loop dispatch for a daemon-forwarded native panel request.
    /// Asset-bearing calls may reply later through `replyPanelRequest`.
    on_panel_request: ?*const fn (ctx: ?*anyopaque, terminal: *Terminal, request_id: u64, request: []const u8) void = null,
    /// Close every panel owned by this stable Terminal origin before its
    /// attachment is permanently torn down. Rewiring preserves this hook.
    on_panel_origin_close: ?*const fn (terminal: *Terminal) void = null,
    /// Refresh mutable panel display/store metadata while confinement keeps
    /// using this Terminal's immutable origin. Rewiring preserves this hook.
    on_panel_origin_renamed: ?*const fn (terminal: *Terminal, name: []const u8) void = null,
    /// Cancel queued or deferred panel mutations when a transport drops;
    /// already-mounted panels survive while this Terminal reconnects.
    on_panel_work_cancel: ?*const fn (terminal: *Terminal) void = null,
    /// GUI-owned relay-scope attachment, erased to keep Terminal GTK-free.
    /// It survives sink rewiring and is released by `closePanelOrigin`.
    panel_scope_ctx: ?*anyopaque = null,
    /// Latest play_state, markers stripped (they are callback-scoped).
    last_play_state: ?PlayState = null,

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

    /// Foreground process name on the session's pty, pushed by the
    /// daemon in `session_meta`. Feeds the `{{ PROGRAM }}` title
    /// placeholder. Fixed buffer, not an allocation: it is one short
    /// comm string and it changes as often as the user runs a command.
    program_buf: [32]u8 = undefined,
    program_len: u8 = 0,

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

    /// One step of a cast-playback session's transport state (a
    /// `play_state` frame). `duration_ms` stays null until the daemon
    /// has seen the recording's EOF once.
    pub const PlayState = struct {
        pub const Kind = enum { playing, paused, seeking, finished };
        pub const Marker = struct { ms: u64, label: []const u8 };
        kind: Kind,
        position_ms: u64 = 0,
        duration_ms: ?u64 = null,
        speed: f64 = 1.0,
        /// Valid only inside the `on_play_state` callback.
        markers: []const Marker = &.{},
    };

    pub const PlayOp = enum { play, pause, restart, seek, speed };

    /// Remote (mux) attachment state.
    pub const Remote = struct {
        conn: mux_client.Conn,
        session: []u8,
        /// Immutable spawn-time identity advertised by session_meta. This is
        /// never rewritten by rename; old daemons fall back to the attach name.
        origin_name: []u8,
        /// Lifetime-unique session incarnation; empty for an old daemon.
        origin_id: []u8 = &.{},
        /// Transport host string (bare auto, forced "udp:"/"ssh:") or null for
        /// the local daemon. Owned for reconnect and layout persistence.
        host: ?[]u8 = null,
        /// UDP firewall range copied from Config for reconnect attempts.
        port_range: []u8 = &.{},
        /// Preserve a read-only attach across reconnects.
        read_only: bool = false,
        /// Preserve an acquired/requested controller lease across transport
        /// replacement; a replacement attach may need to evict the stale fd.
        force_control: bool = false,
        control_known: bool = false,
        /// Rename sent to the daemon, awaiting its OK. Committed to
        /// `session` on .ok, dropped on .err. Owned while non-null.
        pending_rename: ?[]u8 = null,
        /// rec_start (1) / rec_stop (2) awaiting the daemon's OK.
        /// Interactive actions are one-at-a-time, so a single slot
        /// suffices (like pending_rename).
        pending_record: u8 = 0,
        /// In-flight `udp_ticket_req` (one at a time, like the slots
        /// above). The callback fires EXACTLY once — with the ticket,
        /// or with null on refusal/transport loss/teardown — so the
        /// requester can free its context unconditionally.
        pending_ticket_cb: ?*const fn (ctx: ?*anyopaque, ticket: ?mux_client.UdpTicket) void = null,
        pending_ticket_ctx: ?*anyopaque = null,
        watch_id: c_uint = 0,
        write_watch_id: c_uint = 0,
        idle_kick_id: c_uint = 0,
        /// ── Connection state axes (orthogonal, see predicates below) ──
        /// `connected` = transport attached (`conn` valid). False while
        /// the reconnect machinery owns the link. A CLOSED session keeps
        /// its transport until Terminal.deinit — kill/detach ride it.
        connected: bool = true,
        /// Terminal.deinit fence: no new callbacks or jobs may start.
        destroying: bool = false,
        /// In-flight worker jobs. Both can be true at once — a transport
        /// lost mid-upgrade starts a reconnect while the stale upgrade
        /// job is still returning; generation fencing discards the loser.
        reconnect_job_active: bool = false,
        upgrade_job_active: bool = false,
        reconnect_timer: c_uint = 0,
        reconnect_generation: u64 = 0,
        /// Bumped only when the attached connection is lost. Deferred panel
        /// work captures this value so a later reconnect cannot revive it.
        panel_generation: u64 = 1,
        retry_delay_ms: u32 = 1000,
        pending_rows: u16 = 0,
        pending_cols: u16 = 0,
        /// Session ended (daemon EXIT/GONE or protocol error) — terminal
        /// state, never cleared, no more writes.
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
        /// Correlated asynchronous ranged reads used by remote panel assets.
        fs_reads: std.ArrayList(*RemoteFileRead) = .empty,
        fs_next_req: u32 = 0x80000000,
        fs_read_timer: c_uint = 0,
        /// xfer id of the most recent directory-list request; a listing
        /// with a different id is stale (we navigated away) and ignored.
        list_xfer: u32 = 0,

        /// Session running AND transport attached — writes may go out.
        pub fn canSend(self: *const Remote) bool {
            return !self.closed and self.connected;
        }

        /// canSend outside teardown — new background machinery
        /// (transport upgrade, state-changing requests) may start.
        fn isLive(self: *const Remote) bool {
            return self.canSend() and !self.destroying;
        }

        /// Transport lost on a still-running session outside teardown —
        /// the reconnect machinery may run.
        fn awaitingReconnect(self: *const Remote) bool {
            return !self.connected and !self.closed and !self.destroying;
        }

        pub fn sendInput(self: *Remote, bytes: []const u8) bool {
            if (!self.canSend()) return false;
            self.conn.sendFrame(.input, bytes) catch return false;
            return true;
        }

        /// Invalidate every in-flight reconnect/upgrade job. 0 is
        /// reserved as "never fenced", so the counter skips it.
        fn bumpGeneration(self: *Remote) void {
            self.reconnect_generation +%= 1;
            if (self.reconnect_generation == 0) self.reconnect_generation = 1;
        }

        fn bumpPanelGeneration(self: *Remote) void {
            self.panel_generation +%= 1;
            if (self.panel_generation == 0) self.panel_generation = 1;
        }
    };

    const ReconnectJob = struct {
        drain: *DrainHandle,
        generation: u64,
        host: ?[]u8,
        port_range: []u8,
        session: []u8,
        origin_id: []u8,
        pending_rename: ?[]u8,
        read_only: bool,
        control: bool,
        upgrade: bool = false,
        conn: ?mux_client.Conn = null,
        snapshot: ?[]u8 = null,
        session_missing: bool = false,
        identity_mismatch: bool = false,
        rename_applied: bool = false,

        fn destroy(self: *ReconnectJob) void {
            const a = std.heap.c_allocator;
            if (self.conn) |*conn| conn.deinit();
            if (self.snapshot) |snapshot| a.free(snapshot);
            if (self.host) |host| a.free(host);
            if (self.port_range.len > 0) a.free(self.port_range);
            a.free(self.session);
            if (self.origin_id.len > 0) a.free(self.origin_id);
            if (self.pending_rename) |name| a.free(name);
            a.destroy(self);
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

    pub const RemoteFileResult = union(enum) {
        success: struct {
            /// Owned by the callback, allocated with `terminal.allocator`.
            bytes: []u8,
            size: u64,
            mtime_ns: i64,
            ino: u64,
        },
        failure: []const u8,
    };

    pub const RemoteFileCallback = *const fn (
        ctx: ?*anyopaque,
        terminal: *Terminal,
        token: u32,
        result: RemoteFileResult,
    ) void;

    const RemoteFileRead = struct {
        terminal: *Terminal,
        token: u32,
        path: []u8,
        max_bytes: usize,
        deadline_ms: i64,
        ctx: ?*anyopaque,
        callback: RemoteFileCallback,
        data: std.ArrayList(u8) = .empty,
        identity_set: bool = false,
        size: u64 = 0,
        mtime_ns: i64 = 0,
        ino: u64 = 0,
        received_data: bool = false,

        fn deinit(self: *RemoteFileRead) void {
            const allocator = self.terminal.allocator;
            self.data.deinit(allocator);
            allocator.free(self.path);
            allocator.destroy(self);
        }
    };

    const REMOTE_FILE_READ_MAX: usize = 4;
    const REMOTE_FILE_READ_CHUNK: u32 = 256 << 10;

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
        initial_identity: mux_client.AttachIdentity,
        host: ?[]const u8,
        port_range: []const u8,
        read_only: bool,
        want_control: bool,
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
        const acknowledged_name = if (initial_identity.valid) initial_identity.name() else session_name;
        const acknowledged_origin = if (initial_identity.valid) initial_identity.originName() else session_name;
        const session_owned = try allocator.dupe(u8, acknowledged_name);
        errdefer allocator.free(session_owned);
        const origin_name_owned = try allocator.dupe(u8, acknowledged_origin);
        errdefer allocator.free(origin_name_owned);
        const origin_id_owned: []u8 = if (initial_identity.valid)
            try allocator.dupe(u8, initial_identity.originId())
        else
            &.{};
        errdefer if (origin_id_owned.len > 0) allocator.free(origin_id_owned);
        const host_owned: ?[]u8 = if (host) |h| try allocator.dupe(u8, h) else null;
        errdefer if (host_owned) |h| allocator.free(h);
        const port_range_owned: []u8 = if (port_range.len > 0) try allocator.dupe(u8, port_range) else &.{};
        errdefer if (port_range_owned.len > 0) allocator.free(port_range_owned);
        remote.* = .{
            .conn = conn,
            .session = session_owned,
            .origin_name = origin_name_owned,
            .origin_id = origin_id_owned,
            .host = host_owned,
            .port_range = port_range_owned,
            .read_only = read_only,
            .force_control = want_control,
            .predictor = predict_mod.Predictor.init(allocator),
            .is_app = envelope.app,
        };
        if (profile_util.getenv("SKETERM_PREDICT")) |v| {
            if (std.mem.eql(u8, v, "always")) remote.predictor.force = .always;
            if (std.mem.eql(u8, v, "never")) remote.predictor.force = .never;
        }

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
        remote.idle_kick_id = c.g_idle_add(@ptrCast(&remoteIdleKick), @ptrCast(drain));
        return self;
    }

    /// One-shot idle: drain frames recvExpect buffered before the
    /// fd watch existed. G_SOURCE_REMOVE either way.
    fn remoteIdleKick(user: ?*anyopaque) callconv(.c) c.gboolean {
        const drain: *DrainHandle = @ptrCast(@alignCast(user.?));
        if (drain.alive.load(.acquire)) {
            if (drain.terminal) |term| {
                if (term.remote) |remote| {
                    remote.idle_kick_id = 0;
                    if (remote.canSend())
                        _ = remoteSocketCb(-1, c.G_IO_IN, @ptrCast(term));
                }
            }
        }
        return 0;
    }

    fn notifyConnectionState(self: *Terminal, state: ConnectionState, retry_seconds: u32) void {
        if (self.on_connection_state) |f| f(self.user_ctx, state, retry_seconds);
    }

    fn armRemoteWatch(self: *Terminal) void {
        const remote = self.remote orelse return;
        remote.conn.setNonBlocking();
        remote.watch_id = c.g_unix_fd_add(
            remote.conn.fd,
            c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR,
            @ptrCast(&remoteSocketCb),
            @ptrCast(self),
        );
        if (remote.idle_kick_id != 0) _ = c.g_source_remove(remote.idle_kick_id);
        remote.idle_kick_id = c.g_idle_add(@ptrCast(&remoteIdleKick), @ptrCast(self.drain));
    }

    fn armRemoteWriteWatch(self: *Terminal) void {
        const remote = self.remote orelse return;
        if (!remote.canSend() or remote.write_watch_id != 0 or remote.conn.wbuf.items.len == 0) return;
        remote.write_watch_id = c.g_unix_fd_add(
            remote.conn.fd,
            c.G_IO_OUT | c.G_IO_HUP | c.G_IO_ERR,
            @ptrCast(&remoteWriteCb),
            @ptrCast(self.drain),
        );
    }

    fn remoteWriteCb(_: c_int, _: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const drain: *DrainHandle = @ptrCast(@alignCast(user.?));
        if (!drain.alive.load(.acquire)) return 0;
        const self = drain.terminal orelse return 0;
        const remote = self.remote orelse return 0;
        remote.conn.flushQueued() catch {
            remote.write_watch_id = 0;
            self.transportLost("queued mux write failed");
            return 0;
        };
        if (remote.conn.wbuf.items.len == 0) {
            remote.write_watch_id = 0;
            return 0;
        }
        return 1;
    }

    /// Begin one non-blocking ranged read over this attached mux connection.
    pub fn beginRemoteFileRead(
        self: *Terminal,
        path: []const u8,
        max_bytes: usize,
        timeout_ms: i64,
        ctx: ?*anyopaque,
        callback: RemoteFileCallback,
    ) !u32 {
        const remote = self.remote orelse return error.NotRemote;
        if (!remote.canSend()) return error.NotConnected;
        if (path.len == 0 or path.len > 1024 or path[0] != '/') return error.BadPath;
        if (max_bytes == 0) return error.TooBig;
        if (remote.fs_reads.items.len >= REMOTE_FILE_READ_MAX) return error.Busy;

        const read = try self.allocator.create(RemoteFileRead);
        errdefer self.allocator.destroy(read);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const token = self.nextRemoteFileReq();
        read.* = .{
            .terminal = self,
            .token = token,
            .path = owned_path,
            .max_bytes = max_bytes,
            .deadline_ms = clock.nowMs() + @max(timeout_ms, 1),
            .ctx = ctx,
            .callback = callback,
        };
        try remote.fs_reads.append(self.allocator, read);
        errdefer {
            _ = remote.fs_reads.pop();
            read.deinit();
        }
        try self.sendRemoteFileRange(read);
        if (remote.fs_read_timer == 0) {
            remote.fs_read_timer = c.g_timeout_add(
                100,
                @ptrCast(&remoteFileReadTick),
                @ptrCast(self.drain),
            );
        }
        return token;
    }

    fn nextRemoteFileReq(self: *Terminal) u32 {
        const remote = self.remote.?;
        while (true) {
            const req = remote.fs_next_req;
            remote.fs_next_req +%= 1;
            if (remote.fs_next_req < 0x80000000) remote.fs_next_req = 0x80000000;
            if (req == 0) continue;
            var used = false;
            for (remote.fs_reads.items) |read| if (read.token == req) {
                used = true;
                break;
            };
            if (!used) return req;
        }
    }

    fn sendRemoteFileRange(self: *Terminal, read: *RemoteFileRead) !void {
        const remote = self.remote orelse return error.NotConnected;
        if (!remote.canSend()) return error.NotConnected;
        const remaining = read.max_bytes -| read.data.items.len;
        if (remaining == 0) return error.TooBig;
        const len: u32 = @intCast(@min(remaining, REMOTE_FILE_READ_CHUNK));
        read.received_data = false;
        try remote.conn.queueJson(.fs_op, .{
            .req = read.token,
            .op = "read",
            .path = read.path,
            .off = @as(u64, @intCast(read.data.items.len)),
            .len = len,
        });
        self.armRemoteWriteWatch();
    }

    fn remoteFileReadTick(user: ?*anyopaque) callconv(.c) c.gboolean {
        const drain: *DrainHandle = @ptrCast(@alignCast(user.?));
        if (!drain.alive.load(.acquire)) return 0;
        const self = drain.terminal orelse return 0;
        const remote = self.remote orelse return 0;
        const now = clock.nowMs();
        var i: usize = 0;
        while (i < remote.fs_reads.items.len) {
            if (now < remote.fs_reads.items[i].deadline_ms) {
                i += 1;
                continue;
            }
            self.finishRemoteFileRead(i, .{ .failure = "remote asset read timed out" });
        }
        if (remote.fs_reads.items.len == 0) {
            remote.fs_read_timer = 0;
            return 0;
        }
        return 1;
    }

    /// Cancel a pending ranged read without invoking its callback.
    pub fn cancelRemoteFileRead(self: *Terminal, token: u32) void {
        const remote = self.remote orelse return;
        for (remote.fs_reads.items, 0..) |read, i| {
            if (read.token != token) continue;
            _ = remote.fs_reads.orderedRemove(i);
            read.deinit();
            self.stopRemoteFileReadTimerIfIdle();
            return;
        }
    }

    fn cancelRemoteFileReads(self: *Terminal) void {
        const remote = self.remote orelse return;
        while (remote.fs_reads.items.len > 0) {
            const read = remote.fs_reads.pop().?;
            read.deinit();
        }
        self.stopRemoteFileReadTimerIfIdle();
    }

    fn stopRemoteFileReadTimerIfIdle(self: *Terminal) void {
        const remote = self.remote orelse return;
        if (remote.fs_reads.items.len != 0 or remote.fs_read_timer == 0) return;
        _ = c.g_source_remove(remote.fs_read_timer);
        remote.fs_read_timer = 0;
    }

    /// Preserve the pane and frozen screen while reattaching its durable session.
    fn transportLost(self: *Terminal, reason: []const u8) void {
        const remote = self.remote orelse return;
        if (!remote.isLive()) return;
        remote.connected = false;
        if (remote.watch_id != 0) {
            _ = c.g_source_remove(remote.watch_id);
            remote.watch_id = 0;
        }
        if (remote.write_watch_id != 0) {
            _ = c.g_source_remove(remote.write_watch_id);
            remote.write_watch_id = 0;
        }
        if (remote.idle_kick_id != 0) {
            _ = c.g_source_remove(remote.idle_kick_id);
            remote.idle_kick_id = 0;
        }
        remote.bumpPanelGeneration();
        if (self.on_panel_work_cancel) |cancel| cancel(self);
        remote.conn.deinit();
        remote.pending_record = 0;
        self.failPendingTicket();
        self.cancelRemoteFileReads();
        self.cancelUploads();
        self.cancelDownload();
        self.destroyAllChans();
        remote.predictor.pending.clearRetainingCapacity();
        remote.predictor.overlay.clearRetainingCapacity();
        self.syncPredictions();
        // Without a lifetime id there is no way to tell this session apart
        // from a later one that reused its name, so reattaching could silently
        // hand the pane a different shell. Only a daemon older than session
        // identity omits it; say that, since restarting it is the fix.
        if (!@import("mux/daemon.zig").validSessionOriginId(remote.origin_id)) {
            self.notifyConnectionState(.unavailable, 0);
            std.debug.print(
                "sketerm: mux session '{s}': {s}; this daemon reports no session lifetime id, " ++
                    "so reattaching cannot prove it is the same session - restart sketerm-mux to reconnect\n",
                .{ remote.session, reason },
            );
            self.remoteClosed("daemon predates session lifetime identity; reattach cannot be proven safe", true);
            return;
        }
        std.debug.print("sketerm: mux session '{s}': {s}; reconnecting\n", .{ remote.session, reason });
        self.notifyConnectionState(.lost, 0);
        self.startReconnectAttempt();
    }

    fn startReconnectAttempt(self: *Terminal) void {
        const remote = self.remote orelse return;
        if (!remote.awaitingReconnect() or remote.reconnect_job_active) return;
        if (remote.reconnect_timer != 0) {
            _ = c.g_source_remove(remote.reconnect_timer);
            remote.reconnect_timer = 0;
        }
        remote.bumpGeneration();
        const job = self.makeReconnectJob(false) orelse return self.scheduleReconnect();
        remote.reconnect_job_active = true;
        self.notifyConnectionState(.reconnecting, 0);
        const thread = std.Thread.spawn(.{}, reconnectThreadMain, .{job}) catch {
            remote.reconnect_job_active = false;
            job.destroy();
            return self.scheduleReconnect();
        };
        thread.detach();
    }

    /// A synchronous GUI action opens bare hosts over SSH, then moves the
    /// live attachment to UDP off the main loop when the host supports it.
    fn startTransportUpgrade(self: *Terminal) void {
        const remote = self.remote orelse return;
        if (!remote.isLive() or remote.upgrade_job_active) return;
        if (remote.conn.transport != .ssh) return;
        if (!remote.control_known) return;
        const host = remote.host orelse return;
        if (mux_client.RemoteSpec.parse(host).mode != .auto) return;
        remote.bumpGeneration();
        const job = self.makeReconnectJob(true) orelse return;
        remote.upgrade_job_active = true;
        const thread = std.Thread.spawn(.{}, reconnectThreadMain, .{job}) catch {
            remote.upgrade_job_active = false;
            job.destroy();
            return;
        };
        thread.detach();
    }

    fn makeReconnectJob(self: *Terminal, upgrade: bool) ?*ReconnectJob {
        const remote = self.remote orelse return null;
        if (!@import("mux/daemon.zig").validSessionOriginId(remote.origin_id)) return null;
        const a = std.heap.c_allocator;
        const job = a.create(ReconnectJob) catch return null;
        const session = a.dupe(u8, remote.session) catch {
            a.destroy(job);
            return null;
        };
        const host: ?[]u8 = if (remote.host) |h| a.dupe(u8, h) catch {
            a.free(session);
            a.destroy(job);
            return null;
        } else null;
        const port_range: []u8 = if (remote.port_range.len > 0) a.dupe(u8, remote.port_range) catch {
            if (host) |h| a.free(h);
            a.free(session);
            a.destroy(job);
            return null;
        } else &.{};
        const origin_id: []u8 = if (remote.origin_id.len > 0) a.dupe(u8, remote.origin_id) catch {
            if (port_range.len > 0) a.free(port_range);
            if (host) |h| a.free(h);
            a.free(session);
            a.destroy(job);
            return null;
        } else &.{};
        const pending_rename: ?[]u8 = if (remote.pending_rename) |name| a.dupe(u8, name) catch {
            if (origin_id.len > 0) a.free(origin_id);
            if (port_range.len > 0) a.free(port_range);
            if (host) |h| a.free(h);
            a.free(session);
            a.destroy(job);
            return null;
        } else null;
        job.* = .{
            .drain = self.drain,
            .generation = remote.reconnect_generation,
            .host = host,
            .port_range = port_range,
            .session = session,
            .origin_id = origin_id,
            .pending_rename = pending_rename,
            .read_only = remote.read_only,
            .control = self.has_control or remote.force_control,
            .upgrade = upgrade,
        };
        return job;
    }

    fn reconnectThreadMain(job: *ReconnectJob) void {
        const a = std.heap.c_allocator;
        var conn = if (job.upgrade) blk: {
            const host = mux_client.RemoteSpec.parse(job.host orelse return reconnectHandback(job)).host;
            break :blk mux_client.Conn.connectUdp(a, host, if (job.port_range.len > 0) job.port_range else null) catch
                return reconnectHandback(job);
        } else reconnectConnect(a, job) catch return reconnectHandback(job);
        var conn_owned = true;
        defer if (conn_owned) conn.deinit();
        const attach_control = job.control and !job.upgrade;
        const snapshot = reconnectAttach(&conn, job.session, job.origin_id, job.read_only, attach_control) catch |err| blk: {
            if (err == error.DaemonError and std.mem.eql(u8, conn.lastErr(), "no such session")) {
                if (job.pending_rename) |name| {
                    const renamed = reconnectAttach(&conn, name, job.origin_id, job.read_only, attach_control) catch |rename_err| {
                        if (rename_err == error.DaemonError and std.mem.eql(u8, conn.lastErr(), "no such session"))
                            job.session_missing = true;
                        if (rename_err == error.DaemonError and std.mem.eql(u8, conn.lastErr(), "session origin identity changed"))
                            job.identity_mismatch = true;
                        return reconnectHandback(job);
                    };
                    job.rename_applied = true;
                    break :blk renamed;
                }
                job.session_missing = true;
            }
            if (err == error.DaemonError and std.mem.eql(u8, conn.lastErr(), "session origin identity changed"))
                job.identity_mismatch = true;
            return reconnectHandback(job);
        };
        job.snapshot = snapshot.payload;
        job.conn = conn;
        conn_owned = false;
        reconnectHandback(job);
    }

    fn reconnectConnect(a: std.mem.Allocator, job: *const ReconnectJob) !mux_client.Conn {
        const host = job.host orelse return mux_client.Conn.connectLocalAutostart(a);
        if (std.mem.startsWith(u8, host, "sock:")) return mux_client.Conn.connectProbed(a, host[5..]);
        return mux_client.Conn.connectRemote(a, host, if (job.port_range.len > 0) job.port_range else null);
    }

    fn reconnectAttach(conn: *mux_client.Conn, session: []const u8, origin_id: []const u8, read_only: bool, control: bool) !mux_client.Conn.OwnedFrame {
        if (!@import("mux/daemon.zig").validSessionOriginId(origin_id)) return error.MissingOriginId;
        try conn.sendAttach(session, .{
            .origin_id = origin_id,
            .kind = "gui",
            .read_only = read_only,
            .control = control,
            .panel_rpc = conn.panel_rpc,
        });
        return (try conn.recvGuiAttachFor(30_000)).snapshot;
    }

    fn reconnectHandback(job: *ReconnectJob) void {
        _ = c.g_idle_add(@ptrCast(&reconnectDone), @ptrCast(job));
    }

    fn reconnectDone(user: ?*anyopaque) callconv(.c) c.gboolean {
        const job: *ReconnectJob = @ptrCast(@alignCast(user.?));
        defer job.destroy();
        if (!job.drain.alive.load(.acquire)) return 0;
        const self = job.drain.terminal orelse return 0;
        const remote = self.remote orelse return 0;
        if (remote.reconnect_generation != job.generation) {
            if (job.upgrade) remote.upgrade_job_active = false;
            return 0;
        }
        if (job.upgrade) remote.upgrade_job_active = false else remote.reconnect_job_active = false;
        if (job.upgrade) return self.finishTransportUpgrade(job);
        if (!remote.awaitingReconnect()) return 0;
        if (job.session_missing or job.identity_mismatch) {
            self.notifyConnectionState(.unavailable, 0);
            std.debug.print("sketerm: mux session '{s}': {s}\n", .{
                remote.session,
                if (job.identity_mismatch) "lifetime identity changed; refusing same-name replacement" else "no longer available",
            });
            return 0;
        }
        if (job.conn == null) {
            self.scheduleReconnect();
            return 0;
        }
        const snapshot = job.snapshot orelse {
            self.scheduleReconnect();
            return 0;
        };
        self.applyRemoteSnapshot(snapshot) catch {
            self.scheduleReconnect();
            return 0;
        };
        remote.connected = true;
        remote.retry_delay_ms = 1000;
        if (!self.installReattachedConn(remote, job)) return 0;
        self.notifyConnectionState(.connected, 0);
        std.debug.print("sketerm: mux session '{s}': reattached over {s}\n", .{ remote.session, @tagName(remote.conn.transport) });
        return 0;
    }

    /// Commit a rename the reconnect attach already proved applied
    /// daemon-side (the OLD name was gone, the pending one attached).
    fn commitReattachRename(self: *Terminal, remote: *Remote) void {
        const renamed = remote.pending_rename orelse return;
        remote.pending_rename = null;
        self.allocator.free(remote.session);
        remote.session = renamed;
        self.notifySessionRenamed(renamed);
    }

    fn notifySessionRenamed(self: *Terminal, name: []const u8) void {
        if (self.on_panel_origin_renamed) |f| f(self, name);
        if (self.on_session_renamed) |f| f(self.user_ctx, name);
    }

    /// Shared reattach epilogue: install the job's connection, commit or
    /// resend the pending rename, re-arm the watch and replay the latest
    /// resize. Returns false when a replayed write already lost the NEW
    /// transport (transportLost has then restarted the cycle).
    fn installReattachedConn(self: *Terminal, remote: *Remote, job: *ReconnectJob) bool {
        remote.conn = job.conn orelse return false;
        job.conn = null;
        if (job.rename_applied) self.commitReattachRename(remote);
        self.armRemoteWatch();
        self.sendPendingResize();
        if (!remote.connected) return false;
        if (!job.rename_applied) self.sendPendingRename();
        return remote.connected;
    }

    fn finishTransportUpgrade(self: *Terminal, job: *ReconnectJob) c.gboolean {
        const remote = self.remote orelse return 0;
        if (!remote.isLive() or job.session_missing) return 0;
        if (remote.upload != null or remote.download != null or remote.pending_record != 0) return 0;
        if (job.control) {
            if (job.conn) |*candidate| {
                candidate.setNonBlocking();
                candidate.queueFrame(.control_req, "{\"op\":\"takeover\"}") catch return 0;
            }
        }
        if (job.conn == null) return 0;
        const snapshot = job.snapshot orelse return 0;
        self.applyRemoteSnapshot(snapshot) catch return 0;
        if (!remote.isLive()) return 0;
        if (remote.watch_id != 0) {
            _ = c.g_source_remove(remote.watch_id);
            remote.watch_id = 0;
        }
        if (remote.idle_kick_id != 0) {
            _ = c.g_source_remove(remote.idle_kick_id);
            remote.idle_kick_id = 0;
        }
        self.destroyAllChans();
        remote.conn.queueFrame(.detach, "") catch {};
        remote.conn.deinit();
        if (!self.installReattachedConn(remote, job)) return 0;
        std.debug.print("sketerm: mux session '{s}': upgraded to UDP\n", .{remote.session});
        return 0;
    }

    fn cancelTransportUpgrade(self: *Terminal) void {
        const remote = self.remote orelse return;
        if (!remote.upgrade_job_active) return;
        remote.bumpGeneration();
    }

    fn scheduleReconnect(self: *Terminal) void {
        const remote = self.remote orelse return;
        if (!remote.awaitingReconnect() or remote.reconnect_timer != 0) return;
        const delay = remote.retry_delay_ms;
        remote.retry_delay_ms = nextReconnectDelay(delay);
        self.notifyConnectionState(.retry_wait, @max(1, delay / 1000));
        remote.reconnect_timer = c.g_timeout_add(delay, @ptrCast(&reconnectTimer), @ptrCast(self.drain));
    }

    fn reconnectTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
        const drain: *DrainHandle = @ptrCast(@alignCast(user.?));
        if (!drain.alive.load(.acquire)) return 0;
        const self = drain.terminal orelse return 0;
        const remote = self.remote orelse return 0;
        remote.reconnect_timer = 0;
        self.startReconnectAttempt();
        return 0;
    }

    pub fn retryRemoteNow(self: *Terminal) void {
        const remote = self.remote orelse return;
        if (!remote.awaitingReconnect() or remote.reconnect_job_active) return;
        if (remote.reconnect_timer != 0) {
            _ = c.g_source_remove(remote.reconnect_timer);
            remote.reconnect_timer = 0;
        }
        self.startReconnectAttempt();
    }

    fn wireScreenSink(self: *Terminal) void {
        self.screen.sink = .{
            .ctx = @ptrCast(self),
            .on_title = sinkTitle,
            .on_bell = sinkBell,
            .on_write_pty = sinkWritePty,
            .on_clipboard_set = sinkClipboard,
            .on_clipboard_get = sinkClipboardGet,
            .on_glyph_coverage = sinkGlyphCoverage,
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
    fn remoteSocketCb(fd: c_int, condition: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Terminal = @ptrCast(@alignCast(user.?));
        const remote = self.remote orelse return 0;
        const from_fd_watch = fd >= 0;
        // HUP/ERR arrive TOGETHER with the final readable data when the
        // daemon flushes .exit/.gone and closes right after (an app
        // session's worker exits the moment its session dies). Declaring
        // the crash before draining threw the clean termination frame
        // away and painted a false crash face on every app quit — so
        // drain and peel first, close only after.
        _ = condition;
        var dead = false;

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
            remote.conn.rbuf.appendSlice(remote.conn.allocator, tmp[0..@intCast(n)]) catch break;
            // Keep reading until EAGAIN/EOF or the per-dispatch budget.
            // HUP can accompany more than eight chunks, including the
            // final clean .exit frame, so exhausting the budget is not EOF.
        }

        while (true) {
            const owned = remote.conn.takeFrame() catch {
                self.remoteClosed("protocol error", true);
                finishRemoteWatch(remote, from_fd_watch);
                return 0;
            } orelse break;
            // Sinks reached while applying an EVENTS frame can write back to
            // the transport. A failed write deinits conn.rbuf, so dispatch an
            // owned payload rather than borrowing from that buffer.
            const frame_allocator = remote.conn.allocator;
            self.handleRemoteFrame(.{ .ftype = owned.ftype, .payload = owned.payload });
            owned.deinit(frame_allocator);
            // A frame (e.g. .exit/.gone) may have run remoteClosed, which
            // zeroes watch_id on the assumption this callback returns
            // G_SOURCE_REMOVE. Stop touching `remote` and drop the source
            // NOW — returning G_SOURCE_CONTINUE here would leave a live fd
            // watch on a Terminal that detachPaneToShell is about to free.
            if (remote.closed) {
                finishRemoteWatch(remote, from_fd_watch);
                return 0;
            }
            if (!remote.connected) return 0;
        }

        if (dead) {
            self.transportLost("connection lost");
            return 0;
        }

        if (self.screen.dirty and !self.screen.sync_output) {
            if (self.on_render_request) |f| f(self.user_ctx);
        }
        return 1;
    }

    fn finishRemoteWatch(remote: *Remote, from_fd_watch: bool) void {
        const id = remote.watch_id;
        remote.watch_id = 0;
        if (!from_fd_watch and id != 0) _ = c.g_source_remove(id);
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
                self.applyRemoteSnapshot(frame.payload) catch return;
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
                if (std.mem.eql(u8, remote.session, pending)) {
                    self.allocator.free(pending);
                } else {
                    self.allocator.free(remote.session);
                    remote.session = pending;
                    self.notifySessionRenamed(pending);
                }
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
            .control_state => self.handleControlState(frame.payload),
            .play_state => self.handlePlayState(frame.payload),
            .panel_request => self.handlePanelRequest(frame.payload),
            .fs_data => self.handleRemoteFileData(frame.payload),
            .fs_reply => self.handleRemoteFileReply(frame.payload),
            .session_meta => {
                const Meta = struct {
                    cwd: []const u8 = "",
                    program: []const u8 = "",
                    name: []const u8 = "",
                    origin_name: []const u8 = "",
                    origin_id: []const u8 = "",
                };
                var parsed = std.json.parseFromSlice(Meta, self.allocator, frame.payload, .{
                    .ignore_unknown_fields = true,
                }) catch return;
                defer parsed.deinit();
                if (parsed.value.cwd.len > 0) self.setCwd(parsed.value.cwd);
                if (parsed.value.program.len > 0) self.setProgram(parsed.value.program);
                const remote = self.remote orelse return;
                if (parsed.value.origin_name.len > 0 and
                    !std.mem.eql(u8, remote.origin_name, parsed.value.origin_name))
                {
                    const origin = self.allocator.dupe(u8, parsed.value.origin_name) catch return;
                    self.allocator.free(remote.origin_name);
                    remote.origin_name = origin;
                }
                if (@import("mux/daemon.zig").validSessionOriginId(parsed.value.origin_id)) {
                    if (remote.origin_id.len == 0) {
                        remote.origin_id = self.allocator.dupe(u8, parsed.value.origin_id) catch return;
                    } else if (!std.mem.eql(u8, remote.origin_id, parsed.value.origin_id)) {
                        self.transportLost("session lifetime identity changed");
                        return;
                    }
                }
                if (parsed.value.name.len > 0 and
                    !std.mem.eql(u8, remote.session, parsed.value.name))
                {
                    const name = self.allocator.dupe(u8, parsed.value.name) catch return;
                    self.allocator.free(remote.session);
                    remote.session = name;
                    self.notifySessionRenamed(name);
                }
            },
            .file_data => self.downloadData(frame.payload),
            .udp_ticket => {
                const remote = self.remote orelse return;
                const cb = remote.pending_ticket_cb orelse return;
                const ctx = remote.pending_ticket_ctx;
                remote.pending_ticket_cb = null;
                remote.pending_ticket_ctx = null;
                cb(ctx, mux_client.parseUdpTicketReply(self.allocator, frame.payload));
            },
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

    fn handlePanelRequest(self: *Terminal, payload: []const u8) void {
        const envelope = mux_wire.decodePanelEnvelope(payload) catch return;
        const remote = self.remote orelse return;
        if (!remote.canSend()) return;
        if (self.on_panel_request) |dispatch| {
            dispatch(self.user_ctx, self, envelope.id, envelope.json);
        } else {
            self.replyPanelRequest(envelope.id, "{\"ok\":false,\"error\":\"receiving GUI attachment cannot host panels\"}");
        }
    }

    /// Queue one correlated panel response without blocking the GTK loop.
    pub fn replyPanelRequest(self: *Terminal, request_id: u64, response: []const u8) void {
        const remote = self.remote orelse return;
        if (!remote.canSend()) return;
        const json = std.mem.trimEnd(u8, response, "\r\n");
        if (json.len == 0) return;
        remote.conn.queuePanelReply(request_id, json) catch {
            self.transportLost("panel reply write failed");
            return;
        };
        self.armRemoteWriteWatch();
    }

    fn remoteFileReadIndex(self: *Terminal, token: u32) ?usize {
        const remote = self.remote orelse return null;
        for (remote.fs_reads.items, 0..) |read, i| if (read.token == token) return i;
        return null;
    }

    fn handleRemoteFileData(self: *Terminal, payload: []const u8) void {
        if (payload.len < 12) return;
        const token = std.mem.readInt(u32, payload[0..4], .little);
        const index = self.remoteFileReadIndex(token) orelse return;
        const remote = self.remote.?;
        const read = remote.fs_reads.items[index];
        const off = std.mem.readInt(u64, payload[4..12], .little);
        const chunk = payload[12..];
        if (off != read.data.items.len or chunk.len > REMOTE_FILE_READ_CHUNK or
            chunk.len > read.max_bytes -| read.data.items.len)
        {
            self.finishRemoteFileRead(index, .{ .failure = "malformed remote asset data" });
            return;
        }
        read.data.appendSlice(self.allocator, chunk) catch {
            self.finishRemoteFileRead(index, .{ .failure = "out of memory receiving remote asset" });
            return;
        };
        read.received_data = true;
    }

    fn handleRemoteFileReply(self: *Terminal, payload: []const u8) void {
        const Reply = struct {
            req: u32 = 0,
            ok: bool = false,
            @"error": []const u8 = "",
            size: u64 = 0,
            eof: bool = false,
            mtime_ns: i64 = 0,
            ino: u64 = 0,
        };
        var parsed = std.json.parseFromSlice(Reply, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        const reply = parsed.value;
        const index = self.remoteFileReadIndex(reply.req) orelse return;
        const remote = self.remote.?;
        const read = remote.fs_reads.items[index];
        if (!reply.ok) {
            self.finishRemoteFileRead(index, .{ .failure = if (reply.@"error".len > 0) reply.@"error" else "remote asset read failed" });
            return;
        }
        if (reply.size > read.max_bytes) {
            self.finishRemoteFileRead(index, .{ .failure = "remote asset exceeds the per-file byte limit" });
            return;
        }
        if (!read.identity_set) {
            read.identity_set = true;
            read.size = reply.size;
            read.mtime_ns = reply.mtime_ns;
            read.ino = reply.ino;
        } else if (read.size != reply.size or read.mtime_ns != reply.mtime_ns or read.ino != reply.ino) {
            self.finishRemoteFileRead(index, .{ .failure = "remote asset changed while it was being read" });
            return;
        }
        if (read.data.items.len > read.size) {
            self.finishRemoteFileRead(index, .{ .failure = "remote asset size changed while it was being read" });
            return;
        }
        if (reply.eof or read.data.items.len == read.size) {
            if (read.data.items.len != read.size) {
                self.finishRemoteFileRead(index, .{ .failure = "remote asset ended before its advertised size" });
                return;
            }
            const bytes = read.data.toOwnedSlice(self.allocator) catch {
                self.finishRemoteFileRead(index, .{ .failure = "out of memory finalizing remote asset" });
                return;
            };
            self.finishRemoteFileRead(index, .{ .success = .{
                .bytes = bytes,
                .size = read.size,
                .mtime_ns = read.mtime_ns,
                .ino = read.ino,
            } });
            return;
        }
        if (!read.received_data) {
            self.finishRemoteFileRead(index, .{ .failure = "remote asset read made no progress" });
            return;
        }
        self.sendRemoteFileRange(read) catch {
            self.finishRemoteFileRead(index, .{ .failure = "could not request the next remote asset range" });
        };
    }

    fn finishRemoteFileRead(self: *Terminal, index: usize, result: RemoteFileResult) void {
        const remote = self.remote orelse return;
        if (index >= remote.fs_reads.items.len) return;
        const read = remote.fs_reads.orderedRemove(index);
        const callback = read.callback;
        const ctx = read.ctx;
        const token = read.token;
        read.deinit();
        self.stopRemoteFileReadTimerIfIdle();
        callback(ctx, self, token, result);
    }

    fn applyRemoteSnapshot(self: *Terminal, payload: []const u8) !void {
        const envelope = try mux_snapshot.peelEnvelope(payload);
        const fresh = try mux_snapshot.restore(self.allocator, &self.pool, envelope.body);
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
        self.hash_valid = false;
        self.activity_seq +%= 1;
        if (self.remote) |remote| {
            remote.predictor.pending.clearRetainingCapacity();
            remote.predictor.overlay.clearRetainingCapacity();
        }
        self.replayRetainedImages();
        if (self.on_render_request) |f| f(self.user_ctx);
    }

    /// Ask the daemon to rename this remote session. The new name is
    /// committed (and `on_session_renamed` fired) only when the OK
    /// frame comes back.
    pub fn renameSession(self: *Terminal, new_name: []const u8) void {
        const remote = self.remote orelse return;
        if (!remote.canSend()) return;
        self.cancelTransportUpgrade();
        if (remote.pending_rename != null or remote.pending_record != 0) return;
        if (new_name.len == 0 or new_name.len > 64) return;
        if (std.mem.eql(u8, new_name, remote.session)) return;
        const pending = self.allocator.dupe(u8, new_name) catch return;
        if (remote.pending_rename) |old| self.allocator.free(old);
        remote.pending_rename = pending;
        self.sendPendingRename();
    }

    fn sendPendingRename(self: *Terminal) void {
        const remote = self.remote orelse return;
        if (!remote.canSend()) return;
        const pending = remote.pending_rename orelse return;
        remote.conn.sendJson(.rename, .{ .name = remote.session, .new_name = pending }) catch
            self.transportLost("rename write failed");
    }

    /// End the session after a clean daemon frame or an unrecoverable protocol error.
    fn remoteClosed(self: *Terminal, reason: []const u8, crashed: bool) void {
        const remote = self.remote orelse return;
        if (remote.closed) return;
        remote.closed = true;
        self.closePanelOrigin();
        self.failPendingTicket();
        self.cancelRemoteFileReads();
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
        if (!remote.canSend()) return;
        var hdr: [4]u8 = undefined;
        remote.conn.sendFrame(.chan_close, mux_wire.putChanHeader(&hdr, id)) catch
            self.transportLost("channel-close write failed");
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
            self.transportLost("audio transport write failed");
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
        if (!remote.canSend()) return;
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
            self.transportLost("audio transport write failed");
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
        if (!remote.canSend()) return;
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
            self.transportLost("upload request write failed");
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
        if (!remote.canSend() or remote.upload != up) {
            up.idle_id = 0;
            return 0; // G_SOURCE_REMOVE
        }
        remote.conn.flushQueued() catch {
            up.idle_id = 0;
            self.finishUpload(.failed, "connection lost");
            self.transportLost("upload write failed");
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
        if (!remote.canSend()) return;
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
            self.transportLost("download request write failed");
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
        if (!remote.canSend()) return;
        remote.list_xfer = remote.upload_next_id;
        remote.upload_next_id += 1;
        remote.conn.sendJson(.file_list, .{ .xfer = remote.list_xfer, .path = path }) catch
            self.transportLost("directory request write failed");
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
        if (!remote.canSend()) return;
        remote.conn.sendFrame(.app_list, "") catch self.transportLost("app-list write failed");
    }

    /// Start recording this session as an asciicast v2 file. The file
    /// is written by the DAEMON on its host — remote sessions record
    /// to a remote path. `recording` flips when the daemon acks.
    pub fn requestRecordStart(self: *Terminal, path: []const u8) void {
        const remote = self.remote orelse return;
        if (!remote.canSend()) return;
        self.cancelTransportUpgrade();
        if (remote.pending_rename != null or remote.pending_record != 0) return;
        remote.pending_record = 1;
        remote.conn.sendJson(.rec_start, .{ .path = path }) catch self.transportLost("record request write failed");
    }

    pub fn requestRecordStop(self: *Terminal) void {
        const remote = self.remote orelse return;
        if (!remote.canSend()) return;
        self.cancelTransportUpgrade();
        if (remote.pending_rename != null or remote.pending_record != 0) return;
        remote.pending_record = 2;
        remote.conn.sendFrame(.rec_stop, "") catch self.transportLost("record request write failed");
    }

    /// Ask this terminal's daemon for a UDP connection ticket (a
    /// single-use sibling listener a NEW client can dial with no ssh
    /// bootstrap). Returns false — callback never fired — when this
    /// connection can't broker one: not UDP transport, daemon too old,
    /// teardown, or a mint already in flight. On true the callback
    /// fires exactly once (frame, transport loss, or teardown).
    pub fn requestUdpTicket(
        self: *Terminal,
        ctx: ?*anyopaque,
        cb: *const fn (ctx: ?*anyopaque, ticket: ?mux_client.UdpTicket) void,
    ) bool {
        const remote = self.remote orelse return false;
        if (!remote.canSend() or remote.destroying) return false;
        if (remote.conn.transport != .udp or !remote.conn.udp_tickets) return false;
        if (remote.pending_ticket_cb != null) return false;
        const range: ?[]const u8 = if (remote.port_range.len > 0) remote.port_range else null;
        remote.pending_ticket_cb = cb;
        remote.pending_ticket_ctx = ctx;
        remote.conn.sendJson(.udp_ticket_req, .{ .range = range }) catch {
            // transportLost fails the slot (fires cb with null), so
            // the contract holds even on an immediate write failure.
            self.transportLost("udp ticket request write failed");
        };
        return true;
    }

    /// Abandon an in-flight ticket request WITHOUT firing its callback
    /// (the requester timed out and freed its context; a late frame
    /// must find the slot empty). No-op unless `ctx` still owns it.
    pub fn cancelUdpTicket(self: *Terminal, ctx: ?*anyopaque) void {
        const remote = self.remote orelse return;
        if (remote.pending_ticket_cb == null) return;
        if (remote.pending_ticket_ctx != ctx) return;
        remote.pending_ticket_cb = null;
        remote.pending_ticket_ctx = null;
    }

    /// Resolve an in-flight ticket request with null (transport loss,
    /// session end, teardown). Idempotent — the slot empties first.
    fn failPendingTicket(self: *Terminal) void {
        const remote = self.remote orelse return;
        const cb = remote.pending_ticket_cb orelse return;
        const ctx = remote.pending_ticket_ctx;
        remote.pending_ticket_cb = null;
        remote.pending_ticket_ctx = null;
        cb(ctx, null);
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

    /// Controller-lease state for this session. Only the controller's
    /// seat input reaches a forwarded app, so a viewer that did NOT get
    /// the lease must be told — otherwise its clicks silently do
    /// nothing and the app looks hung. Deliberately a log line, not a
    /// dialog: shared-seat arbitration is a rare, advanced situation.
    fn handleControlState(self: *Terminal, payload: []const u8) void {
        const Msg = struct {
            controller: bool = true,
            read_only: bool = false,
            controller_label: []const u8 = "",
            viewers: u32 = 0,
        };
        const parsed = std.json.parseFromSlice(Msg, self.allocator, payload, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return;
        defer parsed.deinit();
        const was = self.has_control;
        if (self.remote) |remote| {
            remote.read_only = parsed.value.read_only;
            remote.force_control = parsed.value.controller;
            remote.control_known = true;
        }
        self.has_control = parsed.value.controller;
        const label = parsed.value.controller_label;
        const holder_changed = !std.mem.eql(
            u8,
            self.control_holder[0..self.control_holder_len],
            label[0..@min(label.len, self.control_holder.len)],
        );
        self.control_holder_len = @min(label.len, self.control_holder.len);
        @memcpy(self.control_holder[0..self.control_holder_len], label[0..self.control_holder_len]);
        const viewers_changed = self.peer_viewers != parsed.value.viewers;
        self.peer_viewers = parsed.value.viewers;
        self.startTransportUpgrade();
        // The titlebar lease chip reads has_control/holder/viewers, so
        // any roster movement must reach the on_peers sink, not just
        // lease flips.
        if (was != self.has_control or holder_changed or viewers_changed) {
            if (self.on_peers) |f| f(self.user_ctx);
        }
        if (was == self.has_control) return;
        const session = if (self.remote) |r| r.session else "?";
        if (self.has_control) {
            std.debug.print("sketerm: session '{s}': this window now controls the app\n", .{session});
        } else {
            std.debug.print(
                "sketerm: session '{s}': VIEW ONLY — '{s}' controls the app ({d} viewers). Input from this window is ignored.\n",
                .{ session, self.control_holder[0..self.control_holder_len], parsed.value.viewers },
            );
        }
    }

    /// JSON shape of a daemon play_state frame. Marker tuples arrive as
    /// [[ms,"label"],...].
    const PlayStateMsg = struct {
        state: []const u8 = "",
        position_ms: u64 = 0,
        duration_ms: ?u64 = null,
        speed: f64 = 1.0,
        markers: []const struct { u64, []const u8 } = &.{},
    };

    fn playKindFromName(name: []const u8) ?PlayState.Kind {
        inline for (@typeInfo(PlayState.Kind).@"enum".fields) |f| {
            if (std.mem.eql(u8, name, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }

    fn handlePlayState(self: *Terminal, payload: []const u8) void {
        const parsed = std.json.parseFromSlice(PlayStateMsg, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        const m = parsed.value;
        // Unknown state names (a future daemon) drop the frame rather
        // than mislabel it — the next known state resyncs everything.
        const kind = playKindFromName(m.state) orelse return;
        var st: PlayState = .{
            .kind = kind,
            .position_ms = m.position_ms,
            .duration_ms = m.duration_ms,
            .speed = m.speed,
        };
        // Stored copy carries no markers (their strings live in the
        // parsed arena, freed on return).
        self.last_play_state = st;
        const f = self.on_play_state orelse return;
        var markers = self.allocator.alloc(PlayState.Marker, m.markers.len) catch return;
        defer self.allocator.free(markers);
        for (m.markers, 0..) |t, i| markers[i] = .{ .ms = t[0], .label = t[1] };
        st.markers = markers;
        f(self.user_ctx, st);
    }

    /// Render a play_control payload into `buf`. Only `.seek` reads
    /// `ms` and only `.speed` reads `speed`.
    fn playControlPayload(buf: []u8, op: PlayOp, ms: u64, speed: f64) ?[]const u8 {
        return switch (op) {
            .seek => std.fmt.bufPrint(buf, "{{\"op\":\"seek\",\"ms\":{d}}}", .{ms}) catch null,
            .speed => std.fmt.bufPrint(buf, "{{\"op\":\"speed\",\"speed\":{d}}}", .{speed}) catch null,
            else => std.fmt.bufPrint(buf, "{{\"op\":\"{s}\"}}", .{@tagName(op)}) catch null,
        };
    }

    /// Send a play_control frame to the attached cast session. No-op on
    /// daemons that don't advertise cast_playback (they would log an
    /// unknown frame) and on non-remote/closed terminals.
    pub fn sendPlayControl(self: *Terminal, op: PlayOp, ms: u64, speed: f64) void {
        const remote = self.remote orelse return;
        if (!remote.canSend()) return;
        if (!remote.conn.cast_playback) return;
        var buf: [96]u8 = undefined;
        const payload = playControlPayload(&buf, op, ms, speed) orelse return;
        remote.conn.sendFrame(.play_control, payload) catch {
            self.transportLost("play control write failed");
        };
    }

    /// Ask the daemon for the session's controller lease. `force` evicts
    /// the current holder; without it a held lease is left alone.
    pub fn requestControl(self: *Terminal, force: bool) void {
        const remote = self.remote orelse return;
        if (!remote.canSend()) return;
        self.cancelTransportUpgrade();
        remote.force_control = force;
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        std.json.Stringify.value(
            .{ .op = if (force) "takeover" else "acquire" },
            .{},
            &aw.writer,
        ) catch return;
        remote.conn.sendFrame(.control_req, aw.written()) catch {
            self.transportLost("control request write failed");
        };
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
        host.on_window = wsappFirstWindow;
        host.window_ctx = wa;
        remote.wsapps.append(self.allocator, wa) catch {
            host.destroy();
            self.allocator.destroy(wa);
            self.sendChanClose(id);
            return;
        };
    }

    /// First remote window of a window-stream channel — the winstream
    /// twin of `nappFirstWindow`. This used to be set at channel OPEN,
    /// which broke the same invariant the native side documents: an app
    /// that exits before presenting anything (a macOS system binary
    /// SIGKILLed by launch constraints, say) then counted as having
    /// shown a window, so the session was dropped silently instead of
    /// materializing the held log tab that explains the exit.
    fn wsappFirstWindow(ctx: ?*anyopaque) void {
        const wa = @import("util/cast.zig").userData(WsApp, ctx);
        const t = wa.terminal;
        const remote = t.remote orelse return;
        if (remote.app_window_opened) return;
        remote.app_window_opened = true;
        if (t.on_app_window) |f| f(t.user_ctx);
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
        if (!remote.canSend()) return;
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
            self.transportLost("window transport write failed");
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
        // xdg-foreign relations name windows session-wide as (app
        // channel id, surface id). Every app channel of this session
        // rides THIS mux connection, so the Terminal is exactly the
        // scope in which the connection half resolves.
        host.conn_id = id;
        host.foreign_ctx = na;
        host.foreign_resolve = nappResolveForeign;
        host.foreign_changed = nappForeignChanged;
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

    /// Resolve a session-wide window identity for an AppHost holding a
    /// cross-connection xdg-foreign parent. The exporting connection is
    /// another `wayland_native` channel of this same session, so its
    /// AppHost is a sibling in `remote.napps`.
    fn nappResolveForeign(ctx: ?*anyopaque, conn: u32, surface: u32) ?*@import("c.zig").c.GtkWindow {
        const na = @import("util/cast.zig").userData(NApp, ctx);
        const remote = na.terminal.remote orelse return null;
        for (remote.napps.items) |other| {
            if (other.id == conn) return other.host.windowForSurface(surface);
        }
        return null;
    }

    /// One connection's toplevel appeared or vanished: sibling
    /// connections may have dialogs latched onto it.
    fn nappForeignChanged(ctx: ?*anyopaque, conn: u32, surface: u32, gone: bool) void {
        const na = @import("util/cast.zig").userData(NApp, ctx);
        const remote = na.terminal.remote orelse return;
        for (remote.napps.items) |other| {
            if (other.id == conn) continue;
            other.host.refreshForeignChildrenOf(.{ .conn = conn, .surface = surface }, gone);
        }
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
        if (!remote.canSend()) return;
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
            self.transportLost("app transport write failed");
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

    /// Whether this session has an uncorked remote-audio voice locally.
    pub fn audioPlaying(self: *Terminal) bool {
        if (comptime builtin.os.tag != .linux) return false;
        const remote = self.remote orelse return false;
        for (remote.aapps.items) |aa| {
            if (aa.sink.playing()) return true;
        }
        return false;
    }

    /// Snapshot of this session's remote playback streams; caller frees only the slice.
    pub fn audioInfos(self: *Terminal, allocator: std.mem.Allocator) []@import("mux/pulse.zig").AudioInfo {
        const AudioInfo = @import("mux/pulse.zig").AudioInfo;
        if (comptime builtin.os.tag != .linux) return &.{};
        const remote = self.remote orelse return &.{};
        var out: std.ArrayList(AudioInfo) = .empty;
        for (remote.aapps.items) |aa| {
            const infos = aa.sink.audioInfos(allocator);
            defer allocator.free(infos);
            out.appendSlice(allocator, infos) catch break;
        }
        return out.toOwnedSlice(allocator) catch {
            out.deinit(allocator);
            return &.{};
        };
    }

    /// Route parser replies, input and focus reports to the mux daemon.
    pub fn writeRaw(self: *Terminal, bytes: []const u8) void {
        const r = self.remote orelse return;
        if (!r.sendInput(bytes) and r.canSend())
            self.transportLost("input write failed");
    }

    /// Resize, routed to the mux daemon. The daemon answers with a fresh
    /// snapshot, so the pane skips a local screen.resize (the snapshot
    /// replaces the grid wholesale).
    pub fn requestResize(self: *Terminal, rows: u16, cols: u16) void {
        const r = self.remote orelse return;
        r.pending_rows = rows;
        r.pending_cols = cols;
        if (!r.canSend()) return;
        self.sendPendingResize();
    }

    fn sendPendingResize(self: *Terminal) void {
        const r = self.remote orelse return;
        if (!r.canSend() or r.pending_rows == 0 or r.pending_cols == 0) return;
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], r.pending_rows, .little);
        std.mem.writeInt(u16, payload[2..4], r.pending_cols, .little);
        r.conn.sendFrame(.resize, &payload) catch {
            self.transportLost("resize write failed");
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

    fn sinkGlyphCoverage(ctx: ?*anyopaque, cp: u32) bool {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        if (self.on_glyph_coverage) |f| return f(self.user_ctx, cp);
        return false;
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
        self.replaceCwd(decoded);
    }

    fn setCwd(self: *Terminal, cwd: []const u8) void {
        const owned = self.allocator.dupe(u8, cwd) catch return;
        self.replaceCwd(owned);
    }

    /// Foreground process name, or "" while unknown.
    pub fn program(self: *const Terminal) []const u8 {
        return self.program_buf[0..self.program_len];
    }

    fn setProgram(self: *Terminal, name: []const u8) void {
        const len: u8 = @intCast(@min(name.len, self.program_buf.len));
        if (len == self.program_len and std.mem.eql(u8, self.program_buf[0..len], name[0..len])) return;
        @memcpy(self.program_buf[0..len], name[0..len]);
        self.program_len = len;
        if (self.on_program_changed) |f| f(self.user_ctx, self.program_buf[0..len]);
    }

    fn replaceCwd(self: *Terminal, owned: []u8) void {
        if (self.cwd) |old| self.allocator.free(old);
        self.cwd = owned;
        if (self.on_cwd_changed) |f| f(self.user_ctx, owned);
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
        self.closePanelOrigin();
        self.clearSinksForRewire();
    }

    /// Fence callbacks while ownership moves from a tabless AppSession to a
    /// Pane, without treating the still-live mux attachment as torn down.
    pub fn clearSinksForRewire(self: *Terminal) void {
        self.user_ctx = null;
        self.on_title = null;
        self.on_cwd_changed = null;
        self.on_program_changed = null;
        self.on_clipboard_set = null;
        self.on_clipboard_get = null;
        self.on_glyph_coverage = null;
        self.on_render_request = null;
        self.on_crashed = null;
        self.on_connection_state = null;
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
        // A pending udp-ticket callback's ctx is requester-owned heap
        // memory (never pane memory); resolving it here lets the
        // requester free it instead of leaking past the fence.
        self.failPendingTicket();
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
        self.on_play_state = null;
        self.on_panel_request = null;
        self.broadcast_sink = null;
        self.broadcast_ctx = null;
    }

    /// Stop daemon routing before the GUI registry exposes a surviving viewer.
    fn retireAttachmentForTeardown(self: *Terminal) void {
        const remote = self.remote orelse return;
        if (remote.closed or remote.destroying) return;
        remote.destroying = true;
        if (remote.watch_id != 0) {
            _ = c.g_source_remove(remote.watch_id);
            remote.watch_id = 0;
        }
        if (remote.write_watch_id != 0) {
            _ = c.g_source_remove(remote.write_watch_id);
            remote.write_watch_id = 0;
        }
        if (remote.idle_kick_id != 0) {
            _ = c.g_source_remove(remote.idle_kick_id);
            remote.idle_kick_id = 0;
        }
        if (!remote.connected) return;

        // Preserve stream framing when possible. If an older queued frame is
        // stuck, closing the transport is still an immediate daemon-side
        // presenter retirement and is safer than discarding a partial frame.
        remote.conn.flushQueuedFor(remote.conn.write_timeout_ms) catch {};
        if (remote.conn.wbuf.items.len == 0) {
            if (remote.ephemeral) {
                remote.conn.sendKill(.{
                    .name = remote.session,
                    .origin_id = remote.origin_id,
                }) catch {};
            } else {
                remote.conn.sendFrame(.detach, "") catch {};
            }
        }
        remote.conn.deinit();
        remote.connected = false;
    }

    /// Permanently retire this Terminal's relay origin exactly once.
    pub fn closePanelOrigin(self: *Terminal) void {
        self.retireAttachmentForTeardown();
        self.drain.panel_assets_live.store(false, .release);
        if (self.on_panel_work_cancel) |cancel| cancel(self);
        self.on_panel_work_cancel = null;
        self.on_panel_origin_renamed = null;
        const close = self.on_panel_origin_close orelse return;
        self.on_panel_origin_close = null;
        close(self);
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
        self.closePanelOrigin();
        if (self.remote) |remote| {
            // Detach, don't kill: the session keeps running in the
            // daemon — that's the entire point.
            self.failPendingTicket();
            self.drain.terminal = null;
            self.drain.alive.store(false, .release);
            if (remote.watch_id != 0) _ = c.g_source_remove(remote.watch_id);
            if (remote.write_watch_id != 0) _ = c.g_source_remove(remote.write_watch_id);
            if (remote.idle_kick_id != 0) _ = c.g_source_remove(remote.idle_kick_id);
            self.cancelRemoteFileReads();
            remote.fs_reads.deinit(self.allocator);
            if (remote.reconnect_timer != 0) _ = c.g_source_remove(remote.reconnect_timer);
            if (remote.expire_timer != 0) _ = c.g_source_remove(remote.expire_timer);
            self.cancelUploads();
            self.cancelDownload();
            remote.upload_queue.deinit(self.allocator);
            self.destroyAllChans();
            remote.napps.deinit(self.allocator);
            remote.wsapps.deinit(self.allocator);
            remote.aapps.deinit(self.allocator);
            remote.predictor.deinit();
            if (remote.connected) remote.conn.deinit();
            if (remote.host) |h| self.allocator.free(h);
            if (remote.port_range.len > 0) self.allocator.free(remote.port_range);
            if (remote.pending_rename) |p| self.allocator.free(p);
            self.allocator.free(remote.session);
            self.allocator.free(remote.origin_name);
            if (remote.origin_id.len > 0) self.allocator.free(remote.origin_id);
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

test "reconnect backoff doubles and caps at thirty seconds" {
    var delay: u32 = 1000;
    const expected = [_]u32{ 2000, 4000, 8000, 16_000, 30_000, 30_000 };
    for (expected) |want| {
        delay = nextReconnectDelay(delay);
        try std.testing.expectEqual(want, delay);
    }
}

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
    term.on_panel_origin_close = null;
    term.on_panel_work_cancel = null;
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
    // clearSinks resolves a pending udp-ticket request; the slot must
    // be EMPTY, not `undefined` garbage, or it calls through it.
    remote.pending_ticket_cb = null;
    remote.pending_ticket_ctx = null;

    var drain = DrainHandle{};
    var term: Terminal = undefined;
    term.drain = &drain;
    term.allocator = alloc;
    term.remote = &remote;
    term.peer_drivers = 0;
    term.on_app_window = null;
    term.on_panel_origin_close = null;
    term.on_panel_work_cancel = null;
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

test "clearSinks retires the mux presenter before closing its GUI origin" {
    const a = std.testing.allocator;
    var pair: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&pair));

    var peer = mux_client.Conn{
        .allocator = a,
        .fd = pair[1],
        .proto = mux_wire.PROTO_VERSION,
        .panel_rpc = mux_wire.PANEL_RPC_VERSION,
    };
    defer peer.deinit();
    var session = [_]u8{ 'r', 'e', 't', 'i', 'r', 'e' };
    var remote = Terminal.Remote{
        .conn = .{
            .allocator = a,
            .fd = pair[0],
            .proto = mux_wire.PROTO_VERSION,
            .panel_rpc = mux_wire.PANEL_RPC_VERSION,
        },
        .session = &session,
        .origin_name = &session,
        .predictor = undefined,
    };

    const Captured = struct {
        peer: *mux_client.Conn,
        saw_detach: bool = false,
        transport_retired: bool = false,

        fn close(terminal: *Terminal) void {
            const self: *@This() = @ptrCast(@alignCast(terminal.user_ctx.?));
            const r = terminal.remote.?;
            self.transport_retired = r.destroying and !r.connected and r.conn.fd == -1;
            const frame = self.peer.recvFrame() catch return;
            defer frame.deinit(self.peer.allocator);
            self.saw_detach = frame.ftype == .detach;
        }
    };
    var captured = Captured{ .peer = &peer };
    var drain = DrainHandle{};
    var term: Terminal = undefined;
    term.allocator = a;
    term.remote = &remote;
    term.drain = &drain;
    term.panel_scope_ctx = null;
    term.user_ctx = &captured;
    term.on_panel_origin_close = Captured.close;
    term.on_panel_work_cancel = null;
    term.on_panel_origin_renamed = null;
    term.on_panel_request = null;
    drain.terminal = &term;

    term.clearSinks();
    try std.testing.expect(captured.transport_retired);
    try std.testing.expect(captured.saw_detach);
    try std.testing.expectEqual(@as(?*anyopaque, null), term.user_ctx);
}

/// True for `?*const fn (...) ...` field types (the external-sink shape).
fn isSinkField(comptime T: type) bool {
    const opt = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => return false,
    };
    const ptr = switch (@typeInfo(opt)) {
        .pointer => |p| p.child,
        else => return false,
    };
    return @typeInfo(ptr) == .@"fn";
}

test "play_state parses state, null duration and marker tuples" {
    const a = std.testing.allocator;

    const Captured = struct {
        var st: ?Terminal.PlayState = null;
        var marker_ms: u64 = 0;
        var marker_label_ok = false;
        fn on(_: ?*anyopaque, s: Terminal.PlayState) void {
            st = s;
            if (s.markers.len == 1) {
                marker_ms = s.markers[0].ms;
                marker_label_ok = std.mem.eql(u8, s.markers[0].label, "half way");
            }
        }
    };

    var term: Terminal = undefined;
    term.allocator = a;
    term.user_ctx = null;
    term.last_play_state = null;
    term.on_play_state = Captured.on;

    term.handlePlayState(
        \\{"state":"playing","position_ms":1234,"duration_ms":null,"speed":1.5,
        \\ "markers":[[1500,"half way"]]}
    );
    const got = Captured.st orelse return error.NoCallback;
    try std.testing.expectEqual(Terminal.PlayState.Kind.playing, got.kind);
    try std.testing.expectEqual(@as(u64, 1234), got.position_ms);
    try std.testing.expectEqual(@as(?u64, null), got.duration_ms);
    try std.testing.expectEqual(@as(f64, 1.5), got.speed);
    try std.testing.expectEqual(@as(u64, 1500), Captured.marker_ms);
    try std.testing.expect(Captured.marker_label_ok);
    // Stored copy: same scalars, no markers (callback-scoped memory).
    const stored = term.last_play_state orelse return error.NoStore;
    try std.testing.expectEqual(@as(u64, 1234), stored.position_ms);
    try std.testing.expectEqual(@as(usize, 0), stored.markers.len);

    // A finished state with a known duration.
    Captured.st = null;
    term.handlePlayState("{\"state\":\"finished\",\"position_ms\":2000,\"duration_ms\":2000,\"speed\":1}");
    try std.testing.expectEqual(Terminal.PlayState.Kind.finished, Captured.st.?.kind);
    try std.testing.expectEqual(@as(?u64, 2000), Captured.st.?.duration_ms);

    // Unknown state names and garbage drop the frame (append-only wire).
    Captured.st = null;
    term.handlePlayState("{\"state\":\"warping\",\"position_ms\":9}");
    try std.testing.expect(Captured.st == null);
    term.handlePlayState("not json");
    try std.testing.expect(Captured.st == null);
}

test "play_control payloads carry op-specific fields only" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"op\":\"seek\",\"ms\":12500}",
        Terminal.playControlPayload(&buf, .seek, 12500, 1.0).?,
    );
    try std.testing.expectEqualStrings(
        "{\"op\":\"speed\",\"speed\":2}",
        Terminal.playControlPayload(&buf, .speed, 0, 2.0).?,
    );
    try std.testing.expectEqualStrings("{\"op\":\"pause\"}", Terminal.playControlPayload(&buf, .pause, 0, 1.0).?);
    try std.testing.expectEqualStrings("{\"op\":\"play\"}", Terminal.playControlPayload(&buf, .play, 0, 1.0).?);
    try std.testing.expectEqualStrings("{\"op\":\"restart\"}", Terminal.playControlPayload(&buf, .restart, 0, 1.0).?);
}

test "clearSinks nulls every on_* callback (reflection drift guard)" {
    // Regression: on_program_changed was added long after clearSinks and never
    // listed there, so a late session_meta frame dispatched it with a nulled
    // user_ctx and cast.userData crashed. Reflection covers any future sink
    // automatically -- never hand-maintain a second list of field names.
    var drain = DrainHandle{};
    var term: Terminal = undefined;
    term.drain = &drain;
    term.remote = null; // failPendingTicket + the napp loop bail out

    const fields = @typeInfo(Terminal).@"struct".fields;
    inline for (fields) |fld| {
        if (comptime (isSinkField(fld.type) and std.mem.startsWith(u8, fld.name, "on_"))) {
            @field(term, fld.name) = @ptrFromInt(0x1000);
        }
    }
    // clearSinks invokes these lifecycle callbacks before nulling them; the
    // other on_* fields are passive sinks and can carry the drift sentinel.
    term.on_panel_origin_close = null;
    term.on_panel_work_cancel = null;

    term.clearSinks();

    inline for (fields) |fld| {
        if (comptime (isSinkField(fld.type) and std.mem.startsWith(u8, fld.name, "on_"))) {
            if (@field(term, fld.name) != null) {
                std.debug.print("clearSinks missed field: {s}\n", .{fld.name});
                return error.SinkNotCleared;
            }
        }
    }
}

test "panel request dispatch returns a correlated reply on the same connection" {
    const a = std.testing.allocator;
    var pair: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&pair));

    var session = [_]u8{ 'r', 'e', 'l', 'a', 'y' };
    var remote = Terminal.Remote{
        .conn = .{
            .allocator = a,
            .fd = pair[0],
            .proto = mux_wire.PROTO_VERSION,
            .panel_rpc = mux_wire.PANEL_RPC_VERSION,
        },
        .session = &session,
        .origin_name = &session,
        .predictor = undefined,
    };
    defer remote.conn.deinit();
    remote.conn.setNonBlocking();

    var peer = mux_client.Conn{
        .allocator = a,
        .fd = pair[1],
        .proto = mux_wire.PROTO_VERSION,
        .panel_rpc = mux_wire.PANEL_RPC_VERSION,
    };
    defer peer.deinit();

    const Captured = struct {
        called: bool = false,
        terminal: ?*Terminal = null,
        request_ok: bool = false,

        fn dispatch(
            ctx: ?*anyopaque,
            terminal: *Terminal,
            request_id: u64,
            request: []const u8,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.called = true;
            self.terminal = terminal;
            self.request_ok = std.mem.eql(u8, request, "{\"cmd\":\"panel-list\"}");
            terminal.replyPanelRequest(request_id, "{\"ok\":true,\"panels\":[]}\n");
        }
    };
    var captured = Captured{};
    var term: Terminal = undefined;
    term.allocator = a;
    term.remote = &remote;
    term.user_ctx = &captured;
    term.on_panel_request = Captured.dispatch;

    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(a);
    try mux_wire.appendPanelEnvelope(&request, a, 0x1234, "{\"cmd\":\"panel-list\"}");
    term.handleRemoteFrame(.{ .ftype = .panel_request, .payload = request.items });

    try std.testing.expect(captured.called);
    try std.testing.expectEqual(&term, captured.terminal.?);
    try std.testing.expect(captured.request_ok);
    const frame = try peer.recvExpectFor(&.{.panel_reply}, 1_000);
    defer frame.deinit(a);
    const envelope = try mux_wire.decodePanelEnvelope(frame.payload);
    try std.testing.expectEqual(@as(u64, 0x1234), envelope.id);
    try std.testing.expectEqualStrings("{\"ok\":true,\"panels\":[]}", envelope.json);
}

test "session metadata separates immutable origin from mutable display rename" {
    const a = std.testing.allocator;
    var remote = Terminal.Remote{
        .conn = .{ .allocator = a, .fd = -1 },
        .session = try a.dupe(u8, "attach-alias"),
        .origin_name = try a.dupe(u8, "attach-alias"),
        .predictor = undefined,
    };
    defer a.free(remote.session);
    defer a.free(remote.origin_name);
    defer if (remote.origin_id.len > 0) a.free(remote.origin_id);

    const Capture = struct {
        var renamed: u32 = 0;
        fn panelRename(_: *Terminal, _: []const u8) void {
            renamed += 1;
        }
    };
    Capture.renamed = 0;
    var term: Terminal = undefined;
    term.allocator = a;
    term.remote = &remote;
    term.on_panel_origin_renamed = Capture.panelRename;
    term.on_session_renamed = null;
    term.handleRemoteFrame(.{
        .ftype = .session_meta,
        .payload = "{\"name\":\"display-now\",\"origin_name\":\"spawn-origin\",\"origin_id\":\"00000000000000000000000000000001\"}",
    });
    try std.testing.expectEqualStrings("display-now", remote.session);
    try std.testing.expectEqualStrings("spawn-origin", remote.origin_name);
    try std.testing.expectEqualStrings("00000000000000000000000000000001", remote.origin_id);
    try std.testing.expectEqual(@as(u32, 1), Capture.renamed);

    term.handleRemoteFrame(.{
        .ftype = .session_meta,
        .payload = "{\"name\":\"display-later\",\"origin_name\":\"spawn-origin\",\"origin_id\":\"00000000000000000000000000000001\"}",
    });
    try std.testing.expectEqualStrings("display-later", remote.session);
    try std.testing.expectEqualStrings("spawn-origin", remote.origin_name);
    try std.testing.expectEqual(@as(u32, 2), Capture.renamed);
}

test "reconnect rename commits terminal and panel metadata exactly once" {
    const a = std.testing.allocator;
    var remote = Terminal.Remote{
        .conn = .{ .allocator = a, .fd = -1 },
        .session = try a.dupe(u8, "before"),
        .origin_name = @constCast("spawn-origin"),
        .pending_rename = try a.dupe(u8, "after"),
        .predictor = undefined,
    };
    defer a.free(remote.session);

    const Capture = struct {
        panel: u32 = 0,
        terminal: u32 = 0,
        panel_name: []const u8 = "",
        terminal_name: []const u8 = "",

        fn panelRenamed(term: *Terminal, name: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(term.user_ctx.?));
            self.panel += 1;
            self.panel_name = name;
        }

        fn sessionRenamed(ctx: ?*anyopaque, name: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.terminal += 1;
            self.terminal_name = name;
        }
    };
    var capture = Capture{};
    var term: Terminal = undefined;
    term.allocator = a;
    term.remote = &remote;
    term.user_ctx = &capture;
    term.on_panel_origin_renamed = Capture.panelRenamed;
    term.on_session_renamed = Capture.sessionRenamed;

    term.commitReattachRename(&remote);
    try std.testing.expectEqualStrings("after", remote.session);
    try std.testing.expectEqual(@as(?[]u8, null), remote.pending_rename);
    try std.testing.expectEqual(@as(u32, 1), capture.panel);
    try std.testing.expectEqual(@as(u32, 1), capture.terminal);
    try std.testing.expectEqualStrings("after", capture.panel_name);
    try std.testing.expectEqualStrings("after", capture.terminal_name);

    term.commitReattachRename(&remote);
    try std.testing.expectEqual(@as(u32, 1), capture.panel);
    try std.testing.expectEqual(@as(u32, 1), capture.terminal);
}

test "clearSinks retires a panel origin exactly once" {
    const Capture = struct {
        var calls: u32 = 0;
        fn close(_: *Terminal) void {
            calls += 1;
        }
    };
    Capture.calls = 0;
    var drain = DrainHandle{};
    var term: Terminal = undefined;
    term.drain = &drain;
    term.remote = null;
    term.on_panel_origin_close = Capture.close;
    term.on_panel_work_cancel = null;
    term.clearSinks();
    term.clearSinks();
    try std.testing.expectEqual(@as(u32, 1), Capture.calls);
    try std.testing.expectEqual(@as(?*const fn (*Terminal) void, null), term.on_panel_origin_close);
    try std.testing.expect(!drain.panel_assets_live.load(.acquire));
}

test "canceling an asynchronous remote file read ignores late frames" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var pair: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&pair));

    var remote = Terminal.Remote{
        .conn = .{
            .allocator = allocator,
            .fd = pair[0],
            .proto = mux_wire.PROTO_VERSION,
        },
        .session = @constCast("cancel-read"),
        .origin_name = @constCast("cancel-read"),
        .predictor = undefined,
    };
    defer {
        remote.fs_reads.deinit(allocator);
        remote.conn.deinit();
    }
    remote.conn.setNonBlocking();
    var peer = mux_client.Conn{
        .allocator = allocator,
        .fd = pair[1],
        .proto = mux_wire.PROTO_VERSION,
    };
    defer peer.deinit();

    const Capture = struct {
        called: bool = false,
        fn done(ctx: ?*anyopaque, _: *Terminal, _: u32, result: Terminal.RemoteFileResult) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.called = true;
            if (result == .success) testing.allocator.free(result.success.bytes);
        }
    };
    var capture = Capture{};
    var drain = DrainHandle{};
    var term: Terminal = undefined;
    term.allocator = allocator;
    term.remote = &remote;
    term.drain = &drain;
    drain.terminal = &term;

    const token = try term.beginRemoteFileRead("/remote/image.png", 1024, 5_000, &capture, Capture.done);
    const request = try peer.recvExpectFor(&.{.fs_op}, 1_000);
    request.deinit(allocator);
    term.cancelRemoteFileRead(token);
    try testing.expectEqual(@as(usize, 0), remote.fs_reads.items.len);

    var data: [16]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], token, .little);
    std.mem.writeInt(u64, data[4..12], 0, .little);
    @memcpy(data[12..], "late");
    term.handleRemoteFrame(.{ .ftype = .fs_data, .payload = &data });
    var reply_buf: [128]u8 = undefined;
    const reply = try std.fmt.bufPrint(
        &reply_buf,
        "{{\"req\":{d},\"ok\":true,\"size\":4,\"eof\":true,\"mtime_ns\":1,\"ino\":2}}",
        .{token},
    );
    term.handleRemoteFrame(.{ .ftype = .fs_reply, .payload = reply });
    try testing.expect(!capture.called);
}
