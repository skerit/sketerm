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
const fsjob = @import("fsjob.zig");
const daemon_fsjobs = @import("daemon_fsjobs.zig");
const pulse = @import("pulse.zig");
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
const nowMs = @import("../util/clock.zig").nowMs;
const cwdOfPid = dmod.cwdOfPid;
const pathZ = @import("../util/pathz.zig").pathZ;
const version = @import("../version.zig");
const cast_rec = @import("cast.zig");
const opuscodec = @import("opuscodec.zig");
const build_options = @import("build_options");
const wsproto = @import("../winstream/proto.zig");
const wallMs = @import("../util/clock.zig").wallMs;
const webstore = @import("webstore.zig");
const webprofiles = @import("../ipc/webprofiles.zig");
const webfindbin = @import("../web/findbin.zig");

// ── broker ↔ worker control channel (process isolation) ─────────
//
// A worker process owns one session and receives its clients as fds
// passed by the broker over a datagram control socketpair (SEQPACKET on
// Linux, DGRAM on Darwin — see platform.controlSocketpair). Each
// control message is one datagram: [opcode][payload], with at most one
// fd in SCM_RIGHTS. A non-positive recv means the channel is gone —
// test `n <= 0`, never `n == 0`, since Darwin reports a closed peer as
// -1/ECONNRESET. Worker-handled opcodes (workerOnControl): 'A' attach
// (payload is PassedClient's append-only byte encoding + the client fd),
// 'K' kill, 'R' broker-authoritative rename, 'n' result of a rename this
// worker forwarded. Broker-handled opcodes (brokerOnWorkerControl):
// 'Y' ready, 'E' spawn-failure reason, 'M' metadata push, 'N' an attached
// client's rename forwarded by the worker.

/// Graceful worker stop, shared by the broker's 'K' and control EOF: close
/// panel scopes, tell live clients it is intentional, and leave the loop.
fn workerShutdown(self: *Daemon) void {
    for (self.sessions.items) |s| self.panelSessionClosed(s);
    for (self.clients.items) |cl| if (!cl.dead) cl.queueFrame(.gone, "");
    self.running = false;
}

/// Worker side: drain one control datagram and act on it.
pub fn workerOnControl(self: *Daemon) void {
    var buf: [256]u8 = undefined;
    var passed: c_int = -1;
    const n = controlRecv(self.control_fd, &buf, &passed);
    if (n <= 0) {
        // Broker closed the control channel — no supervisor left; exit.
        if (passed >= 0) _ = c.close(passed);
        workerShutdown(self);
        return;
    }
    switch (buf[0]) {
        'A' => {
            if (passed < 0) return;
            addPassedClient(self, passed, PassedClient.decode(buf[1..@intCast(n)]));
        },
        'K' => workerShutdown(self),
        'R' => {
            if (passed >= 0) _ = c.close(passed);
            workerApplyRename(self, buf[0..@intCast(n)]);
        },
        'n' => {
            if (passed >= 0) _ = c.close(passed);
            workerRenameResult(self, buf[0..@intCast(n)]);
        },
        else => if (passed >= 0) {
            _ = c.close(passed);
        },
    }
}

/// The broker is the routing authority: it has already renamed its own record
/// and is telling us the new name. Nothing to negotiate.
fn workerApplyRename(self: *Daemon, payload: []const u8) void {
    if (payload.len <= 1 or self.sessions.items.len == 0) return;
    const session = self.sessions.items[0];
    session.renameTo(payload[1..]) catch return;
    self.broadcastSessionIdentity(session);
}

/// Forward an attached client's rename to the broker and answer that client
/// when the broker reports back.
pub fn workerRequestRename(self: *Daemon, cl: *Client, new_name: []const u8) void {
    if (self.worker_rename_request != null) {
        cl.queueErr("session rename already in progress");
        return;
    }
    if (self.sessions.items.len == 0) {
        cl.queueErr("no such session");
        return;
    }
    const session = self.sessions.items[0];
    if (std.mem.eql(u8, session.name, new_name)) {
        cl.queueJson(.ok, .{ .ok = true, .name = session.name });
        return;
    }
    const request_id = self.next_worker_rename_request;
    self.next_worker_rename_request +%= 1;
    if (self.next_worker_rename_request == 0) self.next_worker_rename_request = 1;
    var msg: [9 + dmod.MAX_SESSION_NAME]u8 = undefined;
    msg[0] = 'N';
    std.mem.writeInt(u64, msg[1..9], request_id, .little);
    @memcpy(msg[9..][0..new_name.len], new_name);
    if (!controlSend(self.control_fd, msg[0 .. 9 + new_name.len], -1)) {
        cl.queueErr("session rename could not reach the broker");
        return;
    }
    self.worker_rename_request = .{ .request_id = request_id, .requester_id = cl.id };
}

fn workerRenameResult(self: *Daemon, payload: []const u8) void {
    if (payload.len < 10) return;
    const request_id = std.mem.readInt(u64, payload[1..9], .little);
    const pending = self.worker_rename_request orelse return;
    if (pending.request_id != request_id) return;
    self.worker_rename_request = null;
    const ok = payload[9] != 0;
    const detail = payload[10..];
    for (self.clients.items) |candidate| {
        if (candidate.id != pending.requester_id or candidate.dead) continue;
        if (ok)
            candidate.queueJson(.ok, .{ .ok = true, .name = detail })
        else
            candidate.queueErr(if (detail.len > 0) detail else "broker refused session rename");
        return;
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
    panel_only: bool = false,
    panel_rpc: u8 = 0,
    identity_first: bool = false,

    pub const WIRE_SIZE: usize = 12;

    /// Append-only broker handoff encoding; old workers ignore tail bytes.
    pub fn encode(self: PassedClient) [WIRE_SIZE]u8 {
        var out: [WIRE_SIZE]u8 = @splat(0);
        out[0] = @truncate(self.proto);
        out[1] = @intFromBool(self.video);
        out[2] = @intFromEnum(self.kind);
        out[3] = self.native_state_max;
        out[4] = self.snapshot_version;
        out[5] = @intFromBool(self.audio_channels);
        out[6] = @intFromBool(self.winstream_channels);
        out[7] = @intFromBool(self.read_only);
        out[8] = @intFromBool(self.want_control);
        out[9] = @intFromBool(self.panel_only);
        out[10] = self.panel_rpc;
        out[11] = @intFromBool(self.identity_first);
        return out;
    }

    /// Decode every historical prefix and default only fields not present.
    pub fn decode(bytes: []const u8) PassedClient {
        const proto: u32 = if (bytes.len >= 1) bytes[0] else 1;
        return .{
            .proto = proto,
            .video = bytes.len >= 2 and bytes[1] != 0,
            .kind = if (bytes.len >= 3) std.enums.fromInt(Client.Kind, bytes[2]) orelse .unknown else .unknown,
            .native_state_max = if (bytes.len >= 4)
                bytes[3]
            else if (proto >= wire.NATIVE_STATE_PROTO_VERSION)
                wire.NATIVE_STATE_VERSION
            else if (proto >= 5)
                wire.LEGACY_NATIVE_STATE_VERSION
            else
                0,
            .snapshot_version = if (bytes.len >= 5)
                bytes[4]
            else if (proto >= 6)
                snapshot.SNAPSHOT_VERSION
            else
                snapshot.LEGACY_SNAPSHOT_VERSION,
            .audio_channels = if (bytes.len >= 6) bytes[5] != 0 else proto >= 5,
            .winstream_channels = if (bytes.len >= 7) bytes[6] != 0 else proto >= wire.WINSTREAM_PROTO_VERSION,
            .read_only = bytes.len >= 8 and bytes[7] != 0,
            .want_control = bytes.len >= 9 and bytes[8] != 0,
            .panel_only = bytes.len >= 10 and bytes[9] != 0,
            .panel_rpc = if (bytes.len >= 11) @min(bytes[10], wire.PANEL_RPC_VERSION) else 0,
            .identity_first = bytes.len >= 12 and bytes[11] != 0,
        };
    }
};

test "broker attach handoff preserves panel-only capability fields" {
    const t = std.testing;
    const original = PassedClient{
        .proto = wire.PROTO_VERSION,
        .video = true,
        .kind = .gui,
        .native_state_max = wire.NATIVE_STATE_VERSION,
        .snapshot_version = snapshot.SNAPSHOT_VERSION,
        .audio_channels = true,
        .winstream_channels = true,
        .read_only = true,
        .want_control = true,
        .panel_only = true,
        .panel_rpc = wire.PANEL_RPC_VERSION,
        .identity_first = true,
    };
    const encoded = original.encode();
    const decoded = PassedClient.decode(&encoded);
    try t.expectEqual(original.proto, decoded.proto);
    try t.expectEqual(original.video, decoded.video);
    try t.expectEqual(original.kind, decoded.kind);
    try t.expectEqual(original.native_state_max, decoded.native_state_max);
    try t.expectEqual(original.snapshot_version, decoded.snapshot_version);
    try t.expectEqual(original.audio_channels, decoded.audio_channels);
    try t.expectEqual(original.winstream_channels, decoded.winstream_channels);
    try t.expectEqual(original.read_only, decoded.read_only);
    try t.expectEqual(original.want_control, decoded.want_control);
    try t.expectEqual(original.panel_only, decoded.panel_only);
    try t.expectEqual(original.panel_rpc, decoded.panel_rpc);
    try t.expectEqual(original.identity_first, decoded.identity_first);

    const historical = PassedClient.decode(encoded[0..9]);
    try t.expect(!historical.panel_only);
    try t.expectEqual(@as(u8, 0), historical.panel_rpc);
    try t.expect(!historical.identity_first);
}

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
        .read_only = req.read_only or req.panel_only,
        .panel_rpc_support = req.panel_rpc,
        .panel_rpc = req.panel_rpc,
        .panel_only = req.panel_only,
    };
    self.next_client_id += 1;
    self.clients.append(self.allocator, cl) catch {
        cl.deinit();
        return;
    };
    if (self.sessions.items.len == 0) return;
    const s = self.sessions.items[0];
    cl.resetAttachmentStreamState();
    cl.attached = s;
    log.info("client attached session='{s}' kind={s} proto={d} video={} panel_only={} panel_rpc={d} (worker handoff)", .{
        s.name, @tagName(req.kind), req.proto, req.video, req.panel_only, req.panel_rpc,
    });
    if (req.panel_only) {
        cl.queueJson(.ok, .{
            .ok = true,
            .panel_only = true,
            .name = s.name,
            .origin_name = s.origin_name,
            .origin_id = &s.origin_id,
        });
        self.broadcastPeerInfo(s);
        return;
    }
    if (req.identity_first and req.panel_rpc > 0 and req.kind == .gui)
        self.queueAttachIdentity(cl, s);
    self.queueSnapshot(cl, s);
    // Cast playback auto-starts once its first viewer arrives.
    self.castOnAttach(s, nowMs());
    if (req.winstream_channels and s.winstream != null) self.openWinstreamChan(s, cl);
    if (req.native_state_max >= wire.LEGACY_NATIVE_STATE_VERSION or req.audio_channels) self.replayNativeChannels(cl, s);
    self.refreshVideoGates();
    _ = self.acquireControl(s, cl, req.want_control);
    self.broadcastControlState(s);
    self.broadcastPeerInfo(s);
}

/// Worst-case 'M' JSON: every audio stream at the metadata string cap
/// with every byte \uXXXX-escaped (6x), plus generous room for the
/// title/cwd/path fields. Derived from the pulse constants so growing
/// either one grows this buffer instead of silently truncating the
/// datagram (a truncated push fails to parse FOREVER — the hash matches
/// so it is never resent).
pub const WORKER_META_BUF: usize =
    dmod.Daemon.MAX_AUDIO_STREAMS * (4 * pulse.META_STRING_MAX * 6 + 256) + 32768;

