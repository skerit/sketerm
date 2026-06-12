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
    /// Wayland app forwarding: the session's shell runs wrapped in a
    /// `waypipe server` that provides $WAYLAND_DISPLAY; each app
    /// connection waypipe makes lands on this hub socket and is
    /// tunneled to an attached client as a byte channel. -1 = no
    /// Wayland support for this session (waypipe absent at spawn).
    wl_hub_fd: c_int = -1,
    /// Owned hub + display socket paths, unlinked on teardown.
    wl_hub_path: ?[]u8 = null,
    wl_display_path: ?[]u8 = null,
    /// Sketerm-native app pipe (SKETERM_MUX_NATIVE_WAYLAND=1): the
    /// daemon IS the Wayland display — wl_hub_fd listens on the
    /// display socket itself, no waypipe wrap, and each app
    /// connection gets parsed + shm-mirrored (Channel.native).
    wl_native: bool = false,

    fn deinit(self: *Session) void {
        if (self.wl_hub_fd >= 0) _ = c.close(self.wl_hub_fd);
        var z_buf: [4096]u8 = undefined;
        if (self.wl_hub_path) |p| {
            if (pathZ(&z_buf, p)) |z| _ = c.unlink(z) else |_| {}
            self.allocator.free(p);
        }
        if (self.wl_display_path) |p| {
            if (pathZ(&z_buf, p)) |z| _ = c.unlink(z) else |_| {}
            self.allocator.free(p);
        }
        self.pty.closeAndReap();
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

/// One tunneled byte stream: an accepted waypipe-server connection
/// on a session's Wayland hub, bridged to `client` as chan_* frames.
const Channel = struct {
    allocator: std.mem.Allocator,
    id: u32,
    fd: c_int,
    session: *Session,
    client: *Client,
    /// Bytes from the client not yet written to fd (partial writes).
    pending: std.ArrayList(u8) = .empty,
    dead: bool = false,
    /// Non-null on a native-pipe channel: the app speaks raw Wayland
    /// to us and the byte stream toward the GUI is wlhost/pipe units.
    native: ?*Native = null,

    fn deinit(self: *Channel) void {
        if (self.native) |nv| nv.deinit();
        _ = c.close(self.fd);
        self.pending.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// Per-channel state of the sketerm-native app pipe (no waypipe:
/// the session's app connects straight to the daemon). Owns the
/// protocol tracker and the mmapped shm pool mirrors.
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
    /// pool id → mmapped mirror. Mirrors outlive wl_shm_pool
    /// destructors: existing buffers keep referencing the memory.
    pools: std.AutoHashMapUnmanaged(u32, PoolMirror) = .empty,

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
        self.inbuf.deinit(self.allocator);
        self.unitbuf.deinit(self.allocator);
        self.tracker.deinit();
        self.allocator.destroy(self);
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
        for (self.clients.items) |cl| {
            var ev: c_short = c.POLLIN;
            if (cl.wbuf.items.len > 0) ev |= c.POLLOUT;
            try fds.append(self.allocator, .{ .fd = cl.fd, .events = ev, .revents = 0 });
        }
        const session_base = fds.items.len;
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
        const chan_base = fds.items.len;
        for (self.channels.items) |ch| {
            var ev: c_short = c.POLLIN;
            if (ch.pending.items.len > 0) ev |= c.POLLOUT;
            try fds.append(self.allocator, .{
                .fd = if (ch.dead) -1 else ch.fd,
                .events = ev,
                .revents = 0,
            });
        }

        const pr = c.poll(fds.items.ptr, @intCast(fds.items.len), timeout_ms);
        if (pr < 0) return; // EINTR etc — next tick retries

        if (fds.items[0].revents & c.POLLIN != 0) self.acceptClient();

        for (self.clients.items, 0..) |cl, i| {
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

        for (self.sessions.items, 0..) |s, i| {
            const re = fds.items[session_base + i].revents;
            if (re & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) self.drainSession(s);
        }

        for (self.sessions.items, 0..) |s, i| {
            if (fds.items[hub_base + i].revents & c.POLLIN != 0) self.acceptWaylandApp(s);
        }

        for (self.channels.items, 0..) |ch, i| {
            const re = fds.items[chan_base + i].revents;
            if (ch.dead) continue;
            if (re & c.POLLIN != 0) self.channelReadable(ch);
            if (!ch.dead and re & c.POLLOUT != 0) self.channelWritable(ch);
            if (!ch.dead and re & (c.POLLHUP | c.POLLERR) != 0 and re & c.POLLIN == 0)
                self.closeChannel(ch, true);
        }

        self.reap();
    }

    fn acceptClient(self: *Daemon) void {
        const fd = c.accept(self.listen_fd, null, null);
        if (fd < 0) return;
        _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
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
        if (n_raw <= 0) {
            cl.dead = true;
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
            cl.dead = true;
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
                ch.pending.appendSlice(ch.allocator, frame.payload[4..]) catch {
                    self.closeChannel(ch, true);
                    return;
                };
                self.channelWritable(ch);
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
            _ = c.close(fd);
            return;
        };

        var native: ?*Native = null;
        if (s.wl_native) {
            native = self.allocator.create(Native) catch {
                _ = c.close(fd);
                return;
            };
            const tracker = wltrack.Tracker.init(self.allocator) catch {
                self.allocator.destroy(native.?);
                _ = c.close(fd);
                return;
            };
            native.?.* = .{ .allocator = self.allocator, .tracker = tracker };
        }

        const ch = self.allocator.create(Channel) catch {
            if (native) |nv| nv.deinit();
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
        const kind: wire.ChannelKind = if (s.wl_native) .wayland_native else .wayland;
        cl.queueFrame(.chan_open, wire.encodeChanOpen(&hdr, ch.id, kind));
    }

    /// Forward hub-socket bytes to the channel's client as
    /// chan_data frames. Bounded rounds keep one chatty app from
    /// starving the loop.
    fn channelReadable(self: *Daemon, ch: *Channel) void {
        if (ch.native != null) return self.nativeReadable(ch);
        var rounds: u8 = 0;
        while (rounds < 4) : (rounds += 1) {
            var buf: [4 + 16384]u8 = undefined;
            const n_raw = c.read(ch.fd, buf[4..].ptr, buf.len - 4);
            if (n_raw < 0) {
                if (std.posix.errno(n_raw) != .AGAIN) self.closeChannel(ch, true);
                return;
            }
            if (n_raw == 0) {
                self.closeChannel(ch, true);
                return;
            }
            const n: usize = @intCast(n_raw);
            std.mem.writeInt(u32, buf[0..4], ch.id, .little);
            ch.client.queueFrame(.chan_data, buf[0 .. 4 + n]);
            if (n < buf.len - 4) return;
        }
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
            .pool_create => |p| {
                const fd = nv.popFd() orelse return error.MissingFd;
                errdefer _ = c.close(fd);
                if (p.size <= 0) return error.BadSize;
                const sz: usize = @intCast(p.size);
                const ptr = c.mmap(null, sz, c.PROT_READ, c.MAP_SHARED, fd, 0);
                if (ptr == null or ptr == c.MAP_FAILED) return error.MapFailed;
                try nv.pools.put(a, p.id, .{ .fd = fd, .ptr = @ptrCast(ptr.?), .size = sz });
                try wlpipe.appendUnit(units, a, .wl_msg, msgb);
                try wlpipe.appendPoolMeta(units, a, .pool_create, p.id, @intCast(sz));
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
                // v1 full copy of the committed buffer's extent;
                // damage-based diffing comes later.
                if (nv.pools.get(cm.info.pool)) |mirror| {
                    if (cm.info.offset >= 0 and cm.info.stride > 0 and cm.info.height > 0) {
                        const off: usize = @intCast(cm.info.offset);
                        const len: usize = @intCast(@as(i64, cm.info.stride) * @as(i64, cm.info.height));
                        const end = @min(off +| len, mirror.size);
                        var chunk = off;
                        while (chunk < end) {
                            const chunk_end = @min(chunk + POOL_CHUNK, end);
                            try wlpipe.appendPoolUpdate(units, a, cm.info.pool, @intCast(chunk), mirror.ptr[chunk..chunk_end]);
                            chunk = chunk_end;
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

    /// Vulkan ICD manifests installed on this host? waypipe needs
    /// Vulkan for GPU-buffer (dmabuf) transfer and aborts app
    /// connections without it — Vulkan-less hosts get --no-gpu.
    fn hasVulkanIcd() bool {
        for ([_][*:0]const u8{ "/usr/share/vulkan/icd.d", "/etc/vulkan/icd.d" }) |dir| {
            const d = c.opendir(dir) orelse continue;
            defer _ = c.closedir(d);
            while (c.readdir(d)) |ent| {
                const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
                if (std.mem.endsWith(u8, name, ".json")) return true;
            }
        }
        return false;
    }

    /// waypipe present on this host? Cached after the first check.
    fn waypipeAvailable() bool {
        const S = struct {
            var checked: bool = false;
            var found: bool = false;
        };
        if (S.checked) return S.found;
        S.checked = true;
        const path_env = std.c.getenv("PATH") orelse return false;
        var it = std.mem.splitScalar(u8, std.mem.span(path_env), ':');
        var buf: [4096]u8 = undefined;
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const full = std.fmt.bufPrintZ(&buf, "{s}/waypipe", .{dir}) catch continue;
            if (c.access(full.ptr, c.X_OK) == 0) {
                S.found = true;
                break;
            }
        }
        return S.found;
    }

    const WaylandHub = struct {
        fd: c_int,
        hub_path: []u8,
        display_path: []u8,
    };

    /// Create a session's Wayland hub socket + display paths next to
    /// the daemon socket. Null on any failure — sessions must spawn
    /// regardless, just without Wayland forwarding. In native mode
    /// there is no waypipe between app and daemon, so the listening
    /// socket IS the display socket (the .hub path goes unused).
    fn setupWaylandHub(self: *Daemon, native: bool) ?WaylandHub {
        const dir_end = std.mem.lastIndexOfScalar(u8, self.sock_path, '/') orelse return null;
        const dir = self.sock_path[0..dir_end];
        const id = self.next_wl_id;
        self.next_wl_id += 1;
        const hub_path = std.fmt.allocPrint(self.allocator, "{s}/wl-{d}.hub", .{ dir, id }) catch return null;
        const display_path = std.fmt.allocPrint(self.allocator, "{s}/wl-{d}", .{ dir, id }) catch {
            self.allocator.free(hub_path);
            return null;
        };
        var ok = false;
        defer if (!ok) {
            self.allocator.free(hub_path);
            self.allocator.free(display_path);
        };

        var z_buf: [4096]u8 = undefined;
        if (pathZ(&z_buf, hub_path)) |z| _ = c.unlink(z) else |_| return null;
        if (pathZ(&z_buf, display_path)) |z| _ = c.unlink(z) else |_| return null;

        const fd = @import("../util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return null;
        var addr: c.struct_sockaddr_un = undefined;
        fillSockaddrUn(&addr, if (native) display_path else hub_path) catch {
            _ = c.close(fd);
            return null;
        };
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0 or c.listen(fd, 8) != 0) {
            _ = c.close(fd);
            return null;
        }
        ok = true;
        return .{ .fd = fd, .hub_path = hub_path, .display_path = display_path };
    }

    fn spawnSession(self: *Daemon, req: SpawnReq) !*Session {
        const allocator = self.allocator;

        // Wayland forwarding: wrap the command in a `waypipe server`
        // that provides $WAYLAND_DISPLAY for everything in the
        // session, connecting each app back to our hub socket. With
        // SKETERM_MUX_NATIVE_WAYLAND=1 (the sketerm-native pipe,
        // maturing — waypipe stays the default until it does) the
        // daemon listens on the display socket itself instead.
        const native_wayland = std.c.getenv("SKETERM_MUX_NATIVE_WAYLAND") != null;
        const want_wayland = std.c.getenv("SKETERM_MUX_NO_WAYLAND") == null and
            req.argv.len > 0 and !std.mem.eql(u8, std.fs.path.basename(req.argv[0]), "waypipe") and
            (native_wayland or waypipeAvailable());
        var hub: ?WaylandHub = if (want_wayland) self.setupWaylandHub(native_wayland) else null;
        errdefer if (hub) |h| {
            _ = c.close(h.fd);
            allocator.free(h.hub_path);
            allocator.free(h.display_path);
        };

        var argv_z: std.ArrayList([:0]u8) = .empty;
        defer {
            for (argv_z.items) |a| allocator.free(a);
            argv_z.deinit(allocator);
        }
        var argv_ptrs: std.ArrayList([*:0]const u8) = .empty;
        defer argv_ptrs.deinit(allocator);
        if (hub != null and !native_wayland) {
            const h = hub.?;
            // Options must precede the mode word (waypipe 0.11 CLI).
            const base = [_][]const u8{ "waypipe", "--socket", h.hub_path, "--display", h.display_path };
            const tail = [_][]const u8{ "server", "--" };
            for (base) |a| {
                const z = try allocator.dupeZ(u8, a);
                try argv_z.append(allocator, z);
                try argv_ptrs.append(allocator, z.ptr);
            }
            if (!hasVulkanIcd()) {
                const z = try allocator.dupeZ(u8, "--no-gpu");
                try argv_z.append(allocator, z);
                try argv_ptrs.append(allocator, z.ptr);
            }
            for (tail) |a| {
                const z = try allocator.dupeZ(u8, a);
                try argv_z.append(allocator, z);
                try argv_ptrs.append(allocator, z.ptr);
            }
        }
        for (req.argv) |a| {
            const z = try allocator.dupeZ(u8, a);
            try argv_z.append(allocator, z);
            try argv_ptrs.append(allocator, z.ptr);
        }

        // Native mode: the daemon is the display, so the daemon must
        // set the child's WAYLAND_DISPLAY (waypipe did it before).
        var wl_disp_z: ?[:0]u8 = null;
        defer if (wl_disp_z) |z| allocator.free(z);
        if (native_wayland) {
            if (hub) |h| wl_disp_z = try allocator.dupeZ(u8, h.display_path);
        }

        var pty = try Pty.spawn(.{
            .argv = argv_ptrs.items,
            .cwd = req.cwd,
            .rows = req.rows,
            .cols = req.cols,
            .wayland_display = if (wl_disp_z) |z| z.ptr else null,
        });
        errdefer pty.closeAndReap();
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
            s.wl_hub_path = h.hub_path;
            s.wl_display_path = h.display_path;
            s.wl_native = native_wayland;
            hub = null; // ownership moved to the session
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
        // Mark only — removeSession runs mid-tick (kill frames), and
        // dropping list entries here would desync the pollfd array
        // built at tick start. reap() removes them at tick end.
        for (self.channels.items) |ch| {
            if (ch.session == s) self.closeChannel(ch, true);
        }
        for (self.sessions.items, 0..) |it, i| {
            if (it == s) {
                _ = self.sessions.swapRemove(i);
                break;
            }
        }
        s.deinit();
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
        // waypipe connections see EOF and fail cleanly.
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
