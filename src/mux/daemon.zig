//! sketerm-mux daemon core: sessions that outlive GUI clients.
//!
//! Single-threaded poll loop — no GLib, no GTK, no worker threads.
//! Each session owns a PTY + Parser + authoritative Screen. PTY
//! output is parsed once; events are applied to the Screen AND
//! broadcast (wire-serialized) to every attached client. A client
//! that attaches mid-stream gets a full snapshot first, then the
//! live event stream — that is the whole reattach story.
//!
//! Dependencies: libc (PTY, poll) + the GTK-free terminal core.
//! Must stay linkable without GTK so the daemon deploys to servers
//! as one lean binary.

const std = @import("std");
const c = @import("../c.zig").c;
const wire = @import("wire.zig");
const wlwire = @import("../wlhost/wire.zig");
const wltrack = @import("../wlhost/track.zig");
const wlproto = @import("../wlhost/protocol.zig");
const wlpipe = @import("../wlhost/pipe.zig");
const wlpixcodec = @import("../wlhost/pixcodec.zig");
const build_options = @import("build_options");
const wlvcodec = @import("../wlhost/vcodec.zig");
const churnmod = @import("../util/churn.zig");
const contentmod = @import("../util/content.zig");
const wsproto = @import("../winstream/proto.zig");
const wssource = @import("../winstream/source.zig");
const WsSource = wssource.Source;
const snapshot = @import("snapshot.zig");
const Pty = @import("../pty.zig").Pty;
const Parser = @import("../parser/vt.zig").Parser;
const Event = @import("../parser/event.zig").Event;
const Screen = @import("../grid/screen.zig").Screen;
const Pool = @import("../grid/style_pool.zig").Pool;

/// Monotonic milliseconds — the daemon's own clock. Idle durations are
/// computed daemon-side (never as a client-vs-daemon timestamp diff) so a
/// remote client whose clock differs still sees the right age.
fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @intCast(ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1_000_000));
}

/// The working directory of a session's child via `/proc/<pid>/cwd`. The
/// daemon owns the PID, so this is authoritative even when the shell never
/// emits OSC 7 — clients (which have no local pid for a daemon-backed pane)
/// rely on it for `list` and layout-save. Writes into `buf`, returns the
/// slice or null. Linux-only; harmless elsewhere (readlink fails → null).
fn cwdOfPid(pid: c.pid_t, buf: []u8) ?[]const u8 {
    if (pid <= 0) return null;
    var path_buf: [64]u8 = undefined;
    const link = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/cwd", .{pid}) catch return null;
    const n = c.readlink(link.ptr, buf.ptr, buf.len);
    if (n <= 0) return null;
    return buf[0..@intCast(n)];
}

pub const SpawnReq = struct {
    name: []const u8 = "",
    argv: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    rows: u16 = 24,
    cols: u16 = 80,
    /// One-shot forwarded GUI app (`sketerm app -u`), not an
    /// interactive shell — listed differently by clients.
    app: bool = false,
    /// Force the window-stream backend for this session (the
    /// explicit form of SKETERM_WINSTREAM; what `sketerm app`
    /// toward capture-only remotes will set).
    winstream: bool = false,
    /// Run the session under a private XDG_RUNTIME_DIR with the shared
    /// D-Bus session bus dropped (`sketerm app -i`). Isolates
    /// single-instance apps so each forwarded copy renders on its own
    /// client instead of coalescing into the first one.
    isolated: bool = false,
    /// GUI pane id + IPC socket to export into the child env as
    /// SKETERM_PANE_ID / SKETERM_SOCKET so `sketerm cli --pane self` works
    /// from inside a daemon-backed pane. The GUI passes its own values; they
    /// reflect the spawning client (may go stale after a cross-GUI reattach —
    /// acceptable for the common case). 0 / "" = don't export.
    pane_id: u32 = 0,
    socket: []const u8 = "",
    /// Child TERM / COLORTERM. Empty → Pty.spawn defaults. The GUI passes its
    /// profile's term_env/color_term_env so a daemon-backed local pane gets
    /// the same environment an in-process pane would.
    term: []const u8 = "",
    color_term: []const u8 = "",
    /// Spawn argv[0] as a login shell (leading `-`).
    login_shell: bool = false,
    /// GUI-owned LOCAL session sharing the user's desktop: skip the
    /// wlhost Wayland hub so child GUI apps talk to the real desktop
    /// compositor directly (via `host_wayland_display`) instead of
    /// sketerm's embedded one. Remote/durable sessions leave this
    /// false and get the forwarding hub (which roams with the
    /// session). Only the local ephemeral pane factory sets it.
    local: bool = false,
    /// The GUI's own $WAYLAND_DISPLAY, applied to the child when
    /// `local` is set — the daemon's inherited value may be stale
    /// (it outlives the GUI that started it) or absent. Empty leaves
    /// the child to inherit the daemon's env (X11 / no Wayland).
    host_wayland_display: []const u8 = "",
    /// Auto shell-integration (OSC 7/133 without rc edits). All paths are on
    /// the daemon host; the GUI only fills this for the LOCAL daemon, where
    /// the integration scripts exist. null = off.
    shell_integration: ?SpawnShellIntegration = null,
};

pub const SpawnShellIntegration = struct {
    kind: []const u8 = "", // "zsh" | "fish"
    script: []const u8 = "",
    shim_dir: []const u8 = "",
};

pub const AttachReq = struct {
    name: []const u8 = "",
};

pub const RenameReq = struct {
    name: []const u8 = "",
    new_name: []const u8 = "",
};

pub const SessionInfo = struct {
    name: []const u8,
    rows: u16,
    cols: u16,
    clients: u32,
    exited: bool,
    title: []const u8 = "",
    app: bool = false,
    /// Milliseconds since this session last produced output, computed on the
    /// daemon's own clock at list time (never a client-vs-daemon timestamp
    /// diff — a remote daemon's monotonic clock differs from the caller's).
    idle_ms: i64 = 0,
    /// Child's current working directory (from /proc, daemon-resolved). Empty
    /// if unavailable. Lets `list` show it and gives layout-save a cwd source
    /// for daemon-backed panes (which have no local pid).
    cwd: []const u8 = "",
};

const Session = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    pty: Pty,
    parser: Parser,
    pool: *Pool,
    screen: *Screen,
    /// Sequence number of the NEXT event to be broadcast.
    seq: u64 = 0,
    /// Monotonic-ms timestamp of the last PTY output that produced parser
    /// events (real terminal activity). Drives the active/idle indicator in
    /// `list` — computed daemon-side so detached sessions are observable with
    /// no client attached. Seeded at spawn (a fresh session is "active").
    last_activity_ms: i64 = 0,
    exited: bool = false,
    exit_status: i32 = 0,
    /// Spawned via `sketerm app -u` — a forwarded GUI app, not a shell.
    app: bool = false,
    /// Wayland app forwarding: the daemon IS the Wayland display —
    /// wl_hub_fd listens on the session's display socket itself, sets
    /// the shell's $WAYLAND_DISPLAY, and each app connection is parsed
    /// + shm-mirrored (Channel.native) and tunneled to the attached
    /// client as a byte channel. -1 = no Wayland support this session.
    wl_hub_fd: c_int = -1,
    /// Owned display socket path, unlinked on teardown.
    wl_display_path: ?[]u8 = null,
    /// Isolated session (`sketerm app -i`): owned private runtime-dir
    /// path, recursively removed on teardown. null = not isolated.
    runtime_dir_path: ?[]u8 = null,
    /// Window-stream agent (pixel capture, no display protocol):
    /// the macOS backend, or the stub for pipeline testing
    /// (SKETERM_WINSTREAM=stub). Mutually exclusive with Wayland
    /// forwarding.
    winstream: ?*WsSource = null,
    /// App display connections accepted BEFORE any channel-capable
    /// client attached. Wayland clients block on an unanswered
    /// socket, so queueing here keeps a freshly-spawned app alive
    /// through the spawn→GUI-attach handover gap.
    wl_pending: std.ArrayList(c_int) = .empty,

    fn deinit(self: *Session) void {
        for (self.wl_pending.items) |fd| _ = c.close(fd);
        self.wl_pending.deinit(self.allocator);
        if (self.winstream) |ws| {
            ws.deinit();
            self.allocator.destroy(ws);
        }
        if (self.wl_hub_fd >= 0) _ = c.close(self.wl_hub_fd);
        var z_buf: [4096]u8 = undefined;
        if (self.wl_display_path) |p| {
            if (pathZ(&z_buf, p)) |z| _ = c.unlink(z) else |_| {}
            self.allocator.free(p);
        }
        if (self.runtime_dir_path) |p| {
            removeTreeBestEffort(p);
            self.allocator.free(p);
        }
        if (self.pty.closeAndReap()) |code| self.exit_status = code;
        self.parser.deinit();
        self.screen.deinit();
        self.pool.deinit();
        self.allocator.destroy(self.pool);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Screen sink: DSR/DA replies go straight back to the child.
    fn sinkWritePty(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        _ = self.pty.writeAll(bytes);
    }
};

/// Broker-side record of a forked session worker. The broker holds no Screen;
/// it tracks just enough to route clients (control_fd), answer `list` (cached
/// metadata pushed by the worker, filled in B3), and reap (pid + dead).
const Worker = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    pid: c.pid_t,
    /// Broker end of the broker↔worker control socketpair. Carries passed
    /// client fds (SCM_RIGHTS), kill/rename control bytes, and metadata pushes.
    control_fd: c_int,
    dead: bool = false,
    /// Spawn handshake: the broker defers the spawn `.ok`/`.err` reply until
    /// the worker confirms its session is up ('Y' ready) or dies first
    /// (control EOF before ready = spawn failed). `pending_client` is the
    /// client awaiting that reply (blocked in recvExpect(.ok)); validated
    /// against the live client list before use (the GUI could vanish).
    ready: bool = false,
    pending_client: ?*Client = null,
    /// Cached for `list`, kept current by the worker's metadata pushes ('M'
    /// control datagrams). `last_activity_ms` is on the shared CLOCK_MONOTONIC
    /// clock (same machine), so the broker computes idle_ms straight off it.
    rows: u16 = 24,
    cols: u16 = 80,
    exited: bool = false,
    app: bool = false,
    n_clients: u32 = 0,
    last_activity_ms: i64 = 0,
    /// Owned copies of the worker's last-pushed title / cwd (null = none yet).
    title: ?[]u8 = null,
    cwd: ?[]u8 = null,

    fn deinit(self: *Worker) void {
        if (self.control_fd >= 0) _ = c.close(self.control_fd);
        self.allocator.free(self.name);
        if (self.title) |t| self.allocator.free(t);
        if (self.cwd) |cw| self.allocator.free(cw);
        self.allocator.destroy(self);
    }
};

/// Worker→broker metadata push payload (JSON over the 'M' control datagram).
/// Excludes the session name — that is broker-authoritative (rename updates
/// `Worker.name`; a stale name in a push must never clobber it).
const WorkerMeta = struct {
    rows: u16 = 24,
    cols: u16 = 80,
    clients: u32 = 0,
    exited: bool = false,
    app: bool = false,
    activity: i64 = 0,
    title: []const u8 = "",
    cwd: []const u8 = "",
};

/// Worker-side throttle state for metadata pushes. Structural changes (client
/// count, size, exit, title) push immediately; bare activity advances are
/// rate-limited (the broker derives idle_ms from `activity` against its own
/// clock, so a small lag costs nothing).
const WorkerPush = struct {
    inited: bool = false,
    clients: u32 = 0,
    exited: bool = false,
    rows: u16 = 0,
    cols: u16 = 0,
    title_hash: u64 = 0,
    activity: i64 = 0,
    last_push_ms: i64 = 0,
};

const Client = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    rbuf: std.ArrayList(u8) = .empty,
    wbuf: std.ArrayList(u8) = .empty,
    attached: ?*Session = null,
    dead: bool = false,
    /// Protocol version the client announced in hello. Channels are
    /// only opened toward proto >= 2 clients.
    proto: u32 = 1,
    /// The client advertised it can decode the video codec (hello
    /// `video`). Gates whether forwarded surfaces route through the lossy
    /// video path — never send a tile a client can't decode.
    video: bool = false,

    fn deinit(self: *Client) void {
        _ = c.close(self.fd);
        self.rbuf.deinit(self.allocator);
        self.wbuf.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn queueFrame(self: *Client, ftype: wire.FrameType, payload: []const u8) void {
        wire.appendFrame(&self.wbuf, self.allocator, ftype, payload) catch {
            self.dead = true;
        };
    }

    fn queueJson(self: *Client, ftype: wire.FrameType, value: anytype) void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        std.json.Stringify.value(value, .{}, &aw.writer) catch {
            self.dead = true;
            return;
        };
        self.queueFrame(ftype, aw.written());
    }

    fn queueErr(self: *Client, msg: []const u8) void {
        self.queueJson(.err, .{ .@"error" = msg });
    }
};

const pathZ = @import("../util/pathz.zig").pathZ;

/// Recursively remove `path` and everything under it, best-effort:
/// every failure is ignored (the dir lives on a tmpfs runtime dir that
/// the OS reclaims at logout anyway). Used to tear down an isolated
/// session's private XDG_RUNTIME_DIR, which apps fill with sockets and
/// the odd subdir (dbus-1/, pulse/) we don't track individually.
fn removeTreeBestEffort(path: []const u8) void {
    var z_buf: [4096]u8 = undefined;
    const zpath = pathZ(&z_buf, path) catch return;
    if (c.opendir(zpath)) |dir| {
        while (c.readdir(dir)) |ent| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var child_buf: [4096]u8 = undefined;
            const child = std.fmt.bufPrintZ(&child_buf, "{s}/{s}", .{ path, name }) catch continue;
            // unlinkat fails on a directory (EISDIR/EPERM) → recurse,
            // then drop the now-empty dir with AT_REMOVEDIR.
            if (c.unlinkat(c.AT_FDCWD, child.ptr, 0) != 0) {
                removeTreeBestEffort(child);
                _ = c.unlinkat(c.AT_FDCWD, child.ptr, c.AT_REMOVEDIR);
            }
        }
        _ = c.closedir(dir);
    }
    _ = c.rmdir(zpath);
}