/// Broker side: read one control datagram from a worker. 'Y' = ready
/// (resolve the deferred spawn `.ok`), 'M' = metadata push; n<=0 means the
/// worker exited (before 'Y' = spawn failed → resolve spawn `.err`).
pub fn brokerOnWorkerControl(self: *Daemon, w: *Worker) void {
    var buf: [WORKER_META_BUF]u8 = undefined;
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
            const ready_ok = if (n > 1) applyWorkerReady(self, w, buf[1..@intCast(n)]) else true;
            w.ready = ready_ok;
            replyPendingSpawn(self, w, ready_ok);
            if (!ready_ok) {
                _ = c.kill(w.pid, c.SIGKILL);
                w.dead = true;
            }
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
            w.xwayland = m.xwayland;
            w.gpu = m.gpu;
            w.output_width = m.output_width;
            w.output_height = m.output_height;
            w.ttl_secs = m.ttl_secs;
            w.viewers = m.viewers;
            w.audio = m.audio;
            w.setAudioInfos(m.audio_streams);
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
            w.setOwned(&w.x_display, m.x);
            w.setOwned(&w.xauthority, m.xa);
        },
        'N' => self.brokerWorkerRename(w, buf[0..@intCast(n)]),
        else => {},
    }
}

/// Adopt a worker's 'Y' ready payload. Parsed DEFENSIVELY: the JSON
/// form is current, a bare decimal pid is what pre-JSON workers
/// sent, and anything else leaves the record untouched (a spawn
/// still succeeds — only the returned paths would be missing).
pub fn applyWorkerReady(self: *Daemon, w: *Worker, payload: []const u8) bool {
    if (payload.len > 0 and payload[0] == '{') {
        var parsed = std.json.parseFromSlice(WorkerReady, self.allocator, payload, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return false;
        defer parsed.deinit();
        if (parsed.value.origin_id.len > 0 and
            (!dmod.validSessionOriginId(parsed.value.origin_id) or
                !std.mem.eql(u8, parsed.value.origin_id, &w.origin_id)))
        {
            w.setOwned(&w.spawn_err, "worker session origin identity mismatch");
            return false;
        }
        w.child_pid = parsed.value.pid;
        w.setOwned(&w.wl_display, parsed.value.wl);
        w.setOwned(&w.pulse_server, parsed.value.pa);
        w.setOwned(&w.runtime_dir, parsed.value.rt);
        w.setOwned(&w.x_display, parsed.value.x);
        w.setOwned(&w.xauthority, parsed.value.xa);
        w.xwayland = parsed.value.xwayland;
        w.gpu = parsed.value.gpu;
        w.output_width = parsed.value.output_width;
        w.output_height = parsed.value.output_height;
        return true;
    }
    w.child_pid = std.fmt.parseInt(i32, payload, 10) catch 0;
    return true;
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
                    .origin_name = w.origin_name,
                    .origin_id = &w.origin_id,
                    .pid = w.child_pid,
                    .wl_display = if (w.wl_display) |p| p else "",
                    .pulse_server = if (w.pulse_server) |p| p else "",
                    .runtime_dir = if (w.runtime_dir) |p| p else "",
                    .xwayland = w.xwayland,
                    .x_display = if (w.x_display) |p| p else "",
                    .xauthority = if (w.xauthority) |p| p else "",
                    .gpu = w.gpu,
                    .output_width = w.output_width,
                    .output_height = w.output_height,
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
    const viewers = self.viewerCount(s);
    const th = std.hash.Wyhash.hash(0, title);
    var ctrl_buf: [32]u8 = undefined;
    const controller = self.controllerLabel(s, &ctrl_buf);
    const ch = std.hash.Wyhash.hash(0, controller);
    const audio = self.sessionAudioRunning(s, null);
    const audio_streams = self.sessionAudioInfos(s, self.allocator);
    defer self.allocator.free(audio_streams);
    var audio_hash: u64 = 0;
    for (audio_streams) |info| {
        audio_hash = std.hash.Wyhash.hash(audio_hash, info.application);
        audio_hash = std.hash.Wyhash.hash(audio_hash, info.binary);
        audio_hash = std.hash.Wyhash.hash(audio_hash, info.media);
        audio_hash = std.hash.Wyhash.hash(audio_hash, info.icon);
        audio_hash = std.hash.Wyhash.hash(audio_hash, std.mem.asBytes(&info.pid));
        audio_hash = std.hash.Wyhash.hash(audio_hash, std.mem.asBytes(&info.running));
    }
    const structural = !self.wpush.inited or
        n_clients != self.wpush.clients or
        viewers != self.wpush.viewers or
        s.exited != self.wpush.exited or
        s.screen.rows != self.wpush.rows or
        s.screen.cols != self.wpush.cols or
        th != self.wpush.title_hash or
        ch != self.wpush.controller_hash or
        audio != self.wpush.audio or
        audio_hash != self.wpush.audio_hash;
    const activity_moved = s.last_activity_ms != self.wpush.activity;
    const now = nowMs();
    if (!structural and !(activity_moved and now - self.wpush.last_push_ms >= 200)) return;

    var cwd: []const u8 = "";
    var scratch: [4096]u8 = undefined;
    if (cwdOfPid(s.childPid(), &scratch)) |cw| cwd = cw;
    const meta = WorkerMeta{
        .rows = s.screen.rows,
        .cols = s.screen.cols,
        .clients = n_clients,
        .exited = s.exited,
        .app = s.app,
        .activity = s.last_activity_ms,
        .child_pid = s.childPid(),
        // Bounded so one JSON datagram stays well under the broker's
        // recv buffer (an over-long datagram is truncated, and on Darwin
        // refused outright once it passes the socket buffer).
        .title = title[0..@min(title.len, 256)],
        .cwd = cwd[0..@min(cwd.len, 1024)],
        .display = s.display,
        .xwayland = s.xwayland != null,
        .gpu = s.gpu,
        .output_width = s.output_width,
        .output_height = s.output_height,
        .ttl_secs = @intCast(@divTrunc(s.ttl_ms, 1000)),
        .viewers = viewers,
        .controller = controller,
        .audio = audio,
        .audio_streams = audio_streams,
        .wl = if (s.wl_display_path) |p| p else "",
        .pa = if (s.pa_socket_path) |p| p else "",
        .rt = if (s.runtime_dir_path) |p| p else "",
        .x = if (s.xwayland) |*xwl| xwl.display_name else "",
        .xa = if (s.xwayland) |*xwl| xwl.auth_path else "",
    };
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    aw.writer.writeByte('M') catch return;
    std.json.Stringify.value(meta, .{}, &aw.writer) catch return;
    _ = controlSend(self.control_fd, aw.written(), -1);

    self.wpush = .{
        .inited = true,
        .clients = n_clients,
        .viewers = viewers,
        .exited = s.exited,
        .rows = s.screen.rows,
        .cols = s.screen.cols,
        .title_hash = th,
        .controller_hash = ch,
        .activity = s.last_activity_ms,
        .audio = audio,
        .audio_hash = audio_hash,
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

/// Send one broker/worker control datagram (+ optional fd). Returns false if
/// the kernel refused it, which for the client-fd handoff is the one case the
/// caller must report rather than swallow.
pub fn controlSend(fd: c_int, bytes: []const u8, pass_fd: c_int) bool {
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
    var flags: c_int = 0;
    if (comptime @hasDecl(c, "MSG_NOSIGNAL")) flags |= c.MSG_NOSIGNAL;
    return c.sendmsg(fd, &mh, flags) == @as(isize, @intCast(bytes.len));
}

/// Construct a worker-mode daemon (no listen socket; clients arrive over
/// `control_fd`). `base_dir` is the runtime dir for the session's Wayland /
/// isolated-rt sockets (the broker's socket dir). The caller spawns the one
/// session and runs the loop.
pub fn initWorker(allocator: std.mem.Allocator, control_fd: c_int, base_dir: []const u8, broker_sock: []const u8) !*Daemon {
    _ = c.fcntl(control_fd, c.F_SETFD, c.FD_CLOEXEC);
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
pub fn runWorker(
    allocator: std.mem.Allocator,
    control_fd: c_int,
    req: SpawnReq,
    origin_id: dmod.SessionOriginId,
    base_dir: []const u8,
    broker_sock: []const u8,
) !void {
    wire.validateTerminalSize(req.rows, req.cols) catch |err| {
        var ebuf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&ebuf, "E{s}", .{@errorName(err)}) catch "E?";
        _ = controlSend(control_fd, msg, -1);
        return err;
    };
    const self = try initWorker(allocator, control_fd, base_dir, broker_sock);
    defer self.deinit();
    // If spawnSession fails, report WHY over the control channel ('E' +
    // error name) before dying — the broker folds it into the deferred
    // spawn `.err` so the client sees the reason, not a generic "spawn
    // failed". Then the caller `_exit`s → control EOF → `.err` sent.
    // On success, signal 'Y' (ready) so the broker sends the spawn
    // `.ok` only once the session truly exists.
    const s = self.spawnSessionWithOrigin(req, origin_id) catch |err| {
        var ebuf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&ebuf, "E{s}", .{@errorName(err)}) catch "E?";
        _ = controlSend(control_fd, msg, -1);
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
            .pid = s.childPid(),
            .wl = if (s.wl_display_path) |p| p else "",
            .pa = if (s.pa_socket_path) |p| p else "",
            .rt = if (s.runtime_dir_path) |p| p else "",
            .x = if (s.xwayland) |*xwl| xwl.display_name else "",
            .xa = if (s.xwayland) |*xwl| xwl.auth_path else "",
            .xwayland = s.xwayland != null,
            .gpu = s.gpu,
            .output_width = s.output_width,
            .output_height = s.output_height,
            .origin_id = &s.origin_id,
        }, .{}, &yaw.writer)) |_| {
            _ = controlSend(control_fd, yaw.written(), -1);
        } else |_| _ = controlSend(control_fd, "Y", -1);
    } else |_| _ = controlSend(control_fd, "Y", -1);
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
    if (n > 0) {
        cl.write_frame_started = true;
        if (cl.write_lane == .normal) cl.normal_bytes_written +|= n;
    }
    const remaining = out.items.len - n;
    std.mem.copyForwards(u8, out.items[0..remaining], out.items[n..]);
    out.shrinkRetainingCapacity(remaining);
    cl.write_frame_left -= n;
    if (cl.write_frame_left == 0) {
        cl.write_lane = .none;
        cl.write_frame_started = false;
    }
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
    // A client whose retry budget ran out is already carrying its
    // give-up notice; `retryPendingSnapshots` drops it once that drains.
    if (fully_drained and cl.needs_resync and !cl.resync_gave_up) {
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
            if (!Daemon.terminalViewer(cl, s)) return;
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
            if (!cl.dead and Daemon.terminalViewer(cl, s)) cl.queueFrame(.native_sync, "");
        }
    }
}

