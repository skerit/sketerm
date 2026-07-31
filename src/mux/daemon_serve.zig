//! Client serving — the broker <-> worker control channel (process
//! isolation), per-client frame dispatch, file transfers, and the fs
//! op server — split out of daemon.zig (this is the file's own
//! "broker" section: everything between the broker banner and the fs
//! jobs banner). Functions take the owning *Daemon and are aliased
//! back into Daemon.

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("log.zig");
const wire = @import("wire.zig");
const platform = @import("../util/platform.zig");
const fsserve = @import("fsserve.zig");
const snapshot = @import("snapshot.zig");
const dmod = @import("daemon.zig");
const Daemon = dmod.Daemon;
const Client = dmod.Client;
const Worker = dmod.Worker;
const Session = dmod.Session;
const Channel = dmod.Channel;
const Upload = dmod.Upload;
const Download = dmod.Download;
const FsView = dmod.FsView;
const SpawnReq = dmod.SpawnReq;
const AttachReq = dmod.AttachReq;
const WorkerReady = dmod.WorkerReady;
const WorkerMeta = dmod.WorkerMeta;
const WorkerPush = dmod.WorkerPush;
const nowMs = dmod.nowMs;
const cwdOfPid = dmod.cwdOfPid;
const pathZ = @import("../util/pathz.zig").pathZ;
const version = @import("../version.zig");
const cast_rec = @import("cast.zig");
const opuscodec = @import("opuscodec.zig");
const build_options = @import("build_options");
const wsproto = @import("../winstream/proto.zig");
const wallMs = dmod.wallMs;

// ── broker ↔ worker control channel (process isolation) ─────────
//
// A worker process owns one session and receives its clients as fds
// passed by the broker over a SOCK_SEQPACKET control socketpair. Each
// control message is one datagram: [opcode][payload], with at most one
// fd in SCM_RIGHTS. Opcodes: 'A' attach (payload
// [proto][video][kind][native_state_max][snapshot][audio][winstream]
// + the client fd),
// 'K' kill. (list/rename/metadata join in B3.)

