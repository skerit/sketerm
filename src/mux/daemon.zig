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

pub const Daemon = struct {
    allocator: std.mem.Allocator,
    listen_fd: c_int,
    /// Owned socket path; unlinked on deinit.
    sock_path: []u8,
    sessions: std.ArrayList(*Session) = .empty,
    clients: std.ArrayList(*Client) = .empty,
    channels: std.ArrayList(*Channel) = .empty,
    next_chan_id: u32 = 1,
    /// Monotonic id for per-session Wayland socket paths (session
    /// names are user input — not path-safe).
    next_wl_id: u32 = 1,
    /// Monotonic id for isolated sessions' private runtime dirs (same
    /// path-safety reason as next_wl_id).
    next_rt_id: u32 = 1,
    running: bool = true,

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
        for (self.channels.items) |ch| ch.deinit();
        self.channels.deinit(self.allocator);
        for (self.clients.items) |cl| cl.deinit();
        self.clients.deinit(self.allocator);
        for (self.sessions.items) |s| s.deinit();
        self.sessions.deinit(self.allocator);
        _ = c.close(self.listen_fd);
        var z_buf: [4096]u8 = undefined;
        if (pathZ(&z_buf, self.sock_path)) |p| {
            _ = c.unlink(p);
        } else |_| {}
        self.allocator.free(self.sock_path);
        self.allocator.destroy(self);
    }

    /// Run until a SHUTDOWN frame arrives or `running` is cleared.
    pub fn run(self: *Daemon) !void {
        while (self.running) try self.tick(500);
    }

    /// One poll iteration. Exposed for tests.
    pub fn tick(self: *Daemon, timeout_ms: i32) !void {
        var fds: std.ArrayList(c.struct_pollfd) = .empty;
        defer fds.deinit(self.allocator);

        try fds.append(self.allocator, .{ .fd = self.listen_fd, .events = c.POLLIN, .revents = 0 });
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

        const pr = c.poll(fds.items.ptr, @intCast(fds.items.len), timeout_ms);
        if (pr < 0) return; // EINTR etc — next tick retries

        if (fds.items[0].revents & c.POLLIN != 0) self.acceptClient();

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

        self.pumpWinstreams();
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
                const HelloReq = struct { proto: u32 = 1 };
                if (std.json.parseFromSlice(HelloReq, self.allocator, frame.payload, .{
                    .ignore_unknown_fields = true,
                })) |p| {
                    cl.proto = p.value.proto;
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
                cl.queueJson(.ok, .{ .ok = true });
                self.running = false;
            },
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

                    var mbuf: [256]u8 = undefined;
                    var b = wlwire.Builder.init(&mbuf, source, 1); // send
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

    const WaylandHub = struct {
        fd: c_int,
        display_path: []u8,
    };

    /// Create a session's Wayland display socket next to the daemon
    /// socket and listen on it — the daemon IS the display, so the
    /// listening socket is the one the shell's $WAYLAND_DISPLAY points
    /// at. Null on any failure (the session still spawns, just without
    /// Wayland forwarding).
    fn setupWaylandHub(self: *Daemon) ?WaylandHub {
        const dir_end = std.mem.lastIndexOfScalar(u8, self.sock_path, '/') orelse return null;
        const dir = self.sock_path[0..dir_end];
        const id = self.next_wl_id;
        self.next_wl_id += 1;
        const display_path = std.fmt.allocPrint(self.allocator, "{s}/wl-{d}", .{ dir, id }) catch return null;
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

        const want_wayland = !ws_gate.want and hosts_apps;
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
        if (hub) |h| wl_disp_z = try allocator.dupeZ(u8, h.display_path);

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
            const dir_end = std.mem.lastIndexOfScalar(u8, self.sock_path, '/') orelse 0;
            const dir = self.sock_path[0..dir_end];
            const id = self.next_rt_id;
            self.next_rt_id += 1;
            const p = try std.fmt.allocPrint(allocator, "{s}/rt-{d}", .{ dir, id });
            rt_dir_owned = p;
            var z_buf: [4096]u8 = undefined;
            _ = c.mkdir(try pathZ(&z_buf, p), 0o700);
            rt_dir_z = try allocator.dupeZ(u8, p);
        }

        var pty = try Pty.spawn(.{
            .argv = argv_ptrs.items,
            .cwd = req.cwd,
            .rows = req.rows,
            .cols = req.cols,
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
        // client) must be replayed for this one.
        if (s.winstream) |ws| ws.reannounce();
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
        var seq_hdr: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq_hdr, s.seq, .little);
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
        var infos: std.ArrayList(SessionInfo) = .empty;
        defer infos.deinit(self.allocator);
        for (self.sessions.items) |s| {
            var n_clients: u32 = 0;
            for (self.clients.items) |c2| {
                if (c2.attached == s) n_clients += 1;
            }
            infos.append(self.allocator, .{
                .name = s.name,
                .rows = s.screen.rows,
                .cols = s.screen.cols,
                .clients = n_clients,
                .exited = s.exited,
                .title = if (s.screen.last_title) |t| t else "",
                .app = s.app,
            }) catch return;
        }
        cl.queueJson(.welcome, .{ .proto = wire.PROTO_VERSION, .sessions = infos.items });
    }

    fn handleKill(self: *Daemon, cl: *Client, payload: []const u8) void {
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
