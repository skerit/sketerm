//! Headless driver for forwarded Wayland apps: a proto-v5 mux client
//! that spawns app sessions, keeps passive replica compositors per
//! channel (windows render into memory, nothing on any display),
//! captures PNG screenshots, and injects seat input as intent units.
//! GTK-free — usable from `sketerm mcp` without a GUI anywhere.

const std = @import("std");
const c = @import("../c.zig").c;
const muxclient = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");
const snapshot = @import("../mux/snapshot.zig");
const Screen = @import("../grid/screen.zig").Screen;
const Pool = @import("../grid/style_pool.zig").Pool;
const wlpipe = @import("../wlhost/pipe.zig");
const wlcomp = @import("../wlhost/compositor.zig");
const png = @import("../util/png.zig");
const gifrec = @import("../util/gifrec.zig");
const videorec = @import("../util/videorec.zig");
const evkeys = @import("evkeys.zig");
const xkblayout = @import("xkblayout.zig");
const keymaps = @import("../wlhost/keymaps.zig");

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

pub const Error = error{
    SpawnFailed,
    NotConnected,
    NoSuchWindow,
    BadKey,
    BadLayout,
    Timeout,
    NoClipboard,
    NotRecording,
    OutOfMemory,
};

/// WHY the last `App.launch`/`attachExisting` failed, human-readable
/// (the daemon's own error message when there was one). Error enums
/// can't carry strings; MCP serves one assistant sequentially, so a
/// module-level slot is safe.
var launch_err_buf: [256]u8 = undefined;
var launch_err_len: usize = 0;

pub fn lastLaunchErr() []const u8 {
    return launch_err_buf[0..launch_err_len];
}

fn setLaunchErr(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&launch_err_buf, fmt, args) catch {
        launch_err_len = 0;
        return;
    };
    launch_err_len = s.len;
}

/// Describe a handshake-step failure, folding in the daemon's `.err`
/// message and any half-arrived frame ("2.1 MB of 8.3 MB buffered").
fn setStepErr(step: []const u8, conn: *muxclient.Conn, err: anyerror) void {
    if (err == error.DaemonError) {
        setLaunchErr("{s}: {s}", .{ step, conn.lastErr() });
        return;
    }
    if (err == error.Timeout) {
        if (conn.pendingPartial()) |p| {
            setLaunchErr("{s}: timed out mid-frame ({d} of {d} bytes buffered)", .{ step, p.have, p.expected });
        } else {
            setLaunchErr("{s}: timed out waiting for the daemon's reply", .{step});
        }
        return;
    }
    setLaunchErr("{s}: {s}", .{ step, @errorName(err) });
}

/// Query the daemon host's installed GUI apps (name + exec) without
/// spawning anything. `host` null = local autostart daemon. Returns a
/// JSON array string (arena-owned via the passed allocator's arena
/// semantics: caller frees with allocator.free).
pub fn listInstalledApps(allocator: std.mem.Allocator, host: ?[]const u8, local_sock: ?[]const u8) Error![]u8 {
    var conn = blk: {
        if (host) |h| break :blk muxclient.Conn.connectSsh(allocator, h) catch return Error.SpawnFailed;
        break :blk muxclient.Conn.connectLocalAutostartAt(allocator, local_sock) catch return Error.SpawnFailed;
    };
    defer conn.deinit();
    conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch return Error.NotConnected;
    (conn.recvExpect(&.{.welcome}) catch return Error.NotConnected).deinit(allocator);
    // app_list needs no session attach — the daemon scans its own host.
    conn.sendFrame(.app_list, "") catch return Error.NotConnected;
    const f = conn.recvExpect(&.{.app_listing}) catch return Error.Timeout;
    defer f.deinit(allocator);
    return allocator.dupe(u8, f.payload) catch return Error.OutOfMemory;
}

/// One live app session in a daemon's `list` reply.
pub const AppSessionRef = struct {
    name: []u8,
    /// Session child pid on the daemon's host (0 = unknown).
    pid: i32 = 0,
};

/// Live app sessions on the daemon at `sock`, WITHOUT autostarting one
/// (no daemon = empty). Caller frees each `.name` and the slice.
pub fn listAppSessions(allocator: std.mem.Allocator, sock: []const u8) Error![]AppSessionRef {
    var conn = muxclient.Conn.connect(allocator, sock) catch return Error.SpawnFailed;
    defer conn.deinit();
    conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch return Error.NotConnected;
    (conn.recvExpect(&.{.welcome}) catch return Error.NotConnected).deinit(allocator);
    conn.sendFrame(.list, "") catch return Error.NotConnected;
    const f = conn.recvExpect(&.{.welcome}) catch return Error.Timeout;
    defer f.deinit(allocator);

    const Listing = struct {
        sessions: []const struct {
            name: []const u8,
            app: bool = false,
            exited: bool = false,
            pid: i32 = 0,
        } = &.{},
    };
    const parsed = std.json.parseFromSlice(Listing, allocator, f.payload, .{
        .ignore_unknown_fields = true,
    }) catch return Error.NotConnected;
    defer parsed.deinit();

    var refs: std.ArrayList(AppSessionRef) = .empty;
    errdefer {
        for (refs.items) |r| allocator.free(r.name);
        refs.deinit(allocator);
    }
    for (parsed.value.sessions) |s| {
        if (!s.app or s.exited) continue;
        const n = allocator.dupe(u8, s.name) catch return Error.OutOfMemory;
        refs.append(allocator, .{ .name = n, .pid = s.pid }) catch {
            allocator.free(n);
            return Error.OutOfMemory;
        };
    }
    return refs.toOwnedSlice(allocator) catch Error.OutOfMemory;
}

/// One rendered toplevel (or popup) surface of one app channel.
pub const Window = struct {
    /// Stable public id (MCP-facing), unique within the App.
    id: u32,
    chan: u32,
    sid: u32,
    w: i32 = 0,
    h: i32 = 0,
    scale: i32 = 1,
    format: u32 = 0,
    /// Latest committed pixels, tightly packed w*4 (wl_shm layout).
    pixels: std.ArrayList(u8) = .empty,
    title: ?[]u8 = null,
    app_id: ?[]u8 = null,
    popup: bool = false,
    frames: u64 = 0,
    /// `frames` at the last screenshot of this window — lets a
    /// wait-for-change screenshot block until content actually differs
    /// from what the caller last saw.
    shot_frames: u64 = 0,
    /// Pixel copy taken at the last screenshot / stats observation:
    /// the diff baseline for stats_only and burst min-change gating.
    shot_pixels: std.ArrayList(u8) = .empty,
    shot_w: i32 = 0,
    shot_h: i32 = 0,

    fn deinit(self: *Window, a: std.mem.Allocator) void {
        self.pixels.deinit(a);
        self.shot_pixels.deinit(a);
        if (self.title) |s| a.free(s);
        if (self.app_id) |s| a.free(s);
    }

    /// Record the current committed pixels as the observation baseline
    /// (what the caller "last saw"). Best-effort: OOM just leaves the
    /// previous baseline, which only skews a later diff percentage.
    fn rememberShot(self: *Window, a: std.mem.Allocator) void {
        self.shot_frames = self.frames;
        self.shot_pixels.clearRetainingCapacity();
        self.shot_pixels.appendSlice(a, self.pixels.items) catch return;
        self.shot_w = self.w;
        self.shot_h = self.h;
    }

    /// Fraction (0..100) of pixels differing from the baseline; 100
    /// when the window was resized or no baseline exists yet.
    fn pctVsBaseline(self: *const Window) f64 {
        const n = self.pixels.items.len;
        if (self.shot_pixels.items.len != n or self.shot_w != self.w or self.shot_h != self.h or n < 4)
            return 100.0;
        const cur = self.pixels.items;
        const base = self.shot_pixels.items;
        var diff: usize = 0;
        var i: usize = 0;
        while (i + 4 <= n) : (i += 4) {
            if (!std.mem.eql(u8, cur[i..][0..4], base[i..][0..4])) diff += 1;
        }
        const total = n / 4;
        return @as(f64, @floatFromInt(diff)) * 100.0 / @as(f64, @floatFromInt(total));
    }
};