/// Worker side: drain one control datagram and act on it.
pub fn workerOnControl(self: *Daemon) void {
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
            // Byte 3 (newer brokers): the client's attach kind.
            // Without it an MCP client reads as .unknown in the
            // worker and the whole per-kind native backlog policy
            // (gap + live-mirror resync) silently never engages —
            // the stale-screenshot bug in broker (= `sketerm mcp`
            // isolation) mode while monolith tested clean.
            const kind: Client.Kind = if (n >= 4)
                std.enums.fromInt(Client.Kind, buf[3]) orelse .unknown
            else
                .unknown;
            const native_state_max: u8 = if (n >= 5)
                buf[4]
            else if (proto >= wire.NATIVE_STATE_PROTO_VERSION)
                wire.NATIVE_STATE_VERSION
            else if (proto >= 5)
                wire.LEGACY_NATIVE_STATE_VERSION
            else
                0;
            const snapshot_version: u8 = if (n >= 6)
                buf[5]
            else if (proto >= 6)
                snapshot.SNAPSHOT_VERSION
            else
                snapshot.LEGACY_SNAPSHOT_VERSION;
            const audio_channels = if (n >= 7) buf[6] != 0 else proto >= 5;
            const winstream_channels = if (n >= 8) buf[7] != 0 else proto >= wire.WINSTREAM_PROTO_VERSION;
            // Bytes 8/9 (controller lease): absent = the historical
            // "every viewer drives" request, i.e. take a free lease
            // and never force a takeover.
            const read_only = n >= 9 and buf[8] != 0;
            const want_control = n >= 10 and buf[9] != 0;
            addPassedClient(self, passed, .{
                .proto = proto,
                .video = video,
                .kind = kind,
                .native_state_max = native_state_max,
                .snapshot_version = snapshot_version,
                .audio_channels = audio_channels,
                .winstream_channels = winstream_channels,
                .read_only = read_only,
                .want_control = want_control,
            });
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

/// Decoded 'A' worker-handoff datagram. A struct rather than a
/// parameter list because every new attach-time client property has
/// to travel here — the broker-mode gotcha is that a field left out
/// of this hop makes the worker see a DEFAULT and the whole feature
/// silently never engage (monolith smokes stay green).
pub const PassedClient = struct {
    proto: u32,
    video: bool,
    kind: Client.Kind,
    native_state_max: u8,
    snapshot_version: u8,
    audio_channels: bool,
    winstream_channels: bool,
    read_only: bool = false,
    want_control: bool = false,
};

/// Worker side: adopt a broker-passed client fd as a client attached to
/// our one session, and send it the attach snapshot.
pub fn addPassedClient(self: *Daemon, fd: c_int, req: PassedClient) void {
    _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
    const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
    const cl = self.allocator.create(Client) catch {
        _ = c.close(fd);
        return;
    };
    cl.* = .{
        .allocator = self.allocator,
        .fd = fd,
        .id = self.next_client_id,
        .proto = req.proto,
        .snapshot_version = req.snapshot_version,
        .native_state_max = req.native_state_max,
        .audio_channels = req.audio_channels,
        .winstream_channels = req.winstream_channels,
        .video = req.video,
        .kind = req.kind,
        .read_only = req.read_only,
    };
    self.next_client_id += 1;
    self.clients.append(self.allocator, cl) catch {
        cl.deinit();
        return;
    };
    if (self.sessions.items.len == 0) return;
    const s = self.sessions.items[0];
    cl.attached = s;
    log.info("client attached session='{s}' kind={s} proto={d} video={} (worker handoff)", .{ s.name, @tagName(req.kind), req.proto, req.video });
    self.queueSnapshot(cl, s);
    if (req.winstream_channels and s.winstream != null) self.openWinstreamChan(s, cl);
    if (req.native_state_max >= wire.LEGACY_NATIVE_STATE_VERSION or req.audio_channels) self.replayNativeChannels(cl, s);
    self.refreshVideoGates();
    _ = self.acquireControl(s, cl, req.want_control);
    self.broadcastControlState(s);
    self.broadcastPeerInfo(s);
}

/// Broker side: read one control datagram from a worker. 'Y' = ready
/// (resolve the deferred spawn `.ok`), 'M' = metadata push; n<=0 means the
/// worker exited (before 'Y' = spawn failed → resolve spawn `.err`).
/// The buffer comfortably exceeds the worst-case 'M' JSON (a 256-byte
/// title + 1024-byte cwd, each up to ~6x under \uXXXX escaping).
pub fn brokerOnWorkerControl(self: *Daemon, w: *Worker) void {
    var buf: [16384]u8 = undefined;
    var passed: c_int = -1;
    const n = controlRecv(w.control_fd, &buf, &passed);
    if (passed >= 0) _ = c.close(passed); // workers never pass fds up
    if (n <= 0) {
        if (!w.ready) replyPendingSpawn(self, w, false); // died before ready
        w.dead = true;
        return;
    }
    switch (buf[0]) {
        'Y' => {
            w.ready = true;
            if (n > 1) applyWorkerReady(self, w, buf[1..@intCast(n)]);
            replyPendingSpawn(self, w, true);
        },
        'E' => {
            // Spawn-failure reason; the control EOF that follows
            // triggers the actual `.err` reply.
            if (self.allocator.dupe(u8, buf[1..@intCast(n)])) |e| {
                if (w.spawn_err) |old| self.allocator.free(old);
                w.spawn_err = e;
            } else |_| {}
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
            if (m.child_pid != 0) w.child_pid = m.child_pid;
            w.display = m.display;
            w.ttl_secs = m.ttl_secs;
            w.viewers = m.viewers;
            w.audio = m.audio;
            if (self.allocator.dupe(u8, m.title)) |t| {
                if (w.title) |old| self.allocator.free(old);
                w.title = t;
            } else |_| {}
            if (self.allocator.dupe(u8, m.cwd)) |cw| {
                if (w.cwd) |old| self.allocator.free(old);
                w.cwd = cw;
            } else |_| {}
            // A dropped lease must clear the cached label, so this
            // one assigns even for "" (unlike setOwned's keep-old).
            if (self.allocator.dupe(u8, m.controller)) |ctrl| {
                if (w.controller) |old| self.allocator.free(old);
                w.controller = if (ctrl.len > 0) ctrl else blk: {
                    self.allocator.free(ctrl);
                    break :blk null;
                };
            } else |_| {}
            w.setOwned(&w.wl_display, m.wl);
            w.setOwned(&w.pulse_server, m.pa);
            w.setOwned(&w.runtime_dir, m.rt);
        },
        else => {},
    }
}

/// Adopt a worker's 'Y' ready payload. Parsed DEFENSIVELY: the JSON
/// form is current, a bare decimal pid is what pre-JSON workers
/// sent, and anything else leaves the record untouched (a spawn
/// still succeeds — only the returned paths would be missing).
pub fn applyWorkerReady(self: *Daemon, w: *Worker, payload: []const u8) void {
    if (payload.len > 0 and payload[0] == '{') {
        var parsed = std.json.parseFromSlice(WorkerReady, self.allocator, payload, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return;
        defer parsed.deinit();
        w.child_pid = parsed.value.pid;
        w.setOwned(&w.wl_display, parsed.value.wl);
        w.setOwned(&w.pulse_server, parsed.value.pa);
        w.setOwned(&w.runtime_dir, parsed.value.rt);
        return;
    }
    w.child_pid = std.fmt.parseInt(i32, payload, 10) catch 0;
}

/// Resolve a worker's deferred spawn reply. `ok` = session up (`.ok`),
/// else spawn failed (`.err`). Validates the waiting client is still a live
/// connection (the GUI could have vanished while the worker came up).
pub fn replyPendingSpawn(self: *Daemon, w: *Worker, ok: bool) void {
    const cl = w.pending_client orelse return;
    w.pending_client = null;
    for (self.clients.items) |c2| {
        if (c2 == cl and !c2.dead) {
            if (ok) {
                c2.queueJson(.ok, .{
                    .ok = true,
                    .name = w.name,
                    .pid = w.child_pid,
                    .wl_display = if (w.wl_display) |p| p else "",
                    .pulse_server = if (w.pulse_server) |p| p else "",
                    .runtime_dir = if (w.runtime_dir) |p| p else "",
                });
            } else if (w.spawn_err) |reason| {
                var ebuf: [192]u8 = undefined;
                const msg = std.fmt.bufPrint(&ebuf, "spawn failed: {s}", .{reason}) catch "spawn failed";
                c2.queueErr(msg);
            } else {
                c2.queueErr("spawn failed (worker died during session setup)");
            }
            return;
        }
    }
}

/// Worker side: push current session metadata to the broker if it changed
/// since the last push. Structural changes go immediately; activity-only
/// advances are rate-limited to ~5/s.
pub fn maybePushMeta(self: *Daemon) void {
    if (self.sessions.items.len == 0) return;
    const s = self.sessions.items[0];
    var n_clients: u32 = 0;
    for (self.clients.items) |cl| {
        if (!cl.dead) n_clients += 1;
    }
    const title: []const u8 = if (s.screen.last_title) |t| t else "";
    const th = std.hash.Wyhash.hash(0, title);
    var ctrl_buf: [32]u8 = undefined;
    const controller = self.controllerLabel(s, &ctrl_buf);
    const ch = std.hash.Wyhash.hash(0, controller);
    const audio = self.sessionAudioRunning(s, null);
    const structural = !self.wpush.inited or
        n_clients != self.wpush.clients or
        s.exited != self.wpush.exited or
        s.screen.rows != self.wpush.rows or
        s.screen.cols != self.wpush.cols or
        th != self.wpush.title_hash or
        ch != self.wpush.controller_hash or
        audio != self.wpush.audio;
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
        .child_pid = s.pty.child_pid,
        // Bounded so one JSON datagram stays well under the broker's
        // recv buffer (a SOCK_SEQPACKET over-long datagram is truncated).
        .title = title[0..@min(title.len, 256)],
        .cwd = cwd[0..@min(cwd.len, 1024)],
        .display = s.display,
        .ttl_secs = @intCast(@divTrunc(s.ttl_ms, 1000)),
        .viewers = n_clients,
        .controller = controller,
        .audio = audio,
        .wl = if (s.wl_display_path) |p| p else "",
        .pa = if (s.pa_socket_path) |p| p else "",
        .rt = if (s.runtime_dir_path) |p| p else "",
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
        .controller_hash = ch,
        .activity = s.last_activity_ms,
        .audio = audio,
        .last_push_ms = now,
    };
}

/// recvmsg one control datagram: data into `buf`, the first SCM_RIGHTS fd
/// (or -1) into `fd_out`. Returns datagram length (0 = peer closed).
pub fn controlRecv(fd: c_int, buf: []u8, fd_out: *c_int) isize {
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
        const hdr: *const c.struct_cmsghdr = @ptrCast(@alignCast(&cbuf));
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
pub fn controlSend(fd: c_int, bytes: []const u8, pass_fd: c_int) void {
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
pub fn initWorker(allocator: std.mem.Allocator, control_fd: c_int, base_dir: []const u8, broker_sock: []const u8) !*Daemon {
    const self = try allocator.create(Daemon);
    self.* = .{
        .allocator = allocator,
        .listen_fd = -1,
        .sock_path = try allocator.dupe(u8, ""),
        .control_fd = control_fd,
        .base_dir = if (base_dir.len > 0) try allocator.dupe(u8, base_dir) else null,
        .broker_sock = if (broker_sock.len > 0) try allocator.dupe(u8, broker_sock) else null,
    };
    return self;
}

/// Worker process entry: own one session (from `req`), serve clients the
/// broker hands over `control_fd`, until killed or the broker goes away.
pub fn runWorker(allocator: std.mem.Allocator, control_fd: c_int, req: SpawnReq, base_dir: []const u8, broker_sock: []const u8) !void {
    const self = try initWorker(allocator, control_fd, base_dir, broker_sock);
    defer self.deinit();
    // If spawnSession fails, report WHY over the control channel ('E' +
    // error name) before dying — the broker folds it into the deferred
    // spawn `.err` so the client sees the reason, not a generic "spawn
    // failed". Then the caller `_exit`s → control EOF → `.err` sent.
    // On success, signal 'Y' (ready) so the broker sends the spawn
    // `.ok` only once the session truly exists.
    const s = self.spawnSession(req) catch |err| {
        var ebuf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&ebuf, "E{s}", .{@errorName(err)}) catch "E?";
        controlSend(control_fd, msg, -1);
        return err;
    };
    try self.sessions.append(allocator, s);
    // 'Y' carries the session's child pid (a debugger-attachable
    // handle) AND the hub paths it just created — the broker owns
    // neither, and the spawn `.ok` must return them so an external
    // renderer never has to guess a wl-w<pid> path.
    var yaw: std.Io.Writer.Allocating = .init(allocator);
    defer yaw.deinit();
    if (yaw.writer.writeByte('Y')) |_| {
        if (std.json.Stringify.value(WorkerReady{
            .pid = s.pty.child_pid,
            .wl = if (s.wl_display_path) |p| p else "",
            .pa = if (s.pa_socket_path) |p| p else "",
            .rt = if (s.runtime_dir_path) |p| p else "",
        }, .{}, &yaw.writer)) |_| {
            controlSend(control_fd, yaw.written(), -1);
        } else |_| controlSend(control_fd, "Y", -1);
    } else |_| controlSend(control_fd, "Y", -1);
    try self.run();
}

pub fn clientReadable(self: *Daemon, cl: *Client) void {
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
        handleFrame(self, cl, peeled.frame);
        // Drop consumed bytes (front removal; frames are small
        // except INPUT pastes, and rbuf shrinks right back).
        const remaining = cl.rbuf.items.len - peeled.consumed;
        std.mem.copyForwards(u8, cl.rbuf.items[0..remaining], cl.rbuf.items[peeled.consumed..]);
        cl.rbuf.shrinkRetainingCapacity(remaining);
        if (cl.dead) return;
    }
    // Don't let one big INPUT paste pin its high-water capacity.
    if (cl.rbuf.items.len == 0 and cl.rbuf.capacity > (4 << 20))
        cl.rbuf.clearAndFree(cl.allocator);
}

pub fn clientWritable(self: *Daemon, cl: *Client) void {
    // Ordinary frames keep FIFO order, but at every wire-frame boundary
    // pending PCM gets the next slot instead of waiting behind megabytes
    // of surface updates.
    if (!cl.startNextWriteFrame()) return;

    const out = if (cl.write_lane == .audio) &cl.audio_wbuf else &cl.wbuf;
    const amount = @min(out.items.len, cl.write_frame_left);
    const n_raw = c.write(cl.fd, out.items.ptr, amount);
    if (n_raw < 0) {
        // fd is O_NONBLOCK: EAGAIN means the send buffer is full;
        // keep the active frame and retry on the next POLLOUT.
        if (std.posix.errno(n_raw) != .AGAIN) cl.dead = true;
        return;
    }
    const n: usize = @intCast(n_raw);
    const remaining = out.items.len - n;
    std.mem.copyForwards(u8, out.items[0..remaining], out.items[n..]);
    out.shrinkRetainingCapacity(remaining);
    cl.write_frame_left -= n;
    if (cl.write_frame_left == 0) cl.write_lane = .none;
    // A snapshot/replay burst can leave a many-MB high-water
    // capacity pinned forever; release it once fully drained.
    if (remaining == 0 and out.capacity > (4 << 20))
        out.clearAndFree(cl.allocator);
    // Events were withheld while this client was backlogged; it has
    // caught up, so hand it a fresh snapshot (stamped with the
    // current seq) and resume streaming. Sent even for an exited
    // session — the final screen is exactly what a crash-flood
    // post-mortem needs.
    const fully_drained = cl.queuedBytes() == 0 and cl.write_lane == .none;
    if (fully_drained and cl.needs_resync) {
        cl.needs_resync = false;
        if (cl.attached) |s| {
            log.debug("resync snapshot toward drained client (session '{s}')", .{s.name});
            self.queueSnapshot(cl, s);
        }
    }
    // App frames were withheld (native_gap); the client has caught
    // up — rebuild its replicas from the LIVE mirrors and close
    // the replay with native_sync so its capture paths know the
    // stream is current again.
    if (fully_drained and cl.needs_native_resync) {
        cl.needs_native_resync = false;
        if (cl.attached) |s| {
            log.debug("native resync toward drained mcp client (session '{s}')", .{s.name});
            // A rebuilt replica has no video reference frames.
            for (self.channels.items) |ch| {
                if (ch.session != s) continue;
                if (ch.native) |nv| {
                    var vit = nv.vstate.valueIterator();
                    while (vit.next()) |v| v.needs_kf = true;
                }
            }
            self.replayNativeChannels(cl, s);
        }
        if (!cl.dead) cl.queueFrame(.native_sync, "");
    }
}

pub fn handleFrame(self: *Daemon, cl: *Client, frame: wire.Frame) void {
    if (cl.proto == 0 and frame.ftype != .hello and frame.ftype != .list) {
        cl.queueErr("no shared terminal profile; daemon and sessions preserved");
        return;
    }
    switch (frame.ftype) {
        .hello => {
            const HelloReq = struct {
                proto: u32 = 1,
                min_proto: u32 = 1,
                negotiation: u8 = 0,
                snapshot_max: u8 = 0,
                native_state_max: u8 = 0,
                audio: bool = false,
                winstream: bool = false,
                video: bool = false,
            };
            if (std.json.parseFromSlice(HelloReq, self.allocator, frame.payload, .{
                .ignore_unknown_fields = true,
            })) |p| {
                const negotiated = p.value.negotiation > 0;
                cl.proto = if (negotiated)
                    wire.negotiateProtocol(p.value.min_proto, p.value.proto)
                else if (p.value.proto >= wire.MIN_SERVER_PROTO and p.value.proto <= wire.PROTO_VERSION)
                    p.value.proto
                else
                    0;
                cl.snapshot_version = snapshot.negotiateVersion(cl.proto, p.value.snapshot_max, negotiated);
                cl.native_state_max = if (cl.proto == 0)
                    0
                else if (negotiated)
                    @min(p.value.native_state_max, wire.NATIVE_STATE_VERSION)
                else if (cl.proto >= wire.NATIVE_STATE_PROTO_VERSION)
                    wire.NATIVE_STATE_VERSION
                else if (cl.proto >= 5)
                    wire.LEGACY_NATIVE_STATE_VERSION
                else
                    0;
                cl.audio_channels = cl.proto != 0 and if (negotiated) p.value.audio else cl.proto >= 5;
                cl.winstream_channels = cl.proto != 0 and if (negotiated) p.value.winstream else cl.proto >= wire.WINSTREAM_PROTO_VERSION;
                cl.video = p.value.video;
                p.deinit();
            } else |_| {}
            cl.queueJson(.welcome, .{
                .proto = cl.proto,
                .server_proto = wire.PROTO_VERSION,
                .min_proto = wire.MIN_SERVER_PROTO,
                .negotiation = @as(u8, 1),
                .snapshot = cl.snapshot_version,
                .native_state = cl.native_state_max,
                .audio = cl.audio_channels,
                .winstream = cl.winstream_channels,
                .version = version.string,
                .audio_opus = opuscodec.available(),
                .video = build_options.video,
                // Capability, not a proto bump: clients must not send
                // udp_ticket_req to daemons that would answer `.err`
                // (misattributable on a multiplexed GUI connection).
                .udp_ticket = true,
            });
        },
        .spawn => self.handleSpawn(cl, frame.payload),
        .attach => self.handleAttach(cl, frame.payload),
        .detach => {
            const was = cl.attached;
            cl.attached = null;
            cl.queueJson(.ok, .{ .ok = true });
            if (was) |s| {
                // Detach BEFORE the release so the handover scan
                // cannot pick this client again.
                if (self.releaseControl(s, cl)) self.broadcastControlState(s);
                self.broadcastPeerInfo(s);
            }
        },
        .control_req => self.handleControlReq(cl, frame.payload),
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
            if (s.cast) |*rec| rec.resize(nowMs(), cols, rows);
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
        .udp_ticket_req => handleUdpTicketReq(self, cl, frame.payload),
        .fs_op => handleFsOp(self, cl, frame.payload),
        .fs_write => handleFsWrite(self, cl, frame.payload),
        .file_open => handleFileOpen(self, cl, frame.payload),
        .file_data => handleFileData(self, cl, frame.payload),
        .file_close => handleFileClose(self, cl, frame.payload),
        .file_get => handleFileGet(self, cl, frame.payload),
        .file_list => handleFileList(self, cl, frame.payload),
        .app_list => handleAppList(self, cl),
        .app_a11y => handleAppA11y(self, cl, frame.payload),
        .rec_start => handleRecStart(self, cl, frame.payload),
        .search => self.handleSearch(cl, frame.payload),
        .log_get => self.handleLogGet(cl, frame.payload),
        .forward_open => self.handleForward(cl, frame.payload),
        .rec_stop => {
            const s = cl.attached orelse {
                cl.queueErr("not attached");
                return;
            };
            if (s.cast) |*rec| {
                rec.finish();
                s.cast = null;
                cl.queueJson(.ok, .{ .ok = true });
            } else cl.queueErr("session is not recording");
        },
        .chan_data => {
            const id = wire.decodeChanId(frame.payload) orelse return;
            const ch = findChannel(self, id) orelse return;
            if (ch.dead) return;
            if (ch.native != null) {
                if (!dmod.Daemon.nativeViewer(cl, ch.session.?)) return;
                // Input-shaped units are gated on the controller
                // lease INSIDE nativeClientData (data-transfer
                // replies must keep flowing for every viewer).
                return self.nativeClientData(cl, ch, frame.payload[4..]);
            }
            if (ch.pa != null) {
                if (!dmod.Daemon.audioViewer(cl, ch.session.?)) return;
                return self.paClientData(cl, ch, frame.payload[4..]);
            }
            if (ch.client != cl) return;
            if (ch.tcp) {
                // Raw bytes toward the forward target; the
                // writable path drains `pending` (EAGAIN-safe).
                ch.pending.appendSlice(self.allocator, frame.payload[4..]) catch {
                    self.closeChannel(ch, true);
                    return;
                };
                self.channelWritable(ch);
                return;
            }
            const chs = ch.session orelse return;
            if (chs.winstream) |ws| {
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
            const ch = findChannel(self, id) orelse return;
            // A viewer dropping its side of a NATIVE (or audio)
            // channel is just that viewer going away — the app is
            // durable and keeps running for everyone else (and
            // for a later reattach). Only winstream dies with its
            // client.
            if (ch.native != null or ch.pa != null) return;
            if (ch.client != cl) return;
            ch.dead = true;
        },
        else => cl.queueErr("unknown frame type"),
    }
}

pub fn findChannel(self: *Daemon, id: u32) ?*Channel {
    for (self.channels.items) |ch| {
        if (ch.id == id) return ch;
    }
    return null;
}

// === UDP connection tickets ================================

/// "lo:hi", digits only — same shape --udp-port accepts.
fn validTicketRange(value: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, value, ':') orelse return false;
    if (colon == 0 or colon + 1 == value.len) return false;
    if (std.mem.indexOfScalarPos(u8, value, colon + 1, ':') != null) return false;
    for (value[0..colon]) |byte| if (byte < '0' or byte > '9') return false;
    for (value[colon + 1 ..]) |byte| if (byte < '0' or byte > '9') return false;
    return true;
}

fn udpTicketErr(cl: *Client, msg: []const u8) void {
    cl.queueJson(.udp_ticket, .{ .ok = false, .@"error" = msg });
}

/// Answer `udp_ticket_req`: spawn a single-use sibling UDP listener on
/// THIS host and hand its port+key back, so a new client that already
/// reaches this daemon over an authenticated channel can connect over
/// UDP with no ssh bootstrap of its own (connection-ticket brokering).
///
/// The listener is the unchanged `--udp-listen` path (mosh-server
/// model, one instance per connection), aimed back at THIS instance
/// via `--socket`; it retires itself when nobody authenticates within
/// its 60s grace, so an unclaimed ticket is never a leak. No NAT hole
/// punch rides this path — a host whose announced port is unreachable
/// costs the requester a bounded timeout and the ssh-bootstrap
/// fallback, exactly the status quo.
///
/// The announce read is synchronous but bounded: the child only
/// binds INADDR_ANY and prints (no network, no disk), so the line
/// normally lands in single-digit milliseconds — same class of
/// bounded fork work as handleSpawn. A wedged child costs one
/// deadline'd error, never a stalled poll loop.
pub fn handleUdpTicketReq(self: *Daemon, cl: *Client, payload: []const u8) void {
    const rudp = @import("rudp.zig");
    const punch = @import("punch.zig");

    var range_buf: [32:0]u8 = undefined;
    var range: ?[:0]const u8 = null;
    if (payload.len > 0) {
        const Req = struct { range: ?[]const u8 = null };
        if (std.json.parseFromSlice(Req, self.allocator, payload, .{ .ignore_unknown_fields = true })) |p| {
            defer p.deinit();
            if (p.value.range) |r| {
                if (!validTicketRange(r)) return udpTicketErr(cl, "bad port range");
                range = std.fmt.bufPrintZ(&range_buf, "{s}", .{r}) catch return udpTicketErr(cl, "bad port range");
            }
        } else |_| return udpTicketErr(cl, "bad request");
    }

    // Workers keep `sock_path` empty (deinit must not unlink the
    // broker's socket); the broker's full path travels separately.
    const sock = if (self.sock_path.len > 0) self.sock_path else self.broker_sock orelse
        return udpTicketErr(cl, "daemon socket path unknown");
    var sock_z_buf: [4096:0]u8 = undefined;
    const sock_z = std.fmt.bufPrintZ(&sock_z_buf, "{s}", .{sock}) catch
        return udpTicketErr(cl, "socket path too long");

    // The listener must be a binary that answers --udp-listen: the
    // test rigs host a Daemon in a smoke binary, so SKETERM_MUX_BIN
    // wins over /proc/self/exe, same rule as findMuxBinary.
    var bin_buf: [4096:0]u8 = undefined;
    const bin: [*:0]const u8 = if (c.getenv("SKETERM_MUX_BIN")) |b|
        b
    else if (platform.selfExecPathZ(&bin_buf)) |_|
        @ptrCast(&bin_buf)
    else
        return udpTicketErr(cl, "cannot locate sketerm-mux binary");

    var pipe_fds: [2]c_int = undefined;
    if (c.pipe(&pipe_fds) != 0) return udpTicketErr(cl, "pipe failed");
    // Park the pipe above the stdio range: a daemonized parent can
    // have fds 0-2 closed, and the child's stdio rewiring below must
    // not clobber its own pipe end.
    for (&pipe_fds) |*fd| {
        _ = c.fcntl(fd.*, c.F_SETFD, c.FD_CLOEXEC);
        if (fd.* < 3) {
            const moved = c.fcntl(fd.*, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
            _ = c.close(fd.*);
            if (moved < 0) {
                fd.* = -1;
            } else fd.* = moved;
        }
    }
    if (pipe_fds[0] < 0 or pipe_fds[1] < 0) {
        for (pipe_fds) |fd| if (fd >= 0) {
            _ = c.close(fd);
        };
        return udpTicketErr(cl, "pipe failed");
    }

    // Double fork so init reaps the listener; we waitpid only the
    // short-lived middle child.
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        return udpTicketErr(cl, "fork failed");
    }
    if (pid == 0) {
        if (c.fork() == 0) {
            _ = c.setsid();
            _ = c.dup2(pipe_fds[1], 1);
            // Full stdio for the exec'd listener: /dev/null stdin (no
            // punch line will ever arrive — instant EOF) AND stderr
            // (a detached daemon has no fd 2; leaving it unoccupied
            // would seat the listener's own sockets in the stdio
            // range its detach path closes).
            const devnull = c.open("/dev/null", c.O_RDWR);
            if (devnull >= 0) {
                if (devnull != 0) _ = c.dup2(devnull, 0);
                if (devnull != 2) _ = c.dup2(devnull, 2);
                if (devnull > 2) _ = c.close(devnull);
            }
            _ = c.close(pipe_fds[0]);
            _ = c.close(pipe_fds[1]);
            var argv: [8:null]?[*:0]const u8 = .{null} ** 8;
            var n: usize = 0;
            argv[n] = bin;
            argv[n + 1] = "--udp-listen";
            n += 2;
            if (range) |r| {
                argv[n] = "--udp-port";
                argv[n + 1] = r.ptr;
                n += 2;
            }
            argv[n] = "--socket";
            argv[n + 1] = sock_z.ptr;
            _ = c.execvp(bin, @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        c._exit(0);
    }
    _ = c.close(pipe_fds[1]);
    var st: c_int = 0;
    _ = c.waitpid(pid, &st, 0);

    var line_buf: [256]u8 = undefined;
    const line = punch.readLine(pipe_fds[0], 3_000, &line_buf);
    _ = c.close(pipe_fds[0]);
    const ann = rudp.parseAnnounce(line orelse "") orelse {
        log.warn("udp ticket: listener failed to announce", .{});
        return udpTicketErr(cl, "udp listener failed to announce");
    };
    log.info("udp ticket minted: port {d}", .{ann.port});
    cl.queueJson(.udp_ticket, .{ .ok = true, .port = ann.port, .key = ann.keyhex });
}

// === File upload (file_* frames) ===========================
// The GUI streams a local file to the daemon, which writes it into
// the session shell's working directory — so "drag a file onto a
// remote pane" lands it on the remote box, over any transport.

/// Most concurrent uploads a single client may have open. Bounds
/// the open-fd + partial-file footprint of a misbehaving client.
const max_uploads_per_client = 8;

pub fn findUpload(self: *Daemon, cl: *Client, xfer: u32) ?*Upload {
    for (self.uploads.items) |u| {
        if (u.client == cl and u.xfer == xfer) return u;
    }
    return null;
}

pub fn fileReply(cl: *Client, xfer: u32, status: []const u8, written: u64, path: []const u8, message: []const u8) void {
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
pub fn dropUpload(self: *Daemon, up: *Upload, unlink_partial: bool) void {
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
pub fn uploadBaseName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| return name[slash + 1 ..];
    return name;
}

/// Open a fresh file named `base` in `cwd`, never clobbering an
/// existing one: on a name collision, insert " (N)" before the
/// extension ("notes.txt" → "notes (1).txt"). Writes the chosen
/// absolute path into `out` and returns it plus the open fd.
pub fn openUploadDest(cwd: []const u8, base: []const u8, out: *[4096]u8) !struct { fd: c_int, path: []const u8 } {
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

pub fn handleFileOpen(self: *Daemon, cl: *Client, payload: []const u8) void {
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
    if (findUpload(self, cl, xfer) != null) {
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

pub fn handleFileData(self: *Daemon, cl: *Client, payload: []const u8) void {
    const xfer = wire.decodeChanId(payload) orelse return;
    const up = findUpload(self, cl, xfer) orelse return; // aborted/unknown
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
        dropUpload(self, up, true);
        return;
    }
    up.written += bytes.len;
    // Per-chunk ack: the client gates how much it keeps in flight
    // on the gap between bytes sent and bytes acked.
    fileReply(cl, xfer, "progress", up.written, "", "");
}

pub fn handleFileClose(self: *Daemon, cl: *Client, payload: []const u8) void {
    const xfer = wire.decodeChanId(payload) orelse return;
    const up = findUpload(self, cl, xfer) orelse return;
    _ = c.fsync(up.fd);
    _ = c.close(up.fd);
    up.fd = -1;
    fileReply(cl, xfer, "done", up.written, up.path, "");
    dropUpload(self, up, false);
}

// === File download (file_get + reverse file_data) ==========
// The reverse of upload: the daemon reads a file from the remote
// filesystem and streams it to the requesting client.

const max_downloads_per_client = 4;

pub fn dropDownload(self: *Daemon, dl: *Download) void {
    for (self.downloads.items, 0..) |item, i| {
        if (item == dl) {
            _ = self.downloads.swapRemove(i);
            break;
        }
    }
    dl.deinit();
}

pub fn handleFileGet(self: *Daemon, cl: *Client, payload: []const u8) void {
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

/// Installed-app discovery: scan the daemon host's .desktop
/// entries and answer app_listing. On an SSH/UDP daemon this is
/// the REMOTE's app list — the whole point of the remote launcher.
pub fn handleAppList(self: *Daemon, cl: *Client) void {
    const AppOut = struct { name: []const u8, exec: []const u8, icon: []const u8 };
    const desktop = @import("desktop.zig");
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = desktop.scan(arena, 2048) catch {
        cl.queueJson(.app_listing, .{ .apps = &[_]AppOut{}, .@"error" = "scan failed" });
        return;
    };
    var out = arena.alloc(AppOut, entries.len) catch {
        cl.queueJson(.app_listing, .{ .apps = &[_]AppOut{}, .@"error" = "oom" });
        return;
    };
    for (entries, 0..) |e, i| out[i] = .{ .name = e.name, .exec = e.exec, .icon = e.icon };
    cl.queueJson(.app_listing, .{ .apps = out });
}

/// Serialize the attached app session's AT-SPI tree. The tree
/// JSON is already a bare node object; wrap it as {"tree":...}.
pub fn handleAppA11y(self: *Daemon, cl: *Client, payload: []const u8) void {
    const s = cl.attached orelse {
        cl.queueJson(.app_a11y_tree, .{ .@"error" = "not attached" });
        return;
    };
    var hub = &(s.a11y orelse {
        cl.queueJson(.app_a11y_tree, .{ .@"error" = "no accessibility bus for this session (not an app session, or dbus-daemon unavailable)" });
        return;
    });

    // Optional op payload: {op:"action"|"set_text"|"set_value",
    // id, index?, text?, value?}. Empty / op:"tree" = tree walk.
    if (payload.len > 0) {
        const Op = struct {
            op: []const u8 = "tree",
            id: []const u8 = "",
            index: i32 = 0,
            text: []const u8 = "",
            value: f64 = 0,
        };
        var parsed = std.json.parseFromSlice(Op, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cl.queueJson(.app_a11y_tree, .{ .@"error" = "bad a11y op request" });
            return;
        };
        defer parsed.deinit();
        const op = parsed.value;
        if (!std.mem.eql(u8, op.op, "tree")) {
            if (op.id.len == 0) {
                cl.queueJson(.app_a11y_tree, .{ .@"error" = "a11y op requires 'id' (from the tree)" });
                return;
            }
            const done = if (std.mem.eql(u8, op.op, "action"))
                hub.doAction(self.allocator, op.id, op.index)
            else if (std.mem.eql(u8, op.op, "set_text"))
                hub.setTextContents(self.allocator, op.id, op.text)
            else if (std.mem.eql(u8, op.op, "set_value"))
                hub.setCurrentValue(self.allocator, op.id, op.value)
            else {
                cl.queueJson(.app_a11y_tree, .{ .@"error" = "unknown a11y op" });
                return;
            };
            if (done)
                cl.queueJson(.app_a11y_tree, .{ .ok = true })
            else
                cl.queueJson(.app_a11y_tree, .{ .@"error" = "a11y op failed (node gone, interface unsupported, or bus error)" });
            return;
        }
    }

    const tree = hub.treeJson(self.allocator) orelse {
        cl.queueJson(.app_a11y_tree, .{ .@"error" = "no accessibility tree (the app has not published one; GTK/Qt apps only)" });
        return;
    };
    defer self.allocator.free(tree);
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(self.allocator);
    reply.appendSlice(self.allocator, "{\"tree\":") catch {
        cl.queueErr("oom");
        return;
    };
    reply.appendSlice(self.allocator, tree) catch return;
    reply.appendSlice(self.allocator, "}") catch return;
    cl.queueFrame(.app_a11y_tree, reply.items);
}

/// Start an asciicast v2 recording of the attached session. The
/// file lands on the DAEMON's host (that's where the bytes are) —
/// for SSH/UDP sessions the path is remote.
pub fn handleRecStart(self: *Daemon, cl: *Client, payload: []const u8) void {
    const s = cl.attached orelse {
        cl.queueErr("not attached");
        return;
    };
    const Req = struct { path: []const u8 };
    var parsed = std.json.parseFromSlice(Req, self.allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch {
        cl.queueErr("bad rec_start request");
        return;
    };
    defer parsed.deinit();
    if (parsed.value.path.len == 0 or parsed.value.path[0] != '/') {
        cl.queueErr("rec_start path must be absolute");
        return;
    }
    if (s.cast) |*old| {
        old.finish();
        s.cast = null;
    }
    s.cast = cast_rec.Rec.start(
        self.allocator,
        parsed.value.path,
        s.screen.cols,
        s.screen.rows,
        s.name,
        nowMs(),
    ) catch {
        cl.queueErr("cannot open recording file");
        return;
    };
    cl.queueJson(.ok, .{ .ok = true });
}

// === Remote directory browse (file_list) ===================
// Lets the GUI offer a "remote file picker" without the user
// typing paths. Read-only; no state kept (a one-shot reply).

/// Cap on entries per listing — bounds the reply size for huge dirs.
const max_list_entries = 4096;

/// One directory entry on the wire (JSON-serialized in file_listing).
pub const ListEntry = struct { name: []const u8, dir: bool, size: u64 };

pub fn listingError(cl: *Client, xfer: u32, path: []const u8, msg: []const u8) void {
    cl.queueJson(.file_listing, .{
        .xfer = xfer,
        .path = path,
        .entries = &[_]ListEntry{},
        .@"error" = msg,
        .truncated = false,
    });
}

pub fn handleFileList(self: *Daemon, cl: *Client, payload: []const u8) void {
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

// === File service (fs_op / fs_write / fs_delta) ================
// The phase-1 file-browser surface (docs/filebrowser-roadmap.md):
// rich one-round-trip listings, live directory views over inotify,
// and the small mutation verbs. Everything here is an INLINE job in
// the roadmap's terms — bounded work in the poll loop; recursive /
// long-running verbs arrive in phase 2 as subprocess jobs. NOT
// attach-scoped: in broker mode the broker itself serves these
// (fs clients never attach, so their fds are never handed off).

pub const FsOpReq = struct {
    req: u32 = 0,
    op: []const u8 = "",
    path: []const u8 = "",
    /// rename destination / symlink target / copy dst.
    to: []const u8 = "",
    view: u32 = 0,
    off: u64 = 0,
    len: u32 = 0,
    /// Job verbs: allow hash-verified resume of a staged partial.
    @"resume": bool = false,
    /// copy: per-entry collision policy INSIDE a tree
    /// ("" = overwrite, "skip", "keep_both").
    conflict: []const u8 = "",
    /// copy onto an existing directory: "" / "merge" keeps
    /// destination-only entries, "replace" removes the tree first.
    dir_mode: []const u8 = "",
    /// job_cancel/job_pause/job_resume target.
    job: u64 = 0,
    /// find/grep search pattern.
    pattern: []const u8 = "",
    /// find: only entries modified within this window (0 = all).
    within_ms: u64 = 0,
    /// find: raise the match cap (0 = default 2000; hard 200k).
    max_matches: u64 = 0,
    mode: u32 = 0,
    uid: ?u32 = null,
    gid: ?u32 = null,
    size: u64 = 0,
    atime_ms: ?i64 = null,
    mtime_ms: ?i64 = null,
    src_host: []const u8 = "",
    dst_host: []const u8 = "",
    client_token: []const u8 = "",
    /// Comma-separated extended-attribute names to include with
    /// every entry (listings, stat and deltas).
    attrs: []const u8 = "",
    /// Preferred image transport codecs supported by the receiver.
    image_codecs: []const u8 = "",
    /// thumbnail: cache the codec bytes host-side and serve that
    /// persistent file (remote-serving mode; see fsjob.Spec).
    wire_cache: bool = false,
    /// A preview transport job owns and removes its source scratch.
    delete_source: bool = false,
    /// A panelize preview job owns the scratch path carried in `to`.
    delete_destination: bool = false,
};

/// One change inside an fs_delta. upsert carries `entry`; del only
/// `name`.
pub const FsChange = struct {
    op: []const u8,
    name: []const u8,
    entry: ?fsserve.Entry = null,
};

pub fn fsReplyErr(cl: *Client, req: u32, msg: []const u8) void {
    cl.queueJson(.fs_reply, .{ .req = req, .ok = false, .@"error" = msg });
}

pub fn handleFsOp(self: *Daemon, cl: *Client, payload: []const u8) void {
    const parsed = std.json.parseFromSlice(FsOpReq, self.allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch {
        cl.queueErr("bad fs_op");
        return;
    };
    defer parsed.deinit();
    const r = parsed.value;

    if (std.mem.eql(u8, r.op, "close_view")) return fsCloseView(self, cl, r);
    if (std.mem.startsWith(u8, r.op, "job_")) return self.fsJobOp(cl, r);
    // Every other verb takes an absolute path — the client resolves
    // ~ and relative input; the daemon never guesses a cwd here.
    if (r.path.len == 0 or r.path[0] != '/') return fsReplyErr(cl, r.req, "path must be absolute");
    if (std.mem.eql(u8, r.op, "copy") or std.mem.eql(u8, r.op, "delete_tree") or
        std.mem.eql(u8, r.op, "hash") or std.mem.eql(u8, r.op, "find") or
        std.mem.eql(u8, r.op, "grep") or std.mem.eql(u8, r.op, "extract") or
        std.mem.eql(u8, r.op, "archive_create") or std.mem.eql(u8, r.op, "trash") or
        std.mem.eql(u8, r.op, "trash_restore") or std.mem.eql(u8, r.op, "cross_copy") or
        std.mem.eql(u8, r.op, "panelize") or std.mem.eql(u8, r.op, "live_find") or
        std.mem.eql(u8, r.op, "archive_list") or std.mem.eql(u8, r.op, "archive_extract") or
        std.mem.eql(u8, r.op, "thumbnail") or std.mem.eql(u8, r.op, "preview") or std.mem.eql(u8, r.op, "preview_transport") or
        std.mem.eql(u8, r.op, "dir_size") or std.mem.eql(u8, r.op, "perm_tree") or
        std.mem.eql(u8, r.op, "media_meta"))
        return self.fsStartJob(cl, r);

    if (std.mem.eql(u8, r.op, "open_view")) {
        fsOpenView(self, cl, r);
    } else if (std.mem.eql(u8, r.op, "list")) {
        // A refresh of a directory this client also watches gets its
        // child counts refreshed too (deltas ride the view).
        const view: ?u32 = for (self.fs_views.items) |v| {
            if (v.client == cl and !v.gone and std.mem.eql(u8, v.path, r.path)) break v.id;
        } else null;
        _ = fsStartListing(self, cl, r.req, r.path, r.attrs, view);
    } else if (std.mem.eql(u8, r.op, "stat")) {
        fsStat(self, cl, r);
    } else if (std.mem.eql(u8, r.op, "read")) {
        fsRead(self, cl, r);
    } else if (std.mem.eql(u8, r.op, "apps")) {
        fsApps(self, cl, r);
    } else if (std.mem.eql(u8, r.op, "homedir")) {
        // Host identity for cache placement: thumbnails belong to
        // the machine that owns the files.
        var cache_buf: [4096]u8 = undefined;
        const home: []const u8 = if (c.getenv("HOME")) |h|
            std.mem.span(@as([*:0]const u8, @ptrCast(h)))
        else
            "/";
        const cache: []const u8 = if (c.getenv("XDG_CACHE_HOME")) |xc|
            std.mem.span(@as([*:0]const u8, @ptrCast(xc)))
        else
            std.fmt.bufPrint(&cache_buf, "{s}/.cache", .{home}) catch "/tmp";
        // The template directory is resolved HERE, on the host
        // that owns the files: "New from Template" on a remote tab
        // must offer that machine's templates, and only this
        // daemon can read its user-dirs.dirs.
        var config_buf: [4096]u8 = undefined;
        const config_home: []const u8 = if (c.getenv("XDG_CONFIG_HOME")) |xc|
            std.mem.span(@as([*:0]const u8, @ptrCast(xc)))
        else
            std.fmt.bufPrint(&config_buf, "{s}/.config", .{home}) catch "/tmp";
        var templates_buf: [4096]u8 = undefined;
        const templates = fsserve.templatesDir(home, config_home, &templates_buf);
        cl.queueJson(.fs_reply, .{
            .req = r.req,
            .ok = true,
            .home = home,
            .cache = cache,
            .templates = templates,
        });
    } else if (std.mem.eql(u8, r.op, "mkdir")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const rc = c.mkdir(p, 0o755);
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        const parent = std.fs.path.dirname(r.path) orelse return fsReplyErr(cl, r.req, "directory has no parent");
        var dz: [4096]u8 = undefined;
        const dfd = c.open(pathZ(&dz, parent) catch return fsReplyErr(cl, r.req, "parent path too long"), c.O_RDONLY | c.O_DIRECTORY);
        if (dfd < 0) return fsReplyErr(cl, r.req, "cannot open directory parent");
        defer _ = c.close(dfd);
        if (c.fsync(dfd) != 0) return fsReplyErr(cl, r.req, "cannot fsync directory parent");
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "rename")) {
        if (r.to.len == 0 or r.to[0] != '/') return fsReplyErr(cl, r.req, "to must be absolute");
        var z1: [4096]u8 = undefined;
        var z2: [4096]u8 = undefined;
        const from = pathZ(&z1, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const to = pathZ(&z2, r.to) catch return fsReplyErr(cl, r.req, "path too long");
        const rc = c.rename(from, to);
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        if (std.fs.path.dirname(r.to)) |parent| {
            var dz: [4096]u8 = undefined;
            if (pathZ(&dz, parent)) |dir_z| {
                const dfd = c.open(dir_z, c.O_RDONLY | c.O_DIRECTORY);
                if (dfd < 0) return fsReplyErr(cl, r.req, "cannot open destination parent");
                defer _ = c.close(dfd);
                if (c.fsync(dfd) != 0) return fsReplyErr(cl, r.req, "cannot fsync destination parent");
            } else |_| return fsReplyErr(cl, r.req, "destination parent path too long");
        } else return fsReplyErr(cl, r.req, "destination has no parent");
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "delete")) {
        // Single entry only: files/links unlink, EMPTY dirs rmdir.
        // Recursive delete is a phase-2 subprocess job — the poll
        // loop must never walk an unbounded tree.
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        var st: c.struct_stat = undefined;
        if (c.lstat(p, &st) != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(@as(c_int, -1)));
        const rc = if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) c.rmdir(p) else c.unlink(p);
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "unlink") or std.mem.eql(u8, r.op, "rmdir")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        var owned_temp = false;
        if (std.mem.eql(u8, r.op, "unlink")) {
            for (self.fs_jobs.items) |job| {
                if (job.ownsTempPath(r.path)) owned_temp = true;
            }
        }
        const rc = if (std.mem.eql(u8, r.op, "rmdir")) c.rmdir(p) else c.unlink(p);
        if (rc != 0 and !(owned_temp and std.posix.errno(rc) == .NOENT))
            return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        if (owned_temp) {
            for (self.fs_jobs.items) |job| {
                _ = job.releaseTempPath(r.path, nowMs());
            }
        }
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "create")) {
        // Empty-file create, O_EXCL so an existing file can never
        // be clobbered (the browser's Empty Document).
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const fd = c.open(p, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c.mode_t, 0o644));
        if (fd < 0) return fsReplyErr(cl, r.req, fsserve.errnoName(fd));
        _ = c.close(fd);
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "attr_list")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        cl.queueJson(.fs_reply, .{
            .req = r.req,
            .ok = true,
            .attrs = fsserve.listAttrs(arena_state.allocator(), p),
        });
    } else if (std.mem.eql(u8, r.op, "attr_set")) {
        // `pattern` = attribute name (user.* only), `to` = value
        // ("" removes). Attributes travel with the file, so this
        // is how metadata survives a copy to another host.
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        if (!std.mem.startsWith(u8, r.pattern, "user."))
            return fsReplyErr(cl, r.req, "attribute name must start with user.");
        if (!fsserve.setAttr(p, r.pattern, r.to)) return fsReplyErr(cl, r.req, "xattr set failed");
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "tag_set")) {
        // `to` = comma-separated tags ("" clears). Rides the
        // user.sketerm.tags xattr, so tags travel with the file.
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        if (!fsserve.setTags(p, r.to)) return fsReplyErr(cl, r.req, "xattr set failed");
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "symlink")) {
        // `to` is the link TARGET (may be relative by design);
        // `path` is where the link is created.
        if (r.to.len == 0) return fsReplyErr(cl, r.req, "missing target");
        var z1: [4096]u8 = undefined;
        var z2: [4096]u8 = undefined;
        const tgt = pathZ(&z1, r.to) catch return fsReplyErr(cl, r.req, "target too long");
        const link = pathZ(&z2, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const rc = c.symlink(tgt, link);
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "hardlink")) {
        // `to` is the EXISTING file, `path` the new name. Both
        // impossibilities are reported as themselves rather than
        // as a bare errno: a hard link cannot cross filesystems
        // and cannot name a directory, and a client offering the
        // verb on stale device information deserves the reason.
        if (r.to.len == 0 or r.to[0] != '/') return fsReplyErr(cl, r.req, "to must be absolute");
        var z1: [4096]u8 = undefined;
        var z2: [4096]u8 = undefined;
        const tgt = pathZ(&z1, r.to) catch return fsReplyErr(cl, r.req, "target too long");
        const link = pathZ(&z2, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        var tst: c.struct_stat = undefined;
        if (c.lstat(tgt, &tst) != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(@as(c_int, -1)));
        if ((tst.st_mode & c.S_IFMT) == c.S_IFDIR)
            return fsReplyErr(cl, r.req, "a directory cannot be hard linked");
        const parent = std.fs.path.dirname(r.path) orelse return fsReplyErr(cl, r.req, "link has no parent");
        var z3: [4096]u8 = undefined;
        var pst: c.struct_stat = undefined;
        const pz = pathZ(&z3, parent) catch return fsReplyErr(cl, r.req, "parent path too long");
        if (c.stat(pz, &pst) != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(@as(c_int, -1)));
        if (pst.st_dev != tst.st_dev)
            return fsReplyErr(cl, r.req, "hard link would cross filesystems");
        const rc = c.link(tgt, link);
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "chmod")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const rc = c.chmod(p, @intCast(r.mode & 0o7777));
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "chown")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const uid: c.uid_t = if (r.uid) |v| @intCast(v) else @bitCast(@as(c_int, -1));
        const gid: c.gid_t = if (r.gid) |v| @intCast(v) else @bitCast(@as(c_int, -1));
        const rc = c.lchown(p, uid, gid);
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "truncate")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const rc = c.truncate(p, @intCast(r.size));
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "utimens")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        var times = [_]c.struct_timespec{
            millisTimespec(r.atime_ms),
            millisTimespec(r.mtime_ms),
        };
        const rc = c.utimensat(c.AT_FDCWD, p, &times, c.AT_SYMLINK_NOFOLLOW);
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "access")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const rc = c.access(p, @intCast(r.mode));
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "fsync")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const fd = c.open(p, c.O_RDONLY | c.O_CLOEXEC);
        if (fd < 0) return fsReplyErr(cl, r.req, fsserve.errnoName(fd));
        defer _ = c.close(fd);
        const rc = c.fsync(fd);
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "statfs")) {
        // musl's struct statvfs contains an anonymous bitfield
        // that translate-c cannot represent (the type comes out
        // opaque), so musl-portable daemons serve conservative
        // defaults instead of real filesystem numbers.
        if (comptime @typeInfo(c.struct_statvfs) == .@"opaque") {
            cl.queueJson(.fs_reply, .{
                .req = r.req,
                .ok = true,
                .bsize = @as(u64, 4096),
                .frsize = @as(u64, 4096),
                .blocks = @as(u64, 0),
                .bfree = @as(u64, 0),
                .bavail = @as(u64, 0),
                .files = @as(u64, 0),
                .ffree = @as(u64, 0),
                .namemax = @as(u64, 255),
            });
            return;
        }
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        var st: c.struct_statvfs = undefined;
        const rc = c.statvfs(p, &st);
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{
            .req = r.req,
            .ok = true,
            .bsize = st.f_bsize,
            .frsize = st.f_frsize,
            .blocks = st.f_blocks,
            .bfree = st.f_bfree,
            .bavail = st.f_bavail,
            .files = st.f_files,
            .ffree = st.f_ffree,
            .namemax = st.f_namemax,
        });
    } else {
        fsReplyErr(cl, r.req, "unknown fs op");
    }
}