pub fn handleFrame(self: *Daemon, cl: *Client, frame: wire.Frame) void {
    if (cl.proto == 0 and frame.ftype != .hello and frame.ftype != .list and
        !(cl.panel_rpc_support > 0 and (frame.ftype == .attach or frame.ftype == .detach or
            frame.ftype == .panel_request or frame.ftype == .panel_reply)))
    {
        cl.queueErr("no shared terminal profile; daemon and sessions preserved");
        return;
    }
    if (cl.panel_only and frame.ftype != .hello and frame.ftype != .detach and
        frame.ftype != .panel_request and frame.ftype != .panel_reply)
    {
        cl.queueErr("panel-only attachment accepts panel RPC only");
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
                panel_rpc: u8 = 0,
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
                cl.panel_rpc_support = @min(p.value.panel_rpc, wire.PANEL_RPC_VERSION);
                p.deinit();
            } else |_| {}
            cl.queueJson(.welcome, .{
                .proto = cl.proto,
                .daemon_pid = c.getpid(),
                .server_proto = wire.PROTO_VERSION,
                .min_proto = wire.MIN_SERVER_PROTO,
                .negotiation = @as(u8, 1),
                .snapshot = cl.snapshot_version,
                .native_state = cl.native_state_max,
                .audio = cl.audio_channels,
                .winstream = cl.winstream_channels,
                .version = version.string,
                // Build identity (git describe): a client whose own
                // build differs may upgrade-restart this daemon when
                // it is provably idle (Conn.upgradeStaleIdle).
                .build = build_options.commit,
                .audio_opus = opuscodec.available(),
                .video = build_options.video,
                // Capability, not a proto bump: clients must not send
                // udp_ticket_req to daemons that would answer `.err`
                // (misattributable on a multiplexed GUI connection).
                .udp_ticket = true,
                // cross_copy honors delete_src (move) + dial_tries and
                // stamps dial failures kind:"unreachable". Gates both
                // daemon-owned moves and DIRECT remote-to-remote
                // coordination: an old daemon ignoring delete_src
                // would silently turn a move into a copy.
                .cross_move = true,
                // cross_copy is idempotent by client_token and its
                // terminal job survives until an explicit job_ack.
                .durable_copy = true,
                .copy_no_replace = true,
                // Cancellation and final installation are one durable
                // election; canceled no-replace staging is recovered
                // across helper and daemon restarts.
                .durable_copy_v2 = true,
                // Additive JSON display fields plus guarded display-only
                // destruction. New clients must gate those requests because
                // old daemons silently ignore unknown JSON members.
                .display_v2 = true,
                // KillReq.origin_id is enforced before name resolution. A
                // client must gate the additive field on this bit because an
                // older daemon would silently ignore it and kill by name.
                .kill_origin_fence = true,
                // Capability, same reasoning as udp_ticket: an lsp_open
                // toward an old daemon would answer `.err`, which is
                // misattributable on a multiplexed connection — and its
                // absence is exactly the "no server on this host"
                // silent-degradation path the client already has.
                .lsp = true,
                // Cast-playback sessions (SpawnReq.cast_path +
                // play_control). Capability, same reasoning as lsp:
                // an old daemon would `.err` on the unknown frame.
                .cast_playback = true,
                // Correlated native-panel relay. Independent of the
                // terminal profile: future clients may share this feature
                // even when no snapshot/event profile overlaps.
                .panel_rpc = wire.PANEL_RPC_VERSION,
                .attach_identity = true,
                // Daemon-side web store (web_op/web_reply). Capability,
                // same reasoning as lsp: an old daemon would `.err` on
                // the unknown frame, misattributable on a multiplexed
                // connection.
                .web_store = true,
                // Broker-owned headless browser-profile stores (the
                // web_op profile_* family). Capability, same reasoning
                // as web_store — and its ABSENCE is what makes a new
                // client fall back to taking the store flock itself
                // against an old daemon, i.e. the exact pre-existing
                // single-owner behavior.
                .web_profiles = true,
                // Broker-owned browser ENGINE (web_op engine_open):
                // the daemon spawns the instance's sketerm-webengine
                // with the linger lifecycle and answers with its
                // socket path. Capability, same reasoning as
                // web_profiles — absence makes the client spawn the
                // helper itself (the Phase 2 shape).
                .web_engine = true,
                // Arbitrary-host TCP egress with remote DNS
                // (stream_open/stream_reply). Capability, same reasoning
                // as lsp: an old daemon would `.err` on the unknown
                // frame, misattributable on a multiplexed connection.
                .stream_open = true,
                // Remote browser helper (web_helper_open/web_helper_reply).
                // Capability, same reasoning as lsp — and its absence is
                // the "daemon too old for remote browsing" described
                // error the GUI shows instead of hanging.
                .web_helper = true,
            });
        },
        .spawn => self.handleSpawn(cl, frame.payload),
        .attach => self.handleAttach(cl, frame.payload),
        .detach => {
            self.detachClientAttachment(cl, "panel presenter detached after request delivery; delivery is uncertain, the mutation may have applied, and the request was NOT resent");
            cl.queueJson(.ok, .{ .ok = true });
        },
        .control_req => self.handleControlReq(cl, frame.payload),
        .input => {
            if (cl.panel_only) return;
            const s = cl.attached orelse {
                cl.queueErr("not attached");
                return;
            };
            // Cast playback has no child to type at: drop silently.
            const pty = s.ptyPtr() orelse return;
            _ = pty.writeAll(frame.payload);
        },
        .resize => {
            if (cl.panel_only) return;
            const s = cl.attached orelse return;
            // Client geometry must never overwrite a cast's recorded
            // dimensions — only cast resize events change the grid.
            const pty = s.ptyPtr() orelse return;
            if (frame.payload.len < 4) return;
            const rows = std.mem.readInt(u16, frame.payload[0..2], .little);
            const cols = std.mem.readInt(u16, frame.payload[2..4], .little);
            wire.validateTerminalSize(rows, cols) catch {
                // Tagged: an untagged rejection was dropped by the GUI (or
                // charged to an unrelated pending rename/record) and the
                // user just kept a mis-sized grid with no message.
                cl.queueErrFor(wire.TERMINAL_SIZE_PROTOCOL_ERROR, "resize");
                return;
            };
            s.screen.resize(cols, rows) catch return;
            pty.setSize(rows, cols);
            if (s.cast_recorder) |*rec| rec.resize(nowMs(), cols, rows);
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
                    if (!w.dead) _ = controlSend(w.control_fd, "K", -1);
                }
            }
            cl.queueJson(.ok, .{ .ok = true });
            self.running = false;
        },
        .udp_ticket_req => handleUdpTicketReq(self, cl, frame.payload),
        .fs_op => handleFsOp(self, cl, frame.payload),
        // NOT attach-scoped (like fs_op): the web store belongs to the
        // daemon host, served by whichever process owns the connection.
        .web_op => handleWebOp(self, cl, frame.payload),
        .fs_write => handleFsWrite(self, cl, frame.payload),
        .file_open => handleFileOpen(self, cl, frame.payload),
        .file_data => handleFileData(self, cl, frame.payload),
        .file_close => handleFileClose(self, cl, frame.payload),
        .file_get => handleFileGet(self, cl, frame.payload),
        .file_list => handleFileList(self, cl, frame.payload),
        .app_list => handleAppList(self, cl),
        .app_a11y => handleAppA11y(self, cl, frame.payload),
        .app_debug => self.handleAppDebug(cl, frame.payload),
        .rec_start => handleRecStart(self, cl, frame.payload),
        .play_control => self.handlePlayControl(cl, frame.payload),
        .panel_request => self.handlePanelRequest(cl, frame.payload),
        .panel_reply => self.handlePanelReply(cl, frame.payload),
        .search => self.handleSearch(cl, frame.payload),
        .log_get => self.handleLogGet(cl, frame.payload),
        .forward_open => self.handleForward(cl, frame.payload),
        .stream_open => self.handleStream(cl, frame.payload),
        // NOT attach-scoped (like fs_op): served by whichever process
        // owns the client connection — the broker, in broker mode.
        .lsp_open => self.handleLspOpen(cl, frame.payload),
        // NOT attach-scoped either: the helper renders on the daemon's
        // host and belongs to the client connection, not to a session.
        .web_helper_open => self.handleWebHelperOpen(cl, frame.payload),
        .rec_stop => {
            const s = cl.attached orelse {
                cl.queueErr("not attached");
                return;
            };
            if (s.cast_recorder) |*rec| {
                rec.finish();
                s.cast_recorder = null;
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
        // O_CLOEXEC: an upload fd lives across poll-loop ticks while the
        // daemon forks and execs children (PTY spawns, display keepers).
        const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c_uint, 0o644));
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
    const cwd = cwdOfPid(s.childPid(), &cwd_buf) orelse {
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

/// What a client-named path is allowed to be.
const OpenKind = enum {
    file,
    file_or_dir,

    fn admits(kind: OpenKind, mode: c.mode_t) bool {
        const fmt = mode & c.S_IFMT;
        return switch (kind) {
            .file => fmt == c.S_IFREG,
            .file_or_dir => fmt == c.S_IFREG or fmt == c.S_IFDIR,
        };
    }

    fn refusal(kind: OpenKind) []const u8 {
        return switch (kind) {
            .file => "path is not a regular file",
            .file_or_dir => "path is not a regular file or directory",
        };
    }
};

const Opened = union(enum) {
    fd: c_int,
    /// Refused before or after the open; the client gets this text.
    refused: []const u8,
    /// open() failed; the negative return carries errno.
    failed: c_int,
};

/// Opens a client-controlled path so that the open itself is never the
/// hazard. The kind is checked with stat BEFORE open: a device node whose
/// open has side effects (/dev/watchdog arms a reboot on open alone) or a
/// FIFO with no peer is refused unopened, where a post-open check would
/// have opened it first. O_NONBLOCK then keeps a FIFO from parking the
/// daemon's single poll loop should one appear between the two calls,
/// and the fstat on the opened fd refuses anything that is not the
/// inode stat saw -- so a path swapped underneath is never used, only
/// opened once. That one residual open needs O_PATH to close, which the
/// portable libc set lacks; the swapper must already own the directory.
/// A path stat cannot see (ENOENT with O_CREAT, say) goes straight to
/// open and is held to the post-open kind check alone.
fn openChecked(path: [*:0]const u8, oflags: c_int, mode: c.mode_t, kind: OpenKind) Opened {
    var pre: c.struct_stat = undefined;
    const pre_ok = c.stat(path, &pre) == 0;
    if (pre_ok and !kind.admits(pre.st_mode)) return .{ .refused = kind.refusal() };
    const fd = c.open(path, oflags | c.O_CLOEXEC | c.O_NONBLOCK, mode);
    if (fd < 0) return .{ .failed = fd };
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) {
        _ = c.close(fd);
        return .{ .refused = "fstat failed" };
    }
    if (!kind.admits(st.st_mode)) {
        _ = c.close(fd);
        return .{ .refused = kind.refusal() };
    }
    if (pre_ok and (st.st_dev != pre.st_dev or st.st_ino != pre.st_ino)) {
        _ = c.close(fd);
        return .{ .refused = "path changed during open" };
    }
    return .{ .fd = fd };
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
        const cwd = cwdOfPid(s.childPid(), &cwd_buf) orelse {
            fileReply(cl, xfer, "error", 0, "", "cannot determine session directory");
            return;
        };
        break :blk std.fmt.bufPrintZ(&abs_buf, "{s}/{s}", .{ cwd, req_path }) catch {
            fileReply(cl, xfer, "error", 0, "", "path too long");
            return;
        };
    };

    // Client-controlled path: refused by kind before it is ever opened.
    const fd = switch (openChecked(abs.ptr, c.O_RDONLY, 0, .file)) {
        .fd => |fd| fd,
        .refused => |why| {
            fileReply(cl, xfer, "error", 0, "", why);
            return;
        },
        .failed => {
            fileReply(cl, xfer, "error", 0, "", "cannot open file");
            return;
        },
    };
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) {
        _ = c.close(fd);
        fileReply(cl, xfer, "error", 0, "", "fstat failed");
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
    if (s.isCast()) {
        cl.queueErr("cannot record a cast playback session");
        return;
    }
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
    if (s.cast_recorder) |*old| {
        old.finish();
        s.cast_recorder = null;
    }
    s.cast_recorder = cast_rec.Rec.start(
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
            const cwd = cwdOfPid(s.childPid(), &cwd_buf) orelse {
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
    /// The top-level destination must still be absent when installed.
    no_replace: bool = false,
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
    /// preview_stream: encode from this offset (a time seek restarts
    /// the transcode here).
    start_ms: u64 = 0,
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
    /// Stable logical-transfer identity kept across retry attempts:
    /// lets a resubmission adopt (and restart) the failed job that
    /// already owns staged data, instead of minting a fresh job whose
    /// randomized stage can never see it. Old daemons ignore it.
    transfer_token: []const u8 = "",
    /// A logical retry whose only purpose is durable cancellation
    /// recovery. A v2 coordinator arms the old job before restart.
    cancel_requested: bool = false,
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
    /// cross_copy: delete the verified source afterwards (a move).
    delete_src: bool = false,
    /// copy: hash-verify each file after copy (files_verify_copy).
    verify: bool = false,
    /// cross_copy: cap the initial per-side dial attempts (0 = full
    /// budget); direct remote-to-remote attempts fail fast with it.
    dial_tries: u32 = 0,
    /// install: the mtime_ns the client last saw on the destination.
    /// Null means "install unconditionally" (a fresh file, or a
    /// caller that does not guard against concurrent edits).
    expected_mtime_ns: ?i64 = null,
};

/// One change inside an fs_delta. upsert carries `entry`; del only
/// `name`.
pub const FsChange = struct {
    op: []const u8,
    name: []const u8,
    entry: ?fsserve.Entry = null,
};

/// Errno tags whose failure is the LINK or a backing network
/// filesystem dying rather than the filesystem refusing. Only these
/// earn the client's automatic retry; everything else (ACCES, NOENT,
/// NOSPC, IO, ...) answers the same way forever, and only the manual
/// Retry in the client makes sense for it.
const TRANSIENT_ERRNO_TAGS = [_][]const u8{
    "TIMEDOUT",
    "NOTCONN",
    "CONNRESET",
    "CONNREFUSED",
    "CONNABORTED",
    "HOSTUNREACH",
    "HOSTDOWN",
    "NETUNREACH",
    "NETDOWN",
    "NETRESET",
    "PIPE",
};

/// Classify an fs_reply error message by the errno tag it carries
/// (fsserve.errnoName spells failures as bare tags like "ACCES").
pub fn fsErrKind(msg: []const u8) []const u8 {
    for (TRANSIENT_ERRNO_TAGS) |tag| {
        if (hasErrnoToken(msg, tag)) return "transport";
    }
    return "permanent";
}

fn hasErrnoToken(msg: []const u8, tag: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, msg, start, tag)) |idx| : (start = idx + 1) {
        const boundary_before = idx == 0 or !std.ascii.isAlphanumeric(msg[idx - 1]);
        const end = idx + tag.len;
        const boundary_after = end == msg.len or !std.ascii.isAlphanumeric(msg[end]);
        if (boundary_before and boundary_after) return true;
    }
    return false;
}

