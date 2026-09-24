//! The broker <-> worker control channel: worker-side datagram
//! handling ('A' handoff, 'K', 'R', 'n'), broker-side handling ('Y',
//! 'E', 'M', 'N'), the worker's metadata pushes, the datagram
//! primitives with SCM_RIGHTS, and the worker process entry. Split
//! out of daemon_serve.zig; functions take the owning *Daemon and are
//! aliased back into Daemon.

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("log.zig");
const wire = @import("wire.zig");
const platform = @import("../util/platform.zig");
const selfexec = @import("selfexec.zig");
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
const capabilities = @import("capabilities.zig");

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
/// to travel here: a field left out of this hop makes the worker see a
/// DEFAULT and the whole feature silently never engage, which is why
/// smoke-broker drives the real handoff.
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
            else
                snapshot.negotiateVersion(proto, 0, false),
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
    const pre_negotiation = PassedClient.decode(&.{6});
    try t.expectEqual(@as(u8, 10), pre_negotiation.snapshot_version);
}

/// Worker side: adopt a broker-passed client fd as a client of this
/// process, then attach it to our one session through the same tail a
/// direct `.attach` takes.
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
        .panel_rpc_support = req.panel_rpc,
    };
    self.next_client_id += 1;
    self.clients.append(self.allocator, cl) catch {
        cl.deinit();
        return;
    };
    if (self.sessions.items.len == 0) return;
    const s = self.sessions.items[0];
    cl.resetAttachmentStreamState();
    self.attachClientToSession(cl, s, .{
        .kind = req.kind,
        .read_only = req.read_only,
        .want_control = req.want_control,
        .panel_only = req.panel_only,
        .panel_rpc = req.panel_rpc,
        .identity_first = req.identity_first,
    }, "broker handoff");
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
        .role = .worker,
        .control_fd = control_fd,
        .base_dir = if (base_dir.len > 0) try allocator.dupe(u8, base_dir) else null,
        .broker_sock = if (broker_sock.len > 0) try allocator.dupe(u8, broker_sock) else null,
    };
    return self;
}

/// Exit status of a worker whose poll loop failed; a spawn-phase failure
/// exits 0 because it was already reported through the 'E' datagram.
pub const WORKER_EXIT_RUN_FAILED: u8 = 4;

/// Worker process entry: own one session (from `req`), serve clients the
/// broker hands over `control_fd`, until killed or the broker goes away.
/// Returns the process exit status.
pub fn runWorker(
    allocator: std.mem.Allocator,
    control_fd: c_int,
    req: SpawnReq,
    origin_id: dmod.SessionOriginId,
    base_dir: []const u8,
    broker_sock: []const u8,
) u8 {
    runWorkerInner(allocator, control_fd, req, origin_id, base_dir, broker_sock) catch |err| return switch (err) {
        error.RunFailed => WORKER_EXIT_RUN_FAILED,
        else => 0,
    };
    return 0;
}

fn runWorkerInner(
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
    self.run() catch return error.RunFailed;
}

test "control datagrams carry their bytes and at most one passed fd" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.controlSocketpair(&pair, 4096));
    defer _ = c.close(pair[0]);
    defer _ = c.close(pair[1]);
    // A client fd to hand over: one end of a stream pair.
    var client: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&client));
    defer _ = c.close(client[0]);
    defer _ = c.close(client[1]);

    const handoff = "A" ++ [_]u8{ 6, 1, 1 };
    try t.expect(controlSend(pair[0], handoff, client[0]));
    var buf: [64]u8 = undefined;
    var passed: c_int = -1;
    const n = controlRecv(pair[1], &buf, &passed);
    try t.expectEqual(@as(isize, handoff.len), n);
    try t.expectEqualStrings(handoff, buf[0..@intCast(n)]);
    // The passed descriptor is a live duplicate of the client socket.
    try t.expect(passed >= 0);
    defer _ = c.close(passed);
    try t.expectEqual(@as(isize, 2), c.send(client[1], "ok", 2, 0));
    var got: [2]u8 = undefined;
    try t.expectEqual(@as(isize, 2), c.recv(passed, &got, 2, 0));
    try t.expectEqualStrings("ok", &got);

    // A plain control byte passes no fd, and the receiver says so.
    try t.expect(controlSend(pair[0], "K", -1));
    passed = 0;
    try t.expectEqual(@as(isize, 1), controlRecv(pair[1], &buf, &passed));
    try t.expectEqual(@as(c_int, -1), passed);
    try t.expectEqual(@as(u8, 'K'), buf[0]);

    // A closed peer reads as "channel gone": non-positive, never a
    // datagram (Linux EOFs, Darwin reports ECONNRESET).
    _ = c.close(pair[0]);
    try t.expect(controlRecv(pair[1], &buf, &passed) <= 0);
}