pub fn millisTimespec(ms: ?i64) c.struct_timespec {
    const value = ms orelse return .{ .tv_sec = 0, .tv_nsec = c.UTIME_OMIT };
    return .{
        .tv_sec = @divFloor(value, 1000),
        .tv_nsec = @mod(value, 1000) * 1_000_000,
    };
}

pub fn fsOpenView(self: *Daemon, cl: *Client, r: FsOpReq) void {
    for (self.fs_views.items) |v| {
        if (v.client == cl and v.id == r.view) return fsReplyErr(cl, r.req, "view id in use");
    }
    // Canonicalize so delta paths and the reported root agree.
    var z: [4096]u8 = undefined;
    const pz = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
    var real_buf: [4096]u8 = undefined;
    const canon: []const u8 = if (c.realpath(pz, &real_buf)) |rp|
        std.mem.span(@as([*:0]const u8, @ptrCast(rp)))
    else
        return fsReplyErr(cl, r.req, fsserve.errnoName(@as(c_int, -1)));
    var dst: c.struct_stat = undefined;
    if (c.stat(@as([*:0]const u8, @ptrCast(real_buf[0..canon.len :0])), &dst) != 0 or
        (dst.st_mode & c.S_IFMT) != c.S_IFDIR)
        return fsReplyErr(cl, r.req, "not a directory");

    // Watch BEFORE listing: changes racing the listing surface as
    // deltas after it (upserts are idempotent), never fall in a gap.
    var wd: c_int = -1;
    if (self.fs_watch.ensure()) {
        var z2: [4096]u8 = undefined;
        const cz = pathZ(&z2, canon) catch return fsReplyErr(cl, r.req, "path too long");
        wd = self.fs_watch.add(cz);
    }
    const view = self.allocator.create(FsView) catch return fsReplyErr(cl, r.req, "out of memory");
    const path_owned = self.allocator.dupe(u8, canon) catch {
        self.allocator.destroy(view);
        return fsReplyErr(cl, r.req, "out of memory");
    };
    const attrs_owned = self.allocator.dupe(u8, r.attrs) catch {
        self.allocator.free(path_owned);
        self.allocator.destroy(view);
        return fsReplyErr(cl, r.req, "out of memory");
    };
    view.* = .{
        .allocator = self.allocator,
        .client = cl,
        .id = r.view,
        .path = path_owned,
        .wd = wd,
        .attrs = attrs_owned,
    };
    self.fs_views.append(self.allocator, view) catch {
        view.deinit();
        return fsReplyErr(cl, r.req, "out of memory");
    };
    // Listing failure (dir vanished between checks) → the open as
    // a whole failed; the view must not linger daemon-side.
    if (!fsStartListing(self, cl, r.req, canon, r.attrs, r.view))
        dropFsViewAt(self, self.fs_views.items.len - 1);
}