const FsStatvfs = struct { bsize: u64, frsize: u64, blocks: u64, bfree: u64, bavail: u64, files: u64, ffree: u64, namemax: u64 };

/// musl's `struct statvfs` carries an anonymous bitfield that translate-c
/// turns opaque, so on those targets the (verified, 64-bit LE) layout is
/// declared by hand rather than serving made-up numbers as `bavail = 0`.
const MuslStatvfs = extern struct {
    f_bsize: c_ulong,
    f_frsize: c_ulong,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_favail: u64,
    f_fsid: c_ulong,
    f_flag: c_ulong,
    f_namemax: c_ulong,
    f_type: c_uint,
    __reserved: [5]c_int,
};

fn fsStatvfs(path: [*:0]const u8) ?FsStatvfs {
    if (comptime @typeInfo(c.struct_statvfs) == .@"opaque") {
        comptime {
            if (@sizeOf(c_ulong) != 8 or @import("builtin").cpu.arch.endian() != .little)
                @compileError("hand-declared musl statvfs layout is only verified for 64-bit little-endian targets");
            std.debug.assert(@sizeOf(MuslStatvfs) == 112);
            std.debug.assert(@offsetOf(MuslStatvfs, "f_bavail") == 32);
            std.debug.assert(@offsetOf(MuslStatvfs, "f_namemax") == 80);
        }
        const S = struct {
            extern "c" fn statvfs(path: [*:0]const u8, buf: *MuslStatvfs) c_int;
        };
        var st: MuslStatvfs = undefined;
        if (S.statvfs(path, &st) != 0) return null;
        return .{ .bsize = st.f_bsize, .frsize = st.f_frsize, .blocks = st.f_blocks, .bfree = st.f_bfree, .bavail = st.f_bavail, .files = st.f_files, .ffree = st.f_ffree, .namemax = st.f_namemax };
    }
    var st: c.struct_statvfs = undefined;
    if (c.statvfs(path, &st) != 0) return null;
    return .{ .bsize = st.f_bsize, .frsize = st.f_frsize, .blocks = st.f_blocks, .bfree = st.f_bfree, .bavail = st.f_bavail, .files = st.f_files, .ffree = st.f_ffree, .namemax = st.f_namemax };
}

pub fn fsReplyErr(cl: *Client, req: u32, msg: []const u8) void {
    cl.queueJson(.fs_reply, .{ .req = req, .ok = false, .@"error" = msg, .kind = fsErrKind(msg) });
}

test "openChecked refuses a FIFO and a device node without opening them" {
    const t = std.testing;
    var dir_buf: [64]u8 = undefined;
    @memcpy(dir_buf[0..27], "/tmp/sketerm-openck-XXXXXX\x00");
    const dir = std.mem.span(@as([*:0]u8, @ptrCast(c.mkdtemp(@ptrCast(&dir_buf)) orelse return error.SkipZigTest)));
    var fifo_z: [96]u8 = undefined;
    const fifo = try std.fmt.bufPrintZ(&fifo_z, "{s}/fifo", .{dir});
    var reg_z: [96]u8 = undefined;
    const reg = try std.fmt.bufPrintZ(&reg_z, "{s}/reg", .{dir});
    defer {
        _ = c.unlink(fifo.ptr);
        _ = c.unlink(reg.ptr);
        _ = c.rmdir(dir.ptr);
    }
    try t.expect(c.mkfifo(fifo.ptr, 0o600) == 0);
    // A blocking O_RDONLY open of a writer-less FIFO never returns; the
    // refusal proves the open was never attempted.
    switch (openChecked(fifo.ptr, c.O_RDONLY, 0, .file)) {
        .refused => |why| try t.expectEqualStrings("path is not a regular file", why),
        else => return error.TestUnexpectedResult,
    }
    switch (openChecked(fifo.ptr, c.O_WRONLY, 0, .file)) {
        .refused => {},
        else => return error.TestUnexpectedResult,
    }
    switch (openChecked("/dev/null", c.O_RDONLY, 0, .file_or_dir)) {
        .refused => |why| try t.expectEqualStrings("path is not a regular file or directory", why),
        else => return error.TestUnexpectedResult,
    }
    // A directory is admitted only where the caller allows one.
    switch (openChecked(dir.ptr, c.O_RDONLY, 0, .file)) {
        .refused => {},
        else => return error.TestUnexpectedResult,
    }
    switch (openChecked(dir.ptr, c.O_RDONLY, 0, .file_or_dir)) {
        .fd => |fd| _ = c.close(fd),
        else => return error.TestUnexpectedResult,
    }
    // A regular file that does not exist yet is created (fs_write's
    // O_CREAT shape) and then held to the post-open check.
    switch (openChecked(reg.ptr, c.O_WRONLY | c.O_CREAT, @as(c.mode_t, 0o644), .file)) {
        .fd => |fd| _ = c.close(fd),
        else => return error.TestUnexpectedResult,
    }
    switch (openChecked(reg.ptr, c.O_RDONLY, 0, .file)) {
        .fd => |fd| _ = c.close(fd),
        else => return error.TestUnexpectedResult,
    }
    var missing_z: [96]u8 = undefined;
    const missing = try std.fmt.bufPrintZ(&missing_z, "{s}/missing", .{dir});
    switch (openChecked(missing.ptr, c.O_RDONLY, 0, .file)) {
        .failed => |rc| try t.expect(rc < 0),
        else => return error.TestUnexpectedResult,
    }
}

test "fs_reply errors classify transient link failures as transport" {
    try std.testing.expectEqualStrings("permanent", fsErrKind("ACCES"));
    try std.testing.expectEqualStrings("permanent", fsErrKind("NOENT"));
    try std.testing.expectEqualStrings("permanent", fsErrKind("NOSPC"));
    try std.testing.expectEqualStrings("permanent", fsErrKind("cannot fsync directory parent"));
    try std.testing.expectEqualStrings("transport", fsErrKind("TIMEDOUT"));
    try std.testing.expectEqualStrings("transport", fsErrKind("read failed: CONNRESET"));
    // Tag must stand alone, never match inside a longer word.
    try std.testing.expectEqualStrings("permanent", fsErrKind("file PIPELINE.md is missing"));
}