/// One tunneled byte stream, bridged to `client` as chan_* frames:
/// a Wayland app connection (`native` set) or a window-stream session
/// (`native` null, fd -1, frames produced in the daemon).
const Channel = struct {
    allocator: std.mem.Allocator,
    id: u32,
    fd: c_int,
    session: *Session,
    client: *Client,
    /// Bytes from the client not yet written to fd (partial writes).
    pending: std.ArrayList(u8) = .empty,
    dead: bool = false,
    /// Non-null on a Wayland app channel: the app speaks raw Wayland
    /// to us and the byte stream toward the GUI is wlhost/pipe units.
    native: ?*Native = null,

    fn deinit(self: *Channel) void {
        if (self.native) |nv| nv.deinit();
        _ = c.close(self.fd);
        self.pending.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// Per-channel state of the sketerm-native app pipe: the session's
/// app connects straight to the daemon. Owns the protocol tracker
/// and the mmapped shm pool mirrors.
const Native = struct {
    allocator: std.mem.Allocator,
    tracker: wltrack.Tracker,
    /// Raw bytes from the app socket; messages may arrive split.
    inbuf: std.ArrayList(u8) = .empty,
    /// SCM_RIGHTS fds awaiting their create_pool message (Wayland
    /// pairs fds with messages in arrival order).
    fds: std.ArrayList(c_int) = .empty,
    /// GUI→app unit stream reassembly (chan_data may split units).
    unitbuf: std.ArrayList(u8) = .empty,
    /// Fds to attach (SCM_RIGHTS) to the NEXT write toward the app.
    /// Early arrival is fine — libwayland queues fds until the
    /// consuming message shows up; late is the only fatal order.
    out_fds: std.ArrayList(c_int) = .empty,
    /// Paste: write-ends from wl_data_offer.receive, FIFO-paired
    /// with clip_data units coming from the GUI.
    clip_paste_fds: std.ArrayList(c_int) = .empty,
    /// Copy: read-ends of pipes whose write-ends went to the app
    /// via wl_data_source.send; EOF ships a clip_data unit up.
    clip_reads: std.ArrayList(ClipRead) = .empty,
    /// pool id → mmapped mirror. Mirrors outlive wl_shm_pool
    /// destructors: existing buffers keep referencing the memory.
    pools: std.AutoHashMapUnmanaged(u32, PoolMirror) = .empty,
    /// Per-surface lossy-video state (only populated under
    /// build_options.video): a churn tracker + a fixed-resolution
    /// encoder, keyed by surface id. Hot, photographic surfaces route
    /// through here to pool_vtile instead of the lossless pool_update_c.
    vstate: std.AutoHashMapUnmanaged(u32, VideoSurface) = .empty,
    /// Scratch reused across commits: tight full-surface BGRA, and the
    /// encoded vcodec tile blob.
    vscratch: std.ArrayList(u8) = .empty,
    vblob: std.ArrayList(u8) = .empty,
    /// Set once the attached client advertises it can decode the video
    /// codec (capability negotiation — not yet implemented). Until then
    /// videoCommit stays dormant: never emit a tile no client can decode.
    wants_video: bool = false,

    const VideoSurface = struct {
        churn: churnmod.Tracker,
        enc: wlvcodec.Encoder,
        w: i32,
        h: i32,
        seq: u32 = 0,
        needs_kf: bool = true,

        fn deinit(self: *VideoSurface) void {
            self.churn.deinit();
            self.enc.deinit();
        }
    };

    const ClipRead = struct {
        fd: c_int,
        buf: std.ArrayList(u8) = .empty,
    };

    const PoolMirror = struct {
        fd: c_int,
        ptr: [*]u8,
        size: usize,
    };

    fn deinit(self: *Native) void {
        var it = self.pools.valueIterator();
        while (it.next()) |p| {
            _ = c.munmap(p.ptr, p.size);
            _ = c.close(p.fd);
        }
        self.pools.deinit(self.allocator);
        for (self.fds.items) |fd| _ = c.close(fd);
        self.fds.deinit(self.allocator);
        for (self.out_fds.items) |fd| _ = c.close(fd);
        self.out_fds.deinit(self.allocator);
        for (self.clip_paste_fds.items) |fd| _ = c.close(fd);
        self.clip_paste_fds.deinit(self.allocator);
        for (self.clip_reads.items) |*cr| {
            _ = c.close(cr.fd);
            cr.buf.deinit(self.allocator);
        }
        self.clip_reads.deinit(self.allocator);
        self.inbuf.deinit(self.allocator);
        self.unitbuf.deinit(self.allocator);
        var vit = self.vstate.valueIterator();
        while (vit.next()) |v| v.deinit();
        self.vstate.deinit(self.allocator);
        self.vscratch.deinit(self.allocator);
        self.vblob.deinit(self.allocator);
        self.tracker.deinit();
        self.allocator.destroy(self);
    }

    /// Lossy-video routing for a commit (build_options.video only). Feeds
    /// per-surface churn; when the surface is HOT and looks photographic,
    /// encodes the WHOLE surface as one H.264 tile and emits a pool_vtile,
    /// returning true so the caller skips the lossless path. Any failure
    /// (odd dims, encoder open, mirror too small) returns false → lossless.
    fn videoCommit(nv: *Native, units: *std.ArrayList(u8), a: std.mem.Allocator, cm: anytype, mirror: PoolMirror, y0: i64, y1: i64) !bool {
        if (!nv.wants_video) return false; // no client can decode video yet
        const w = cm.info.width;
        const h = cm.info.height;
        if (w <= 0 or h <= 0 or @rem(w, 2) != 0 or @rem(h, 2) != 0) return false; // codec needs even dims
        const stride: usize = @intCast(cm.info.stride);
        const base: usize = @intCast(cm.info.offset);
        const uw: usize = @intCast(w);
        const uh: usize = @intCast(h);
        const tight = uw * 4;
        if (base + (uh - 1) * stride + tight > mirror.size) return false; // whole surface must fit

        const gop = try nv.vstate.getOrPut(nv.allocator, cm.surface);
        if (!gop.found_existing or gop.value_ptr.w != w or gop.value_ptr.h != h) {
            if (gop.found_existing) gop.value_ptr.deinit();
            var enc = wlvcodec.Encoder.initX264(nv.allocator, w, h, 30) catch {
                _ = nv.vstate.remove(cm.surface);
                return false;
            };
            const tracker = churnmod.Tracker.init(nv.allocator, @intCast(w), @intCast(h), .{}) catch {
                enc.deinit();
                _ = nv.vstate.remove(cm.surface);
                return false;
            };
            gop.value_ptr.* = .{ .churn = tracker, .enc = enc, .w = w, .h = h };
        }
        const vs = gop.value_ptr;

        // Advance churn with this commit's damage (full-width rows).
        vs.churn.noteDamage(0, @intCast(y0), w, @intCast(y1 - y0));
        vs.churn.endFrame();
        if (!vs.churn.hot(0, 0, w, h)) return false;

        // Extract the whole surface tightly (drop stride padding).
        try nv.vscratch.resize(nv.allocator, uw * uh * 4);
        for (0..uh) |r| {
            @memcpy(nv.vscratch.items[r * tight ..][0..tight], mirror.ptr[base + r * stride ..][0..tight]);
        }
        if (!contentmod.looksPhotographic(nv.vscratch.items, .{})) return false;

        const res = vs.enc.encodeTile(w, h, nv.vscratch.items, vs.needs_kf) catch return false;
        vs.needs_kf = false;

        nv.vblob.clearRetainingCapacity();
        wlvcodec.appendTile(&nv.vblob, nv.allocator, .{
            .codec = vs.enc.codec(),
            .keyframe = res.keyframe,
            .x = 0,
            .y = 0,
            .w = w,
            .h = h,
            .seq = vs.seq,
            .payload = res.bytes,
        }) catch return false;
        vs.seq +%= 1;

        try wlpipe.appendPoolVtile(units, a, cm.info.pool, @intCast(base), @intCast(stride), nv.vblob.items);
        return true;
    }

    fn popFd(self: *Native) ?c_int {
        if (self.fds.items.len == 0) return null;
        return self.fds.orderedRemove(0);
    }
};

/// Bind + listen on a fresh Unix socket. Shared with client.zig's
/// connect for the sockaddr_un fill.
pub fn fillSockaddrUn(addr: *c.struct_sockaddr_un, path: []const u8) error{BadPath}!void {
    addr.* = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    if (path.len >= addr.sun_path.len) return error.BadPath;
    @memcpy(addr.sun_path[0..path.len], path);
}

/// An in-flight file upload from a client. The client streams bytes
/// (file_data frames); we write them straight into a file opened in
/// the session shell's working directory. Lives only for the duration
/// of one transfer — finalized by file_close or dropped with its
/// client. `xfer` is the CLIENT's id (unique per client, not globally).
const Upload = struct {
    allocator: std.mem.Allocator,
    client: *Client,
    xfer: u32,
    /// Open destination fd (O_WRONLY), or -1 once closed/aborted.
    fd: c_int,
    /// Bytes written so far — echoed back in file_reply for flow control.
    written: u64 = 0,
    /// Resolved absolute destination path (owned), reported to the client.
    path: []u8,

    fn deinit(self: *Upload) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
};

/// An in-flight file download to a client. The daemon reads a file
/// from the remote filesystem and streams it out as file_data frames
/// (the reverse of Upload). Paced by `pumpDownloads` against the
/// client's write-buffer high-water mark so a big file can't balloon
/// memory. `xfer` is the CLIENT's id.
const Download = struct {
    allocator: std.mem.Allocator,
    client: *Client,
    xfer: u32,
    /// Open source fd (O_RDONLY), or -1 once finished.
    fd: c_int,
    size: u64 = 0,
    sent: u64 = 0,

    fn deinit(self: *Download) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.allocator.destroy(self);
    }
};

pub const Daemon = struct {
    allocator: std.mem.Allocator,
    listen_fd: c_int,
    /// Owned socket path; unlinked on deinit.
    sock_path: []u8,
    sessions: std.ArrayList(*Session) = .empty,
    clients: std.ArrayList(*Client) = .empty,
    channels: std.ArrayList(*Channel) = .empty,
    /// In-flight file uploads (file_* frames), keyed by (client, xfer).
    uploads: std.ArrayList(*Upload) = .empty,
    /// In-flight file downloads (file_get), keyed by (client, xfer).
    downloads: std.ArrayList(*Download) = .empty,
    next_chan_id: u32 = 1,
    /// Monotonic id for per-session Wayland socket paths (session
    /// names are user input — not path-safe).
    next_wl_id: u32 = 1,
    /// Monotonic id for isolated sessions' private runtime dirs (same
    /// path-safety reason as next_wl_id).
    next_rt_id: u32 = 1,
    running: bool = true,
    /// Process-isolation mode (Firefox-style). A WORKER process owns exactly
    /// one session and has `control_fd` >= 0 (a socketpair to the broker)
    /// instead of a listen socket — new clients arrive as passed fds, not via
    /// accept(). A BROKER process listens, holds NO sessions, and forks one
    /// worker per session, handing client fds to workers on attach. The
    /// default (both -1 / false) is the legacy monolith — kept working until
    /// the broker path is the proven default.
    control_fd: c_int = -1,
    is_broker: bool = false,
    /// Broker only: forked session workers, by session name.
    workers: std.ArrayList(*Worker) = .empty,
    /// Worker only: last metadata signature pushed to the broker, so
    /// `maybePushMeta` only sends on a real change (and throttles activity).
    wpush: WorkerPush = .{},
    /// Worker only: runtime dir (owned) for the session's Wayland display /
    /// isolated rt sockets. A worker has no listen socket, so it can't derive
    /// the dir from `sock_path` ("") the way the monolith/broker does — the
    /// broker hands it the dir at fork time. null in monolith/broker.
    base_dir: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, sock_path: []const u8) !*Daemon {
        const dir_end = std.mem.lastIndexOfScalar(u8, sock_path, '/') orelse return error.BadPath;
        // mkdir -p the parent (one level is enough in practice:
        // $XDG_RUNTIME_DIR exists; we create the sketerm dir).
        var z_buf: [4096]u8 = undefined;
        _ = c.mkdir(try pathZ(&z_buf, sock_path[0..dir_end]), 0o700);
        _ = c.unlink(try pathZ(&z_buf, sock_path));

        const fd = @import("../util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        var addr: c.struct_sockaddr_un = undefined;
        try fillSockaddrUn(&addr, sock_path);
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return error.BindFailed;
        if (c.listen(fd, 8) != 0) return error.ListenFailed;

        const self = try allocator.create(Daemon);
        self.* = .{
            .allocator = allocator,
            .listen_fd = fd,
            .sock_path = try allocator.dupe(u8, sock_path),
        };
        return self;
    }

    pub fn deinit(self: *Daemon) void {
        for (self.uploads.items) |u| u.deinit();
        self.uploads.deinit(self.allocator);
        for (self.downloads.items) |dl| dl.deinit();
        self.downloads.deinit(self.allocator);
        for (self.channels.items) |ch| ch.deinit();
        self.channels.deinit(self.allocator);
        for (self.clients.items) |cl| cl.deinit();
        self.clients.deinit(self.allocator);
        for (self.sessions.items) |s| s.deinit();
        self.sessions.deinit(self.allocator);
        for (self.workers.items) |w| w.deinit();
        self.workers.deinit(self.allocator);
        if (self.listen_fd >= 0) _ = c.close(self.listen_fd);
        if (self.control_fd >= 0) _ = c.close(self.control_fd);
        if (self.base_dir) |d| self.allocator.free(d);
        // Only the broker/monolith owns the socket file; a worker has none.
        if (self.sock_path.len > 0) {
            var z_buf: [4096]u8 = undefined;
            if (pathZ(&z_buf, self.sock_path)) |p| {
                _ = c.unlink(p);
            } else |_| {}
        }
        self.allocator.free(self.sock_path);
        self.allocator.destroy(self);
    }

    /// Run until a SHUTDOWN frame arrives or `running` is cleared.
    pub fn run(self: *Daemon) !void {
        while (self.running) try self.tick(500);
        // The run loop exits the same tick `running` is cleared, so any frame
        // queued by the shutdown path (`.gone` on `.shutdown`, or a worker's
        // `.gone` on a broker `'K'`) is still sitting in each client's wbuf —
        // POLLOUT for this tick was computed before the frame existed, so
        // `clientWritable` never ran for it. Without a final flush the client
        // sees a bare EOF and the GUI mistakes a clean retire for a crash
        // (sad-face). Drain the small tail before deinit closes the fds; the
        // kernel still delivers it after we close.
        self.flushClientsFinal();
    }

    /// Best-effort final drain of every client's wbuf before teardown. The
    /// only frames queued at this point are tiny shutdown notices, so a short
    /// bounded POLLOUT wait per round is plenty.
    fn flushClientsFinal(self: *Daemon) void {
        var rounds: usize = 0;
        while (rounds < 8) : (rounds += 1) {
            var pending = false;
            for (self.clients.items) |cl| {
                if (cl.dead or cl.wbuf.items.len == 0) continue;
                var pfd = c.struct_pollfd{ .fd = cl.fd, .events = c.POLLOUT, .revents = 0 };
                _ = c.poll(&pfd, 1, 50);
                if (pfd.revents & c.POLLOUT != 0) self.clientWritable(cl);
                if (!cl.dead and cl.wbuf.items.len > 0) pending = true;
            }
            if (!pending) break;
        }
    }

    /// One poll iteration. Exposed for tests.
    pub fn tick(self: *Daemon, timeout_ms: i32) !void {
        var fds: std.ArrayList(c.struct_pollfd) = .empty;
        defer fds.deinit(self.allocator);

        try fds.append(self.allocator, .{ .fd = self.listen_fd, .events = c.POLLIN, .revents = 0 });
        // Worker: the broker↔worker control channel (passed client fds + kill/
        // rename/metadata). -1 in broker/monolith → ignored by poll.
        const control_idx = fds.items.len;
        try fds.append(self.allocator, .{ .fd = self.control_fd, .events = c.POLLIN, .revents = 0 });
        const client_base = fds.items.len;
        const n_clients_built = self.clients.items.len;
        for (self.clients.items) |cl| {
            var ev: c_short = c.POLLIN;
            if (cl.wbuf.items.len > 0) ev |= c.POLLOUT;
            try fds.append(self.allocator, .{ .fd = cl.fd, .events = ev, .revents = 0 });
        }
        const session_base = fds.items.len;
        const n_sessions_built = self.sessions.items.len;
        for (self.sessions.items) |s| {
            try fds.append(self.allocator, .{
                .fd = if (s.exited) -1 else s.pty.master_fd,
                .events = c.POLLIN,
                .revents = 0,
            });
        }
        const hub_base = fds.items.len;
        for (self.sessions.items) |s| {
            try fds.append(self.allocator, .{
                .fd = s.wl_hub_fd, // -1 entries are ignored by poll
                .events = c.POLLIN,
                .revents = 0,
            });
        }
        // Window-stream wakeup pipes: SCK delivers frames on its own
        // dispatch queues — a readable byte here just ends the poll
        // wait early so pumpWinstreams() drains with low latency.
        // No revents handling: the source reads its pipe dry in
        // poll(). Only polled while a live channel exists — without
        // one nothing drains the pipe, and a permanently-readable fd
        // would spin this loop hot.
        for (self.sessions.items) |s| {
            var ws_fd: c_int = -1;
            if (s.winstream) |ws| {
                for (self.channels.items) |ch| {
                    if (ch.session == s and !ch.dead and ch.native == null and !ch.client.dead) {
                        ws_fd = ws.pollFd();
                        break;
                    }
                }
            }
            try fds.append(self.allocator, .{
                .fd = ws_fd,
                .events = c.POLLIN,
                .revents = 0,
            });
        }
        const chan_base = fds.items.len;
        const n_channels_built = self.channels.items.len;
        for (self.channels.items) |ch| {
            var ev: c_short = c.POLLIN;
            if (ch.pending.items.len > 0) ev |= c.POLLOUT;
            try fds.append(self.allocator, .{
                .fd = if (ch.dead) -1 else ch.fd,
                .events = ev,
                .revents = 0,
            });
        }
        const clip_base = fds.items.len;
        for (self.channels.items) |ch| {
            if (ch.native) |nv| {
                for (nv.clip_reads.items) |cr| {
                    try fds.append(self.allocator, .{
                        .fd = if (ch.dead) -1 else cr.fd,
                        .events = c.POLLIN,
                        .revents = 0,
                    });
                }
            }
        }
        // Broker: each worker's control channel — readable = a metadata push
        // ('M'); HUP/error = the worker process exited (reap removes it).
        const worker_base = fds.items.len;
        const n_workers_built = self.workers.items.len;
        for (self.workers.items) |w| {
            try fds.append(self.allocator, .{
                .fd = if (w.dead) -1 else w.control_fd,
                .events = c.POLLIN,
                .revents = 0,
            });
        }

        const pr = c.poll(fds.items.ptr, @intCast(fds.items.len), timeout_ms);
        if (pr < 0) return; // EINTR etc — next tick retries

        if (self.listen_fd >= 0 and fds.items[0].revents & c.POLLIN != 0) self.acceptClient();
        if (self.control_fd >= 0 and fds.items[control_idx].revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0)
            self.workerOnControl();

        // Snapshot counts: acceptClient/handleSpawn/attach run inside
        // the loops below and APPEND to these lists. Entries appended
        // this tick have no slot in this tick's poll set, so iterating
        // them would read a stale slot (a later base's revents) and
        // could fire a blocking read on a fd that was never polled.
        // They get serviced next tick. Lists only grow during a tick,
        // so n_* <= items.len always holds.
        const n_clients = n_clients_built;
        const n_sessions = n_sessions_built;
        const n_channels = n_channels_built;

        var i: usize = 0;
        while (i < n_clients) : (i += 1) {
            const cl = self.clients.items[i];
            const re = fds.items[client_base + i].revents;
            // POLLIN before POLLHUP: a client that writes its last
            // frame and closes raises both at once, and the data is
            // still readable. Declaring it dead first silently drops
            // that final input (a `mux send`'s Enter, typically).
            // clientReadable flags dead itself once read() hits EOF.
            if (re & c.POLLIN != 0) {
                self.clientReadable(cl);
            } else if (re & (c.POLLHUP | c.POLLERR) != 0) {
                cl.dead = true;
                continue;
            }
            if (re & c.POLLOUT != 0 and !cl.dead) self.clientWritable(cl);
        }

        i = 0;
        while (i < n_sessions) : (i += 1) {
            const s = self.sessions.items[i];
            const re = fds.items[session_base + i].revents;
            if (re & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) self.drainSession(s);
        }

        i = 0;
        while (i < n_sessions) : (i += 1) {
            const s = self.sessions.items[i];
            if (fds.items[hub_base + i].revents & c.POLLIN != 0) self.acceptWaylandApp(s);
        }

        i = 0;
        while (i < n_channels) : (i += 1) {
            const ch = self.channels.items[i];
            const re = fds.items[chan_base + i].revents;
            if (ch.dead) continue;
            if (re & c.POLLIN != 0) self.channelReadable(ch);
            if (!ch.dead and re & c.POLLOUT != 0) self.channelWritable(ch);
            if (!ch.dead and re & (c.POLLHUP | c.POLLERR) != 0 and re & c.POLLIN == 0)
                self.closeChannel(ch, true);
        }

        // Clipboard-fetch pipes (snapshot the count: clip_reads may
        // shrink while we drain, never grow — chan reads above can
        // append, but those fds weren't polled this tick).
        var clip_idx: usize = 0;
        i = 0;
        while (i < n_channels) : (i += 1) {
            const ch = self.channels.items[i];
            const nv = ch.native orelse continue;
            var j: usize = 0;
            while (j < nv.clip_reads.items.len and clip_base + clip_idx < fds.items.len) {
                const re = fds.items[clip_base + clip_idx].revents;
                clip_idx += 1;
                if (re & (c.POLLIN | c.POLLHUP) != 0 and !ch.dead) {
                    if (self.clipReadable(ch, j)) continue; // removed; j stays
                }
                j += 1;
            }
        }

        // Broker: drain worker control channels (metadata pushes + exit).
        i = 0;
        while (i < n_workers_built) : (i += 1) {
            const w = self.workers.items[i];
            if (w.dead) continue;
            const re = fds.items[worker_base + i].revents;
            if (re & c.POLLIN != 0) {
                self.brokerOnWorkerControl(w);
            } else if (re & (c.POLLHUP | c.POLLERR) != 0) {
                // Worker process gone (clean exit or crash) — reap removes it.
                w.dead = true;
            }
        }

        self.pumpWinstreams();
        self.pumpDownloads();
        // Worker: tell the broker our latest metadata (throttled).
        if (self.control_fd >= 0 and !self.is_broker) self.maybePushMeta();
        self.reap();
    }

    fn acceptClient(self: *Daemon) void {
        const fd = c.accept(self.listen_fd, null, null);
        if (fd < 0) return;
        _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        // Non-blocking: the single-threaded poll loop must never block
        // in read() on a silent client (a brand-new accept this tick
        // isn't in the poll set yet, and a stale-slot read could fire).
        const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
        const cl = self.allocator.create(Client) catch {
            _ = c.close(fd);
            return;
        };
        cl.* = .{ .allocator = self.allocator, .fd = fd };
        self.clients.append(self.allocator, cl) catch {
            cl.deinit();
            return;
        };
    }

    // ── broker ↔ worker control channel (process isolation) ─────────
    //
    // A worker process owns one session and receives its clients as fds
    // passed by the broker over a SOCK_SEQPACKET control socketpair. Each
    // control message is one datagram: [opcode][payload], with at most one
    // fd in SCM_RIGHTS. Opcodes: 'A' attach (payload [proto][video] + the
    // client fd), 'K' kill. (list/rename/metadata join in B3.)

    /// Worker side: drain one control datagram and act on it.
    fn workerOnControl(self: *Daemon) void {
        var buf: [256]u8 = undefined;
        var passed: c_int = -1;
        const n = controlRecv(self.control_fd, &buf, &passed);
        if (n <= 0) {
            // Broker closed the control channel — no supervisor left; exit.
            if (passed >= 0) _ = c.close(passed);
            self.running = false;
            return;
        }
        switch (buf[0]) {
            'A' => {
                if (passed < 0) return;
                const proto: u32 = if (n >= 2) buf[1] else 1;
                const video: bool = n >= 3 and buf[2] != 0;
                self.addPassedClient(passed, proto, video);
            },
            'K' => {
                for (self.clients.items) |cl| if (!cl.dead) cl.queueFrame(.gone, "");
                self.running = false;
            },
            'R' => {
                // Rename our session to match the broker's new authoritative
                // name (keeps the worker's own state consistent; the broker is
                // the routing authority). Payload after 'R' is the raw name.
                if (passed >= 0) _ = c.close(passed);
                if (n > 1 and self.sessions.items.len > 0) {
                    const new_name = buf[1..@intCast(n)];
                    if (self.allocator.dupe(u8, new_name)) |fresh| {
                        self.allocator.free(self.sessions.items[0].name);
                        self.sessions.items[0].name = fresh;
                    } else |_| {}
                }
            },
            else => if (passed >= 0) {
                _ = c.close(passed);
            },
        }
    }

    /// Worker side: adopt a broker-passed client fd as a client attached to
    /// our one session, and send it the attach snapshot.
    fn addPassedClient(self: *Daemon, fd: c_int, proto: u32, video: bool) void {
        _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
        const cl = self.allocator.create(Client) catch {
            _ = c.close(fd);
            return;
        };
        cl.* = .{ .allocator = self.allocator, .fd = fd, .proto = proto, .video = video };
        self.clients.append(self.allocator, cl) catch {
            cl.deinit();
            return;
        };
        if (self.sessions.items.len == 0) return;
        const s = self.sessions.items[0];
        cl.attached = s;
        self.queueSnapshot(cl, s);
        if (proto >= 2) {
            if (s.winstream != null) self.openWinstreamChan(s, cl);
            while (s.wl_pending.items.len > 0) {
                const afd = s.wl_pending.orderedRemove(0);
                self.openAppChannel(s, cl, afd);
            }
        }
    }

    /// Broker side: read one control datagram from a worker. 'Y' = ready
    /// (resolve the deferred spawn `.ok`), 'M' = metadata push; n<=0 means the
    /// worker exited (before 'Y' = spawn failed → resolve spawn `.err`).
    /// The buffer comfortably exceeds the worst-case 'M' JSON (a 256-byte
    /// title + 1024-byte cwd, each up to ~6x under \uXXXX escaping).
    fn brokerOnWorkerControl(self: *Daemon, w: *Worker) void {
        var buf: [16384]u8 = undefined;
        var passed: c_int = -1;
        const n = controlRecv(w.control_fd, &buf, &passed);
        if (passed >= 0) _ = c.close(passed); // workers never pass fds up
        if (n <= 0) {
            if (!w.ready) self.replyPendingSpawn(w, false); // died before ready
            w.dead = true;
            return;
        }
        switch (buf[0]) {
            'Y' => {
                w.ready = true;
                self.replyPendingSpawn(w, true);
            },
            'M' => {
                var parsed = std.json.parseFromSlice(WorkerMeta, self.allocator, buf[1..@intCast(n)], .{
                    .ignore_unknown_fields = true,
                }) catch return;
                defer parsed.deinit();
                const m = parsed.value;
                w.rows = m.rows;
                w.cols = m.cols;
                w.n_clients = m.clients;
                w.exited = m.exited;
                w.app = m.app;
                w.last_activity_ms = m.activity;
                if (self.allocator.dupe(u8, m.title)) |t| {
                    if (w.title) |old| self.allocator.free(old);
                    w.title = t;
                } else |_| {}
                if (self.allocator.dupe(u8, m.cwd)) |cw| {
                    if (w.cwd) |old| self.allocator.free(old);
                    w.cwd = cw;
                } else |_| {}
            },
            else => {},
        }
    }

    /// Resolve a worker's deferred spawn reply. `ok` = session up (`.ok`),
    /// else spawn failed (`.err`). Validates the waiting client is still a live
    /// connection (the GUI could have vanished while the worker came up).
    fn replyPendingSpawn(self: *Daemon, w: *Worker, ok: bool) void {
        const cl = w.pending_client orelse return;
        w.pending_client = null;
        for (self.clients.items) |c2| {
            if (c2 == cl and !c2.dead) {
                if (ok) c2.queueJson(.ok, .{ .ok = true, .name = w.name }) else c2.queueErr("spawn failed");
                return;
            }
        }
    }

    /// Worker side: push current session metadata to the broker if it changed
    /// since the last push. Structural changes go immediately; activity-only
    /// advances are rate-limited to ~5/s.
    fn maybePushMeta(self: *Daemon) void {
        if (self.sessions.items.len == 0) return;
        const s = self.sessions.items[0];
        var n_clients: u32 = 0;
        for (self.clients.items) |cl| {
            if (!cl.dead) n_clients += 1;
        }
        const title: []const u8 = if (s.screen.last_title) |t| t else "";
        const th = std.hash.Wyhash.hash(0, title);
        const structural = !self.wpush.inited or
            n_clients != self.wpush.clients or
            s.exited != self.wpush.exited or
            s.screen.rows != self.wpush.rows or
            s.screen.cols != self.wpush.cols or
            th != self.wpush.title_hash;
        const activity_moved = s.last_activity_ms != self.wpush.activity;
        const now = nowMs();
        if (!structural and !(activity_moved and now - self.wpush.last_push_ms >= 200)) return;

        var cwd: []const u8 = "";
        var scratch: [4096]u8 = undefined;
        if (cwdOfPid(s.pty.child_pid, &scratch)) |cw| cwd = cw;
        const meta = WorkerMeta{
            .rows = s.screen.rows,
            .cols = s.screen.cols,
            .clients = n_clients,
            .exited = s.exited,
            .app = s.app,
            .activity = s.last_activity_ms,
            // Bounded so one JSON datagram stays well under the broker's
            // recv buffer (a SOCK_SEQPACKET over-long datagram is truncated).
            .title = title[0..@min(title.len, 256)],
            .cwd = cwd[0..@min(cwd.len, 1024)],
        };
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        aw.writer.writeByte('M') catch return;
        std.json.Stringify.value(meta, .{}, &aw.writer) catch return;
        controlSend(self.control_fd, aw.written(), -1);

        self.wpush = .{
            .inited = true,
            .clients = n_clients,
            .exited = s.exited,
            .rows = s.screen.rows,
            .cols = s.screen.cols,
            .title_hash = th,
            .activity = s.last_activity_ms,
            .last_push_ms = now,
        };
    }

    /// recvmsg one control datagram: data into `buf`, the first SCM_RIGHTS fd
    /// (or -1) into `fd_out`. Returns datagram length (0 = peer closed).
    fn controlRecv(fd: c_int, buf: []u8, fd_out: *c_int) isize {
        fd_out.* = -1;
        var iov = c.struct_iovec{ .iov_base = buf.ptr, .iov_len = buf.len };
        var cbuf: [64]u8 align(@alignOf(c.struct_cmsghdr)) = std.mem.zeroes([64]u8);
        var mh = std.mem.zeroes(c.struct_msghdr);
        mh.msg_iov = @ptrCast(&iov);
        mh.msg_iovlen = 1;
        mh.msg_control = &cbuf;
        mh.msg_controllen = cbuf.len;
        const n = c.recvmsg(fd, &mh, 0);
        if (n <= 0) return n;
        const hdr_size: usize = @sizeOf(c.struct_cmsghdr);
        if (@as(usize, @intCast(mh.msg_controllen)) >= hdr_size) {
            const hdr: *const c.struct_cmsghdr = @alignCast(@ptrCast(&cbuf));
            if (hdr.cmsg_level == c.SOL_SOCKET and hdr.cmsg_type == c.SCM_RIGHTS and
                @as(usize, @intCast(hdr.cmsg_len)) >= hdr_size + @sizeOf(c_int))
            {
                var passed: c_int = undefined;
                @memcpy(std.mem.asBytes(&passed), cbuf[hdr_size..][0..@sizeOf(c_int)]);
                fd_out.* = passed;
            }
        }
        return n;
    }

    /// Broker side: send a control datagram (+ optional fd) to a worker.
    fn controlSend(fd: c_int, bytes: []const u8, pass_fd: c_int) void {
        var iov = c.struct_iovec{ .iov_base = @constCast(bytes.ptr), .iov_len = bytes.len };
        var cbuf: [64]u8 align(@alignOf(c.struct_cmsghdr)) = std.mem.zeroes([64]u8);
        var mh = std.mem.zeroes(c.struct_msghdr);
        mh.msg_iov = @ptrCast(&iov);
        mh.msg_iovlen = 1;
        if (pass_fd >= 0) {
            const hdr_size: usize = @sizeOf(c.struct_cmsghdr);
            const cmsg: *c.struct_cmsghdr = @ptrCast(&cbuf);
            cmsg.cmsg_len = @intCast(hdr_size + @sizeOf(c_int));
            cmsg.cmsg_level = c.SOL_SOCKET;
            cmsg.cmsg_type = c.SCM_RIGHTS;
            @memcpy(cbuf[hdr_size..][0..@sizeOf(c_int)], std.mem.asBytes(&pass_fd));
            mh.msg_control = &cbuf;
            const space = (cmsg.cmsg_len + @sizeOf(usize) - 1) & ~@as(usize, @sizeOf(usize) - 1);
            mh.msg_controllen = @intCast(space);
        }
        _ = c.sendmsg(fd, &mh, 0);
    }

    /// Construct a worker-mode daemon (no listen socket; clients arrive over
    /// `control_fd`). `base_dir` is the runtime dir for the session's Wayland /
    /// isolated-rt sockets (the broker's socket dir). The caller spawns the one
    /// session and runs the loop.
    pub fn initWorker(allocator: std.mem.Allocator, control_fd: c_int, base_dir: []const u8) !*Daemon {
        const self = try allocator.create(Daemon);
        self.* = .{
            .allocator = allocator,
            .listen_fd = -1,
            .sock_path = try allocator.dupe(u8, ""),
            .control_fd = control_fd,
            .base_dir = if (base_dir.len > 0) try allocator.dupe(u8, base_dir) else null,
        };
        return self;
    }

    /// Worker process entry: own one session (from `req`), serve clients the
    /// broker hands over `control_fd`, until killed or the broker goes away.
    pub fn runWorker(allocator: std.mem.Allocator, control_fd: c_int, req: SpawnReq, base_dir: []const u8) !void {
        const self = try initWorker(allocator, control_fd, base_dir);
        defer self.deinit();
        // If spawnSession fails we return the error → the caller `_exit`s →
        // the broker sees control EOF before any 'Y' → it replies `.err` to
        // the waiting client. On success, signal 'Y' (ready) so the broker
        // sends the spawn `.ok` only once the session truly exists.
        const s = try self.spawnSession(req);
        try self.sessions.append(allocator, s);
        controlSend(control_fd, "Y", -1);
        try self.run();
    }

    fn clientReadable(self: *Daemon, cl: *Client) void {
        var tmp: [16384]u8 = undefined;
        const n_raw = c.read(cl.fd, &tmp, tmp.len);
        if (n_raw < 0) {
            // fd is O_NONBLOCK: EAGAIN just means "nothing right now".
            if (std.posix.errno(n_raw) != .AGAIN) cl.dead = true;
            return;
        }
        if (n_raw == 0) {
            cl.dead = true; // EOF
            return;
        }
        const n: usize = @intCast(n_raw);
        cl.rbuf.appendSlice(cl.allocator, tmp[0..n]) catch {
            cl.dead = true;
            return;
        };
        while (true) {
            const peeled = wire.peelFrame(cl.rbuf.items) catch {
                cl.dead = true;
                return;
            } orelse break;
            self.handleFrame(cl, peeled.frame);
            // Drop consumed bytes (front removal; frames are small
            // except INPUT pastes, and rbuf shrinks right back).
            const remaining = cl.rbuf.items.len - peeled.consumed;
            std.mem.copyForwards(u8, cl.rbuf.items[0..remaining], cl.rbuf.items[peeled.consumed..]);
            cl.rbuf.shrinkRetainingCapacity(remaining);
            if (cl.dead) return;
        }
    }

    fn clientWritable(self: *Daemon, cl: *Client) void {
        _ = self;
        const n_raw = c.write(cl.fd, cl.wbuf.items.ptr, cl.wbuf.items.len);
        if (n_raw < 0) {
            // fd is O_NONBLOCK: EAGAIN means the send buffer is full;
            // keep wbuf and retry on the next POLLOUT.
            if (std.posix.errno(n_raw) != .AGAIN) cl.dead = true;
            return;
        }
        const n: usize = @intCast(n_raw);
        const remaining = cl.wbuf.items.len - n;
        std.mem.copyForwards(u8, cl.wbuf.items[0..remaining], cl.wbuf.items[n..]);
        cl.wbuf.shrinkRetainingCapacity(remaining);
    }

    fn handleFrame(self: *Daemon, cl: *Client, frame: wire.Frame) void {
        switch (frame.ftype) {
            .hello => {
                const HelloReq = struct { proto: u32 = 1, video: bool = false };
                if (std.json.parseFromSlice(HelloReq, self.allocator, frame.payload, .{
                    .ignore_unknown_fields = true,
                })) |p| {
                    cl.proto = p.value.proto;
                    cl.video = p.value.video;
                    p.deinit();
                } else |_| {}
                cl.queueJson(.welcome, .{ .proto = wire.PROTO_VERSION });
            },
            .spawn => self.handleSpawn(cl, frame.payload),
            .attach => self.handleAttach(cl, frame.payload),
            .detach => {
                cl.attached = null;
                cl.queueJson(.ok, .{ .ok = true });
            },
            .input => {
                const s = cl.attached orelse {
                    cl.queueErr("not attached");
                    return;
                };
                _ = s.pty.writeAll(frame.payload);
            },
            .resize => {
                const s = cl.attached orelse return;
                if (frame.payload.len < 4) return;
                const rows = std.mem.readInt(u16, frame.payload[0..2], .little);
                const cols = std.mem.readInt(u16, frame.payload[2..4], .little);
                if (rows == 0 or cols == 0 or rows > 1000 or cols > 1000) return;
                s.screen.resize(cols, rows) catch return;
                s.pty.setSize(rows, cols);
                // Geometry changed: every attached client needs a
                // fresh snapshot (event streams assume fixed grids).
                self.broadcastSnapshot(s);
            },
            .list => self.handleList(cl),
            .kill => self.handleKill(cl, frame.payload),
            .rename => self.handleRename(cl, frame.payload),
            .shutdown => {
                // Clean shutdown: tell attached clients it's intentional
                // (.gone) so they don't paint a crash sad-face on the EOF.
                for (self.clients.items) |other| {
                    if (other != cl and !other.dead) other.queueFrame(.gone, "");
                }
                // Broker: a worker's clients are on the WORKER, not here — a
                // bare control-fd close would read as a crash to them. Send
                // each worker a graceful 'K' so it flushes `.gone` to its own
                // clients before exiting (the buffered datagram is delivered
                // even though we're about to stop).
                if (self.is_broker) {
                    for (self.workers.items) |w| {
                        if (!w.dead) controlSend(w.control_fd, "K", -1);
                    }
                }
                cl.queueJson(.ok, .{ .ok = true });
                self.running = false;
            },
            .file_open => self.handleFileOpen(cl, frame.payload),
            .file_data => self.handleFileData(cl, frame.payload),
            .file_close => self.handleFileClose(cl, frame.payload),
            .file_get => self.handleFileGet(cl, frame.payload),
            .file_list => self.handleFileList(cl, frame.payload),
            .chan_data => {
                const id = wire.decodeChanId(frame.payload) orelse return;
                const ch = self.findChannel(id) orelse return;
                if (ch.client != cl or ch.dead) return;
                if (ch.native != null) return self.nativeClientData(ch, frame.payload[4..]);
                if (ch.session.winstream) |ws| {
                    var pos: usize = 0;
                    const bytes = frame.payload[4..];
                    while (wsproto.peelUnit(bytes[pos..]) catch null) |p| {
                        ws.handleInput(p.unit);
                        pos += p.consumed;
                    }
                }
            },
            .chan_close => {
                const id = wire.decodeChanId(frame.payload) orelse return;
                const ch = self.findChannel(id) orelse return;
                if (ch.client != cl) return;
                // Client already dropped its side — no echo needed.
                ch.dead = true;
            },
            else => cl.queueErr("unknown frame type"),
        }
    }

    fn findChannel(self: *Daemon, id: u32) ?*Channel {
        for (self.channels.items) |ch| {
            if (ch.id == id) return ch;
        }
        return null;
    }

    // === File upload (file_* frames) ===========================
    // The GUI streams a local file to the daemon, which writes it into
    // the session shell's working directory — so "drag a file onto a
    // remote pane" lands it on the remote box, over any transport.

    /// Most concurrent uploads a single client may have open. Bounds
    /// the open-fd + partial-file footprint of a misbehaving client.
    const max_uploads_per_client = 8;

    fn findUpload(self: *Daemon, cl: *Client, xfer: u32) ?*Upload {
        for (self.uploads.items) |u| {
            if (u.client == cl and u.xfer == xfer) return u;
        }
        return null;
    }

    fn fileReply(cl: *Client, xfer: u32, status: []const u8, written: u64, path: []const u8, message: []const u8) void {
        cl.queueJson(.file_reply, .{
            .xfer = xfer,
            .status = status,
            .written = written,
            .path = path,
            .message = message,
        });
    }

    /// Remove an upload from the list and free it. `unlink_partial`
    /// removes the on-disk file too (used on a write error — the
    /// half-written file we created is ours to clean up).
    fn dropUpload(self: *Daemon, up: *Upload, unlink_partial: bool) void {
        if (unlink_partial) {
            var z: [4096]u8 = undefined;
            if (pathZ(&z, up.path)) |p| {
                _ = c.unlink(p);
            } else |_| {}
        }
        for (self.uploads.items, 0..) |item, i| {
            if (item == up) {
                _ = self.uploads.swapRemove(i);
                break;
            }
        }
        up.deinit();
    }

    /// The last path component of `name`, with any directory part
    /// stripped — a client can't write outside the session cwd.
    fn uploadBaseName(name: []const u8) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| return name[slash + 1 ..];
        return name;
    }

    /// Open a fresh file named `base` in `cwd`, never clobbering an
    /// existing one: on a name collision, insert " (N)" before the
    /// extension ("notes.txt" → "notes (1).txt"). Writes the chosen
    /// absolute path into `out` and returns it plus the open fd.
    fn openUploadDest(cwd: []const u8, base: []const u8, out: *[4096]u8) !struct { fd: c_int, path: []const u8 } {
        // Split "stem.ext" so the suffix lands before the extension.
        const dot = std.mem.lastIndexOfScalar(u8, base, '.');
        const stem = if (dot) |d| (if (d == 0) base else base[0..d]) else base;
        const ext = if (dot) |d| (if (d == 0) "" else base[d..]) else "";

        var n: u32 = 0;
        while (n < 1000) : (n += 1) {
            const path = if (n == 0)
                std.fmt.bufPrintZ(out, "{s}/{s}", .{ cwd, base }) catch return error.NameTooLong
            else
                std.fmt.bufPrintZ(out, "{s}/{s} ({d}){s}", .{ cwd, stem, n, ext }) catch return error.NameTooLong;
            const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL, @as(c_uint, 0o644));
            if (fd >= 0) return .{ .fd = fd, .path = path };
            if (std.posix.errno(fd) != .EXIST) return error.OpenFailed;
        }
        return error.OpenFailed;
    }

    fn handleFileOpen(self: *Daemon, cl: *Client, payload: []const u8) void {
        const Req = struct { xfer: u32 = 0, name: []const u8 = "", size: u64 = 0 };
        const parsed = std.json.parseFromSlice(Req, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch {
            cl.queueErr("bad file_open");
            return;
        };
        defer parsed.deinit();
        const xfer = parsed.value.xfer;

        const s = cl.attached orelse {
            fileReply(cl, xfer, "error", 0, "", "not attached to a session");
            return;
        };
        if (self.findUpload(cl, xfer) != null) {
            fileReply(cl, xfer, "error", 0, "", "duplicate transfer id");
            return;
        }
        var n_for_client: usize = 0;
        for (self.uploads.items) |u| {
            if (u.client == cl) n_for_client += 1;
        }
        if (n_for_client >= max_uploads_per_client) {
            fileReply(cl, xfer, "error", 0, "", "too many concurrent uploads");
            return;
        }

        const base = uploadBaseName(parsed.value.name);
        if (base.len == 0 or base.len > 200 or
            std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..") or
            std.mem.indexOfScalar(u8, base, 0) != null)
        {
            fileReply(cl, xfer, "error", 0, "", "invalid file name");
            return;
        }

        var cwd_buf: [4096]u8 = undefined;
        const cwd = cwdOfPid(s.pty.child_pid, &cwd_buf) orelse {
            fileReply(cl, xfer, "error", 0, "", "cannot determine session directory");
            return;
        };

        var path_buf: [4096]u8 = undefined;
        const dest = openUploadDest(cwd, base, &path_buf) catch {
            fileReply(cl, xfer, "error", 0, "", "cannot create destination file");
            return;
        };

        const up = self.allocator.create(Upload) catch {
            _ = c.close(dest.fd);
            cl.queueErr("oom");
            return;
        };
        const owned_path = self.allocator.dupe(u8, dest.path) catch {
            _ = c.close(dest.fd);
            self.allocator.destroy(up);
            cl.queueErr("oom");
            return;
        };
        up.* = .{ .allocator = self.allocator, .client = cl, .xfer = xfer, .fd = dest.fd, .path = owned_path };
        self.uploads.append(self.allocator, up) catch {
            up.deinit();
            cl.queueErr("oom");
            return;
        };
        // "ready" greenlights the client to start streaming; the path
        // is the real (possibly de-clobbered) name the file landed under.
        fileReply(cl, xfer, "ready", 0, owned_path, "");
    }

    fn handleFileData(self: *Daemon, cl: *Client, payload: []const u8) void {
        const xfer = wire.decodeChanId(payload) orelse return;
        const up = self.findUpload(cl, xfer) orelse return; // aborted/unknown
        const bytes = payload[4..];
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(up.fd, bytes.ptr + off, bytes.len - off);
            if (n > 0) {
                off += @intCast(n);
                continue;
            }
            if (std.posix.errno(n) == .INTR) continue;
            fileReply(cl, xfer, "error", up.written, up.path, "write failed");
            self.dropUpload(up, true);
            return;
        }
        up.written += bytes.len;
        // Per-chunk ack: the client gates how much it keeps in flight
        // on the gap between bytes sent and bytes acked.
        fileReply(cl, xfer, "progress", up.written, "", "");
    }

    fn handleFileClose(self: *Daemon, cl: *Client, payload: []const u8) void {
        const xfer = wire.decodeChanId(payload) orelse return;
        const up = self.findUpload(cl, xfer) orelse return;
        _ = c.fsync(up.fd);
        _ = c.close(up.fd);
        up.fd = -1;
        fileReply(cl, xfer, "done", up.written, up.path, "");
        self.dropUpload(up, false);
    }

    // === File download (file_get + reverse file_data) ==========
    // The reverse of upload: the daemon reads a file from the remote
    // filesystem and streams it to the requesting client.

    const max_downloads_per_client = 4;

    fn dropDownload(self: *Daemon, dl: *Download) void {
        for (self.downloads.items, 0..) |item, i| {
            if (item == dl) {
                _ = self.downloads.swapRemove(i);
                break;
            }
        }
        dl.deinit();
    }

    fn handleFileGet(self: *Daemon, cl: *Client, payload: []const u8) void {
        const Req = struct { xfer: u32 = 0, path: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Req, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch {
            cl.queueErr("bad file_get");
            return;
        };
        defer parsed.deinit();
        const xfer = parsed.value.xfer;

        const s = cl.attached orelse {
            fileReply(cl, xfer, "error", 0, "", "not attached to a session");
            return;
        };
        var n_for_client: usize = 0;
        for (self.downloads.items) |dl| {
            if (dl.client == cl) n_for_client += 1;
        }
        if (n_for_client >= max_downloads_per_client) {
            fileReply(cl, xfer, "error", 0, "", "too many concurrent downloads");
            return;
        }

        const req_path = parsed.value.path;
        if (req_path.len == 0 or std.mem.indexOfScalar(u8, req_path, 0) != null) {
            fileReply(cl, xfer, "error", 0, "", "invalid path");
            return;
        }

        // Resolve: absolute as-is, otherwise relative to the shell cwd.
        // The user already has shell access to this session, so reading
        // any file they can read is within their existing privilege.
        var abs_buf: [4096]u8 = undefined;
        const abs = blk: {
            if (req_path[0] == '/') break :blk std.fmt.bufPrintZ(&abs_buf, "{s}", .{req_path}) catch {
                fileReply(cl, xfer, "error", 0, "", "path too long");
                return;
            };
            var cwd_buf: [4096]u8 = undefined;
            const cwd = cwdOfPid(s.pty.child_pid, &cwd_buf) orelse {
                fileReply(cl, xfer, "error", 0, "", "cannot determine session directory");
                return;
            };
            break :blk std.fmt.bufPrintZ(&abs_buf, "{s}/{s}", .{ cwd, req_path }) catch {
                fileReply(cl, xfer, "error", 0, "", "path too long");
                return;
            };
        };

        const fd = c.open(abs.ptr, c.O_RDONLY, @as(c_uint, 0));
        if (fd < 0) {
            fileReply(cl, xfer, "error", 0, "", "cannot open file");
            return;
        }
        var st: c.struct_stat = undefined;
        if (c.fstat(fd, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG) {
            _ = c.close(fd);
            fileReply(cl, xfer, "error", 0, "", "not a regular file");
            return;
        }
        const size: u64 = if (st.st_size > 0) @intCast(st.st_size) else 0;

        const dl = self.allocator.create(Download) catch {
            _ = c.close(fd);
            cl.queueErr("oom");
            return;
        };
        dl.* = .{ .allocator = self.allocator, .client = cl, .xfer = xfer, .fd = fd, .size = size };
        self.downloads.append(self.allocator, dl) catch {
            dl.deinit();
            cl.queueErr("oom");
            return;
        };
        // "ready" carries the size + the basename the client saves under;
        // pumpDownloads then streams the bytes as file_data.
        cl.queueJson(.file_reply, .{
            .xfer = xfer,
            .status = "ready",
            .written = @as(u64, 0),
            .path = uploadBaseName(req_path),
            .message = "",
            .size = size,
        });
    }

    // === Remote directory browse (file_list) ===================
    // Lets the GUI offer a "remote file picker" without the user
    // typing paths. Read-only; no state kept (a one-shot reply).

    /// Cap on entries per listing — bounds the reply size for huge dirs.
    const max_list_entries = 4096;

    /// One directory entry on the wire (JSON-serialized in file_listing).
    const ListEntry = struct { name: []const u8, dir: bool, size: u64 };

    fn listingError(cl: *Client, xfer: u32, path: []const u8, msg: []const u8) void {
        cl.queueJson(.file_listing, .{
            .xfer = xfer,
            .path = path,
            .entries = &[_]ListEntry{},
            .@"error" = msg,
            .truncated = false,
        });
    }

    fn handleFileList(self: *Daemon, cl: *Client, payload: []const u8) void {
        const Req = struct { xfer: u32 = 0, path: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Req, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch {
            cl.queueErr("bad file_list");
            return;
        };
        defer parsed.deinit();
        const xfer = parsed.value.xfer;

        const s = cl.attached orelse {
            listingError(cl, xfer, "", "not attached to a session");
            return;
        };

        // Resolve the directory: empty → cwd, absolute as-is, else
        // relative to cwd.
        var dir_z: [4096]u8 = undefined;
        const req_path = parsed.value.path;
        const dirpath: [:0]const u8 = blk: {
            if (req_path.len == 0 or req_path[0] != '/') {
                var cwd_buf: [4096]u8 = undefined;
                const cwd = cwdOfPid(s.pty.child_pid, &cwd_buf) orelse {
                    listingError(cl, xfer, "", "cannot determine session directory");
                    return;
                };
                if (req_path.len == 0) {
                    break :blk std.fmt.bufPrintZ(&dir_z, "{s}", .{cwd}) catch {
                        listingError(cl, xfer, "", "path too long");
                        return;
                    };
                }
                break :blk std.fmt.bufPrintZ(&dir_z, "{s}/{s}", .{ cwd, req_path }) catch {
                    listingError(cl, xfer, "", "path too long");
                    return;
                };
            }
            break :blk std.fmt.bufPrintZ(&dir_z, "{s}", .{req_path}) catch {
                listingError(cl, xfer, "", "path too long");
                return;
            };
        };

        // Canonicalize for the reported path (collapses .. and symlinks)
        // so the GUI's address bar stays clean.
        var real_buf: [4096]u8 = undefined;
        const resolved: []const u8 = if (c.realpath(dirpath.ptr, &real_buf)) |r|
            std.mem.span(@as([*:0]const u8, @ptrCast(r)))
        else
            dirpath;

        const dir = c.opendir(dirpath.ptr) orelse {
            listingError(cl, xfer, resolved, "cannot open directory");
            return;
        };
        defer _ = c.closedir(dir);

        const Entry = ListEntry;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var entries: std.ArrayList(Entry) = .empty;
        var truncated = false;

        while (c.readdir(dir)) |de| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
            if (name.len == 0) continue;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            // JSON can't carry non-UTF-8; skip such names (very rare).
            if (!std.unicode.utf8ValidateSlice(name)) continue;
            if (entries.items.len >= max_list_entries) {
                truncated = true;
                break;
            }
            // Resolve type/size. d_type is a fast path; fall back to a
            // stat (following symlinks so a link to a dir browses).
            var is_dir = de.*.d_type == c.DT_DIR;
            var size: u64 = 0;
            if (de.*.d_type != c.DT_DIR) {
                var full_z: [4096]u8 = undefined;
                if (std.fmt.bufPrintZ(&full_z, "{s}/{s}", .{ dirpath, name })) |fp| {
                    var st: c.struct_stat = undefined;
                    if (c.stat(fp.ptr, &st) == 0) {
                        is_dir = (st.st_mode & c.S_IFMT) == c.S_IFDIR;
                        if (!is_dir and st.st_size > 0) size = @intCast(st.st_size);
                    }
                } else |_| {}
            }
            const owned = arena.dupe(u8, name) catch continue;
            entries.append(arena, .{ .name = owned, .dir = is_dir, .size = size }) catch break;
        }

        // Directories first, then case-insensitive by name.
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                if (a.dir != b.dir) return a.dir;
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.lt);

        cl.queueJson(.file_listing, .{
            .xfer = xfer,
            .path = resolved,
            .entries = entries.items,
            .@"error" = "",
            .truncated = truncated,
        });
    }

    /// Stream each active download toward its client, bounded by the
    /// client's write-buffer high-water mark (same backpressure rule as
    /// pumpWinstreams). Fills up to the mark each tick, then waits for
    /// the socket to drain (POLLOUT re-wakes the loop).
    fn pumpDownloads(self: *Daemon) void {
        const watermark = 8 << 20;
        const chunk = 256 * 1024;
        var buf: [4 + chunk]u8 = undefined; // reused across downloads/chunks
        var i: usize = 0;
        while (i < self.downloads.items.len) {
            const dl = self.downloads.items[i];
            if (dl.client.dead) {
                i += 1;
                continue;
            }
            var done_or_dropped = false;
            while (dl.client.wbuf.items.len < watermark) {
                const n = c.read(dl.fd, buf[4..], chunk);
                if (n < 0) {
                    if (std.posix.errno(n) == .INTR) continue;
                    fileReply(dl.client, dl.xfer, "error", dl.sent, "", "read failed");
                    self.dropDownload(dl);
                    done_or_dropped = true;
                    break;
                }
                if (n == 0) {
                    fileReply(dl.client, dl.xfer, "done", dl.sent, "", "");
                    self.dropDownload(dl);
                    done_or_dropped = true;
                    break;
                }
                _ = wire.putChanHeader(buf[0..4], dl.xfer);
                const len: usize = @intCast(n);
                dl.client.queueFrame(.file_data, buf[0 .. 4 + len]);
                dl.sent += len;
            }
            // dropDownload swap-removed index i — re-check it; otherwise
            // advance past the still-streaming download.
            if (!done_or_dropped) i += 1;
        }
    }

    /// A Wayland app connected to the session's hub: tunnel it to an
    /// attached channel-capable client, or refuse (the app gets a
    /// clean "cannot connect to display" instead of a hang).
    fn acceptWaylandApp(self: *Daemon, s: *Session) void {
        const fd = c.accept(s.wl_hub_fd, null, null);
        if (fd < 0) return;
        _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);

        // Latest attached client wins (multiple GUIs on one session
        // is rare; the newest attachment is the active human).
        var target: ?*Client = null;
        for (self.clients.items) |cl| {
            if (cl.attached == s and !cl.dead and cl.proto >= 2) target = cl;
        }
        const cl = target orelse {
            // Nobody to render yet — park the connection; the app
            // blocks harmlessly. Drained on the next attach.
            if (s.wl_pending.items.len >= 16) {
                _ = c.close(fd);
                return;
            }
            s.wl_pending.append(self.allocator, fd) catch {
                _ = c.close(fd);
            };
            return;
        };
        self.openAppChannel(s, cl, fd);
    }

    /// Bridge one accepted app connection to `cl` as a channel.
    fn openAppChannel(self: *Daemon, s: *Session, cl: *Client, fd: c_int) void {
        const native = self.allocator.create(Native) catch {
            _ = c.close(fd);
            return;
        };
        const tracker = wltrack.Tracker.init(self.allocator) catch {
            self.allocator.destroy(native);
            _ = c.close(fd);
            return;
        };
        native.* = .{ .allocator = self.allocator, .tracker = tracker };

        const ch = self.allocator.create(Channel) catch {
            native.deinit();
            _ = c.close(fd);
            return;
        };
        ch.* = .{
            .allocator = self.allocator,
            .id = self.next_chan_id,
            .fd = fd,
            .session = s,
            .client = cl,
            .native = native,
        };
        // Route this app's surfaces through the video coder only if the
        // target client advertised it can decode (and we can encode —
        // videoCommit is comptime-gated on build_options.video).
        native.wants_video = cl.video;
        self.next_chan_id += 1;
        self.channels.append(self.allocator, ch) catch {
            ch.deinit();
            return;
        };
        var hdr: [5]u8 = undefined;
        cl.queueFrame(.chan_open, wire.encodeChanOpen(&hdr, ch.id, .wayland_native));
    }

    /// App-socket bytes toward the client (the parsed sketerm-native
    /// pipe). Winstream channels carry fd = -1 and never land here.
    fn channelReadable(self: *Daemon, ch: *Channel) void {
        if (ch.native != null) self.nativeReadable(ch);
    }

    fn channelWritable(self: *Daemon, ch: *Channel) void {
        if (ch.pending.items.len == 0) return;
        const n_raw = if (ch.native != null and ch.native.?.out_fds.items.len > 0)
            self.writeWithFds(ch)
        else
            c.write(ch.fd, ch.pending.items.ptr, ch.pending.items.len);
        if (n_raw < 0) {
            if (std.posix.errno(n_raw) != .AGAIN) self.closeChannel(ch, true);
            return;
        }
        const n: usize = @intCast(n_raw);
        const remaining = ch.pending.items.len - n;
        std.mem.copyForwards(u8, ch.pending.items[0..remaining], ch.pending.items[n..]);
        ch.pending.shrinkRetainingCapacity(remaining);
    }

    /// sendmsg with the queued SCM_RIGHTS fds attached. Attaching
    /// to the first available write keeps fds AT OR BEFORE their
    /// message bytes, which is the order Wayland clients require.
    fn writeWithFds(self: *Daemon, ch: *Channel) isize {
        _ = self;
        const nv = ch.native.?;
        const n_fds = @min(nv.out_fds.items.len, 8);
        var iov = c.struct_iovec{
            .iov_base = ch.pending.items.ptr,
            .iov_len = ch.pending.items.len,
        };
        const hdr_size: usize = @sizeOf(c.struct_cmsghdr);
        var cbuf: [128]u8 align(@alignOf(c.struct_cmsghdr)) = std.mem.zeroes([128]u8);
        const cmsg: *c.struct_cmsghdr = @ptrCast(&cbuf);
        cmsg.cmsg_len = @intCast(hdr_size + n_fds * @sizeOf(c_int));
        cmsg.cmsg_level = c.SOL_SOCKET;
        cmsg.cmsg_type = c.SCM_RIGHTS;
        for (nv.out_fds.items[0..n_fds], 0..) |fd, i| {
            @memcpy(cbuf[hdr_size + i * @sizeOf(c_int) ..][0..@sizeOf(c_int)], std.mem.asBytes(&fd));
        }
        var mh = std.mem.zeroes(c.struct_msghdr);
        mh.msg_iov = @ptrCast(&iov);
        mh.msg_iovlen = 1;
        mh.msg_control = &cbuf;
        const space = (cmsg.cmsg_len + @sizeOf(usize) - 1) & ~@as(usize, @sizeOf(usize) - 1);
        mh.msg_controllen = @intCast(space);
        const r = c.sendmsg(ch.fd, &mh, 0);
        if (r > 0) {
            // Kernel duplicated them into the receiver's queue.
            for (nv.out_fds.items[0..n_fds]) |fd| _ = c.close(fd);
            for (0..n_fds) |_| _ = nv.out_fds.orderedRemove(0);
        }
        return r;
    }

    // ── sketerm-native app pipe ─────────────────────────────────

    /// Drain the app's Wayland socket: bytes into the reassembly
    /// buffer, SCM_RIGHTS fds into the pairing queue, then process
    /// complete messages.
    fn nativeReadable(self: *Daemon, ch: *Channel) void {
        const nv = ch.native.?;
        var rounds: u8 = 0;
        while (rounds < 4) : (rounds += 1) {
            var data: [16384]u8 = undefined;
            var cbuf: [256]u8 align(@alignOf(c.struct_cmsghdr)) = undefined;
            var iov = c.struct_iovec{ .iov_base = &data, .iov_len = data.len };
            var mh = std.mem.zeroes(c.struct_msghdr);
            mh.msg_iov = @ptrCast(&iov);
            mh.msg_iovlen = 1;
            mh.msg_control = &cbuf;
            mh.msg_controllen = cbuf.len;
            // No MSG_CMSG_CLOEXEC: Darwin lacks it, and the daemon
            // is single-threaded — collectFds sets FD_CLOEXEC before
            // anything can fork.
            const r = c.recvmsg(ch.fd, &mh, 0);
            if (r < 0) {
                if (std.posix.errno(r) != .AGAIN) self.closeChannel(ch, true);
                break;
            }
            if (r == 0) {
                self.closeChannel(ch, true);
                break;
            }
            collectFds(nv, &mh);
            nv.inbuf.appendSlice(nv.allocator, data[0..@intCast(r)]) catch {
                self.closeChannel(ch, true);
                return;
            };
            if (@as(usize, @intCast(r)) < data.len) break;
        }
        if (!ch.dead) self.nativeProcess(ch);
    }

    /// Hand-rolled CMSG walk (the CMSG_* macros don't survive
    /// translate-c). On both 64-bit glibc and musl the cmsghdr is 16
    /// bytes and CMSG_ALIGN(sizeof cmsghdr) == sizeof cmsghdr, so
    /// data follows the header directly.
    fn collectFds(nv: *Native, mh: *const c.struct_msghdr) void {
        const ctl: [*]const u8 = @ptrCast(mh.msg_control orelse return);
        const clen: usize = @intCast(mh.msg_controllen);
        const hdr_size: usize = @sizeOf(c.struct_cmsghdr);
        const alignment: usize = @sizeOf(usize);
        var off: usize = 0;
        while (off + hdr_size <= clen) {
            const hdr: *const c.struct_cmsghdr = @alignCast(@ptrCast(ctl + off));
            const cl: usize = @intCast(hdr.cmsg_len);
            if (cl < hdr_size or off + cl > clen) break;
            if (hdr.cmsg_level == c.SOL_SOCKET and hdr.cmsg_type == c.SCM_RIGHTS) {
                const n_fds = (cl - hdr_size) / @sizeOf(c_int);
                var i: usize = 0;
                while (i < n_fds) : (i += 1) {
                    var fd: c_int = undefined;
                    @memcpy(std.mem.asBytes(&fd), ctl[off + hdr_size + i * @sizeOf(c_int) ..][0..@sizeOf(c_int)]);
                    _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
                    nv.fds.append(nv.allocator, fd) catch {
                        _ = c.close(fd);
                    };
                }
            }
            off += (cl + alignment - 1) & ~(alignment - 1);
        }
    }

    /// Peel complete Wayland messages off the reassembly buffer,
    /// track them, and emit pipe units toward the GUI. Any protocol
    /// violation kills the app connection (matching a strict
    /// compositor).
    fn nativeProcess(self: *Daemon, ch: *Channel) void {
        const nv = ch.native.?;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(self.allocator);

        var pos: usize = 0;
        var fail = false;
        while (!fail) {
            const avail = nv.inbuf.items[pos..];
            const mh = wlwire.parseHeader(avail) catch {
                fail = true;
                break;
            } orelse break;
            if (avail.len < mh.size) break;
            const msgb = avail[0..mh.size];
            const action = nv.tracker.clientMessage(mh, msgb[wlwire.header_size..]) catch {
                fail = true;
                break;
            };
            self.nativeAction(nv, &units, msgb, action) catch {
                fail = true;
                break;
            };
            pos += mh.size;
        }
        if (pos > 0) {
            const rem = nv.inbuf.items.len - pos;
            std.mem.copyForwards(u8, nv.inbuf.items[0..rem], nv.inbuf.items[pos..]);
            nv.inbuf.shrinkRetainingCapacity(rem);
        }
        if (units.items.len > 0) self.queueUnits(ch, units.items);
        if (fail) self.closeChannel(ch, true);
    }

    /// Bound on pool bytes per pipe unit — also the granularity at
    /// which queueUnits may split the stream into chan_data frames.
    const POOL_CHUNK: usize = 1 << 20;

    fn nativeAction(self: *Daemon, nv: *Native, units: *std.ArrayList(u8), msgb: []const u8, action: wltrack.Action) !void {
        const a = self.allocator;
        switch (action) {
            .relay, .buffer_create, .buffer_destroy => try wlpipe.appendUnit(units, a, .wl_msg, msgb),
            .clip_receive => {
                // App wants to paste: hold the write-end until the
                // GUI ships clip_data; relay so the GUI knows the
                // mime asked for.
                const fd = nv.popFd() orelse return error.MissingFd;
                nv.clip_paste_fds.append(a, fd) catch {
                    _ = c.close(fd);
                    return error.MissingFd;
                };
                try wlpipe.appendUnit(units, a, .wl_msg, msgb);
            },
            .pool_create => |p| {
                const fd = nv.popFd() orelse return error.MissingFd;
                errdefer _ = c.close(fd);
                if (p.size <= 0) return error.BadSize;
                const sz: usize = @intCast(p.size);
                const ptr = c.mmap(null, sz, c.PROT_READ, c.MAP_SHARED, fd, 0);
                if (ptr == null or ptr == c.MAP_FAILED) return error.MapFailed;
                // munmap before close on the failure path, matching the
                // teardown order in Native.deinit (errdefers run LIFO,
                // and the fd's close errdefer was registered earlier).
                // Emit the pipe units FIRST so the only remaining
                // fallible step is pools.put: once put succeeds the map
                // owns the mapping (deinit frees it) and this errdefer
                // no longer fires.
                errdefer _ = c.munmap(@ptrCast(ptr.?), sz);
                try wlpipe.appendUnit(units, a, .wl_msg, msgb);
                try wlpipe.appendPoolMeta(units, a, .pool_create, p.id, @intCast(sz));
                try nv.pools.put(a, p.id, .{ .fd = fd, .ptr = @ptrCast(ptr.?), .size = sz });
            },
            .pool_resize => |p| {
                const mirror = nv.pools.getPtr(p.id) orelse return error.NoSuchPool;
                if (p.size <= 0) return error.BadSize;
                const sz: usize = @intCast(p.size);
                if (sz < mirror.size) return error.BadSize; // pools only grow
                _ = c.munmap(mirror.ptr, mirror.size);
                const ptr = c.mmap(null, sz, c.PROT_READ, c.MAP_SHARED, mirror.fd, 0);
                if (ptr == null or ptr == c.MAP_FAILED) {
                    // Mirror is gone; the pool is unusable from here.
                    _ = c.close(mirror.fd);
                    _ = nv.pools.remove(p.id);
                    return error.MapFailed;
                }
                mirror.ptr = @ptrCast(ptr.?);
                mirror.size = sz;
                try wlpipe.appendUnit(units, a, .wl_msg, msgb);
                try wlpipe.appendPoolMeta(units, a, .pool_resize, p.id, @intCast(sz));
            },
            .pool_destroy => {
                // Keep the mirror: live buffers still reference the
                // pool memory (wl_shm_pool destructor semantics).
                try wlpipe.appendUnit(units, a, .wl_msg, msgb);
            },
            .commit => |cm| {
                // Copy the damaged rows (full buffer when the client
                // never declares damage). Rows are contiguous in the
                // pool, so the range is one linear copy.
                if (nv.pools.get(cm.info.pool)) |mirror| {
                    if (cm.info.offset >= 0 and cm.info.stride > 0 and cm.info.height > 0) {
                        var y0: i64 = 0;
                        var y1: i64 = cm.info.height;
                        if (cm.damage) |d| {
                            y0 = @max(y0, @as(i64, d.y0));
                            y1 = @min(y1, @as(i64, d.y1));
                        }
                        if (y0 < y1) {
                            // A hot + photographic surface routes through the
                            // lossy video coder (pool_vtile) instead; the
                            // whole branch is comptime-off without -Dvideo, so
                            // default builds take the lossless path verbatim.
                            var did_video = false;
                            if (comptime build_options.video) {
                                did_video = nv.videoCommit(units, a, cm, mirror, y0, y1) catch false;
                            }
                            if (!did_video) {
                                // Chunk by WHOLE ROWS so each chunk starts at
                                // column 0 — the pixcodec predictor resets per
                                // row, and arbitrary byte cuts would misalign it.
                                const stride: usize = @intCast(cm.info.stride);
                                const rows_per_chunk: i64 = @intCast(@max(1, POOL_CHUNK / stride));
                                var sc: wlpixcodec.Scratch = .{}; // arena-backed; reset on drain
                                var y = y0;
                                while (y < y1) {
                                    const yc = @min(y + rows_per_chunk, y1);
                                    const off: usize = @intCast(@as(i64, cm.info.offset) + y * cm.info.stride);
                                    const len: usize = @intCast((yc - y) * cm.info.stride);
                                    const end = @min(off +| len, mirror.size);
                                    if (off < end) {
                                        const raw = mirror.ptr[off..end];
                                        const enc = wlpixcodec.encodeRegion(&sc, a, raw, stride) catch
                                            wlpixcodec.Encoded{ .coder = .raw, .filter = .none, .bytes = raw };
                                        try wlpipe.appendPoolUpdateC(units, a, cm.info.pool, @intCast(off), enc, @intCast(raw.len), @intCast(stride));
                                    }
                                    y = yc;
                                }
                            }
                        }
                    }
                }
                try wlpipe.appendUnit(units, a, .wl_msg, msgb);
            },
        }
    }

    /// Ship a unit stream to the channel's client, split into
    /// chan_data frames well below MAX_FRAME (units may split across
    /// frames — pipe.zig receivers reassemble).
    fn queueUnits(self: *Daemon, ch: *Channel, bytes: []const u8) void {
        const MAX_CHUNK: usize = 4 << 20;
        var off: usize = 0;
        while (off < bytes.len) {
            const end = @min(off + MAX_CHUNK, bytes.len);
            const payload = self.allocator.alloc(u8, 4 + (end - off)) catch {
                self.closeChannel(ch, true);
                return;
            };
            defer self.allocator.free(payload);
            std.mem.writeInt(u32, payload[0..4], ch.id, .little);
            @memcpy(payload[4..], bytes[off..end]);
            ch.client.queueFrame(.chan_data, payload);
            off = end;
        }
    }

    /// One clipboard-fetch pipe is readable: drain it; on EOF ship
    /// the collected bytes up as a clip_data unit and drop the
    /// entry. Returns true when the entry was removed.
    fn clipReadable(self: *Daemon, ch: *Channel, idx: usize) bool {
        const nv = ch.native.?;
        const cr = &nv.clip_reads.items[idx];
        var done = false;
        while (true) {
            var buf: [4096]u8 = undefined;
            const r = c.read(cr.fd, &buf, buf.len);
            if (r > 0) {
                // Cap pathological sources at 16 MB.
                if (cr.buf.items.len < (16 << 20)) {
                    cr.buf.appendSlice(nv.allocator, buf[0..@intCast(r)]) catch {
                        done = true;
                        break;
                    };
                }
                continue;
            }
            if (r < 0 and std.posix.errno(r) == .AGAIN) break;
            done = true; // EOF or error
            break;
        }
        if (!done) return false;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(self.allocator);
        wlpipe.appendUnit(&units, self.allocator, .clip_data, cr.buf.items) catch {};
        if (units.items.len > 0) self.queueUnits(ch, units.items);
        _ = c.close(cr.fd);
        cr.buf.deinit(nv.allocator);
        _ = nv.clip_reads.orderedRemove(idx);
        return true;
    }

    /// GUI→app bytes on a native channel: peel pipe units, write the
    /// Wayland events through to the app, watch for delete_id.
    fn nativeClientData(self: *Daemon, ch: *Channel, bytes: []const u8) void {
        const nv = ch.native.?;
        nv.unitbuf.appendSlice(nv.allocator, bytes) catch {
            self.closeChannel(ch, true);
            return;
        };
        var pos: usize = 0;
        while (true) {
            const peeled = wlpipe.peelUnit(nv.unitbuf.items[pos..]) catch {
                self.closeChannel(ch, true);
                return;
            } orelse break;
            switch (peeled.unit.tag) {
                .wl_msg => {
                    // One Wayland message per unit (pipe contract).
                    const maybe_hdr = wlwire.parseHeader(peeled.unit.payload) catch null;
                    if (maybe_hdr) |h| {
                        nv.tracker.serverMessage(h, peeled.unit.payload[wlwire.header_size..]) catch {};
                    }
                    ch.pending.appendSlice(ch.allocator, peeled.unit.payload) catch {
                        self.closeChannel(ch, true);
                        return;
                    };
                },
                .keymap => {
                    // u32 keyboard id, u32 format, keymap bytes.
                    // Materialize an anon fd and emit the real
                    // wl_keyboard.keymap(format, fd, size) event.
                    const pl = peeled.unit.payload;
                    if (pl.len < 8) break;
                    const kbd = std.mem.readInt(u32, pl[0..4], .little);
                    const format = std.mem.readInt(u32, pl[4..8], .little);
                    const blob = pl[8..];
                    // NUL-terminated per xkb convention.
                    const fd = @import("../util/platform.zig").anonFileFd(blob.len + 1);
                    if (fd < 0) break;
                    var written: usize = 0;
                    var w_ok = true;
                    while (written < blob.len) {
                        const w = c.write(fd, blob.ptr + written, blob.len - written);
                        if (w <= 0) {
                            w_ok = false;
                            break;
                        }
                        written += @intCast(w);
                    }
                    if (!w_ok) {
                        _ = c.close(fd);
                        break;
                    }
                    var mbuf: [24]u8 = undefined;
                    var b = wlwire.Builder.init(&mbuf, kbd, 0); // keymap
                    b.putUint(format);
                    // 'h' fd arg: no bytes on the wire
                    b.putUint(@intCast(blob.len + 1));
                    const msg = b.finish() catch {
                        _ = c.close(fd);
                        break;
                    };
                    ch.pending.appendSlice(ch.allocator, msg) catch {
                        _ = c.close(fd);
                        self.closeChannel(ch, true);
                        return;
                    };
                    nv.out_fds.append(nv.allocator, fd) catch {
                        _ = c.close(fd);
                    };
                },
                .clip_send => {
                    // GUI fetches the app's clipboard: pipe(), the
                    // write-end rides a wl_data_source.send event,
                    // the read-end is polled until the app's EOF.
                    const pl = peeled.unit.payload;
                    if (pl.len < 4) break;
                    const source = std.mem.readInt(u32, pl[0..4], .little);
                    const mime = pl[4..];
                    var pfds: [2]c_int = undefined;
                    if (c.pipe(&pfds) != 0) break;
                    _ = c.fcntl(pfds[0], c.F_SETFD, c.FD_CLOEXEC);
                    _ = c.fcntl(pfds[1], c.F_SETFD, c.FD_CLOEXEC);
                    const fl = c.fcntl(pfds[0], c.F_GETFL, @as(c_int, 0));
                    _ = c.fcntl(pfds[0], c.F_SETFL, fl | c.O_NONBLOCK);

                    // `send` is opcode 1 on wl_data_source but opcode 0
                    // on zwlr_data_control_source_v1 — pick by the
                    // source object's tracked interface.
                    const send_op: u16 = if (nv.tracker.objects.get(source)) |sif|
                        (if (sif == &wlproto.zwlr_data_control_source_v1) 0 else 1)
                    else
                        1;
                    var mbuf: [256]u8 = undefined;
                    var b = wlwire.Builder.init(&mbuf, source, send_op); // send
                    b.putString(mime);
                    const msg = b.finish() catch {
                        _ = c.close(pfds[0]);
                        _ = c.close(pfds[1]);
                        break;
                    };
                    ch.pending.appendSlice(ch.allocator, msg) catch {
                        _ = c.close(pfds[0]);
                        _ = c.close(pfds[1]);
                        self.closeChannel(ch, true);
                        return;
                    };
                    nv.out_fds.append(nv.allocator, pfds[1]) catch {
                        _ = c.close(pfds[1]);
                    };
                    nv.clip_reads.append(nv.allocator, .{ .fd = pfds[0] }) catch {
                        _ = c.close(pfds[0]);
                    };
                },
                .clip_data => {
                    // Paste bytes for the oldest held receive-fd.
                    if (nv.clip_paste_fds.items.len == 0) break;
                    const fd = nv.clip_paste_fds.orderedRemove(0);
                    const data = peeled.unit.payload;
                    var written: usize = 0;
                    while (written < data.len) {
                        const w = c.write(fd, data.ptr + written, data.len - written);
                        if (w <= 0) break;
                        written += @intCast(w);
                    }
                    _ = c.close(fd);
                },
                // Unknown tags skip for forward compat.
                else => {},
            }
            pos += peeled.consumed;
        }
        if (pos > 0) {
            const rem = nv.unitbuf.items.len - pos;
            std.mem.copyForwards(u8, nv.unitbuf.items[0..rem], nv.unitbuf.items[pos..]);
            nv.unitbuf.shrinkRetainingCapacity(rem);
        }
        self.channelWritable(ch);
    }

    fn closeChannel(self: *Daemon, ch: *Channel, notify: bool) void {
        _ = self;
        if (ch.dead) return;
        ch.dead = true;
        if (notify and !ch.client.dead) {
            var hdr: [4]u8 = undefined;
            ch.client.queueFrame(.chan_close, wire.putChanHeader(&hdr, ch.id));
        }
    }

    fn findSession(self: *Daemon, name: []const u8) ?*Session {
        for (self.sessions.items) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    fn handleSpawn(self: *Daemon, cl: *Client, payload: []const u8) void {
        if (self.is_broker) return self.brokerSpawn(cl, payload);
        var parsed = std.json.parseFromSlice(SpawnReq, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cl.queueErr("bad spawn request");
            return;
        };
        defer parsed.deinit();
        var req = parsed.value;
        if (req.name.len == 0 or req.name.len > 64) {
            cl.queueErr("spawn needs a name");
            return;
        }
        // Empty argv = "the daemon host's login shell" — remote
        // clients can't know what's installed here.
        const default_shell: []const []const u8 = &.{blk: {
            const sh = std.c.getenv("SHELL");
            break :blk if (sh != null) std.mem.span(sh.?) else "/bin/sh";
        }};
        if (req.argv.len == 0) req.argv = default_shell;
        if (self.findSession(req.name) != null) {
            cl.queueErr("session name already exists");
            return;
        }
        const s = self.spawnSession(req) catch {
            cl.queueErr("spawn failed");
            return;
        };
        self.sessions.append(self.allocator, s) catch {
            s.deinit();
            cl.queueErr("oom");
            return;
        };
        cl.queueJson(.ok, .{ .ok = true, .name = s.name });
    }

    fn brokerFindWorker(self: *Daemon, name: []const u8) ?*Worker {
        for (self.workers.items) |w| {
            if (!w.dead and std.mem.eql(u8, w.name, name)) return w;
        }
        return null;
    }

    /// Apply per-worker resource limits in the freshly forked child, before it
    /// becomes a worker. Opt-in via SKETERM_WORKER_MEM_MB (megabytes of address
    /// space, RLIMIT_AS); unset or 0 = no cap. A capped worker that runs away
    /// hits ENOMEM and dies alone — the broker just sees it exit (containment),
    /// so a single OOM never reaches the machine's global OOM killer. Off by
    /// default because RLIMIT_AS bounds VIRTUAL space, which heavy-image
    /// sessions can legitimately reserve; the knob is for hosts that want a
    /// hard ceiling.
    fn applyWorkerLimits() void {
        const env = std.c.getenv("SKETERM_WORKER_MEM_MB") orelse return;
        const mb = std.fmt.parseInt(u64, std.mem.span(env), 10) catch {
            std.debug.print("sketerm-mux: ignoring unparseable SKETERM_WORKER_MEM_MB={s}\n", .{std.mem.span(env)});
            return;
        };
        if (mb == 0) return;
        const bytes = mb * 1024 * 1024;
        const rl = c.struct_rlimit{ .rlim_cur = @intCast(bytes), .rlim_max = @intCast(bytes) };
        _ = c.setrlimit(c.RLIMIT_AS, &rl);
    }

    /// Broker side of spawn: fork a worker process that owns this session.
    /// fork-without-exec — the child runs `runWorker` against an inherited
    /// (COW) copy of the SpawnReq; it first drops every broker fd it inherited.
    fn brokerSpawn(self: *Daemon, cl: *Client, payload: []const u8) void {
        var parsed = std.json.parseFromSlice(SpawnReq, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cl.queueErr("bad spawn request");
            return;
        };
        defer parsed.deinit();
        var req = parsed.value;
        if (req.name.len == 0 or req.name.len > 64) {
            cl.queueErr("spawn needs a name");
            return;
        }
        const default_shell: []const []const u8 = &.{blk: {
            const sh = std.c.getenv("SHELL");
            break :blk if (sh != null) std.mem.span(sh.?) else "/bin/sh";
        }};
        if (req.argv.len == 0) req.argv = default_shell;
        if (self.brokerFindWorker(req.name) != null) {
            cl.queueErr("session name already exists");
            return;
        }

        // SEQPACKET so each control message (and its SCM_RIGHTS fd) is one
        // clean datagram on the broker↔worker channel.
        var sp: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_SEQPACKET, 0, &sp) != 0) {
            cl.queueErr("spawn failed");
            return;
        }
        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(sp[0]);
            _ = c.close(sp[1]);
            cl.queueErr("spawn failed");
            return;
        }
        if (pid == 0) {
            // Worker child: drop every inherited broker fd, then become a
            // single-session worker. `req` is valid here via COW; we _exit
            // before the parent's `defer parsed.deinit()` matters to us.
            _ = c.close(sp[0]);
            if (self.listen_fd >= 0) _ = c.close(self.listen_fd);
            for (self.clients.items) |cc| _ = c.close(cc.fd);
            for (self.workers.items) |w| {
                if (w.control_fd >= 0) _ = c.close(w.control_fd);
            }
            _ = c.setsid();
            applyWorkerLimits();
            // Hand the worker the broker's socket dir so its Wayland display /
            // isolated-rt sockets land in the right runtime dir (the worker has
            // no listen socket of its own to derive it from). COW-valid here.
            const dir_end = std.mem.lastIndexOfScalar(u8, self.sock_path, '/') orelse self.sock_path.len;
            runWorker(self.allocator, sp[1], req, self.sock_path[0..dir_end]) catch {};
            c._exit(0);
        }
        // Broker parent.
        _ = c.close(sp[1]);
        _ = c.fcntl(sp[0], c.F_SETFD, c.FD_CLOEXEC);
        const name_owned = self.allocator.dupe(u8, req.name) catch {
            _ = c.close(sp[0]);
            cl.queueErr("oom");
            return;
        };
        const w = self.allocator.create(Worker) catch {
            self.allocator.free(name_owned);
            _ = c.close(sp[0]);
            cl.queueErr("oom");
            return;
        };
        w.* = .{ .allocator = self.allocator, .name = name_owned, .pid = pid, .control_fd = sp[0], .app = req.app, .pending_client = cl };
        self.workers.append(self.allocator, w) catch {
            w.deinit();
            cl.queueErr("oom");
            return;
        };
        // Reply is deferred: `brokerOnWorkerControl` sends `.ok` when the
        // worker reports 'Y' (session up), or `.err` if the worker dies first
        // (spawnSession failed). The client is blocked in recvExpect(.ok).
    }

    /// Broker side of attach: hand the client's socket fd to the session's
    /// worker (SCM_RIGHTS) and drop our copy — the worker serves it directly.
    fn brokerAttach(self: *Daemon, cl: *Client, payload: []const u8) void {
        var parsed = std.json.parseFromSlice(AttachReq, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cl.queueErr("bad attach request");
            return;
        };
        defer parsed.deinit();
        const w = self.brokerFindWorker(parsed.value.name) orelse {
            cl.queueErr("no such session");
            return;
        };
        const msg = [_]u8{ 'A', @truncate(cl.proto), @intFromBool(cl.video) };
        controlSend(w.control_fd, &msg, cl.fd);
        // Handed off: the kernel duplicated the fd into the worker. Drop our
        // copy + the Client (reap closes the broker's fd; the worker's stays).
        //
        // ASSUMPTION: the client is synchronous — it sends `.attach` and then
        // blocks on the snapshot, so nothing is pipelined behind `.attach`. If
        // it ever weren't, bytes the broker already pulled into `cl.rbuf` would
        // be stranded here (the kernel buffer the worker inherits no longer has
        // them). Revisit (forward leftover rbuf in the 'A' frame) before any
        // client starts streaming input ahead of the snapshot.
        cl.dead = true;
    }

    /// Broker side of list: answer from each worker's pushed metadata cache.
    /// The broker holds no Screen, so every field here came over a worker 'M'
    /// push; idle_ms is computed against the broker's own (shared) clock.
    fn brokerList(self: *Daemon, cl: *Client) void {
        var infos: std.ArrayList(SessionInfo) = .empty;
        defer infos.deinit(self.allocator);
        const now = nowMs();
        for (self.workers.items) |w| {
            if (w.dead) continue;
            infos.append(self.allocator, .{
                .name = w.name,
                .rows = w.rows,
                .cols = w.cols,
                .clients = w.n_clients,
                .exited = w.exited,
                .title = if (w.title) |t| t else "",
                .app = w.app,
                // A worker that has never pushed (activity==0) reads as idle 0
                // rather than a bogus multi-decade idle.
                .idle_ms = if (w.last_activity_ms == 0) 0 else now - w.last_activity_ms,
                .cwd = if (w.cwd) |cw| cw else "",
            }) catch return;
        }
        cl.queueJson(.welcome, .{ .proto = wire.PROTO_VERSION, .sessions = infos.items });
    }

    /// Broker side of kill: send the worker a graceful 'K' (it flushes `.gone`
    /// to its clients and exits) and mark it dead so the name frees at once.
    /// The buffered 'K' datagram is delivered to the worker even though reap
    /// closes the broker's control end this tick.
    fn brokerKill(self: *Daemon, cl: *Client, payload: []const u8) void {
        var parsed = std.json.parseFromSlice(AttachReq, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cl.queueErr("bad kill request");
            return;
        };
        defer parsed.deinit();
        const w = self.brokerFindWorker(parsed.value.name) orelse {
            cl.queueErr("no such session");
            return;
        };
        controlSend(w.control_fd, "K", -1);
        w.dead = true;
        cl.queueJson(.ok, .{ .ok = true });
    }

    /// Broker side of rename: the broker is the routing authority, so update
    /// `Worker.name` here, and forward an 'R' to the worker so its own session
    /// state stays consistent.
    fn brokerRename(self: *Daemon, cl: *Client, payload: []const u8) void {
        var parsed = std.json.parseFromSlice(RenameReq, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cl.queueErr("bad rename request");
            return;
        };
        defer parsed.deinit();
        const req = parsed.value;
        if (req.new_name.len == 0 or req.new_name.len > 64) {
            cl.queueErr("rename needs a name (1-64 chars)");
            return;
        }
        const w = self.brokerFindWorker(req.name) orelse {
            cl.queueErr("no such session");
            return;
        };
        if (self.brokerFindWorker(req.new_name)) |other| {
            if (other != w) {
                cl.queueErr("session name already exists");
                return;
            }
        }
        const fresh = self.allocator.dupe(u8, req.new_name) catch {
            cl.queueErr("oom");
            return;
        };
        self.allocator.free(w.name);
        w.name = fresh;
        var msg: [1 + 64]u8 = undefined;
        msg[0] = 'R';
        @memcpy(msg[1..][0..req.new_name.len], req.new_name);
        controlSend(w.control_fd, msg[0 .. 1 + req.new_name.len], -1);
        cl.queueJson(.ok, .{ .ok = true, .name = w.name });
    }

    const WaylandHub = struct {
        fd: c_int,
        display_path: []u8,
    };

    /// Create a session's Wayland display socket next to the daemon
    /// socket and listen on it — the daemon IS the display, so the
    /// listening socket is the one the shell's $WAYLAND_DISPLAY points
    /// at. Null on any failure (the session still spawns, just without
    /// Wayland forwarding).
    /// True in a forked session worker (owns one session over a control_fd,
    /// no listen socket). Broker and monolith both have control_fd == -1.
    inline fn isWorker(self: *const Daemon) bool {
        return self.control_fd >= 0;
    }

    /// Directory the session's auxiliary sockets (Wayland display, isolated rt
    /// dir) live in. The monolith/broker derive it from their listen socket
    /// path; a worker was handed it at fork (it has no listen socket). Null if
    /// neither is available.
    fn runtimeBaseDir(self: *const Daemon) ?[]const u8 {
        if (self.base_dir) |d| return d;
        const dir_end = std.mem.lastIndexOfScalar(u8, self.sock_path, '/') orelse return null;
        return self.sock_path[0..dir_end];
    }

    fn setupWaylandHub(self: *Daemon) ?WaylandHub {
        const dir = self.runtimeBaseDir() orelse return null;
        // Workers share the runtime dir, each with one session, so a per-worker
        // counter would collide ("wl-1" in every worker) — name by pid instead.
        // The monolith keeps the sequential "wl-N" the rigs expect.
        const display_path = if (self.isWorker())
            std.fmt.allocPrint(self.allocator, "{s}/wl-w{d}", .{ dir, c.getpid() }) catch return null
        else blk: {
            const id = self.next_wl_id;
            self.next_wl_id += 1;
            break :blk std.fmt.allocPrint(self.allocator, "{s}/wl-{d}", .{ dir, id }) catch return null;
        };
        var ok = false;
        defer if (!ok) self.allocator.free(display_path);

        var z_buf: [4096]u8 = undefined;
        if (pathZ(&z_buf, display_path)) |z| _ = c.unlink(z) else |_| return null;

        const fd = @import("../util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return null;
        var addr: c.struct_sockaddr_un = undefined;
        fillSockaddrUn(&addr, display_path) catch {
            _ = c.close(fd);
            return null;
        };
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0 or c.listen(fd, 8) != 0) {
            _ = c.close(fd);
            return null;
        }
        ok = true;
        return .{ .fd = fd, .display_path = display_path };
    }

    /// Window-stream backend policy for a spawn. On macOS builds
    /// with the ScreenCaptureKit backend, app sessions capture
    /// automatically (their apps have no forwardable display
    /// protocol). The SKETERM_WINSTREAM env is the rig override:
    /// "stub" = test pattern for app sessions, "all" = test pattern
    /// for every session, "sck" = real capture for every session. Any
    /// value but "sck" forces the stub so smoke-mux and Linux rigs get
    /// a deterministic pattern.
    /// `hosts_apps` = this session would forward GUI apps on Linux
    /// (interactive command, forwarding not disabled). On macOS,
    /// winstream IS that forwarding mechanism, so capture turns on for
    /// ANY such session — a GUI app launched from a durable Mac shell
    /// streams exactly like one launched from a Linux durable shell
    /// ($WAYLAND_DISPLAY). Env overrides for the test rigs: "off"
    /// suppresses the macOS auto gate (Linux-like behaviour),
    /// "all"/"sck" widen to every session, "stub"/other force the
    /// test pattern.
    fn winstreamGate(req: SpawnReq, hosts_apps: bool) struct { want: bool, use_sck: bool } {
        const env = std.c.getenv("SKETERM_WINSTREAM");
        const val: ?[]const u8 = if (env) |e| std.mem.span(e) else null;
        const eq = struct {
            fn f(v: ?[]const u8, s: []const u8) bool {
                return v != null and std.mem.eql(u8, v.?, s);
            }
        }.f;
        const off = eq(val, "off");
        const widen = eq(val, "all") or eq(val, "sck");
        // macOS apps have no display protocol to forward — winstream
        // is the only mechanism, so it stands in for Wayland
        // forwarding on any app-hosting session.
        const auto_mac = (comptime wssource.have_sck) and !off and hosts_apps;
        return .{
            .want = req.winstream or (val != null and !off and (req.app or widen)) or auto_mac,
            .use_sck = (comptime wssource.have_sck) and (val == null or eq(val, "sck")),
        };
    }

    fn spawnSession(self: *Daemon, req: SpawnReq) !*Session {
        const allocator = self.allocator;

        // Wayland forwarding: the daemon IS the session's display —
        // it listens on the display socket itself and parses each app
        // connection. SKETERM_MUX_NO_WAYLAND=1 disables app forwarding.
        // hosts_apps: forwarding enabled with an actual command —
        // drives BOTH Wayland forwarding (Linux) and winstream capture
        // (macOS), the same notion of "a session whose child apps
        // should appear on the client".
        const hosts_apps = std.c.getenv("SKETERM_MUX_NO_WAYLAND") == null and
            req.argv.len > 0;

        // Window-stream backend (pixel capture): policy in winstreamGate.
        const ws_gate = winstreamGate(req, hosts_apps);

        // A local GUI-owned session passes its apps through to the
        // real desktop compositor — no embedded hub for it.
        const want_wayland = !ws_gate.want and hosts_apps and !req.local;
        var hub: ?WaylandHub = if (want_wayland) self.setupWaylandHub() else null;
        errdefer if (hub) |h| {
            _ = c.close(h.fd);
            allocator.free(h.display_path);
        };

        var argv_z: std.ArrayList([:0]u8) = .empty;
        defer {
            for (argv_z.items) |a| allocator.free(a);
            argv_z.deinit(allocator);
        }
        var argv_ptrs: std.ArrayList([*:0]const u8) = .empty;
        defer argv_ptrs.deinit(allocator);
        for (req.argv) |a| {
            const z = try allocator.dupeZ(u8, a);
            try argv_z.append(allocator, z);
            try argv_ptrs.append(allocator, z.ptr);
        }

        // The daemon is the display, so it sets the child's
        // WAYLAND_DISPLAY (= the hub's display socket).
        var wl_disp_z: ?[:0]u8 = null;
        defer if (wl_disp_z) |z| allocator.free(z);
        if (hub) |h| {
            wl_disp_z = try allocator.dupeZ(u8, h.display_path);
        } else if (req.local and req.host_wayland_display.len > 0) {
            // Local passthrough: point the child at the host compositor.
            wl_disp_z = try allocator.dupeZ(u8, req.host_wayland_display);
        }

        // Isolated session: a private runtime dir (sibling of the wl
        // sockets) so single-instance apps can't coalesce across
        // clients. The wl socket stays in the shared dir — its absolute
        // path in WAYLAND_DISPLAY is unaffected by XDG_RUNTIME_DIR.
        var rt_dir_z: ?[:0]u8 = null;
        defer if (rt_dir_z) |z| allocator.free(z);
        var rt_dir_owned: ?[]u8 = null;
        errdefer if (rt_dir_owned) |p| {
            removeTreeBestEffort(p);
            allocator.free(p);
        };
        if (req.isolated) {
            const dir = self.runtimeBaseDir() orelse "";
            const p = if (self.isWorker())
                try std.fmt.allocPrint(allocator, "{s}/rt-w{d}", .{ dir, c.getpid() })
            else blk: {
                const id = self.next_rt_id;
                self.next_rt_id += 1;
                break :blk try std.fmt.allocPrint(allocator, "{s}/rt-{d}", .{ dir, id });
            };
            rt_dir_owned = p;
            var z_buf: [4096]u8 = undefined;
            _ = c.mkdir(try pathZ(&z_buf, p), 0o700);
            rt_dir_z = try allocator.dupeZ(u8, p);
        }

        // Null-terminated copies of the GUI-supplied env/identity strings,
        // freed after spawn (the child has its own env copy by then). All
        // optional — empty/absent falls back to Pty.spawn's defaults.
        const sock_z: ?[:0]u8 = if (req.socket.len > 0) allocator.dupeZ(u8, req.socket) catch null else null;
        defer if (sock_z) |z| allocator.free(z);
        // The daemon owns the session name, so it (not the GUI) exports the
        // stable SKETERM_SESSION identity — no plumbing through the client.
        const name_z: ?[:0]u8 = if (req.name.len > 0) allocator.dupeZ(u8, req.name) catch null else null;
        defer if (name_z) |z| allocator.free(z);
        const term_z: ?[:0]u8 = if (req.term.len > 0) allocator.dupeZ(u8, req.term) catch null else null;
        defer if (term_z) |z| allocator.free(z);
        const cterm_z: ?[:0]u8 = if (req.color_term.len > 0) allocator.dupeZ(u8, req.color_term) catch null else null;
        defer if (cterm_z) |z| allocator.free(z);
        var si_script_z: ?[:0]u8 = null;
        var si_shim_z: ?[:0]u8 = null;
        defer if (si_script_z) |z| allocator.free(z);
        defer if (si_shim_z) |z| allocator.free(z);
        const PtyMod = @import("../pty.zig");
        const shell_integration: ?PtyMod.ShellIntegration = blk: {
            const si = req.shell_integration orelse break :blk null;
            const kind: PtyMod.ShellIntegration.Kind =
                if (std.mem.eql(u8, si.kind, "zsh")) .zsh
                else if (std.mem.eql(u8, si.kind, "fish")) .fish
                else break :blk null;
            si_script_z = allocator.dupeZ(u8, si.script) catch break :blk null;
            si_shim_z = allocator.dupeZ(u8, si.shim_dir) catch break :blk null;
            break :blk .{ .kind = kind, .script = si_script_z.?.ptr, .shim_dir = si_shim_z.?.ptr };
        };
        var pty = try Pty.spawn(.{
            .argv = argv_ptrs.items,
            .cwd = req.cwd,
            .rows = req.rows,
            .cols = req.cols,
            .term = if (term_z) |z| z.ptr else "xterm-256color",
            .color_term = if (cterm_z) |z| z.ptr else "truecolor",
            .login_shell = req.login_shell,
            .pane_id = req.pane_id,
            .socket_path = if (sock_z) |z| z.ptr else null,
            .session_name = if (name_z) |z| z.ptr else null,
            .shell_integration = shell_integration,
            .wayland_display = if (wl_disp_z) |z| z.ptr else null,
            .runtime_dir = if (rt_dir_z) |z| z.ptr else null,
        });
        errdefer _ = pty.closeAndReap();
        // The poll loop does bounded read rounds — master must not
        // block (the GUI's dedicated reader thread blocks; we can't).
        const fl = c.fcntl(pty.master_fd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(pty.master_fd, c.F_SETFL, fl | c.O_NONBLOCK);

        const pool = try allocator.create(Pool);
        errdefer allocator.destroy(pool);
        pool.* = try Pool.init(allocator);
        errdefer pool.deinit();
        const screen = try Screen.init(allocator, pool, req.cols, req.rows);
        errdefer screen.deinit();
        // Keep image placements for the attach snapshot — there's no
        // per-pane ImageStore on the daemon side to remember them.
        screen.retain_images = true;
        // Queries only the GUI can answer (clipboard read, color
        // scheme) are left for the attached mirror to reply to.
        screen.defer_gui_queries = true;

        const s = try allocator.create(Session);
        errdefer allocator.destroy(s);
        s.* = .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, req.name),
            .pty = pty,
            .parser = Parser.init(allocator),
            .pool = pool,
            .screen = screen,
            .app = req.app,
            .last_activity_ms = nowMs(),
        };
        if (hub) |h| {
            s.wl_hub_fd = h.fd;
            s.wl_display_path = h.display_path;
            hub = null; // ownership moved to the session
        }
        if (rt_dir_owned) |p| {
            s.runtime_dir_path = p;
            rt_dir_owned = null; // ownership moved to the session
        }
        if (ws_gate.want) create_ws: {
            const w = allocator.create(WsSource) catch break :create_ws;
            if (ws_gate.use_sck) {
                w.* = WsSource.initSck(allocator, s.pty.child_pid) catch |err| {
                    std.debug.print("sketerm-mux: window capture init failed ({s}) — session '{s}' has no app streaming\n", .{ @errorName(err), req.name });
                    allocator.destroy(w);
                    break :create_ws;
                };
            } else {
                w.* = WsSource.initStub(allocator);
            }
            s.winstream = w;
        }
        screen.sink = .{ .ctx = @ptrCast(s), .on_write_pty = Session.sinkWritePty };
        return s;
    }

    fn handleAttach(self: *Daemon, cl: *Client, payload: []const u8) void {
        if (self.is_broker) return self.brokerAttach(cl, payload);
        var parsed = std.json.parseFromSlice(AttachReq, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cl.queueErr("bad attach request");
            return;
        };
        defer parsed.deinit();
        const s = self.findSession(parsed.value.name) orelse {
            cl.queueErr("no such session");
            return;
        };
        if (s.exited) {
            // The corpse only lingers until the next reap; attaching
            // to it would wedge the client on a dead screen.
            cl.queueErr("session has exited");
            return;
        }
        cl.attached = s;
        // A (re)attaching client has no prior video reference frames, so
        // force the next video tile on every live surface to be a
        // keyframe. No-op unless video is active (vstate is otherwise
        // empty). rudp makes the transport reliable, so this — not
        // loss-recovery — is the only keyframe trigger needed.
        for (self.channels.items) |ch| {
            if (ch.session == s) {
                if (ch.native) |nv| {
                    var vit = nv.vstate.valueIterator();
                    while (vit.next()) |v| v.needs_kf = true;
                }
            }
        }
        self.queueSnapshot(cl, s);
        if (cl.proto >= 2) {
            if (s.winstream != null) self.openWinstreamChan(s, cl);
            // Apps that connected before any renderer was attached.
            while (s.wl_pending.items.len > 0) {
                const fd = s.wl_pending.orderedRemove(0);
                self.openAppChannel(s, cl, fd);
            }
        }
    }

    /// Window-stream channels have no fd (frames originate in the
    /// daemon) — fd = -1 is ignored by poll; the channel exists for
    /// id allocation and client routing.
    fn openWinstreamChan(self: *Daemon, s: *Session, cl: *Client) void {
        for (self.channels.items) |ch| {
            if (ch.session == s and !ch.dead and ch.native == null and s.winstream != null) return; // one per session
        }
        const ch = self.allocator.create(Channel) catch return;
        ch.* = .{
            .allocator = self.allocator,
            .id = self.next_chan_id,
            .fd = -1,
            .session = s,
            .client = cl,
        };
        self.next_chan_id += 1;
        self.channels.append(self.allocator, ch) catch {
            ch.deinit();
            return;
        };
        var hdr: [5]u8 = undefined;
        cl.queueFrame(.chan_open, wire.encodeChanOpen(&hdr, ch.id, .winstream));
        // Windows opened while nobody was attached (or for a prior
        // client) must be replayed for this one. Route windows through the
        // lossy video coder only if THIS client can decode it (mirrors the
        // Wayland `native.wants_video = cl.video`).
        if (s.winstream) |ws| {
            ws.setWantsVideo(cl.video);
            ws.reannounce();
        }
    }

    /// Pump every live window-stream session: frames toward the
    /// attached client, bounded by the poll cadence.
    fn pumpWinstreams(self: *Daemon) void {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        const now_ms: u64 = @intCast(ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1_000_000));
        for (self.channels.items) |ch| {
            if (ch.dead or ch.native != null) continue;
            const ws = ch.session.winstream orelse continue;
            if (ch.client.dead) continue;
            // Backpressure: a slow link must not balloon the client
            // write buffer — skip frame production until it drains
            // (the source keeps streaming; only emission pauses).
            if (ch.client.wbuf.items.len > 8 << 20) continue;
            var units: std.ArrayList(u8) = .empty;
            defer units.deinit(self.allocator);
            ws.poll(&units, self.allocator, now_ms) catch continue;
            if (units.items.len > 0) self.queueUnits(ch, units.items);
        }
    }

    fn queueSnapshot(self: *Daemon, cl: *Client, s: *Session) void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        // Header: [seq:u64][app:u8]. The app byte lets an attaching
        // client hold the pane open with the log visible when a
        // forwarded app exits, instead of detaching to a shell.
        var seq_hdr: [9]u8 = undefined;
        std.mem.writeInt(u64, seq_hdr[0..8], s.seq, .little);
        seq_hdr[8] = if (s.app) 1 else 0;
        buf.appendSlice(self.allocator, &seq_hdr) catch {
            cl.dead = true;
            return;
        };
        snapshot.serialize(s.screen, &buf, self.allocator) catch {
            cl.queueErr("snapshot failed");
            return;
        };
        cl.queueFrame(.snapshot, buf.items);
    }

    fn broadcastSnapshot(self: *Daemon, s: *Session) void {
        for (self.clients.items) |cl| {
            if (cl.attached == s and !cl.dead) self.queueSnapshot(cl, s);
        }
    }

    fn handleList(self: *Daemon, cl: *Client) void {
        if (self.is_broker) return self.brokerList(cl);
        var infos: std.ArrayList(SessionInfo) = .empty;
        defer infos.deinit(self.allocator);
        // Per-session cwd strings, owned for the life of this call (the
        // SessionInfo slices must stay valid through queueJson). One scratch
        // buffer per session, kept alive in `cwd_bufs`.
        var cwd_bufs: std.ArrayList([]u8) = .empty;
        defer {
            for (cwd_bufs.items) |b| self.allocator.free(b);
            cwd_bufs.deinit(self.allocator);
        }
        const now = nowMs();
        for (self.sessions.items) |s| {
            var n_clients: u32 = 0;
            for (self.clients.items) |c2| {
                if (c2.attached == s) n_clients += 1;
            }
            var cwd: []const u8 = "";
            var scratch: [4096]u8 = undefined;
            if (cwdOfPid(s.pty.child_pid, &scratch)) |cw| {
                if (self.allocator.dupe(u8, cw)) |owned| {
                    cwd_bufs.append(self.allocator, owned) catch {};
                    cwd = owned;
                } else |_| {}
            }
            infos.append(self.allocator, .{
                .name = s.name,
                .rows = s.screen.rows,
                .cols = s.screen.cols,
                .clients = n_clients,
                .exited = s.exited,
                .title = if (s.screen.last_title) |t| t else "",
                .app = s.app,
                .idle_ms = now - s.last_activity_ms,
                .cwd = cwd,
            }) catch return;
        }
        cl.queueJson(.welcome, .{ .proto = wire.PROTO_VERSION, .sessions = infos.items });
    }

    fn handleKill(self: *Daemon, cl: *Client, payload: []const u8) void {
        if (self.is_broker) return self.brokerKill(cl, payload);
        var parsed = std.json.parseFromSlice(AttachReq, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cl.queueErr("bad kill request");
            return;
        };
        defer parsed.deinit();
        const s = self.findSession(parsed.value.name) orelse {
            cl.queueErr("no such session");
            return;
        };
        self.removeSession(s);
        cl.queueJson(.ok, .{ .ok = true });
    }

    fn handleRename(self: *Daemon, cl: *Client, payload: []const u8) void {
        if (self.is_broker) return self.brokerRename(cl, payload);
        var parsed = std.json.parseFromSlice(RenameReq, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cl.queueErr("bad rename request");
            return;
        };
        defer parsed.deinit();
        const req = parsed.value;
        if (req.new_name.len == 0 or req.new_name.len > 64) {
            cl.queueErr("rename needs a name (1-64 chars)");
            return;
        }
        const s = self.findSession(req.name) orelse {
            cl.queueErr("no such session");
            return;
        };
        if (self.findSession(req.new_name)) |other| {
            if (other != s) {
                cl.queueErr("session name already exists");
                return;
            }
        }
        const fresh = self.allocator.dupe(u8, req.new_name) catch {
            cl.queueErr("oom");
            return;
        };
        self.allocator.free(s.name);
        s.name = fresh;
        cl.queueJson(.ok, .{ .ok = true, .name = s.name });
    }

    fn removeSession(self: *Daemon, s: *Session) void {
        for (self.clients.items) |cl| {
            if (cl.attached == s) {
                cl.attached = null;
                cl.queueJson(.gone, .{ .reason = "session closed" });
            }
        }
        for (self.channels.items) |ch| {
            if (ch.session == s) self.closeChannel(ch, true);
        }
        // Mark only — removeSession runs mid-tick (kill frames), and
        // dropping list entries here would desync the pollfd array
        // built at tick start. Marking exited makes this tick poll the
        // session fd as -1 (see tick()) so it stops draining
        // immediately, and reap() at tick end removes it via
        // swapRemove + s.deinit() — which calls pty.closeAndReap() to
        // SIGHUP/SIGTERM/SIGKILL and reap the child. The kill still
        // feels immediate: the client's .ok is queued by the caller
        // and the session is gone within this same tick.
        s.exited = true;
    }

    fn dropDeadChannels(self: *Daemon) void {
        var i: usize = 0;
        while (i < self.channels.items.len) {
            const ch = self.channels.items[i];
            if (ch.dead) {
                _ = self.channels.swapRemove(i);
                ch.deinit();
            } else {
                i += 1;
            }
        }
    }

    /// Read whatever the PTY has, parse, apply to the authoritative
    /// Screen, and broadcast the serialized events to attached
    /// clients in one EVENTS frame.
    fn drainSession(self: *Daemon, s: *Session) void {
        var chunk: [32768]u8 = undefined;
        var total_events = EventCollector{
            .allocator = self.allocator,
            .screen = s.screen,
            .writer = wire.Writer.init(self.allocator),
        };
        defer total_events.writer.deinit();

        var rounds: u8 = 0;
        while (rounds < 8) : (rounds += 1) {
            const n_raw = c.read(s.pty.master_fd, &chunk, chunk.len);
            if (n_raw < 0) {
                // EAGAIN = drained; anything else (EIO) = child gone.
                if (std.posix.errno(n_raw) != .AGAIN) self.sessionExited(s);
                break;
            }
            if (n_raw == 0) {
                self.sessionExited(s);
                break;
            }
            const n: usize = @intCast(n_raw);
            s.parser.advance(chunk[0..n], EventCollector.emit, @ptrCast(&total_events));
            if (n < chunk.len) break;
        }

        const n_events = total_events.count;
        if (n_events == 0) return;
        // Real terminal output this drain → the session is active now.
        s.last_activity_ms = nowMs();
        var any_attached = false;
        for (self.clients.items) |cl| {
            if (cl.attached == s and !cl.dead) {
                any_attached = true;
                break;
            }
        }
        if (any_attached) {
            var payload: std.ArrayList(u8) = .empty;
            defer payload.deinit(self.allocator);
            var hdr: [12]u8 = undefined;
            std.mem.writeInt(u64, hdr[0..8], s.seq, .little);
            std.mem.writeInt(u32, hdr[8..12], n_events, .little);
            payload.appendSlice(self.allocator, &hdr) catch return;
            payload.appendSlice(self.allocator, total_events.writer.buf.items) catch return;
            for (self.clients.items) |cl| {
                if (cl.attached == s and !cl.dead) cl.queueFrame(.events, payload.items);
            }
        }
        s.seq += n_events;
    }

    fn sessionExited(self: *Daemon, s: *Session) void {
        if (s.exited) return;
        s.exited = true;
        // We reach here on PTY EOF/EIO: the child has exited but is
        // not yet waited. Reap it now (non-blocking) so the .exit
        // frame carries the real WEXITSTATUS instead of the default 0.
        // If it isn't reapable yet, leave the default — the teardown
        // path (Session.deinit → closeAndReap) will wait it later.
        if (s.pty.reap()) |code| s.exit_status = code;
        var st: [4]u8 = undefined;
        std.mem.writeInt(i32, &st, s.exit_status, .little);
        // Deliver the exit, then force-detach: nothing will ever flow
        // on this session again, and a client that vanished without a
        // clean goodbye (UDP peer roamed away for good) must not pin
        // the dead session in the list forever.
        for (self.clients.items) |cl| {
            if (cl.attached == s) {
                if (!cl.dead) cl.queueFrame(.exit, &st);
                cl.attached = null;
            }
        }
    }

    fn reap(self: *Daemon) void {
        // A dying client takes its channels down — the remote apps'
        // display connections see EOF and fail cleanly.
        for (self.channels.items) |ch| {
            if (ch.client.dead) ch.dead = true;
        }
        self.dropDeadChannels();
        // A dying client abandons its uploads: close the partial file
        // (it stays on disk under its chosen name — no auto-delete; a
        // half-written upload is the user's to discard).
        {
            var i: usize = 0;
            while (i < self.uploads.items.len) {
                if (self.uploads.items[i].client.dead) {
                    self.uploads.swapRemove(i).deinit();
                } else i += 1;
            }
        }
        {
            var i: usize = 0;
            while (i < self.downloads.items.len) {
                if (self.downloads.items[i].client.dead) {
                    self.downloads.swapRemove(i).deinit();
                } else i += 1;
            }
        }
        var i: usize = 0;
        while (i < self.clients.items.len) {
            const cl = self.clients.items[i];
            if (cl.dead) {
                _ = self.clients.swapRemove(i);
                cl.deinit();
            } else {
                i += 1;
            }
        }
        // Exited sessions are removed outright — sessionExited
        // already detached every client (defensively re-checked here
        // so a dangling cl.attached is impossible). Live sessions are
        // NEVER reaped, attached or not: surviving client-less for
        // days is the whole point of the daemon.
        i = 0;
        while (i < self.sessions.items.len) {
            const s = self.sessions.items[i];
            if (s.exited) {
                for (self.clients.items) |cl| {
                    if (cl.attached == s) cl.attached = null;
                }
                _ = self.sessions.swapRemove(i);
                s.deinit();
                continue;
            }
            i += 1;
        }
        // A worker exists only to serve its one session. Once that session is
        // gone (shell exited on its own, or was killed), the worker has no
        // reason to live — tear it down so the broker sees control EOF and
        // reaps it (otherwise it polls forever, orphaned, and `list` keeps a
        // stale entry). The `.exit`/`.gone` already queued to the client is
        // delivered by run()'s flushClientsFinal before we close. The monolith
        // (no control_fd) keeps running client-less — that's its whole point.
        if (self.isWorker() and self.sessions.items.len == 0) self.running = false;
        // Broker: a dead worker (control EOF or killed) is removed once its
        // process has been waitpid'd — otherwise it lingers as a zombie. We
        // hold the record (with its pid) until the reap succeeds; WNOHANG==0
        // means "not exited yet", retry next tick. ECHILD (<0) → already gone.
        i = 0;
        while (i < self.workers.items.len) {
            const w = self.workers.items[i];
            if (w.dead) {
                var status: c_int = 0;
                const r = c.waitpid(w.pid, &status, c.WNOHANG);
                if (r == 0) {
                    i += 1; // still alive; check again next tick
                    continue;
                }
                _ = self.workers.swapRemove(i);
                w.deinit();
                continue;
            }
            i += 1;
        }
    }
};