pub fn fsCloseView(self: *Daemon, cl: *Client, r: FsOpReq) void {
    var i: usize = 0;
    while (i < self.fs_views.items.len) : (i += 1) {
        const v = self.fs_views.items[i];
        if (v.client == cl and v.id == r.view) {
            dropFsViewAt(self, i);
            cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
            return;
        }
    }
    fsReplyErr(cl, r.req, "no such view");
}

/// Remove fs_views[i]; the kernel watch goes only when no other
/// view shares its wd (inotify hands equal paths the same wd).
pub fn dropFsViewAt(self: *Daemon, i: usize) void {
    const v = self.fs_views.swapRemove(i);
    // A dying view aborts its in-flight listing outright. Statting on
    // for a view nobody watches would queue chunks AHEAD of whatever
    // the client asks for next — on a slow link that backlog is why
    // a navigation away from a huge folder went dead. Every
    // close_view is preceded by cancelPendingDir client-side, so the
    // terminator frame can never land on a live accumulator.
    var j: usize = 0;
    while (j < self.fs_listings.items.len) {
        const l = self.fs_listings.items[j];
        if (l.client == v.client and l.view != null and l.view.? == v.id) {
            if (l.stage == .stat) {
                l.client.queueJson(.fs_reply, .{
                    .req = l.req,
                    .ok = true,
                    .path = l.path,
                    .entries = &[_]fsserve.Entry{},
                    .more = false,
                    .aborted = true,
                });
            }
            _ = self.fs_listings.swapRemove(j);
            l.deinit();
        } else j += 1;
    }
    if (v.wd >= 0) {
        var shared = false;
        for (self.fs_views.items) |o| {
            if (o.wd == v.wd) {
                shared = true;
                break;
            }
        }
        if (!shared) self.fs_watch.remove(v.wd);
    }
    v.deinit();
}