/// fsync the directory a just-committed mutation changed, so it
/// survives a crash.
///
/// Best-effort BY DESIGN, and the one home for that decision: by the
/// time this runs the rename/mkdir/unlink has already landed and is
/// irrevocable. A filesystem that refuses a directory fsync (FUSE, NFS
/// and CIFS answer EROFS or EINVAL) used to make the reply `ok=false`,
/// which told the client nothing had happened while the operation had
/// in fact succeeded — the client then discarded its undo record and
/// showed "operation failed". `webext/install.zig`'s `syncBase` reached
/// the same conclusion for the same reason.
fn syncParentDir(path: []const u8, what: []const u8) void {
    const parent = std.fs.path.dirname(path) orelse return;
    var dz: [4096]u8 = undefined;
    const dir_z = pathZ(&dz, parent) catch return;
    const dfd = c.open(dir_z, c.O_RDONLY | c.O_DIRECTORY);
    if (dfd < 0) {
        log.info("fs {s}: cannot open '{s}' to fsync it; the change stands but is not yet durable", .{ what, parent });
        return;
    }
    defer _ = c.close(dfd);
    if (c.fsync(dfd) != 0)
        log.info("fs {s}: fsync of '{s}' refused ({s}); the change stands but is not yet durable", .{ what, parent, fsserve.errnoName(@as(c_int, -1)) });
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
    // Screen Recording is the DAEMON's permission, not the GUI's — it
    // is the process that captures — so the GUI has to ask over the
    // wire. Answered before the absolute-path check below: neither
    // verb takes a path.
    if (std.mem.eql(u8, r.op, "screen_perm")) return screenPerm(cl, r, false);
    if (std.mem.eql(u8, r.op, "screen_perm_request")) return screenPerm(cl, r, true);
    if (std.mem.startsWith(u8, r.op, "job_")) return self.fsJobOp(cl, r);
    // Every other verb takes an absolute path — the client resolves
    // ~ and relative input; the daemon never guesses a cwd here.
    if (r.path.len == 0 or r.path[0] != '/') return fsReplyErr(cl, r.req, "path must be absolute");
    // Job verbs are recognised straight off FsJob.Op's tag names, so
    // routing here and the dispatch in fsStartJob cannot drift apart
    // (a hand-maintained duplicate list silently dropped git_status /
    // diff / split / combine / secure_delete into "unknown fs op").
    if (@import("daemon_fsjobs.zig").jobOpFor(r.op) != null)
        return self.fsStartJob(cl, r);

    if (std.mem.eql(u8, r.op, "open_view")) {
        fsOpenView(self, cl, r);
    } else if (std.mem.eql(u8, r.op, "list")) {
        // A refresh of a directory this client also watches gets its
        // snapshot boundary and child counts on that exact view. Old
        // clients omit `view`, so path matching remains the fallback.
        const view: ?*FsView = if (r.view != 0)
            fsViewForRefresh(self, cl, r)
        else for (self.fs_views.items) |v| {
            if (v.client == cl and !v.gone and std.mem.eql(u8, v.path, r.path)) break v;
        } else null;
        _ = fsStartListing(self, cl, r.req, if (view) |v| v.path else r.path, r.attrs, view);
    } else if (std.mem.eql(u8, r.op, "stat")) {
        fsStat(self, cl, r);
    } else if (std.mem.eql(u8, r.op, "read")) {
        fsRead(self, cl, r);
    } else if (std.mem.eql(u8, r.op, "install")) {
        fsInstall(self, cl, r);
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
        // The sidebar's user directories, only those that exist here.
        var body: [8192]u8 = undefined;
        const dirs_body = fsserve.readUserDirsFile(config_home, &body);
        var dir_bufs: [fsserve.user_dirs.len][4096]u8 = undefined;
        var dirs: [fsserve.user_dirs.len]struct { label: []const u8, path: []const u8 } = undefined;
        var ndirs: usize = 0;
        for (fsserve.user_dirs, 0..) |d, i| {
            const p = fsserve.userDirPath(dirs_body, d, home, &dir_bufs[i]) orelse continue;
            // xdg-user-dirs disables a directory by pointing it at "$HOME/".
            if (std.mem.eql(u8, std.mem.trimEnd(u8, p, "/"), std.mem.trimEnd(u8, home, "/"))) continue;
            var z: [4096]u8 = undefined;
            var st: c.struct_stat = undefined;
            const pz = pathZ(&z, p) catch continue;
            if (c.stat(pz, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFDIR) continue;
            dirs[ndirs] = .{ .label = d.label, .path = p };
            ndirs += 1;
        }
        cl.queueJson(.fs_reply, .{
            .req = r.req,
            .ok = true,
            .home = home,
            .cache = cache,
            .templates = templates,
            .dirs = dirs[0..ndirs],
        });
    } else if (std.mem.eql(u8, r.op, "mkdir")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const rc = c.mkdir(p, 0o755);
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        syncParentDir(r.path, "mkdir");
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "rename")) {
        if (r.to.len == 0 or r.to[0] != '/') return fsReplyErr(cl, r.req, "to must be absolute");
        var z1: [4096]u8 = undefined;
        var z2: [4096]u8 = undefined;
        const from = pathZ(&z1, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const to = pathZ(&z2, r.to) catch return fsReplyErr(cl, r.req, "path too long");
        if (r.no_replace) {
            switch (@import("../util/platform.zig").renameNoReplace(from, to)) {
                .ok => {},
                .exists => return fsReplyErr(cl, r.req, "EXIST"),
                .cross_device => return fsReplyErr(cl, r.req, "XDEV"),
                .failed => |err| return fsReplyErr(cl, r.req, @tagName(err)),
            }
        } else {
            const rc = c.rename(from, to);
            if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        }
        syncParentDir(r.path, "rename source");
        syncParentDir(r.to, "rename destination");
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
        syncParentDir(r.path, "delete");
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
        // Client-controlled path, refused by kind BEFORE open (see
        // openChecked): a durability barrier means nothing on a device
        // node or FIFO, and opening one is the hazard. Directories stay
        // allowed because fsyncing one IS the barrier after a rename.
        const fd = switch (openChecked(p, c.O_RDONLY, 0, .file_or_dir)) {
            .fd => |fd| fd,
            .refused => |why| return fsReplyErr(cl, r.req, why),
            .failed => |rc| return fsReplyErr(cl, r.req, fsserve.errnoName(rc)),
        };
        defer _ = c.close(fd);
        const rc = c.fsync(fd);
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "statfs")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const st = fsStatvfs(p) orelse return fsReplyErr(cl, r.req, fsserve.errnoName(-1));
        cl.queueJson(.fs_reply, .{
            .req = r.req,
            .ok = true,
            .bsize = st.bsize,
            .frsize = st.frsize,
            .blocks = st.blocks,
            .bfree = st.bfree,
            .bavail = st.bavail,
            .files = st.files,
            .ffree = st.ffree,
            .namemax = st.namemax,
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

/// Resolve the live view a `list` request names, reviving a parked one.
///
/// @return null when nothing usable resolves, so the caller lists
/// `r.path` viewless and a real errno reaches the client as itself
/// rather than as a misleading "no such view".
fn fsViewForRefresh(self: *Daemon, cl: *Client, r: FsOpReq) ?*FsView {
    for (self.fs_views.items) |v| {
        if (v.client != cl or v.id != r.view) continue;
        if (!v.gone) return v;
        return if (fsReviveView(self, v, r.path)) v else null;
    }
    return null;
}

/// Re-establish a `gone` view against `path`, watch included.
///
/// A view whose directory was deleted keeps a dead inotify watch and
/// never speaks again; refusing every later refresh on it made
/// `rm -rf x && mkdir x` unrecoverable without navigating away, when
/// the request itself carries the path to re-open.
/// @return false when `path` is not a directory now.
fn fsReviveView(self: *Daemon, v: *FsView, path: []const u8) bool {
    var z: [4096]u8 = undefined;
    const pz = pathZ(&z, path) catch return false;
    var real_buf: [4096]u8 = undefined;
    const canon: []const u8 = if (c.realpath(pz, &real_buf)) |rp|
        std.mem.span(@as([*:0]const u8, @ptrCast(rp)))
    else
        return false;
    var dst: c.struct_stat = undefined;
    if (c.stat(@as([*:0]const u8, @ptrCast(real_buf[0..canon.len :0])), &dst) != 0 or
        (dst.st_mode & c.S_IFMT) != c.S_IFDIR) return false;
    const path_owned = self.allocator.dupe(u8, canon) catch return false;

    // The old watch died with the old inode; a fresh one on the new
    // directory is what makes deltas resume. dropFsViewAt's sharing
    // rule applies here too (equal paths share one wd).
    if (v.wd >= 0) {
        var shared = false;
        for (self.fs_views.items) |o| {
            if (o != v and o.wd == v.wd) {
                shared = true;
                break;
            }
        }
        if (!shared) self.fs_watch.remove(v.wd);
        v.wd = -1;
    }
    self.allocator.free(v.path);
    v.path = path_owned;
    // The listing about to start is the new baseline, so any deferred
    // burst (including the gone verdict itself) is stale.
    v.boundary.clear(self.allocator);
    v.gone = false;
    if (self.fs_watch.ensure()) {
        var z2: [4096]u8 = undefined;
        const cz = pathZ(&z2, v.path) catch return true;
        const was_full = self.fs_watch.exhausted;
        v.wd = self.fs_watch.add(cz);
        noteWatchExhaustion(self, was_full, v.path);
    }
    return true;
}

/// Log the MOMENT the watch backend runs out, once. `exhausted` is
/// sticky, so comparing it across a single `add` fires on the
/// transition and never again — an out-of-descriptors daemon must not
/// also drown its own log while a client retries.
fn noteWatchExhaustion(self: *Daemon, was_full: bool, path: []const u8) void {
    if (was_full or !self.fs_watch.exhausted) return;
    log.warn("fs watch backend out of capacity at '{s}': views opened from now on list but do not update", .{path});
}

/// True when this view's watch was REFUSED for want of backend
/// capacity: the listing is real, the deltas will never come, and the
/// client has no way to tell that apart from a directory nobody
/// touches. kqueue spends one descriptor per watch and hits
/// EMFILE/ENFILE; inotify spends a max_user_watches slot and hits
/// ENOSPC. `liveScanDir` reports exactly this condition on a query as
/// `watch_limit`; a view owed the same answer and never got it.
///
/// `Watcher.exhausted` is sticky, so a later view that fails to watch
/// for an unrelated reason is attributed to capacity too. That
/// misnames the cause, never the fact: with `wd < 0` the view is not
/// live either way, which is the part the client acts on.
fn fsViewWatchLimited(self: *Daemon, view: ?*FsView) bool {
    const v = view orelse return false;
    return watchLimited(v.wd, self.fs_watch.exhausted);
}

/// The decision alone, so it can be pinned without a live Daemon.
/// A view that HOLDS a watch is live no matter how exhausted the
/// backend became afterwards — reporting those would cry wolf on
/// every view once one refusal made the flag sticky.
fn watchLimited(wd: c_int, backend_exhausted: bool) bool {
    return wd < 0 and backend_exhausted;
}

test "a view is watch-limited only when it holds no watch AND the backend refused" {
    const t = std.testing;
    // No watch, backend out of capacity: the listing is real, the
    // deltas never come — the one case the client must be told about.
    try t.expect(watchLimited(-1, true));
    // Holds a watch: live, even though `exhausted` is sticky and some
    // OTHER view was refused earlier.
    try t.expect(!watchLimited(3, true));
    try t.expect(!watchLimited(0, true));
    // No watch, backend never refused (no watcher backend at all, or a
    // path-specific failure): not a capacity story, so not this flag.
    try t.expect(!watchLimited(-1, false));
    try t.expect(!watchLimited(3, false));
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
        const was_full = self.fs_watch.exhausted;
        wd = self.fs_watch.add(cz);
        noteWatchExhaustion(self, was_full, canon);
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
    if (!fsStartListing(self, cl, r.req, canon, r.attrs, view))
        dropFsViewAt(self, self.fs_views.items.len - 1);
}

/// Report — and optionally raise the system prompt for — this
/// daemon's Screen Recording grant.
///
/// The GUI cannot answer this itself: `sketerm` and `sketerm-mux` are
/// separate binaries with separate TCC identities, and the capture
/// happens here. Preflighting in the GUI would report the wrong
/// process's permission, which is worse than reporting none.
///
/// `supported=false` off macOS (and on a build without the SCK
/// backend), so the welcome dialog can hide the step entirely rather
/// than show a control that cannot mean anything.
///
/// Note `granted` cannot distinguish "never asked" from "denied" —
/// `CGPreflightScreenCaptureAccess` returns false for both and no
/// public API separates them. The reply says what is true and the UI
/// offers both routes rather than guessing.
fn screenPerm(cl: *Client, r: FsOpReq, do_request: bool) void {
    const wssource = @import("../winstream/source.zig");
    if (comptime !wssource.have_sck) {
        cl.queueJson(.fs_reply, .{
            .req = r.req,
            .ok = true,
            .supported = false,
            .granted = false,
            .adhoc = false,
            .identity_known = false,
        });
        return;
    }
    const sck = @import("../winstream/sck.zig");
    // Requesting BEFORE reading back is deliberate: a first-ever
    // request can be answered by the user while the prompt is up, and
    // reporting the pre-prompt value would look like the click did
    // nothing. It usually still reads false here — TCC applies the
    // grant to the next launch — which is why the dialog tells the
    // user a daemon restart is what makes it live.
    if (do_request) sck.permissionRequest();
    const adhoc = sck.permissionIdentityAdhoc();
    cl.queueJson(.fs_reply, .{
        .req = r.req,
        .ok = true,
        .supported = true,
        .granted = sck.permissionGranted(),
        .adhoc = adhoc orelse false,
        .identity_known = adhoc != null,
        .exe = daemonExePath(),
    });
}

/// This daemon's own executable path, so the dialog can name the
/// binary the user must find in System Settings — with two daemons
/// installed (a dev build and a signed one) the name alone is
/// ambiguous, and picking the wrong row grants nothing.
fn daemonExePath() []const u8 {
    const S = struct {
        var buf: [4096]u8 = undefined;
    };
    return platform.exePath(&S.buf) orelse "sketerm-mux";
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
        if (l.client == v.client and l.view == v) {
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
            l.boundary_open = false;
            l.view = null;
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
pub fn fsStartListing(self: *Daemon, cl: *Client, req: u32, dir_path: []const u8, attr_spec: []const u8, view: ?*FsView) bool {
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
    if (view) |v| {
        v.boundary.begin();
        listing.boundary_open = true;
    }
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
    if (listing.client.dead) {
        closeListingBoundary(self, listing, false);
        return true;
    }
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
                    .watch_limit = fsViewWatchLimited(self, listing.view),
                });
            }
            if (!last) return false;
            closeListingBoundary(self, listing, true);
            if (listing.view == null or listing.dirs.items.len == 0) return true;
            listing.stage = .count;
            return false;
        },
        .count => {
            const view = listing.view orelse return true;
            if (view.gone) return true;
            // Another refresh snapshot for this view is still open.
            // Count upserts are deltas too, so they wait behind it.
            if (view.boundary.active > 0) return false;
            var changes: std.ArrayList(FsChange) = .empty;
            const deadline = nowMs() + COUNT_BATCH_MS;
            var attr_buf: [MAX_ATTR_NAMES][]const u8 = undefined;
            const attrs = splitAttrs(listing.attrs, &attr_buf);
            while (listing.count_idx < listing.dirs.items.len) {
                const e = &listing.dirs.items[listing.count_idx];
                listing.count_idx += 1;
                var z: [4096]u8 = undefined;
                if (fsserve.joinZ(&z, listing.path, e.name)) |full| {
                    const cnt = fsserve.countChildren(full);
                    // Vanished or over the cap: leave it unknown
                    // rather than upsert a stale entry back to life.
                    if (cnt >= 0) {
                        // The entry may have changed while snapshots
                        // streamed. Re-stat so a late count cannot
                        // overwrite a newer watch delta with old metadata.
                        if (fsserve.statEntryAttrs(a, listing.path, e.name, attrs, true)) |fresh| {
                            var counted = fresh;
                            counted.children = if (counted.tdir) cnt else -1;
                            changes.append(a, .{ .op = "upsert", .name = counted.name, .entry = counted }) catch break;
                        }
                    }
                } else |_| {}
                if (nowMs() >= deadline) break;
            }
            if (changes.items.len > 0)
                listing.client.queueJson(.fs_delta, .{ .view = view.id, .changes = changes.items });
            return listing.count_idx == listing.dirs.items.len;
        },
    }
}

fn closeListingBoundary(self: *Daemon, listing: *dmod.FsListing, flush: bool) void {
    if (!listing.boundary_open) return;
    listing.boundary_open = false;
    const view = listing.view orelse return;
    if (!view.boundary.finish()) return;
    if (flush) {
        flushFsViewBoundary(view);
    } else {
        view.boundary.clear(self.allocator);
    }
}

/// Emit the current state of every name touched while snapshots were active.
fn flushFsViewBoundary(view: *FsView) void {
    const allocator = view.allocator;
    defer view.boundary.clear(allocator);
    if (view.boundary.gone) {
        view.gone = true;
        view.client.queueJson(.fs_delta, .{
            .view = view.id,
            .gone = true,
            .changes = &[_]FsChange{},
        });
        return;
    }
    if (view.boundary.resync) {
        view.client.queueJson(.fs_delta, .{
            .view = view.id,
            .resync = true,
            .changes = &[_]FsChange{},
        });
        return;
    }
    if (view.boundary.names.items.len == 0) return;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var changes: std.ArrayList(FsChange) = .empty;
    var attr_buf: [MAX_ATTR_NAMES][]const u8 = undefined;
    const attrs = splitAttrs(view.attrs, &attr_buf);
    for (view.boundary.names.items) |name| {
        if (fsserve.statEntryAttrs(arena, view.path, name, attrs, true)) |entry| {
            changes.append(arena, .{ .op = "upsert", .name = entry.name, .entry = entry }) catch {
                view.client.queueJson(.fs_delta, .{ .view = view.id, .resync = true, .changes = &[_]FsChange{} });
                return;
            };
        } else {
            changes.append(arena, .{ .op = "del", .name = name }) catch {
                view.client.queueJson(.fs_delta, .{ .view = view.id, .resync = true, .changes = &[_]FsChange{} });
                return;
            };
        }
    }
    if (changes.items.len > 0)
        view.client.queueJson(.fs_delta, .{ .view = view.id, .changes = changes.items });
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
    // Remote-controlled path, refused by kind before open (openChecked).
    const fd = switch (openChecked(p, c.O_RDONLY, 0, .file)) {
        .fd => |fd| fd,
        .refused => |why| return fsReplyErr(cl, r.req, why),
        .failed => |rc| return fsReplyErr(cl, r.req, fsserve.errnoName(rc)),
    };
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
    // Deliberately NO second stat: a file growing under the reader (a live
    // log is the common case) must still answer with the bytes that were
    // read. Callers that need one identity across a MULTI-range read compare
    // the mtime/ino below themselves — panel asset hydration does exactly
    // that in Terminal.handleRemoteFileReply.
    cl.queueFrame(.fs_data, buf[0 .. 12 + got]);
    if (std.mem.startsWith(u8, r.path, fsjob.SPOOL_PREFIX)) daemon_fsjobs.spoolNoteRead(self, r.path, r.off + got);
    cl.queueJson(.fs_reply, .{
        .req = r.req,
        .ok = true,
        .size = size,
        .eof = r.off + got >= size,
        // Identity of the bytes just handed out, taken from the SAME
        // fd they were read through: an editor that stats separately
        // races a writer between the two calls.
        .mtime_ns = fsserve.mtimeNs(&st),
        .ino = @as(u64, @intCast(st.st_ino)),
    });
}

/// Fresh single-path stat as a wire Entry, for replies that hand the
/// client its next baseline. Null when the path cannot be stat'ed.
fn entryAt(arena: std.mem.Allocator, path: []const u8) ?fsserve.Entry {
    const base = std.fs.path.basename(path);
    if (base.len == 0) return fsserve.statEntry(arena, "/", ".");
    return fsserve.statEntry(arena, std.fs.path.dirname(path) orelse "/", base);
}

/// Atomic save: install the staged regular file `path` over `to`.
///
/// The destination's permission bits and ownership are inherited (a
/// save must not turn a 0755 script into a 0644 one), the staged file
/// is fsynced before the rename and the destination's parent
/// directory after it, and a destination whose mtime_ns no longer
/// matches `expected_mtime_ns` is refused as `conflict` with a fresh
/// entry so the caller can show the external change. Every failure
/// after the staged-file check leaves the temp in place — the caller
/// owns it and cleans up.
pub fn fsInstall(self: *Daemon, cl: *Client, r: FsOpReq) void {
    if (r.to.len == 0 or r.to[0] != '/') return fsReplyErr(cl, r.req, "to must be absolute");
    var z1: [4096]u8 = undefined;
    var z2: [4096]u8 = undefined;
    const tmp = pathZ(&z1, r.path) catch return fsReplyErr(cl, r.req, "staged path too long");
    const dest = pathZ(&z2, r.to) catch return fsReplyErr(cl, r.req, "destination path too long");

    var tst: c.struct_stat = undefined;
    if (c.lstat(tmp, &tst) != 0) return fsReplyErr(cl, r.req, "staged file missing");
    if ((tst.st_mode & c.S_IFMT) != c.S_IFREG)
        return fsReplyErr(cl, r.req, "staged path is not a regular file");

    var dst: c.struct_stat = undefined;
    const dest_exists = c.stat(dest, &dst) == 0;
    if (dest_exists) {
        if (r.expected_mtime_ns) |want| {
            if (fsserve.mtimeNs(&dst) != want) {
                var arena_state = std.heap.ArenaAllocator.init(self.allocator);
                defer arena_state.deinit();
                cl.queueJson(.fs_reply, .{
                    .req = r.req,
                    .ok = false,
                    .@"error" = "conflict",
                    .entry = entryAt(arena_state.allocator(), r.to),
                });
                return;
            }
        }
    }

    // One fd serves both the metadata inheritance and the durability
    // barrier; fchmod/fchown need ownership, not write access.
    const fd = c.open(tmp, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return fsReplyErr(cl, r.req, "cannot open staged file");
    if (dest_exists) {
        _ = c.fchmod(fd, @intCast(dst.st_mode & 0o7777));
        // EPERM is the normal answer for an unprivileged daemon; a
        // save must not fail because it could not also move owners.
        _ = c.fchown(fd, dst.st_uid, dst.st_gid);
    }
    const sync_rc = c.fsync(fd);
    _ = c.close(fd);
    if (sync_rc != 0) return fsReplyErr(cl, r.req, "cannot fsync staged file");

    const rc = c.rename(tmp, dest);
    if (rc != 0) {
        var msg: [96]u8 = undefined;
        const text = std.fmt.bufPrint(&msg, "install rename failed: {s}", .{
            fsserve.errnoName(rc),
        }) catch "install rename failed";
        return fsReplyErr(cl, r.req, text);
    }

    const parent = std.fs.path.dirname(r.to) orelse return fsReplyErr(cl, r.req, "destination has no parent");
    var dz: [4096]u8 = undefined;
    const dfd = c.open(
        pathZ(&dz, parent) catch return fsReplyErr(cl, r.req, "destination parent path too long"),
        c.O_RDONLY | c.O_DIRECTORY,
    );
    if (dfd < 0) return fsReplyErr(cl, r.req, "cannot open destination parent");
    defer _ = c.close(dfd);
    if (c.fsync(dfd) != 0) return fsReplyErr(cl, r.req, "cannot fsync destination parent");

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const e = entryAt(arena_state.allocator(), r.to) orelse
        return fsReplyErr(cl, r.req, "installed but stat failed");
    cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true, .entry = e });
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

    // Client-controlled path, refused by kind BEFORE open (see openChecked):
    // an existing device node or FIFO never gets the daemon's open, let
    // alone its writes. O_CREAT makes a regular file, so a path stat
    // cannot see is created and then held to the post-open check. The
    // O_NONBLOCK openChecked adds cannot reach the write loop as a
    // spurious EAGAIN: only regular files survive the kind check, and
    // the flag has no effect on their read/write.
    var oflags: c_int = c.O_WRONLY;
    if (flags & 1 != 0) oflags |= c.O_CREAT;
    if (flags & 2 != 0) oflags |= c.O_TRUNC;
    if (flags & 4 != 0) oflags |= c.O_APPEND;
    if (flags & 8 != 0) oflags |= c.O_EXCL;
    var z: [4096]u8 = undefined;
    const p = pathZ(&z, path) catch return fsReplyErr(cl, req, "path too long");
    const fd = switch (openChecked(p, oflags, @as(c.mode_t, 0o644), .file)) {
        .fd => |fd| fd,
        .refused => |why| return fsReplyErr(cl, req, why),
        .failed => |rc| return fsReplyErr(cl, req, fsserve.errnoName(rc)),
    };
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
        const n = self.fs_watch.readInto(&buf);
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
        // A streamed snapshot is an older baseline. Keep every watch
        // verdict behind all overlapping snapshots for this view;
        // flushFsViewBoundary re-stats the bounded name set after the
        // matching final reply has been queued.
        if (pv.view.boundary.active > 0) {
            if (pv.gone) {
                pv.view.boundary.markGone(self.allocator);
            } else if (pv.resync) {
                pv.view.boundary.markResync(self.allocator);
            } else {
                for (pv.changes.items) |change|
                    pv.view.boundary.deferName(self.allocator, change.name);
            }
        } else if (pv.gone) {
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

// === Web store (web_op / web_reply) ============================
// Browsing history, bookmarks and per-site settings persisted on THIS
// daemon's host ($XDG_STATE_HOME/sketerm/web) — a GUI attached to a
// remote daemon sees that host's browsing state. All verbs are bounded
// inline work in the poll loop. NOT attach-scoped: served by whichever
// process owns the client connection (the broker, in broker mode).

pub const WebOpReq = struct {
    req: u32 = 0,
    op: []const u8 = "",
    /// profile_* ops: the MCP instance key whose store the op names
    /// ("" = the anonymous store). Client-sent, same-user trust domain
    /// (the store root is 0700); the daemon's own socket already scopes
    /// which clients can reach it at all.
    instance: []const u8 = "",
    url: []const u8 = "",
    title: []const u8 = "",
    /// history_query search text ("" = overall top entries).
    q: []const u8 = "",
    /// history_query result bound (0 = default 20, hard cap 200).
    max: u32 = 0,
    /// bookmark_remove/bookmark_update target.
    id: u64 = 0,
    /// Absent = leave a bookmark's folder alone; "" moves it back to
    /// the top level. Optional rather than "" -meaning-unchanged so
    /// that "no folder" stays expressible.
    folder: ?[]const u8 = null,
    /// bookmark_update reorder destination.
    index: ?u32 = null,
    origin: []const u8 = "",
    zoom_x100: ?i32 = null,
    popup: ?[]const u8 = null,
    block: ?bool = null,
    block_clear: bool = false,
    perm: []const u8 = "",
    decision: []const u8 = "",
    /// userscript_add display name.
    name: []const u8 = "",
    /// userscript_add raw source / userstyle_set CSS carrier.
    source: []const u8 = "",
    /// userscript_enable / userstyle_set enabled flag.
    enabled: ?bool = null,
    /// userstyle host key ("" = every page — which is why this is not
    /// `origin`: an empty origin is invalid there).
    host: []const u8 = "",
    css: []const u8 = "",
    /// container_update/remove target, and the container a
    /// container_site_set rule points at (0 clears the rule).
    container: u32 = 0,
    /// container_add stable jar key ("" = seed it from `name`).
    jar: []const u8 = "",
    /// Container accent as 0xRRGGBB; absent leaves it alone.
    color: ?u32 = null,
    /// Container default route in `web/route.zig`'s text grammar;
    /// absent leaves it alone, "" clears it to direct.
    route: ?[]const u8 = null,
};

fn rgbFromU32(v: u32) [3]u8 {
    return .{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
}

fn webReplyErr(cl: *Client, req: u32, msg: []const u8) void {
    cl.queueJson(.web_reply, .{ .req = req, .ok = false, .@"error" = msg });
}

/// The daemon's web store, opened on first use (missing files are an
/// empty store; an unresolvable state dir fails each op, not the daemon).
fn webStore(self: *Daemon) ?*webstore.WebStore {
    if (self.web_store == null) {
        const dir = webstore.defaultDirAlloc(self.allocator) catch return null;
        defer self.allocator.free(dir);
        self.web_store = webstore.WebStore.init(self.allocator, dir) catch return null;
    }
    return &self.web_store.?;
}

pub fn handleWebOp(self: *Daemon, cl: *Client, payload: []const u8) void {
    const parsed = std.json.parseFromSlice(WebOpReq, self.allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch {
        cl.queueErr("bad web_op");
        return;
    };
    defer parsed.deinit();
    const r = parsed.value;
    // The profile family has its own store (per instance, flock-held);
    // routing it first keeps the history/bookmark store untouched for
    // clients that only ever do profile work.
    if (std.mem.startsWith(u8, r.op, "profile_")) return handleWebProfileOp(self, cl, r);
    if (std.mem.eql(u8, r.op, "engine_open")) return handleWebEngineOpen(self, cl, r);
    const store = webStore(self) orelse return webReplyErr(cl, r.req, "web store unavailable");

    if (std.mem.eql(u8, r.op, "history_add")) {
        store.addVisit(r.url, r.title, wallMs()) catch return webReplyErr(cl, r.req, "history write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "history_title")) {
        store.setTitle(r.url, r.title) catch return webReplyErr(cl, r.req, "history write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "history_query")) {
        const max: usize = if (r.max == 0) 20 else @min(r.max, 200);
        const hits = store.query(self.allocator, r.q, max, wallMs()) catch
            return webReplyErr(cl, r.req, "query failed");
        defer self.allocator.free(hits);
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .hits = hits });
    } else if (std.mem.eql(u8, r.op, "history_delete")) {
        const removed = store.deleteUrl(r.url) catch return webReplyErr(cl, r.req, "history write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .removed = removed });
    } else if (std.mem.eql(u8, r.op, "history_clear")) {
        store.clearHistory() catch return webReplyErr(cl, r.req, "history write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "bookmark_add")) {
        const id = store.bookmarkAdd(r.url, r.title, r.folder orelse "") catch
            return webReplyErr(cl, r.req, "bookmark write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .id = id });
    } else if (std.mem.eql(u8, r.op, "bookmark_remove")) {
        const removed = store.bookmarkRemove(r.id) catch
            return webReplyErr(cl, r.req, "bookmark write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .removed = removed });
    } else if (std.mem.eql(u8, r.op, "bookmark_update")) {
        // An empty url/title means "leave unchanged" — a bookmark with
        // neither is cleared by removing it, not by blanking fields.
        // `folder` is the exception: an ABSENT folder is unchanged and
        // an empty one is the top level, which a bookmark must be able
        // to move back to.
        const found = store.bookmarkUpdate(r.id, .{
            .url = if (r.url.len > 0) r.url else null,
            .title = if (r.title.len > 0) r.title else null,
            .folder = r.folder,
            .index = if (r.index) |i| i else null,
        }) catch return webReplyErr(cl, r.req, "bookmark write failed");
        if (!found) return webReplyErr(cl, r.req, "no such bookmark");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "bookmark_list")) {
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .bookmarks = store.bookmarks.items });
    } else if (std.mem.eql(u8, r.op, "site_get")) {
        if (store.siteGet(r.origin)) |site| {
            cl.queueJson(.web_reply, .{
                .req = r.req,
                .ok = true,
                .origin = r.origin,
                .site = .{
                    .zoom_x100 = site.zoom_x100,
                    .popup = site.popup,
                    .block = site.block,
                    .perms = site.perms.items,
                },
            });
        } else {
            cl.queueJson(.web_reply, .{
                .req = r.req,
                .ok = true,
                .origin = r.origin,
                .site = @as(?u8, null),
            });
        }
    } else if (std.mem.eql(u8, r.op, "site_set")) {
        store.siteSet(r.origin, .{
            .zoom_x100 = r.zoom_x100,
            .popup = r.popup,
            .block = r.block,
            .block_clear = r.block_clear,
            .perm = r.perm,
            .decision = r.decision,
        }) catch return webReplyErr(cl, r.req, "site write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "userscript_add")) {
        const id = store.userscriptAdd(r.name, r.source) catch
            return webReplyErr(cl, r.req, "userscript write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .id = id });
    } else if (std.mem.eql(u8, r.op, "userscript_remove")) {
        const removed = store.userscriptRemove(r.id) catch
            return webReplyErr(cl, r.req, "userscript write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .removed = removed });
    } else if (std.mem.eql(u8, r.op, "userscript_enable")) {
        const found = store.userscriptEnable(r.id, r.enabled orelse true) catch
            return webReplyErr(cl, r.req, "userscript write failed");
        if (!found) return webReplyErr(cl, r.req, "no such userscript");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "userscript_list")) {
        // Sources included: the GUI pushes them whole to the helper.
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .scripts = store.userscripts.items });
    } else if (std.mem.eql(u8, r.op, "userstyle_set")) {
        store.userstyleSet(r.host, r.css, r.enabled orelse true) catch
            return webReplyErr(cl, r.req, "userstyle write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "userstyle_get")) {
        if (store.userstyleGet(r.host)) |style| {
            cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .style = style.* });
        } else {
            cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .style = @as(?u8, null) });
        }
    } else if (std.mem.eql(u8, r.op, "userstyle_list")) {
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .styles = store.userstyles.items });
    } else if (std.mem.eql(u8, r.op, "container_list")) {
        // Containers and their site rules travel together: a rule is
        // meaningless without the container it names, and the GUI
        // resolves both in one pass at startup.
        cl.queueJson(.web_reply, .{
            .req = r.req,
            .ok = true,
            .containers = store.containers.items,
            .sites = store.container_sites.items,
        });
    } else if (std.mem.eql(u8, r.op, "container_add")) {
        const id = store.containerAdd(
            r.name,
            r.jar,
            rgbFromU32(r.color orelse 0),
            r.route orelse "",
        ) catch |err| return webReplyErr(cl, r.req, switch (err) {
            error.BadContainer => "a container needs a name and a route of direct | tor | via:<host> | on:<host>",
            else => "container write failed",
        });
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .id = id });
    } else if (std.mem.eql(u8, r.op, "container_update")) {
        const found = store.containerUpdate(r.container, .{
            .name = if (r.name.len != 0) r.name else null,
            .color = if (r.color) |v| rgbFromU32(v) else null,
            .route = r.route,
        }) catch |err| return webReplyErr(cl, r.req, switch (err) {
            error.BadContainer => "a container route is direct | tor | via:<host> | on:<host>",
            else => "container write failed",
        });
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .found = found });
    } else if (std.mem.eql(u8, r.op, "container_remove")) {
        const removed = store.containerRemove(r.container) catch
            return webReplyErr(cl, r.req, "container write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .found = removed });
    } else if (std.mem.eql(u8, r.op, "container_site_set")) {
        store.containerSiteSet(r.host, r.container) catch |err| return webReplyErr(cl, r.req, switch (err) {
            error.NoSuchContainer => "no such container",
            error.BadContainer => "bad host",
            else => "container write failed",
        });
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true });
    } else {
        webReplyErr(cl, r.req, "unknown web op");
    }
}