/// One wayland_native channel = one app display connection, with its
/// own replica compositor.
const Chan = struct {
    app: *App,
    id: u32,
    comp: wlcomp.Compositor,
};

var name_counter: u32 = 0;

pub const App = struct {
    allocator: std.mem.Allocator,
    conn: muxclient.Conn,
    name: []u8,
    chans: std.AutoArrayHashMapUnmanaged(u32, *Chan) = .empty,
    /// Audio channels: headless — no playback, but the consumed
    /// clock must keep ticking or the app blocks on a full sink.
    audio_ids: std.AutoHashMapUnmanaged(u32, void) = .empty,
    windows: std.ArrayList(*Window) = .empty,
    next_win_id: u32 = 1,
    /// Bumped on every committed frame — the quiescence signal.
    frame_seq: u64 = 0,
    exited: bool = false,
    exit_status: i32 = 0,
    /// Session child pid ON THE DAEMON'S HOST (0 = unknown). A string
    /// command spawns via `/bin/sh -c`, so this is the shell; argv-array
    /// launches exec directly and the pid IS the app.
    pid: i32 = 0,
    /// Toplevel the keyboard was last aimed at (0 = none yet).
    kbd_focus: u32 = 0, // public window id
    /// Latest clipboard selection the app announced (copy source).
    clip_offer: ?ClipOffer = null,
    /// Fetched app-clipboard bytes (answer to a clip_send).
    clip_buf: std.ArrayList(u8) = .empty,
    clip_got: bool = false,
    /// Text we offered as the host clipboard; served on app paste.
    paste_data: ?[]u8 = null,
    /// Parsed session keymap for layout-aware typing (null = the
    /// builtin us tables in evkeys.zig).
    layout: ?xkblayout.Layout = null,
    /// Active recording of one window's frames (app_record_*): GIF or
    /// WebM/VP9. At most one is set at a time.
    rec: ?gifrec.Rec = null,
    vrec: ?videorec.Rec = null,
    rec_win: u32 = 0,
    /// Client-side Screen mirror of the app session's PTY (the app's
    /// stdout/stderr as a rendered terminal — the "held log tab"),
    /// built from the attach snapshot + the event stream, exactly like
    /// termdrive.Term. This is what `output()` reads.
    term_pool: ?*Pool = null,
    term_screen: ?*Screen = null,
    term_seq: u64 = 0,
    /// Latest `.log_data` payload (a logGet reply, or the daemon's
    /// unsolicited post-mortem push just before `.exit`).
    log_buf: std.ArrayList(u8) = .empty,
    /// Bumped per received `.log_data` — logGet waits on this.
    log_seq: u64 = 0,
    /// Screenshots stashed when the app emitted the OSC 5522 marker
    /// escape: "the window at that instant", keyed by the marker's
    /// log-line id. Bounded ring, oldest dropped.
    markers: std.ArrayList(MarkerShot) = .empty,

    /// `OSC 5522;+N;label` markers waiting for the primary window's
    /// Nth future commit before stashing.
    pending_markers: std.ArrayList(PendingMarker) = .empty,
    /// Window id + frame counter at the last stash encode — a marker
    /// burst against an unchanged frame reuses the previous PNG
    /// instead of paying another encode.
    last_stash_win: u32 = 0,
    last_stash_frames: u64 = 0,

    pub const MarkerShot = struct {
        id: u64,
        label: []u8,
        /// Full-window PNG at marker time (null = no rendered window).
        png: ?[]u8,
    };
    const MAX_MARKER_SHOTS = 8;
    const PendingMarker = struct { id: u64, label: []u8, remaining: u32 };
    const MAX_PENDING_MARKERS = 32;

    const ClipOffer = struct { chan: u32, source: u32, mime: []u8 };

    /// Optional launch parameters (`launch_app` schema mirrors this).
    pub const LaunchOpts = struct {
        cols: u16 = 80,
        rows: u16 = 24,
        host: ?[]const u8 = null,
        kb_layout: ?[]const u8 = null,
        local_sock: ?[]const u8 = null,
        gpu: bool = false,
        cwd: ?[]const u8 = null,
        /// "KEY=VALUE" strings for the child environment.
        env: []const []const u8 = &.{},
        /// Per-step handshake deadline; a stalled daemon surfaces as a
        /// described SpawnFailed instead of a hung tool call.
        step_timeout_ms: i64 = 15_000,
    };

    /// Spawn an app session on the local (autostart) daemon, or on
    /// `host` over SSH, and attach as a proto-v5 viewer. `kb_layout`
    /// picks the session keymap (wlhost/keymaps.zig; null/"" = us) —
    /// typing is encoded against the same blob. `local_sock` targets a
    /// private daemon instance (MCP isolation); null = shared daemon.
    /// `gpu` = per-session dmabuf opt-in (real GL driver on the host).
    pub fn launch(
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        opts: LaunchOpts,
    ) Error!*App {
        launch_err_len = 0;
        const layout_name = opts.kb_layout orelse "";
        const blob = keymaps.get(layout_name) orelse return Error.BadLayout;
        var layout: ?xkblayout.Layout = xkblayout.parse(allocator, blob) catch null;
        errdefer if (layout) |*l| l.deinit(allocator);
        var conn = blk: {
            if (opts.host) |h| break :blk muxclient.Conn.connectSsh(allocator, h) catch |err| {
                setLaunchErr("ssh connect to {s}: {s}", .{ h, @errorName(err) });
                return Error.SpawnFailed;
            };
            break :blk muxclient.Conn.connectLocalAutostartAt(allocator, opts.local_sock) catch |err| {
                setLaunchErr("daemon connect: {s}", .{@errorName(err)});
                return Error.SpawnFailed;
            };
        };
        errdefer conn.deinit();

        conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch return Error.SpawnFailed;
        (conn.recvExpectFor(&.{.welcome}, opts.step_timeout_ms) catch |err| {
            setStepErr("hello handshake", &conn, err);
            return Error.SpawnFailed;
        }).deinit(allocator);

        name_counter += 1;
        const name = std.fmt.allocPrint(allocator, "mcpapp-{d}-{d}", .{ c.getpid(), name_counter }) catch
            return Error.OutOfMemory;
        errdefer allocator.free(name);

        conn.sendJson(.spawn, .{
            .name = name,
            .argv = argv,
            .rows = opts.rows,
            .cols = opts.cols,
            .app = true,
            .kb_layout = layout_name,
            .gpu = opts.gpu,
            .cwd = opts.cwd,
            .env = opts.env,
        }) catch return Error.SpawnFailed;
        var spawn_pid: i32 = 0;
        {
            const ok = conn.recvExpectFor(&.{.ok}, opts.step_timeout_ms) catch |err| {
                setStepErr("spawn", &conn, err);
                return Error.SpawnFailed;
            };
            defer ok.deinit(allocator);
            const OkReply = struct { pid: i32 = 0 };
            if (std.json.parseFromSlice(OkReply, allocator, ok.payload, .{
                .ignore_unknown_fields = true,
            })) |p| {
                spawn_pid = p.value.pid;
                p.deinit();
            } else |_| {}
        }
        conn.sendJson(.attach, .{ .name = name, .kind = "mcp" }) catch return Error.SpawnFailed;
        const snap = conn.recvExpectFor(&.{.snapshot}, opts.step_timeout_ms) catch |err| {
            setStepErr("attach", &conn, err);
            return Error.SpawnFailed;
        };
        defer snap.deinit(allocator);

        const self = allocator.create(App) catch return Error.OutOfMemory;
        self.* = .{ .allocator = allocator, .conn = conn, .name = name, .layout = layout, .pid = spawn_pid };
        layout = null; // ownership moved
        self.applyTermSnapshot(snap.payload);
        return self;
    }

    /// Attach to an EXISTING app session (named-instance reconnect).
    /// Same wire flow as `launch` minus the spawn — the daemon replays
    /// pool bytes + state_sync, so windows rebuild with pixels. The
    /// session's keymap isn't recoverable from the wire; `kb_layout`
    /// should repeat the launch-time value (null = us).
    pub fn attachExisting(
        allocator: std.mem.Allocator,
        session_name: []const u8,
        kb_layout: ?[]const u8,
        local_sock: ?[]const u8,
    ) Error!*App {
        launch_err_len = 0;
        const layout_name = kb_layout orelse "";
        const blob = keymaps.get(layout_name) orelse return Error.BadLayout;
        var layout: ?xkblayout.Layout = xkblayout.parse(allocator, blob) catch null;
        errdefer if (layout) |*l| l.deinit(allocator);
        var conn = muxclient.Conn.connectLocalAutostartAt(allocator, local_sock) catch |err| {
            setLaunchErr("daemon connect: {s}", .{@errorName(err)});
            return Error.SpawnFailed;
        };
        errdefer conn.deinit();

        conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch return Error.SpawnFailed;
        (conn.recvExpectFor(&.{.welcome}, 15_000) catch |err| {
            setStepErr("hello handshake", &conn, err);
            return Error.SpawnFailed;
        }).deinit(allocator);

        const name = allocator.dupe(u8, session_name) catch return Error.OutOfMemory;
        errdefer allocator.free(name);
        conn.sendJson(.attach, .{ .name = name, .kind = "mcp" }) catch return Error.SpawnFailed;
        const snap = conn.recvExpectFor(&.{.snapshot}, 15_000) catch |err| {
            setStepErr("attach", &conn, err);
            return Error.SpawnFailed;
        };
        defer snap.deinit(allocator);

        const self = allocator.create(App) catch return Error.OutOfMemory;
        self.* = .{ .allocator = allocator, .conn = conn, .name = name, .layout = layout };
        layout = null; // ownership moved
        self.applyTermSnapshot(snap.payload);
        return self;
    }

    /// Free the client-side state WITHOUT killing the session — a
    /// durable instance's apps outlive the MCP process.
    pub fn detach(self: *App) void {
        self.exited = true; // suppress deinit's kill frame
        self.deinit();
    }

    /// Kill the session (the app dies with it) and free everything.
    pub fn deinit(self: *App) void {
        const a = self.allocator;
        if (!self.exited) {
            self.conn.sendJson(.kill, .{ .name = self.name }) catch {};
        }
        self.conn.deinit();
        for (self.chans.values()) |ch| {
            ch.comp.deinit();
            a.destroy(ch);
        }
        self.chans.deinit(a);
        self.audio_ids.deinit(a);
        for (self.windows.items) |w| {
            w.deinit(a);
            a.destroy(w);
        }
        self.windows.deinit(a);
        if (self.clip_offer) |o| a.free(o.mime);
        self.clip_buf.deinit(a);
        self.log_buf.deinit(a);
        for (self.markers.items) |m| {
            a.free(m.label);
            if (m.png) |p| a.free(p);
        }
        self.markers.deinit(a);
        for (self.pending_markers.items) |pm| a.free(pm.label);
        self.pending_markers.deinit(a);
        if (self.paste_data) |p| a.free(p);
        if (self.layout) |*l| l.deinit(a);
        if (self.rec) |*r| r.abort();
        if (self.vrec) |*r| r.abort();
        if (self.term_screen) |s| s.deinit();
        if (self.term_pool) |p| {
            p.deinit();
            a.destroy(p);
        }
        a.free(self.name);
        a.destroy(self);
    }

    /// Rebuild the terminal mirror from an attach snapshot
    /// ([seq:u64][app:u8] + serialized Screen). Best-effort: a decode
    /// failure just leaves the mirror empty (output unavailable).
    fn applyTermSnapshot(self: *App, payload: []const u8) void {
        if (payload.len < 9) return;
        const a = self.allocator;
        self.term_seq = std.mem.readInt(u64, payload[0..8], .little);
        if (self.term_screen) |s| s.deinit();
        self.term_screen = null;
        if (self.term_pool == null) {
            const p = a.create(Pool) catch return;
            p.* = Pool.init(a) catch {
                a.destroy(p);
                return;
            };
            self.term_pool = p;
        } else {
            self.term_pool.?.deinit();
            self.term_pool.?.* = Pool.init(a) catch {
                a.destroy(self.term_pool.?);
                self.term_pool = null;
                return;
            };
        }
        self.term_screen = snapshot.restore(a, self.term_pool.?, payload[9..]) catch null;
    }

    /// Apply an `.events` frame ([seq:u64][count:u32] + wire events)
    /// to the terminal mirror.
    fn applyTermEvents(self: *App, payload: []const u8) void {
        if (payload.len < 12) return;
        const base = std.mem.readInt(u64, payload[0..8], .little);
        const n = std.mem.readInt(u32, payload[8..12], .little);
        const screen = self.term_screen orelse return;
        var r = wire.Reader.init(payload[12..]);
        while (!r.atEnd()) {
            var ev = r.getEvent(self.allocator) catch break;
            screen.apply(ev);
            ev.deinit(self.allocator);
        }
        self.term_seq = base + n;
    }

    /// The app's PTY output (stdout+stderr as rendered by the
    /// terminal). `scrollback` includes history above the grid.
    /// Caller owns the bytes.
    pub fn output(self: *App, scrollback: bool) Error![]u8 {
        self.drain();
        const screen = self.term_screen orelse return Error.NotConnected;
        return (if (scrollback)
            screen.extractScrollback(self.allocator)
        else
            screen.extractScreen(self.allocator)) catch Error.OutOfMemory;
    }

    // ── stream pumping ──────────────────────────────────────────

    fn pollIn(fd: c_int, ms: i32) bool {
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        const r = c.poll(&pfd, 1, ms);
        return r > 0 and (pfd.revents & (c.POLLIN | c.POLLHUP)) != 0;
    }

    /// Process at most one incoming frame, waiting up to `wait_ms`.
    /// Returns false when nothing COMPLETE arrived in time (or after exit).
    ///
    /// This must never block past `wait_ms`, which is why it does not call
    /// recvFrame: recvFrame read()s until it has a whole frame, and a big frame (an
    /// 8 MB window buffer) arrives in many chunks. A readable fd therefore does NOT
    /// mean a whole frame is there, and waiting for the tail of one that has not
    /// been sent yet hangs the caller. Partial bytes simply stay in the buffer and
    /// are peeled once the rest lands.
    pub fn pumpOnce(self: *App, wait_ms: i32) bool {
        if (self.exited) return false;

        // Attach-time recvExpect may have buffered frames PAST the
        // snapshot into conn.rbuf (a small dmabuf replay fits in one
        // read); those never make the fd readable again — drain the
        // buffer before polling for new bytes.
        if (self.takeOne()) return true;

        if (!pollIn(self.conn.fd, wait_ms)) return false;
        if (!self.conn.fillAvailable()) {
            self.exited = true;
            return false;
        }
        return self.takeOne();
    }

    /// Handle one complete buffered frame, if there is one.
    fn takeOne(self: *App) bool {
        const f = (self.conn.takeFrame() catch {
            self.exited = true;
            return false;
        }) orelse return false;
        defer f.deinit(self.allocator);
        self.handleFrame(f.ftype, f.payload);
        return true;
    }

    /// Drain whatever is queued without blocking — TIME-BOXED. A
    /// flooding app (debug spam on its PTY) produces `.events` frames
    /// at least as fast as we consume them, so an unbounded loop here
    /// never returns and one wedged tool call stalls every MCP request
    /// behind it. The daemon stops streaming events to a backlogged
    /// client and resyncs it with a fresh snapshot once it drains, so
    /// cutting out early loses nothing.
    pub fn drain(self: *App) void {
        const deadline = nowMs() + 100;
        while (self.pumpOnce(0)) {
            if (nowMs() >= deadline) break;
        }
    }

    fn handleFrame(self: *App, ftype: wire.FrameType, payload: []const u8) void {
        switch (ftype) {
            .chan_open => {
                const open = wire.decodeChanOpen(payload) orelse return;
                if (open.kind == .audio) {
                    self.audio_ids.put(self.allocator, open.id, {}) catch {};
                    // Subscribe: we drain PCM (instant-consume clock).
                    const pulse = @import("../mux/pulse.zig");
                    var units: std.ArrayList(u8) = .empty;
                    defer units.deinit(self.allocator);
                    pulse.appendUnit(&units, self.allocator, .subscribe, "") catch return;
                    self.sendIntents(open.id, units.items) catch {};
                    return;
                }
                if (open.kind != .wayland_native) return;
                const ch = self.allocator.create(Chan) catch return;
                ch.* = .{ .app = self, .id = open.id, .comp = undefined };
                ch.comp = wlcomp.Compositor.init(self.allocator, .{
                    .ctx = ch,
                    .toplevel_new = onNew,
                    .toplevel_frame = onFrame,
                    .toplevel_title = onTitle,
                    .toplevel_app_id = onAppId,
                    .toplevel_gone = onGone,
                    .popup_new = onPopupNew,
                    .popup_gone = onGone,
                    .clipboard_offer = onClipOffer,
                    .clipboard_data = onClipData,
                    .clipboard_read = onClipRead,
                    .primary_read = onPrimaryRead,
                }) catch {
                    self.allocator.destroy(ch);
                    return;
                };
                ch.comp.lenient = true;
                self.chans.put(self.allocator, open.id, ch) catch {
                    ch.comp.deinit();
                    self.allocator.destroy(ch);
                };
            },
            .chan_close => {
                const id = wire.decodeChanId(payload) orelse return;
                if (self.chans.fetchSwapRemove(id)) |kv| {
                    self.dropChanWindows(id);
                    kv.value.comp.deinit();
                    self.allocator.destroy(kv.value);
                }
            },
            .chan_data => {
                const id = wire.decodeChanId(payload) orelse return;
                if (self.audio_ids.contains(id)) {
                    self.drainAudio(id, payload[4..]);
                    return;
                }
                const ch = self.chans.get(id) orelse return;
                ch.comp.feed(payload[4..]) catch |err| {
                    std.debug.print("appdrive: replica feed error: {s}\n", .{@errorName(err)});
                };
                ch.comp.clearOut(); // replica output is discarded
            },
            .snapshot => self.applyTermSnapshot(payload),
            .events => self.applyTermEvents(payload),
            .log_data => {
                self.log_buf.clearRetainingCapacity();
                self.log_buf.appendSlice(self.allocator, payload) catch return;
                self.log_seq += 1;
            },
            .marker => self.stashMarker(payload),
            .exit => {
                self.exited = true;
                if (payload.len >= 4) self.exit_status = std.mem.readInt(i32, payload[0..4], .little);
                self.resolvePendingMarkers();
            },
            else => {},
        }
    }

    /// The app emitted the OSC 5522 marker escape. `after` == 0:
    /// stash a screenshot of the primary window NOW; `after` > 0
    /// (the `+N` syntax): wait for that many future commits first.
    fn stashMarker(self: *App, payload: []const u8) void {
        const a = self.allocator;
        const P = struct { id: u64 = 0, label: []const u8 = "", after: u32 = 0 };
        const parsed = std.json.parseFromSlice(P, a, payload, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        if (parsed.value.id == 0) return;
        if (parsed.value.after > 0) {
            const label = a.dupe(u8, parsed.value.label) catch return;
            self.pending_markers.append(a, .{
                .id = parsed.value.id,
                .label = label,
                .remaining = parsed.value.after,
            }) catch {
                a.free(label);
                return;
            };
            while (self.pending_markers.items.len > MAX_PENDING_MARKERS) {
                // Resolve rather than lose: the oldest gets the
                // current frame instead of the one it waited for.
                const old = self.pending_markers.orderedRemove(0);
                self.doStash(old.id, old.label);
                a.free(old.label);
            }
            return;
        }
        self.doStash(parsed.value.id, parsed.value.label);
    }

    /// Stash a marker screenshot of the primary window as it is right
    /// now. A burst against an UNCHANGED frame reuses the previous
    /// stash's PNG bytes instead of re-encoding.
    fn doStash(self: *App, id: u64, label: []const u8) void {
        const a = self.allocator;
        var shot_png: ?[]u8 = null;
        for (self.windows.items) |w| {
            if (w.popup or w.frames == 0) continue;
            if (self.last_stash_win == w.id and self.last_stash_frames == w.frames) {
                var i = self.markers.items.len;
                while (i > 0) {
                    i -= 1;
                    if (self.markers.items[i].png) |p| {
                        shot_png = a.dupe(u8, p) catch null;
                        break;
                    }
                }
            }
            if (shot_png == null) {
                if (self.encodeWindowPng(w, 1568, null, 1)) |shot| shot_png = shot.png else |_| {}
            }
            if (shot_png != null) {
                self.last_stash_win = w.id;
                self.last_stash_frames = w.frames;
            }
            break;
        }
        const label_copy = a.dupe(u8, label) catch {
            if (shot_png) |p| a.free(p);
            return;
        };
        self.markers.append(a, .{ .id = id, .label = label_copy, .png = shot_png }) catch {
            a.free(label_copy);
            if (shot_png) |p| a.free(p);
            return;
        };
        while (self.markers.items.len > MAX_MARKER_SHOTS) {
            const old = self.markers.orderedRemove(0);
            a.free(old.label);
            if (old.png) |p| a.free(p);
        }
    }

    /// A frame just committed on `win`: advance `+N` markers when it
    /// is the primary toplevel, stashing those that reach zero.
    fn tickPendingMarkers(self: *App, win: *Window) void {
        if (self.pending_markers.items.len == 0) return;
        for (self.windows.items) |w| {
            if (w.popup or w.frames == 0) continue;
            if (w != win) return; // only the primary's commits count
            break;
        }
        var i: usize = 0;
        while (i < self.pending_markers.items.len) {
            const pm = &self.pending_markers.items[i];
            pm.remaining -= 1;
            if (pm.remaining == 0) {
                const done = self.pending_markers.orderedRemove(i);
                self.doStash(done.id, done.label);
                self.allocator.free(done.label);
                continue;
            }
            i += 1;
        }
    }

    /// The app is gone: `+N` markers that never saw their Nth commit
    /// resolve against the final frame (an id must never dangle).
    fn resolvePendingMarkers(self: *App) void {
        while (self.pending_markers.items.len > 0) {
            const pm = self.pending_markers.orderedRemove(0);
            self.doStash(pm.id, pm.label);
            self.allocator.free(pm.label);
        }
    }

    pub fn markerShot(self: *const App, id: u64) ?*const MarkerShot {
        for (self.markers.items) |*m| {
            if (m.id == id) return m;
        }
        return null;
    }

    /// Fetch log lines from the daemon (`req_json` = a LogGetReq
    /// object). For an EXITED app the daemon already pushed the final
    /// log ahead of `.exit`; that stash is served instead (the session
    /// is gone daemon-side). Caller owns the returned JSON.
    pub fn logGet(self: *App, req_json: []const u8, timeout_ms: i64) Error![]u8 {
        self.drain();
        if (!self.exited) {
            const before = self.log_seq;
            self.conn.sendFrame(.log_get, req_json) catch return Error.NotConnected;
            const deadline = nowMs() + timeout_ms;
            while (self.log_seq == before and nowMs() < deadline) {
                if (self.exited) break;
                _ = self.pumpOnce(25);
            }
            if (self.log_seq == before and !self.exited) return Error.Timeout;
        }
        if (self.log_buf.items.len == 0) return Error.NotConnected;
        return self.allocator.dupe(u8, self.log_buf.items) catch Error.OutOfMemory;
    }

    fn dropChanWindows(self: *App, chan: u32) void {
        var i: usize = 0;
        while (i < self.windows.items.len) {
            if (self.windows.items[i].chan == chan) {
                const w = self.windows.swapRemove(i);
                w.deinit(self.allocator);
                self.allocator.destroy(w);
            } else i += 1;
        }
    }

    fn winBySurface(self: *App, chan: u32, sid: u32) ?*Window {
        for (self.windows.items) |w| {
            if (w.chan == chan and w.sid == sid) return w;
        }
        return null;
    }

    pub fn winById(self: *App, id: u32) ?*Window {
        for (self.windows.items) |w| {
            if (w.id == id) return w;
        }
        return null;
    }

    fn ensureWindow(self: *App, chan: u32, sid: u32, popup: bool) ?*Window {
        if (self.winBySurface(chan, sid)) |w| return w;
        const w = self.allocator.create(Window) catch return null;
        w.* = .{ .id = self.next_win_id, .chan = chan, .sid = sid, .popup = popup };
        self.next_win_id += 1;
        self.windows.append(self.allocator, w) catch {
            self.allocator.destroy(w);
            return null;
        };
        return w;
    }

    // ── replica view callbacks ──────────────────────────────────

    fn chanOf(ctx: ?*anyopaque) *Chan {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn onNew(ctx: ?*anyopaque, sid: u32) void {
        const ch = chanOf(ctx);
        _ = ch.app.ensureWindow(ch.id, sid, false);
    }

    fn onPopupNew(ctx: ?*anyopaque, sid: u32, parent: u32, x: i32, y: i32) void {
        _ = parent;
        _ = x;
        _ = y;
        const ch = chanOf(ctx);
        _ = ch.app.ensureWindow(ch.id, sid, true);
    }

    fn onFrame(ctx: ?*anyopaque, sid: u32, w: i32, h: i32, scale: i32, lw: i32, lh: i32, format: u32, pixels: []const u8) void {
        // Headless sessions run at scale 1 (no viewer sends
        // set_scale), so logical == physical here.
        _ = lw;
        _ = lh;
        const ch = chanOf(ctx);
        const win = ch.app.ensureWindow(ch.id, sid, false) orelse return;
        win.w = w;
        win.h = h;
        win.scale = scale;
        win.format = format;
        win.pixels.clearRetainingCapacity();
        win.pixels.appendSlice(ch.app.allocator, pixels) catch {};
        win.frames += 1;
        ch.app.frame_seq += 1;
        ch.app.tickPendingMarkers(win);
        if (win.id == ch.app.rec_win and w > 0 and h > 0) {
            const t = nowMs();
            if (ch.app.rec) |*r| r.addShmFrame(pixels, @intCast(w), @intCast(h), format, t) catch {};
            if (ch.app.vrec) |*r| r.addShmFrame(pixels, @intCast(w), @intCast(h), format, t) catch {};
        }
    }

    fn onTitle(ctx: ?*anyopaque, sid: u32, title: []const u8) void {
        const ch = chanOf(ctx);
        const win = ch.app.ensureWindow(ch.id, sid, false) orelse return;
        const copy = ch.app.allocator.dupe(u8, title) catch return;
        if (win.title) |old| ch.app.allocator.free(old);
        win.title = copy;
    }

    fn onAppId(ctx: ?*anyopaque, sid: u32, app_id: []const u8) void {
        const ch = chanOf(ctx);
        const win = ch.app.ensureWindow(ch.id, sid, false) orelse return;
        const copy = ch.app.allocator.dupe(u8, app_id) catch return;
        if (win.app_id) |old| ch.app.allocator.free(old);
        win.app_id = copy;
    }

    fn onClipOffer(ctx: ?*anyopaque, source: u32, mime: []const u8) void {
        const ch = chanOf(ctx);
        const a = ch.app.allocator;
        const copy = a.dupe(u8, mime) catch return;
        if (ch.app.clip_offer) |old| a.free(old.mime);
        ch.app.clip_offer = .{ .chan = ch.id, .source = source, .mime = copy };
    }

    fn onClipData(ctx: ?*anyopaque, bytes: []const u8) void {
        const ch = chanOf(ctx);
        ch.app.clip_buf.clearRetainingCapacity();
        ch.app.clip_buf.appendSlice(ch.app.allocator, bytes) catch return;
        ch.app.clip_got = true;
    }

    fn onClipRead(ctx: ?*anyopaque, mime: []const u8) void {
        _ = mime;
        const ch = chanOf(ctx);
        const data = ch.app.paste_data orelse "";
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(ch.app.allocator);
        wlpipe.appendUnit(&units, ch.app.allocator, .clip_data, data) catch return;
        ch.app.sendIntents(ch.id, units.items) catch {};
    }

    /// Primary paste: answer the offered text (same buffer as the
    /// regular paste) — the daemon holds a fd until we do.
    fn onPrimaryRead(ctx: ?*anyopaque, mime: []const u8) void {
        _ = mime;
        const ch = chanOf(ctx);
        const data = ch.app.paste_data orelse "";
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(ch.app.allocator);
        wlpipe.appendUnit(&units, ch.app.allocator, .primary_data, data) catch return;
        ch.app.sendIntents(ch.id, units.items) catch {};
    }

    fn onGone(ctx: ?*anyopaque, sid: u32) void {
        const ch = chanOf(ctx);
        var i: usize = 0;
        while (i < ch.app.windows.items.len) {
            const w = ch.app.windows.items[i];
            if (w.chan == ch.id and w.sid == sid) {
                _ = ch.app.windows.swapRemove(i);
                w.deinit(ch.app.allocator);
                ch.app.allocator.destroy(w);
                continue;
            }
            i += 1;
        }
    }

    // ── waiting ─────────────────────────────────────────────────

    /// Pump until at least one toplevel has pixels (or timeout).
    pub fn waitFirstWindow(self: *App, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (nowMs() < deadline) {
            for (self.windows.items) |w| {
                if (!w.popup and w.frames > 0) return true;
            }
            if (self.exited) return false;
            _ = self.pumpOnce(50);
        }
        for (self.windows.items) |w| {
            if (!w.popup and w.frames > 0) return true;
        }
        return false;
    }

    /// Pump until no frame arrived for `quiet_ms` (bounded by
    /// `timeout_ms`). Returns true when quiescence was reached.
    pub fn waitIdle(self: *App, quiet_ms: i64, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        var last_seq = self.frame_seq;
        var quiet_since = nowMs();
        while (nowMs() < deadline) {
            _ = self.pumpOnce(25);
            if (self.frame_seq != last_seq) {
                last_seq = self.frame_seq;
                quiet_since = nowMs();
            } else if (nowMs() - quiet_since >= quiet_ms) {
                return true;
            }
            if (self.exited) return true;
        }
        return false;
    }

    // ── input intents ───────────────────────────────────────────

    /// Headless audio: acknowledge PCM as instantly played so the
    /// remote app never stalls on a full sink buffer.
    fn drainAudio(self: *App, id: u32, bytes: []const u8) void {
        const pulse = @import("../mux/pulse.zig");
        var consumed: u64 = 0;
        var pos: usize = 0;
        while (pulse.peelUnit(bytes[pos..])) |p| {
            if (p.tag == .pcm and p.payload.len > 4) consumed += p.payload.len - 4;
            if (p.tag == .pcm_opus and p.payload.len >= 8)
                consumed += std.mem.readInt(u32, p.payload[4..8], .little);
            pos += p.consumed;
        }
        if (consumed == 0) return;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(self.allocator);
        var pl: [12]u8 = undefined;
        // Stream id: first pcm unit's header (one stream per report
        // is fine — multiple streams re-report on their own data).
        pos = 0;
        while (pulse.peelUnit(bytes[pos..])) |p| {
            if ((p.tag == .pcm or p.tag == .pcm_opus) and p.payload.len > 4) {
                @memcpy(pl[0..4], p.payload[0..4]);
                std.mem.writeInt(u64, pl[4..12], consumed, .little);
                pulse.appendUnit(&units, self.allocator, .consumed, &pl) catch return;
                break;
            }
            pos += p.consumed;
        }
        if (units.items.len > 0) self.sendIntents(id, units.items) catch {};
    }

    fn sendIntents(self: *App, chan: u32, units: []const u8) Error!void {
        if (self.exited) return Error.NotConnected;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, chan, .little);
        payload.appendSlice(self.allocator, &idb) catch return Error.OutOfMemory;
        payload.appendSlice(self.allocator, units) catch return Error.OutOfMemory;
        self.conn.sendFrame(.chan_data, payload.items) catch return Error.NotConnected;
    }

    /// Left=1 Middle=2 Right=3 (GDK numbering) → evdev BTN_*.
    fn evdevButton(button: u32) u32 {
        return switch (button) {
            2 => 0x112,
            3 => 0x111,
            else => 0x110,
        };
    }

    pub fn click(self: *App, win_id: u32, x: f64, y: f64, button: u32) Error!void {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendSeatEnter(&units, a, win.sid, x, y) catch return Error.OutOfMemory;
        wlpipe.appendSeatMotion(&units, a, x, y) catch return Error.OutOfMemory;
        wlpipe.appendSeatButton(&units, a, evdevButton(button), true) catch return Error.OutOfMemory;
        wlpipe.appendSeatButton(&units, a, evdevButton(button), false) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    pub fn scroll(self: *App, win_id: u32, x: f64, y: f64, dx: f64, dy: f64) Error!void {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendSeatEnter(&units, a, win.sid, x, y) catch return Error.OutOfMemory;
        if (dy != 0) wlpipe.appendSeatAxis(&units, a, 0, dy * 10.0, @intFromFloat(dy * 120.0)) catch return Error.OutOfMemory;
        if (dx != 0) wlpipe.appendSeatAxis(&units, a, 1, dx * 10.0, @intFromFloat(dx * 120.0)) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    /// Press-move-release drag. Motions go out in small bursts with
    /// pumps between so the app sees a gesture, not one event blob.
    pub fn drag(self: *App, win_id: u32, x1: f64, y1: f64, x2: f64, y2: f64, button: u32) Error!void {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendSeatEnter(&units, a, win.sid, x1, y1) catch return Error.OutOfMemory;
        wlpipe.appendSeatMotion(&units, a, x1, y1) catch return Error.OutOfMemory;
        wlpipe.appendSeatButton(&units, a, evdevButton(button), true) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
        const dist = @max(@abs(x2 - x1), @abs(y2 - y1));
        const steps: u32 = @intFromFloat(std.math.clamp(dist / 16.0, 4.0, 40.0));
        var i: u32 = 1;
        while (i <= steps) : (i += 1) {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            units.clearRetainingCapacity();
            wlpipe.appendSeatMotion(&units, a, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t) catch return Error.OutOfMemory;
            try self.sendIntents(win.chan, units.items);
            if (i % 4 == 0) _ = self.pumpOnce(5);
        }
        units.clearRetainingCapacity();
        wlpipe.appendSeatButton(&units, a, evdevButton(button), false) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    /// Fetch the app's AT-SPI accessibility tree as JSON (the daemon
    /// reads it from the session's private a11y bus). Caller owns.
    pub fn a11yTree(self: *App, timeout_ms: i64) Error![]u8 {
        return self.a11yRequest("", timeout_ms);
    }

    /// One AT-SPI node op — payload is the JSON op object the daemon
    /// expects ({op, id, ...}). Returns the raw JSON reply
    /// ({"ok":true} or {"error":...}); caller owns it.
    pub fn a11yOp(self: *App, payload: []const u8, timeout_ms: i64) Error![]u8 {
        return self.a11yRequest(payload, timeout_ms);
    }

    fn a11yRequest(self: *App, payload: []const u8, timeout_ms: i64) Error![]u8 {
        self.drain();
        if (self.exited) return Error.NotConnected;
        self.conn.sendFrame(.app_a11y, payload) catch return Error.NotConnected;
        // The reply may take a moment (the daemon walks the bus).
        // recvFrameFor, not recvFrame: a half-arrived frame from a
        // stalled daemon must time out, not block forever.
        const deadline = nowMs() + timeout_ms;
        while (nowMs() < deadline) {
            const f = self.conn.recvFrameFor(100) catch |err| switch (err) {
                error.Timeout => continue,
                else => return Error.NotConnected,
            };
            defer f.deinit(self.allocator);
            if (f.ftype == .app_a11y_tree)
                return self.allocator.dupe(u8, f.payload) catch Error.OutOfMemory;
            // Any other frame (events, chan data) is handled normally.
            self.handleFrame(f.ftype, f.payload);
        }
        return Error.Timeout;
    }

    // ── clipboard ───────────────────────────────────────────────

    /// Fetch what the app last copied. Requires the app to have
    /// announced a selection (clip_offer); pumps until the daemon
    /// pipes the bytes back. Caller owns the result.
    pub fn getClipboard(self: *App, timeout_ms: i64) Error![]u8 {
        self.drain();
        const offer = self.clip_offer orelse return Error.NoClipboard;
        const a = self.allocator;
        self.clip_got = false;
        var pl: std.ArrayList(u8) = .empty;
        defer pl.deinit(a);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, offer.source, .little);
        pl.appendSlice(a, &idb) catch return Error.OutOfMemory;
        pl.appendSlice(a, offer.mime) catch return Error.OutOfMemory;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendUnit(&units, a, .clip_send, pl.items) catch return Error.OutOfMemory;
        try self.sendIntents(offer.chan, units.items);
        const deadline = nowMs() + timeout_ms;
        while (!self.clip_got and nowMs() < deadline) {
            if (self.exited) return Error.NotConnected;
            _ = self.pumpOnce(25);
        }
        if (!self.clip_got) return Error.Timeout;
        return a.dupe(u8, self.clip_buf.items) catch Error.OutOfMemory;
    }

    /// Announce `text` as the host clipboard toward every app
    /// connection; served when the app pastes (onClipRead).
    pub fn setClipboard(self: *App, text: []const u8) Error!void {
        const a = self.allocator;
        const copy = a.dupe(u8, text) catch return Error.OutOfMemory;
        if (self.paste_data) |old| a.free(old);
        self.paste_data = copy;
        for (self.chans.values()) |ch| {
            var units: std.ArrayList(u8) = .empty;
            defer units.deinit(a);
            wlpipe.appendUnit(&units, a, .offer_selection, "text/plain;charset=utf-8") catch
                return Error.OutOfMemory;
            self.sendIntents(ch.id, units.items) catch {};
        }
    }

    /// Clipboard-paste text into a window: offer + Ctrl+V. The paste
    /// itself completes during subsequent pumps (waitIdle/drain).
    pub fn pasteText(self: *App, win_id: ?u32, text: []const u8) Error!void {
        try self.setClipboard(text);
        _ = try self.resolveKbd(win_id);
        try self.pressKey(win_id, "ctrl+v");
    }

    /// Aim the keyboard at a window (idempotent).
    fn kbdTarget(self: *App, win_id: u32) Error!*Window {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendSeatKbdEnter(&units, a, win.sid) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
        self.kbd_focus = win_id;
        return win;
    }

    /// Default keyboard target: the explicit id, or the first toplevel.
    fn resolveKbd(self: *App, win_id: ?u32) Error!*Window {
        if (win_id) |id| return self.kbdTarget(id);
        if (self.kbd_focus != 0) {
            if (self.winById(self.kbd_focus)) |w| return w;
        }
        for (self.windows.items) |w| {
            if (!w.popup) return self.kbdTarget(w.id);
        }
        return Error.NoSuchWindow;
    }

    /// Codepoint -> keycode+mods against the session's keymap (or
    /// the builtin us tables when no layout was parsed).
    fn charEntry(self: *App, cp: u21) ?xkblayout.Entry {
        if (cp == '\n') return .{ .code = evkeys.KEY_ENTER };
        if (cp == '\t') return .{ .code = 15 };
        if (self.layout) |*l| return l.lookup(cp);
        if (cp > 127) return null;
        const k = evkeys.charKey(@intCast(cp)) orelse return null;
        return .{ .code = k.code, .shift = k.shift };
    }

    pub fn typeText(self: *App, win_id: ?u32, text: []const u8) Error!void {
        // Anything the keymap can't express goes through the
        // clipboard-paste path instead.
        const view = std.unicode.Utf8View.init(text) catch
            return self.pasteText(win_id, text);
        var probe = view.iterator();
        while (probe.nextCodepoint()) |cp| {
            if (self.charEntry(cp) == null) return self.pasteText(win_id, text);
        }
        const win = try self.resolveKbd(win_id);
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        var held: u32 = 0;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            const e = self.charEntry(cp) orelse return Error.BadKey;
            const want: u32 = (@as(u32, @intFromBool(e.shift))) | (@as(u32, @intFromBool(e.altgr)) * 128);
            if (want != held) {
                held = want;
                wlpipe.appendSeatMods(&units, a, held, 0, 0, 0) catch return Error.OutOfMemory;
            }
            wlpipe.appendSeatKey(&units, a, e.code, true) catch return Error.OutOfMemory;
            wlpipe.appendSeatKey(&units, a, e.code, false) catch return Error.OutOfMemory;
        }
        if (held != 0) wlpipe.appendSeatMods(&units, a, 0, 0, 0, 0) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    pub fn pressKey(self: *App, win_id: ?u32, spec: []const u8) Error!void {
        var chord = evkeys.parseChord(spec) orelse return Error.BadKey;
        if (chord.ch) |ch| {
            // Chord letters name CHARACTERS ("ctrl+c" means the key
            // that types 'c'), so they follow the session layout.
            if (self.layout != null) {
                const e = self.charEntry(ch) orelse return Error.BadKey;
                chord.key.code = e.code;
                chord.mods.shift = chord.mods.shift or e.shift;
                chord.mods.altgr = e.altgr;
            }
        }
        const win = try self.resolveKbd(win_id);
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        if (chord.mods.any())
            wlpipe.appendSeatMods(&units, a, chord.mods.bits(), 0, 0, 0) catch return Error.OutOfMemory;
        wlpipe.appendSeatKey(&units, a, chord.key.code, true) catch return Error.OutOfMemory;
        wlpipe.appendSeatKey(&units, a, chord.key.code, false) catch return Error.OutOfMemory;
        if (chord.mods.any())
            wlpipe.appendSeatMods(&units, a, 0, 0, 0, 0) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    pub fn resizeWindow(self: *App, win_id: u32, w: i32, h: i32) Error!void {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendConfigure(&units, a, win.sid, w, h, 1) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    pub fn closeWindow(self: *App, win_id: u32) Error!void {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendRequestClose(&units, a, win.sid) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    // ── capture ─────────────────────────────────────────────────

    /// Start recording a window's frames as GIF (`webm` false) or
    /// WebM/VP9 (`webm` true). Replaces any recording in progress.
    pub fn recordStart(self: *App, win_id: u32, max_dim: u32, webm: bool) Error!void {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        if (self.rec) |*r| r.abort();
        if (self.vrec) |*r| r.abort();
        self.rec = null;
        self.vrec = null;
        if (webm)
            self.vrec = videorec.Rec.init(self.allocator, max_dim)
        else
            self.rec = gifrec.Rec.init(self.allocator, max_dim);
        self.rec_win = win.id;
        // Seed with the current frame so recording starts from "now".
        if (win.w > 0 and win.pixels.items.len > 0) {
            const t = nowMs();
            if (self.rec) |*r| r.addShmFrame(win.pixels.items, @intCast(win.w), @intCast(win.h), win.format, t) catch {};
            if (self.vrec) |*r| r.addShmFrame(win.pixels.items, @intCast(win.w), @intCast(win.h), win.format, t) catch {};
        }
    }

    /// Stop recording; returns the encoded bytes (caller owns), the
    /// frame count, and whether it is WebM (else GIF).
    pub fn recordStop(self: *App) Error!struct { data: []u8, frames: usize, webm: bool } {
        if (self.vrec) |vr| {
            var r = vr; // copy out before clearing the optional
            self.vrec = null;
            const frames = r.frames;
            const data = r.finish(nowMs()) catch |err| return switch (err) {
                videorec.Error.OutOfMemory => Error.OutOfMemory,
                else => Error.Timeout,
            };
            return .{ .data = data, .frames = frames, .webm = true };
        }
        var r = self.rec orelse return Error.NotRecording;
        self.rec = null;
        const frames = r.frames + @intFromBool(r.pend != null);
        const gif = r.finish(nowMs()) catch |err| {
            return switch (err) {
                gifrec.Error.OutOfMemory => Error.OutOfMemory,
                else => Error.Timeout, // no frames captured
            };
        };
        return .{ .data = gif, .frames = frames, .webm = false };
    }

    pub const Shot = struct {
        png: []u8,
        /// Emitted image dimensions (after crop/zoom/downscale).
        img_w: u32,
        img_h: u32,
        /// Surface pixels per image pixel; multiply image coords by
        /// this (then add ox/oy) to get click coordinates. 1.0 = 1:1.
        scale: f64,
        /// Surface coordinates of the image's top-left (crop origin).
        ox: u32 = 0,
        oy: u32 = 0,
    };

    /// Sub-rectangle of a window in surface pixels (screenshot crop).
    pub const Region = struct { x: u32, y: u32, w: u32, h: u32 };

    /// Latest committed pixels of one window as a PNG: optional
    /// `region` crop, optional integer `zoom` (nearest-neighbor, for
    /// pixel inspection), then downscaled so neither dimension exceeds
    /// `max_dim` (0 = no bound). Caller owns `.png`. Moves the
    /// wait_change/diff baseline ("what the caller last saw").
    pub fn screenshotPng(self: *App, win_id: u32, max_dim: u32, region: ?Region, zoom_req: u32) Error!Shot {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        if (win.w <= 0 or win.h <= 0 or win.pixels.items.len == 0) return Error.NoSuchWindow;
        win.rememberShot(self.allocator);
        return self.encodeWindowPng(win, max_dim, region, zoom_req);
    }

    /// PNG-encode a window WITHOUT touching the observation baseline
    /// (marker stashes must not eat a pending wait_change).
    fn encodeWindowPng(self: *App, win: *Window, max_dim: u32, region: ?Region, zoom_req: u32) Error!Shot {
        if (win.w <= 0 or win.h <= 0 or win.pixels.items.len == 0) return Error.NoSuchWindow;
        const uw: u32 = @intCast(win.w);
        const uh: u32 = @intCast(win.h);
        const a = self.allocator;

        var ox: u32 = 0;
        var oy: u32 = 0;
        var cw: u32 = uw;
        var ch: u32 = uh;
        if (region) |r| {
            if (r.x >= uw or r.y >= uh or r.w == 0 or r.h == 0) return Error.NoSuchWindow;
            ox = r.x;
            oy = r.y;
            cw = @min(r.w, uw - r.x);
            ch = @min(r.h, uh - r.y);
        }
        const zoom: u32 = @max(1, zoom_req);
        const longest = @max(cw, ch) * zoom;

        // Fast path: whole window, no zoom, within the bound.
        if (region == null and zoom == 1 and (max_dim == 0 or longest <= max_dim)) {
            const bytes = png.encodeShm(a, win.pixels.items, uw, uh, uw * 4, win.format) catch
                return Error.OutOfMemory;
            return .{ .png = bytes, .img_w = uw, .img_h = uh, .scale = 1.0 };
        }

        var rgba = png.shmToRgba(a, win.pixels.items, uw, uh, uw * 4, win.format) catch
            return Error.OutOfMemory;
        var rw: u32 = uw;
        var rh: u32 = uh;
        defer a.free(rgba);

        if (region != null) {
            const crop = a.alloc(u8, @as(usize, cw) * ch * 4) catch return Error.OutOfMemory;
            var y: usize = 0;
            while (y < ch) : (y += 1) {
                const src = ((@as(usize, oy) + y) * uw + ox) * 4;
                @memcpy(crop[y * cw * 4 ..][0 .. @as(usize, cw) * 4], rgba[src..][0 .. @as(usize, cw) * 4]);
            }
            a.free(rgba);
            rgba = crop;
            rw = cw;
            rh = ch;
        }
        if (zoom > 1) {
            const big = png.upscaleRgba(a, rgba, rw, rh, zoom) catch return Error.OutOfMemory;
            a.free(rgba);
            rgba = big;
            rw *= zoom;
            rh *= zoom;
        }
        if (max_dim != 0 and @max(rw, rh) > max_dim) {
            const l = @max(rw, rh);
            const dw: u32 = @max(1, rw * max_dim / l);
            const dh: u32 = @max(1, rh * max_dim / l);
            const small = png.downscaleRgba(a, rgba, rw, rh, dw, dh) catch return Error.OutOfMemory;
            a.free(rgba);
            rgba = small;
            rw = dw;
            rh = dh;
        }
        const bytes = png.encodeRgba(a, rgba, rw, rh) catch return Error.OutOfMemory;
        return .{
            .png = bytes,
            .img_w = rw,
            .img_h = rh,
            // Surface px per image px over the CROPPED region.
            .scale = @as(f64, @floatFromInt(cw)) / @as(f64, @floatFromInt(rw)),
            .ox = ox,
            .oy = oy,
        };
    }

    /// Pump until this window has committed a frame NEWER than its
    /// last screenshot (bounded). True when new content arrived.
    pub fn waitWindowChange(self: *App, win_id: u32, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (nowMs() < deadline) {
            const win = self.winById(win_id) orelse return false;
            if (win.frames != win.shot_frames) return true;
            if (self.exited) return false;
            _ = self.pumpOnce(25);
        }
        const win = self.winById(win_id) orelse return false;
        return win.frames != win.shot_frames;
    }

    /// Pump until the window has committed NO new frame for
    /// `stable_ms` (settle-then-capture), bounded by `timeout_ms`.
    /// False = frames were still landing at the deadline.
    pub fn waitWindowSettle(self: *App, win_id: u32, stable_ms: i64, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        var last: u64 = (self.winById(win_id) orelse return false).frames;
        var quiet_since = nowMs();
        while (nowMs() < deadline) {
            if (self.exited) return true;
            _ = self.pumpOnce(25);
            const win = self.winById(win_id) orelse return false;
            if (win.frames != last) {
                last = win.frames;
                quiet_since = nowMs();
            } else if (nowMs() - quiet_since >= stable_ms) return true;
        }
        return false;
    }

    pub const DiffStats = struct {
        changed: bool,
        resized: bool,
        diff_pct: f64,
        w: i32,
        h: i32,
        frames: u64,
    };

    /// Changed fraction vs the baseline WITHOUT moving it — burst
    /// capture gates on this before paying for a PNG encode.
    pub fn peekDiffPct(self: *App, win_id: u32) f64 {
        const win = self.winById(win_id) orelse return 0;
        // Pixels only change on a commit; same frame counter = same content.
        if (win.frames == win.shot_frames) return 0;
        return win.pctVsBaseline();
    }

    /// Cheap "did it change" answer: compare current pixels against the
    /// baseline from the last screenshot/stats call, then move the
    /// baseline forward. No image is encoded.
    pub fn diffStats(self: *App, win_id: u32) Error!DiffStats {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        if (win.w <= 0 or win.h <= 0 or win.pixels.items.len == 0) return Error.NoSuchWindow;
        const had_baseline = win.shot_pixels.items.len != 0;
        const resized = had_baseline and (win.shot_w != win.w or win.shot_h != win.h);
        const pct = win.pctVsBaseline();
        const stats = DiffStats{
            .changed = win.frames != win.shot_frames and pct > 0,
            .resized = resized,
            .diff_pct = pct,
            .w = win.w,
            .h = win.h,
            .frames = win.frames,
        };
        win.rememberShot(self.allocator);
        return stats;
    }
};