/// Cap on how many attributes one listing may carry per entry:
/// each name costs an lgetxattr per entry, so the column set is
/// bounded rather than trusted.
const MAX_ATTR_NAMES = 8;

/// Split a comma-separated attribute request into `buf`, keeping
/// only `user.`-namespaced names.
pub fn splitAttrs(spec: []const u8, buf: *[MAX_ATTR_NAMES][]const u8) []const []const u8 {
    if (spec.len == 0) return &.{};
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |raw| {
        if (n >= buf.len) break;
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0 or !std.mem.startsWith(u8, name, "user.")) continue;
        buf[n] = name;
        n += 1;
    }
    return buf[0..n];
}

/// Per-batch bounds for pumpFsListings: a chunk frame never carries
/// more than CHUNK_ENTRIES entries, and a batch stops early once its
/// time box elapses — one slow filesystem (NFS, cold disk) then costs
/// small chunks, never a stalled poll loop.
const LISTING_BATCH_MS: i64 = 8;
const COUNT_BATCH_MS: i64 = 5;
/// Skip a listing while its client's write buffer is over this mark;
/// POLLOUT drains it and the pump resumes (pumpDownloads' rule).
/// Deliberately far below the download watermark: everything the
/// client asks for NEXT queues behind these bytes, and on a slow
/// remote link a megabyte of backlog is already seconds of dead UI.
const LISTING_WATERMARK: usize = 1 << 20;