// === Broker-owned browser-profile stores (web_op profile_*) =========
// The headless browser-profile store (jars + profiles.json + the
// exclusivity flock) is owned by THIS daemon rather than by any one
// MCP client, so N concurrent clients of one instance all resolve the
// same (name -> id) table and the second is no longer refused with
// "another sketerm mcp process owns the browser profile store". The
// flock is held for the daemon's lifetime; a client asks for ids and
// receives the store ROOT path to hand the helper as --cache-dir
// (same host by construction — this daemon spawned next to its
// clients' instance dir).

/// The store for `instance`, opened on first use and kept. On refusal
/// the reason is written to `err_out` and null returned.
fn webProfileStore(self: *Daemon, instance: []const u8, err_out: *[]const u8) ?*webprofiles.Store {
    if (self.isWorker()) {
        // A worker only ever owns fds passed to it AFTER attach; the
        // store must live in the one process that outlives clients.
        err_out.* = "browser profile ops are served by the broker, not a session worker";
        return null;
    }
    for (self.web_profile_stores.items) |*nps| {
        if (std.mem.eql(u8, nps.key, instance)) return &nps.store;
    }
    var holder: c.pid_t = 0;
    const inst: ?[]const u8 = if (instance.len == 0) null else instance;
    const store = webprofiles.Store.open(self.allocator, inst, &holder) catch |err| {
        err_out.* = switch (err) {
            // Another PROCESS holds this root (an old-build MCP client
            // flocking it itself, or a second daemon addressed at the
            // same instance key). The client's fallback path then shows
            // its own refusal sentence naming the pid.
            error.Locked => "the browser profile store is owned by another process",
            error.NoStateDir => "no state directory to keep browser profiles in (neither XDG_STATE_HOME nor HOME is set)",
            error.PathTooLong => "the browser profile store path is too long for the browser helper's cache-path limit (use a shorter XDG_STATE_HOME)",
            error.Io, error.OutOfMemory => "the browser profile store could not be created (check permissions on XDG_STATE_HOME/sketerm)",
        };
        return null;
    };
    const key = self.allocator.dupe(u8, instance) catch {
        var dead = store;
        dead.deinit();
        err_out.* = "out of memory";
        return null;
    };
    self.web_profile_stores.append(self.allocator, .{ .key = key, .store = store }) catch {
        self.allocator.free(key);
        var dead = store;
        dead.deinit();
        err_out.* = "out of memory";
        return null;
    };
    return &self.web_profile_stores.items[self.web_profile_stores.items.len - 1].store;
}