/// Per-drain context: applies each event to the Screen and
/// serializes it for broadcast in the same pass.
const EventCollector = struct {
    allocator: std.mem.Allocator,
    screen: *Screen,
    writer: wire.Writer,
    count: u32 = 0,

    fn emit(user: ?*anyopaque, ev: Event) void {
        const self: *EventCollector = @ptrCast(@alignCast(user.?));
        // Kitty file/tempfile/shm transmissions reference THIS
        // host's filesystem — fetch and inline them so the client
        // (which can't read our disk) gets the data. Apply the
        // rewritten event locally too, keeping the authoritative
        // screen identical to what clients see.
        var fwd = ev;
        var owned: ?[]u8 = null;
        defer if (owned) |b| self.allocator.free(b);
        if (ev == .apc) {
            if (@import("kitty_inline.zig").rewrite(self.allocator, ev.apc.bytes)) |nb| {
                owned = nb;
                fwd = .{ .apc = .{ .bytes = nb } };
            }
        }
        self.writer.putEvent(fwd) catch {};
        self.screen.apply(fwd);
        self.count += 1;
        var mut = ev;
        mut.deinit(self.allocator);
    }
};

pub fn defaultSocketPath(allocator: std.mem.Allocator) ![]u8 {
    const rt = @import("../util/platform.zig").runtimeDir();
    return std.fmt.allocPrint(allocator, "{s}/sketerm/mux.sock", .{rt});
}