/// Begin an incremental listing. The names are read and sorted NOW —
/// one cheap readdir pass, so open failures still reply synchronously
/// and fsOpenView's drop-the-view-on-failure contract holds — then
/// the per-entry stats stream from pumpFsListings as the fs_reply
/// chunk run (`more:true` until the last) every client already
/// accumulates. `view` non-null schedules async child counts after
/// the listing, delivered as upsert deltas on that view.
pub fn fsStartListing(self: *Daemon, cl: *Client, req: u32, dir_path: []const u8, attr_spec: []const u8, view: ?u32) bool {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    // The REASON travels: "cannot open directory" made a permission
    // denial and a vanished directory indistinguishable, and a
    // client cannot report what it was never told.
    var why: []const u8 = "";
    const names = fsserve.readNames(arena_state.allocator(), dir_path, fsserve.MAX_ENTRIES, &why) catch {
        arena_state.deinit();
        fsReplyErr(cl, req, if (why.len > 0) why else "cannot open directory");
        return false;
    };

    // The directory's device id rides the listing (one number, not
    // per entry): it is what lets a client decide BEFORE offering
    // the verb whether a hard link into this directory could work.
    var dir_st: c.struct_stat = undefined;
    var z: [4096]u8 = undefined;
    const dev: u64 = if (pathZ(&z, dir_path)) |dz|
        (if (c.stat(dz, &dir_st) == 0) @intCast(dir_st.st_dev) else 0)
    else |_|
        0;

    const listing = self.allocator.create(dmod.FsListing) catch {
        arena_state.deinit();
        fsReplyErr(cl, req, "out of memory");
        return false;
    };
    const path_owned = self.allocator.dupe(u8, dir_path) catch {
        self.allocator.destroy(listing);
        arena_state.deinit();
        fsReplyErr(cl, req, "out of memory");
        return false;
    };
    const attrs_owned = self.allocator.dupe(u8, attr_spec) catch {
        self.allocator.free(path_owned);
        self.allocator.destroy(listing);
        arena_state.deinit();
        fsReplyErr(cl, req, "out of memory");
        return false;
    };
    listing.* = .{
        .allocator = self.allocator,
        .arena = arena_state,
        .client = cl,
        .req = req,
        .path = path_owned,
        .attrs = attrs_owned,
        .names = names.names,
        .truncated = names.truncated,
        .dev = dev,
        .view = view,
    };
    self.fs_listings.append(self.allocator, listing) catch {
        listing.deinit();
        fsReplyErr(cl, req, "out of memory");
        return false;
    };
    // First batch immediately: a small local directory completes in
    // this very call, keeping the old one-round-trip latency.
    if (pumpListing(self, listing)) {
        _ = self.fs_listings.pop();
        listing.deinit();
    }
    return true;
}