fn handleWebProfileOp(self: *Daemon, cl: *Client, r: WebOpReq) void {
    var why: []const u8 = "";
    const store = webProfileStore(self, r.instance, &why) orelse
        return webReplyErr(cl, r.req, why);

    if (std.mem.eql(u8, r.op, "profile_open")) {
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .root = store.root });
    } else if (std.mem.eql(u8, r.op, "profile_ensure")) {
        const id = store.ensure(r.name) catch |err| return webReplyErr(cl, r.req, switch (err) {
            error.BadName => "invalid profile name",
            error.Io, error.OutOfMemory => "the browser profile store could not be written",
        });
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .id = id, .root = store.root });
    } else if (std.mem.eql(u8, r.op, "profile_list")) {
        const Row = struct { name: []const u8, id: u32, created_ms: i64, last_used_ms: i64 };
        var rows: std.ArrayList(Row) = .empty;
        defer rows.deinit(self.allocator);
        for (store.list()) |e| {
            rows.append(self.allocator, .{
                .name = e.name,
                .id = e.id,
                .created_ms = e.created_ms,
                .last_used_ms = e.last_used_ms,
            }) catch return webReplyErr(cl, r.req, "out of memory");
        }
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .root = store.root, .profiles = rows.items });
    } else if (std.mem.eql(u8, r.op, "profile_touch")) {
        store.touch(r.name, wallMs());
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "profile_retire")) {
        const prior = store.find(r.name);
        const removed = store.retire(r.name) catch |err| return webReplyErr(cl, r.req, switch (err) {
            error.BadName => "invalid profile name",
            error.Io, error.OutOfMemory => "the browser profile store could not be written",
        });
        cl.queueJson(.web_reply, .{
            .req = r.req,
            .ok = true,
            .removed = removed,
            .id = if (prior) |e| e.id else 0,
        });
    } else {
        webReplyErr(cl, r.req, "unknown web profile op");
    }
}