/// Advance every in-flight listing by one bounded batch (tick).
pub fn pumpFsListings(self: *Daemon) void {
    var i: usize = 0;
    while (i < self.fs_listings.items.len) {
        const listing = self.fs_listings.items[i];
        if (pumpListing(self, listing)) {
            _ = self.fs_listings.swapRemove(i);
            listing.deinit();
        } else i += 1;
    }
}

/// One batch of one listing. True = finished (caller removes it).
fn pumpListing(self: *Daemon, listing: *dmod.FsListing) bool {
    if (listing.client.dead) return true;
    if (listing.client.queuedBytes() >= LISTING_WATERMARK) return false;
    const a = listing.arena.allocator();
    switch (listing.stage) {
        .stat => {
            var attr_buf: [MAX_ATTR_NAMES][]const u8 = undefined;
            const attrs = splitAttrs(listing.attrs, &attr_buf);
            var chunk: std.ArrayList(fsserve.Entry) = .empty;
            const deadline = nowMs() + LISTING_BATCH_MS;
            while (listing.idx < listing.names.len and chunk.items.len < fsserve.CHUNK_ENTRIES) {
                const name = listing.names[listing.idx];
                listing.idx += 1;
                if (fsserve.statEntryAttrs(a, listing.path, name, attrs, false)) |e| {
                    chunk.append(a, e) catch break;
                    if (listing.view != null and e.tdir) listing.dirs.append(a, e) catch {};
                }
                if (nowMs() >= deadline) break;
            }
            const last = listing.idx == listing.names.len;
            // An empty non-final batch (every stat in the box was a
            // vanished entry, or one stat ate the whole box) sends
            // nothing — the run is still open, the next tick continues.
            if (chunk.items.len > 0 or last) {
                listing.client.queueJson(.fs_reply, .{
                    .req = listing.req,
                    .ok = true,
                    .path = listing.path,
                    .dev = listing.dev,
                    .entries = chunk.items,
                    .more = !last,
                    .truncated = listing.truncated,
                });
            }
            if (!last) return false;
            if (listing.view == null or listing.dirs.items.len == 0) return true;
            listing.stage = .count;
            return false;
        },
        .count => {
            const view_id = listing.view orelse return true;
            // The view may have died since (tab closed, navigation).
            const alive = for (self.fs_views.items) |v| {
                if (v.client == listing.client and v.id == view_id and !v.gone) break true;
            } else false;
            if (!alive) return true;
            var changes: std.ArrayList(FsChange) = .empty;
            const deadline = nowMs() + COUNT_BATCH_MS;
            while (listing.count_idx < listing.dirs.items.len) {
                const e = &listing.dirs.items[listing.count_idx];
                listing.count_idx += 1;
                var z: [4096]u8 = undefined;
                if (fsserve.joinZ(&z, listing.path, e.name)) |full| {
                    const cnt = fsserve.countChildren(full);
                    // Vanished or over the cap: leave it unknown
                    // rather than upsert a stale entry back to life.
                    if (cnt >= 0) {
                        e.children = cnt;
                        changes.append(a, .{ .op = "upsert", .name = e.name, .entry = e.* }) catch break;
                    }
                } else |_| {}
                if (nowMs() >= deadline) break;
            }
            if (changes.items.len > 0)
                listing.client.queueJson(.fs_delta, .{ .view = view_id, .changes = changes.items });
            return listing.count_idx == listing.dirs.items.len;
        },
    }
}

pub fn fsStat(self: *Daemon, cl: *Client, r: FsOpReq) void {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const dir = std.fs.path.dirname(r.path) orelse "/";
    const base = std.fs.path.basename(r.path);
    if (base.len == 0) {
        // Stat of "/" itself.
        const e = fsserve.statEntry(arena_state.allocator(), "/", ".") orelse
            return fsReplyErr(cl, r.req, "stat failed");
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true, .entry = e });
        return;
    }
    const e = fsserve.statEntry(arena_state.allocator(), dir, base) orelse
        return fsReplyErr(cl, r.req, fsserve.errnoName(@as(c_int, -1)));
    cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true, .entry = e });
}

/// Bounded ranged read: fs_data [u32 req][u64 off][bytes], then a
/// closing fs_reply { size, eof }. Clients loop for large files —
/// one request can never queue more than MAX_READ toward a client.
pub fn fsRead(self: *Daemon, cl: *Client, r: FsOpReq) void {
    var z: [4096]u8 = undefined;
    const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
    const fd = c.open(p, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return fsReplyErr(cl, r.req, fsserve.errnoName(fd));
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return fsReplyErr(cl, r.req, "fstat failed");
    const size: u64 = if (st.st_size > 0) @intCast(st.st_size) else 0;

    const want: usize = @min(@as(usize, r.len), fsserve.MAX_READ);
    const buf = self.allocator.alloc(u8, 12 + want) catch
        return fsReplyErr(cl, r.req, "out of memory");
    defer self.allocator.free(buf);
    std.mem.writeInt(u32, buf[0..4], r.req, .little);
    std.mem.writeInt(u64, buf[4..12], r.off, .little);
    var got: usize = 0;
    while (got < want) {
        const n = c.pread(fd, buf.ptr + 12 + got, want - got, @intCast(r.off + got));
        if (n < 0) return fsReplyErr(cl, r.req, fsserve.errnoName(@as(c_int, @intCast(n))));
        if (n == 0) break;
        got += @intCast(n);
    }
    cl.queueFrame(.fs_data, buf[0 .. 12 + got]);
    cl.queueJson(.fs_reply, .{
        .req = r.req,
        .ok = true,
        .size = size,
        .eof = r.off + got >= size,
    });
}

pub const AppEntry = struct {
    name: []const u8,
    exec: []const u8,
    mimes: []const u8,
};

/// Enumerate this host's launchable .desktop applications in one
/// reply, so a remote "Open With" costs one round trip instead of
/// one per .desktop file. Bounded: MAX_APPS entries, 8KB/file.
pub fn fsApps(self: *Daemon, cl: *Client, r: FsOpReq) void {
    const MAX_APPS = 400;
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var apps: std.ArrayList(AppEntry) = .empty;

    var home_buf: [4096]u8 = undefined;
    const home_apps: ?[]const u8 = if (c.getenv("HOME")) |h|
        std.fmt.bufPrint(&home_buf, "{s}/.local/share/applications", .{
            std.mem.span(@as([*:0]const u8, @ptrCast(h))),
        }) catch null
    else
        null;
    const dirs = [_]?[]const u8{
        home_apps,
        "/usr/local/share/applications",
        "/usr/share/applications",
    };
    for (dirs) |maybe_dir| {
        const dir_path = maybe_dir orelse continue;
        var dz: [4096]u8 = undefined;
        const dp = pathZ(&dz, dir_path) catch continue;
        const d = c.opendir(dp) orelse continue;
        defer _ = c.closedir(d);
        while (c.readdir(d)) |de| {
            if (apps.items.len >= MAX_APPS) break;
            const fname = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
            if (!std.mem.endsWith(u8, fname, ".desktop")) continue;
            var fz: [4400:0]u8 = undefined;
            const fp = std.fmt.bufPrintZ(&fz, "{s}/{s}", .{ dir_path, fname }) catch continue;
            const f = c.fopen(fp.ptr, "rb") orelse continue;
            var content: [8192]u8 = undefined;
            const n = c.fread(&content, 1, content.len, f);
            _ = c.fclose(f);
            var name: []const u8 = "";
            var exec: []const u8 = "";
            var mimes: []const u8 = "";
            var is_app = false;
            var hidden = false;
            var in_entry = false;
            var it = std.mem.tokenizeScalar(u8, content[0..n], '\n');
            while (it.next()) |line_raw| {
                const line = std.mem.trim(u8, line_raw, " \t\r");
                if (line.len > 0 and line[0] == '[') {
                    in_entry = std.mem.eql(u8, line, "[Desktop Entry]");
                    continue;
                }
                if (!in_entry) continue;
                if (std.mem.startsWith(u8, line, "Name=") and name.len == 0) name = line[5..];
                if (std.mem.startsWith(u8, line, "Exec=") and exec.len == 0) exec = line[5..];
                if (std.mem.startsWith(u8, line, "MimeType=")) mimes = line[9..];
                if (std.mem.startsWith(u8, line, "Type=")) is_app = std.mem.eql(u8, line[5..], "Application");
                if (std.mem.startsWith(u8, line, "NoDisplay=") or std.mem.startsWith(u8, line, "Hidden=")) {
                    const v = line[std.mem.indexOfScalar(u8, line, '=').? + 1 ..];
                    if (std.mem.eql(u8, v, "true")) hidden = true;
                }
            }
            if (!is_app or hidden or name.len == 0 or exec.len == 0) continue;
            // User-dir entries shadow system ones of the same name.
            const dup = for (apps.items) |a| {
                if (std.mem.eql(u8, a.name, name)) break true;
            } else false;
            if (dup) continue;
            apps.append(arena, .{
                .name = arena.dupe(u8, name) catch continue,
                .exec = arena.dupe(u8, exec) catch continue,
                .mimes = arena.dupe(u8, mimes) catch continue,
            }) catch break;
        }
    }
    cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true, .apps = apps.items });
}

/// fs_write payload: [u32 req][u64 off][u8 flags][u16 path_len]
/// [path][data]. flags bit0=create bit1=truncate bit2=append
/// bit3=exclusive.
pub fn handleFsWrite(self: *Daemon, cl: *Client, payload: []const u8) void {
    _ = self;
    if (payload.len < 15) {
        cl.queueErr("bad fs_write");
        return;
    }
    const req = std.mem.readInt(u32, payload[0..4], .little);
    const off = std.mem.readInt(u64, payload[4..12], .little);
    const flags = payload[12];
    const plen = std.mem.readInt(u16, payload[13..15], .little);
    if (payload.len < 15 + @as(usize, plen)) return fsReplyErr(cl, req, "bad fs_write");
    const path = payload[15 .. 15 + plen];
    const data = payload[15 + plen ..];
    if (path.len == 0 or path[0] != '/') return fsReplyErr(cl, req, "path must be absolute");

    var oflags: c_int = c.O_WRONLY | c.O_CLOEXEC;
    if (flags & 1 != 0) oflags |= c.O_CREAT;
    if (flags & 2 != 0) oflags |= c.O_TRUNC;
    if (flags & 4 != 0) oflags |= c.O_APPEND;
    if (flags & 8 != 0) oflags |= c.O_EXCL;
    var z: [4096]u8 = undefined;
    const p = pathZ(&z, path) catch return fsReplyErr(cl, req, "path too long");
    const fd = c.open(p, oflags, @as(c.mode_t, 0o644));
    if (fd < 0) return fsReplyErr(cl, req, fsserve.errnoName(fd));
    defer _ = c.close(fd);

    var written: usize = 0;
    while (written < data.len) {
        const n = if (flags & 4 != 0)
            c.write(fd, data.ptr + written, data.len - written)
        else
            c.pwrite(fd, data.ptr + written, data.len - written, @intCast(off + written));
        if (n <= 0) return fsReplyErr(cl, req, fsserve.errnoName(@as(c_int, @intCast(n))));
        written += @intCast(n);
    }
    cl.queueJson(.fs_reply, .{ .req = req, .ok = true, .written = written });
}

/// Drain the shared inotify fd and push coalesced fs_delta frames.
/// Per view per drain: at most one delta frame, changes deduped by
/// name (last state wins — a create+delete burst nets out to what
/// a fresh stat says). Kernel queue overflow degrades honestly to
/// `resync:true` (the client must re-list; deltas alone are no
/// longer trustworthy).
pub fn fsWatchReadable(self: *Daemon) void {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const PerView = struct {
        view: *FsView,
        changes: std.ArrayList(FsChange) = .empty,
        gone: bool = false,
        resync: bool = false,
    };
    var touched: std.ArrayList(*PerView) = .empty;

    const findOrAdd = struct {
        fn go(a: std.mem.Allocator, list: *std.ArrayList(*PerView), v: *FsView) ?*PerView {
            for (list.items) |pv| {
                if (pv.view == v) return pv;
            }
            const pv = a.create(PerView) catch return null;
            pv.* = .{ .view = v };
            list.append(a, pv) catch return null;
            return pv;
        }
    }.go;

    var buf: [16 * 1024]u8 = undefined;
    var overflow = false;
    while (true) {
        const n = c.read(self.fs_watch.fd, &buf, buf.len);
        if (n <= 0) break; // EAGAIN → drained
        var it = fsserve.EventIter{ .buf = buf[0..@intCast(n)] };
        while (it.next()) |ev| {
            if (ev.isOverflow()) {
                overflow = true;
                continue;
            }
            for (self.fs_views.items) |v| {
                if (v.wd != ev.wd or v.gone) continue;
                const pv = findOrAdd(arena, &touched, v) orelse continue;
                if (ev.isSelfGone()) {
                    pv.gone = true;
                    continue;
                }
                if (ev.name.len == 0) continue;
                // Last state wins: drop any earlier change for this
                // name, then append the current verdict.
                var i: usize = 0;
                while (i < pv.changes.items.len) {
                    if (std.mem.eql(u8, pv.changes.items[i].name, ev.name)) {
                        _ = pv.changes.swapRemove(i);
                    } else i += 1;
                }
                // A rename target may exist even when the event says
                // MOVED_FROM (rapid re-create) — trust a fresh stat
                // over the event kind.
                var attr_buf: [MAX_ATTR_NAMES][]const u8 = undefined;
                if (fsserve.statEntryAttrs(arena, v.path, ev.name, splitAttrs(v.attrs, &attr_buf), true)) |e| {
                    pv.changes.append(arena, .{ .op = "upsert", .name = e.name, .entry = e }) catch {};
                } else {
                    // Stat failed → the entry is gone now, whatever
                    // the event kind said (create+delete bursts).
                    const name_owned = arena.dupe(u8, ev.name) catch continue;
                    pv.changes.append(arena, .{ .op = "del", .name = name_owned }) catch {};
                }
            }
        }
    }

    if (overflow) {
        for (self.fs_views.items) |v| {
            if (v.gone) continue;
            const pv = findOrAdd(arena, &touched, v) orelse continue;
            pv.resync = true;
        }
    }

    for (touched.items) |pv| {
        if (pv.gone) {
            pv.view.gone = true;
            pv.view.client.queueJson(.fs_delta, .{
                .view = pv.view.id,
                .gone = true,
                .changes = &[_]FsChange{},
            });
        } else if (pv.resync) {
            pv.view.client.queueJson(.fs_delta, .{
                .view = pv.view.id,
                .resync = true,
                .changes = &[_]FsChange{},
            });
        } else if (pv.changes.items.len > 0) {
            pv.view.client.queueJson(.fs_delta, .{
                .view = pv.view.id,
                .changes = pv.changes.items,
            });
        }
    }
}