// === Broker-owned browser engine (web_op engine_open) ===============
// Phase 3 of the broker-owned-engine work: the daemon SPAWNS the
// instance's sketerm-webengine (with `--linger-ms`, so it survives its
// last client and reaps ITSELF through the graceful drain — the only
// path that reliably flushes profile jars) and answers with the
// engine's listening socket path. The daemon never relays a web byte:
// clients connect to that socket directly, exactly as they always
// connected to a sibling-spawned helper. Refcounting is deliberately
// absent — the engine's own connection count is the ground truth, and
// a client that crashes needs no bookkeeping to be forgotten.

/// How long a broker-owned engine keeps listening after its LAST
/// client disconnects. Overridable for the smoke rigs; the default
/// keeps a warm engine (and its logged-in profiles) across the gap
/// between one assistant task and the next.
fn engineLingerMs() i64 {
    const v = c.getenv("SKETERM_WEB_LINGER_MS") orelse return 180_000;
    const s = std.mem.span(@as([*:0]const u8, @ptrCast(v)));
    return std.fmt.parseInt(i64, s, 10) catch 180_000;
}

/// The instance key this daemon serves, derived from its own socket
/// (`.../mcp-<name>/mux.sock`); null for the per-user default daemon
/// and ephemeral `mcp-tmp-<pid>` instances, which host no engine.
fn selfInstanceKey(self: *Daemon) ?[]const u8 {
    const dir_end = std.mem.lastIndexOfScalar(u8, self.sock_path, '/') orelse return null;
    const dir = self.sock_path[0..dir_end];
    const base_start = (std.mem.lastIndexOfScalar(u8, dir, '/') orelse return null) + 1;
    const base = dir[base_start..];
    if (!std.mem.startsWith(u8, base, "mcp-")) return null;
    if (std.mem.startsWith(u8, base, "mcp-tmp-")) return null;
    return base["mcp-".len..];
}

/// Reap engines that exited on their own (the linger TTL); called
/// before every use so a dead entry never masks a needed spawn.
fn sweepWebEngines(self: *Daemon) void {
    var i: usize = 0;
    while (i < self.web_engines.items.len) {
        const e = self.web_engines.items[i];
        var status: c_int = 0;
        if (c.waitpid(e.pid, &status, c.WNOHANG) == e.pid) {
            removePresenceAt(e.sock);
            self.allocator.free(e.key);
            self.allocator.free(e.sock);
            _ = self.web_engines.swapRemove(i);
            continue;
        }
        i += 1;
    }
}

/// A connect probe: someone is accepting on this engine socket.
fn engineSocketLive(sock: []const u8) bool {
    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    if (sock.len + 1 > addr.sun_path.len) return false;
    addr.sun_family = c.AF_UNIX;
    @memcpy(addr.sun_path[0..sock.len], sock);
    const fd = @import("../util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    return c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) == 0;
}

/// Unlink the `web.json` presence file next to an engine socket.
fn removePresenceAt(sock: []const u8) void {
    const dir_end = std.mem.lastIndexOfScalar(u8, sock, '/') orelse return;
    var z: [4096:0]u8 = undefined;
    const p = std.fmt.bufPrintZ(&z, "{s}/web.json", .{sock[0..dir_end]}) catch return;
    _ = c.unlink(p.ptr);
}

fn handleWebEngineOpen(self: *Daemon, cl: *Client, r: WebOpReq) void {
    if (self.isWorker())
        return webReplyErr(cl, r.req, "browser engine ops are served by the broker, not a session worker");
    const key = selfInstanceKey(self) orelse
        return webReplyErr(cl, r.req, "this daemon hosts no browser engine (not a named MCP instance daemon)");
    if (r.instance.len != 0 and !std.mem.eql(u8, r.instance, key))
        return webReplyErr(cl, r.req, "engine_open named a different instance than this daemon serves");

    sweepWebEngines(self);
    var sock_buf: [4096]u8 = undefined;
    const dir_end = std.mem.lastIndexOfScalar(u8, self.sock_path, '/') orelse
        return webReplyErr(cl, r.req, "unresolvable instance dir");
    const sock = std.fmt.bufPrint(&sock_buf, "{s}/web.sock", .{self.sock_path[0..dir_end]}) catch
        return webReplyErr(cl, r.req, "engine socket path too long");

    for (self.web_engines.items) |e| {
        if (std.mem.eql(u8, e.key, key)) {
            cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .sock = e.sock, .pid = e.pid, .spawned = false });
            return;
        }
    }

    // An engine THIS broker did not spawn may still be listening — a
    // predecessor broker's lingering engine (brokers idle-exit; their
    // engines deliberately outlive them), or an old client-spawned
    // helper. Spawning beside it would collide two CEF processes on
    // one root; hand out the live socket instead.
    if (engineSocketLive(sock)) {
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .sock = sock, .pid = @as(c.pid_t, 0), .spawned = false });
        return;
    }

    // The engine's --cache-dir must BE the profile store root, so the
    // store is opened (and its flock taken by THIS daemon) first.
    var why: []const u8 = "";
    const store = webProfileStore(self, key, &why) orelse return webReplyErr(cl, r.req, why);

    var bin_buf: [4096:0]u8 = undefined;
    const bin = webfindbin.find(&bin_buf) orelse
        return webReplyErr(cl, r.req, "sketerm-webengine is not installed on this host");

    // NUL-terminated argv, prepared before the fork.
    var sock_z: [4096:0]u8 = undefined;
    const sock_arg = std.fmt.bufPrintZ(&sock_z, "{s}", .{sock}) catch
        return webReplyErr(cl, r.req, "engine socket path too long");
    var cache_z: [4096:0]u8 = undefined;
    const cache_arg = std.fmt.bufPrintZ(&cache_z, "{s}", .{store.root}) catch
        return webReplyErr(cl, r.req, "engine cache path too long");
    var linger_z: [24:0]u8 = undefined;
    const linger_arg = std.fmt.bufPrintZ(&linger_z, "{d}", .{engineLingerMs()}) catch unreachable;

    // A stale socket from a crashed engine would make clients connect
    // against nothing; the daemon's single loop serializes this unlink
    // against every sibling engine_open.
    _ = c.unlink(sock_arg.ptr);

    const pid = c.fork();
    if (pid < 0) return webReplyErr(cl, r.req, "fork failed");
    if (pid == 0) {
        // Own process group so a future teardown can take CEF's whole
        // subprocess tree; stdio to /dev/null (CEF noise), like the
        // remote-helper spawn above.
        _ = c.setpgid(0, 0);
        const devnull = c.open("/dev/null", c.O_RDWR);
        if (devnull >= 0) {
            _ = c.dup2(devnull, 0);
            _ = c.dup2(devnull, 1);
            _ = c.dup2(devnull, 2);
            if (devnull > 2) _ = c.close(devnull);
        }
        var argv: [8:null]?[*:0]const u8 = .{ bin, "--socket", sock_arg.ptr, "--cache-dir", cache_arg.ptr, "--linger-ms", linger_z[0..linger_arg.len :0].ptr, null };
        _ = c.execv(bin, @ptrCast(@constCast(&argv)));
        c._exit(127);
    }

    const owned_key = self.allocator.dupe(u8, key) catch return webReplyErr(cl, r.req, "oom");
    const owned_sock = self.allocator.dupe(u8, sock) catch {
        self.allocator.free(owned_key);
        return webReplyErr(cl, r.req, "oom");
    };
    self.web_engines.append(self.allocator, .{ .key = owned_key, .pid = pid, .sock = owned_sock }) catch {
        self.allocator.free(owned_key);
        self.allocator.free(owned_sock);
        return webReplyErr(cl, r.req, "oom");
    };
    writeEnginePresence(self, sock, pid, key);
    log.debug("engine_open: spawned sketerm-webengine pid {d} for instance {s}", .{ pid, key });
    // The client owns the bind wait: replying now keeps the daemon's
    // loop free while CEF pays its multi-second startup.
    cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .sock = owned_sock, .pid = pid, .spawned = true });
}

/// The presence file `web.json` (see webdrive's header), now written by
/// the OWNER of the engine pid — this daemon.
fn writeEnginePresence(self: *Daemon, sock: []const u8, pid: c.pid_t, key: []const u8) void {
    const dir_end = std.mem.lastIndexOfScalar(u8, sock, '/') orelse return;
    var z: [4096:0]u8 = undefined;
    const p = std.fmt.bufPrintZ(&z, "{s}/web.json", .{sock[0..dir_end]}) catch return;
    const f = c.fopen(p.ptr, "w") orelse return;
    defer _ = c.fclose(f);
    var line: [640]u8 = undefined;
    const body = std.fmt.bufPrint(&line, "{{\"broker_pid\":{d},\"helper_pid\":{d},\"client\":\"sketerm-mux:{s}\",\"started_at_ms\":{d}}}\n", .{
        c.getpid(), pid, key, wallMs(),
    }) catch return;
    _ = c.fwrite(body.ptr, 1, body.len, f);
    _ = self;
}
