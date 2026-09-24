//! Client serving: reading and writing client sockets, the per-frame
//! dispatch (`handleFrame`) that routes every wire frame to its
//! service module, and the daemon's own retirement (`shutdown`,
//! `quit_idle`). The services themselves live in their own modules
//! (daemon_control, daemon_udp, daemon_transfer, daemon_apps,
//! daemon_browse, daemon_fsops, daemon_web, daemon_webengine);
//! functions take the owning *Daemon and are aliased back into Daemon.

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
const daemon_adopt = @import("daemon_adopt.zig");
const wlvcodec = @import("../wlhost/vcodec.zig");

const daemon_apps = @import("daemon_apps.zig");
const daemon_browse = @import("daemon_browse.zig");
const daemon_control = @import("daemon_control.zig");
const daemon_fsops = @import("daemon_fsops.zig");
const daemon_transfer = @import("daemon_transfer.zig");
const daemon_udp = @import("daemon_udp.zig");
const daemon_web = @import("daemon_web.zig");
const controlSend = daemon_control.controlSend;
const handleAppA11y = daemon_apps.handleAppA11y;
const handleAppList = daemon_apps.handleAppList;
const handleFileClose = daemon_transfer.handleFileClose;
const handleFileData = daemon_transfer.handleFileData;
const handleFileGet = daemon_transfer.handleFileGet;
const handleFileList = daemon_browse.handleFileList;
const handleFileOpen = daemon_transfer.handleFileOpen;
const handleFsOp = daemon_fsops.handleFsOp;
const handleFsWrite = daemon_fsops.handleFsWrite;
const handleRecStart = daemon_apps.handleRecStart;
const handleUdpTicketReq = daemon_udp.handleUdpTicketReq;
const handleWebOp = daemon_web.handleWebOp;

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

/// The welcome's non-flag fields; `capabilities.WithFlags` appends
/// one bool per advertised capability, flat, as the wire has always
/// carried them.
const WelcomeBase = struct {
    proto: u32,
    daemon_pid: c.pid_t,
    server_proto: u32,
    min_proto: u32,
    negotiation: u8,
    snapshot: u8,
    native_state: u8,
    audio: bool,
    winstream: bool,
    version: []const u8,
    build: []const u8,
    audio_opus: bool,
    video: bool,
    video_codecs: []const []const u8,
    panel_rpc: u8,
};

/// The client's hello. Every field defaults to what a client predating
/// it meant, and unknown fields are ignored (a newer client's extras).
pub const HelloReq = struct {
    proto: u32 = 1,
    min_proto: u32 = 1,
    negotiation: u8 = 0,
    snapshot_max: u8 = 0,
    native_state_max: u8 = 0,
    audio: bool = false,
    winstream: bool = false,
    /// Pre-negotiation video capability: "I decode H.264".
    video: bool = false,
    /// Codecs the client decodes, in its preference order (vcodec
    /// names). Present = authoritative, even when empty (a user who
    /// chose lossless); absent = an older client, fall back to `video`.
    video_codecs: ?[]const []const u8 = null,
    panel_rpc: u8 = 0,

    pub fn videoCodecs(self: HelloReq) wlvcodec.CodecList {
        if (self.video_codecs) |names| return wlvcodec.CodecList.fromNames(names);
        return wlvcodec.CodecList.fromLegacy(self.video);
    }
};

test "an old GUI's hello (video bool only) negotiates x264, never AV1" {
    const t = std.testing;
    const old = try std.json.parseFromSlice(HelloReq, t.allocator,
        \\{"proto":6,"min_proto":1,"negotiation":1,"audio":true,"winstream":true,"video":true}
    , .{ .ignore_unknown_fields = true });
    defer old.deinit();
    const list = old.value.videoCodecs();
    try t.expectEqualSlices(wlvcodec.Codec, &.{.h264}, list.items());
    // Even against a daemon that could encode AV1 too.
    const both = wlvcodec.CodecList.fromNames(&.{ "av1", "h264" });
    try t.expectEqual(@as(?wlvcodec.Codec, .h264), wlvcodec.negotiate(&.{list}, both));

    const none = try std.json.parseFromSlice(HelloReq, t.allocator, "{\"proto\":6}", .{ .ignore_unknown_fields = true });
    defer none.deinit();
    try t.expectEqual(@as(u8, 0), none.value.videoCodecs().len);

    // A new GUI's explicit list wins over its compatibility bool, and an
    // explicit EMPTY list (lossless by choice) stays empty.
    const new = try std.json.parseFromSlice(HelloReq, t.allocator,
        \\{"proto":6,"video":true,"video_codecs":["av1","h264","vp9"]}
    , .{ .ignore_unknown_fields = true });
    defer new.deinit();
    try t.expectEqualSlices(wlvcodec.Codec, &.{ .av1, .h264 }, new.value.videoCodecs().items());
    const off = try std.json.parseFromSlice(HelloReq, t.allocator,
        \\{"proto":6,"video":false,"video_codecs":[]}
    , .{ .ignore_unknown_fields = true });
    defer off.deinit();
    try t.expectEqual(@as(u8, 0), off.value.videoCodecs().len);
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
                cl.video_codecs = p.value.videoCodecs();
                cl.panel_rpc_support = @min(p.value.panel_rpc, wire.PANEL_RPC_VERSION);
                p.deinit();
            } else |_| {}
            // Every boolean capability rides `capabilities.all`: one
            // table advertises, parses and resets them, and a frame an
            // old daemon would `.err` on is gated client-side by its flag
            // (misattributable on a multiplexed connection otherwise).
            var codec_names: [wlvcodec.CodecList.cap][]const u8 = undefined;
            cl.queueJson(.welcome, capabilities.withFlags(WelcomeBase{
                .proto = cl.proto,
                .daemon_pid = c.getpid(),
                .server_proto = wire.PROTO_VERSION,
                .min_proto = wire.MIN_SERVER_PROTO,
                .negotiation = 1,
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
                // Pre-negotiation meaning ("this daemon encodes H.264"),
                // kept for old clients; `video_codecs` is the full
                // runtime-probed encode set, informational (the daemon
                // picks from the client's hello list, see HelloReq).
                .video = wlvcodec.canEncode(.h264),
                .video_codecs = wlvcodec.encodableHere().names(&codec_names),
                // Correlated native-panel relay, a version rather than
                // a flag: independent of the terminal profile, so
                // future clients may share it with no snapshot/event
                // profile overlap.
                .panel_rpc = wire.PANEL_RPC_VERSION,
            }, capabilities.all));
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
            // Cast playback has no child to type at: dropped inside.
            s.writeToChild(frame.payload);
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
            retire(self, cl);
            cl.queueJson(.ok, .{ .ok = true });
        },
        .quit_idle => handleQuitIdle(self, cl, frame.payload),
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
        .web_helper_connect => self.handleWebHelperConnect(cl, frame.payload),
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

/// Leave the run loop on a client's request, telling every OTHER client
/// it is intentional (`.gone`) so nobody paints a crash face on the EOF.
/// A worker's clients are on the WORKER, not here, and a bare control-fd
/// close would read as a crash to them: each worker gets a graceful 'K'
/// so it flushes its own `.gone` before exiting (the buffered datagram is
/// delivered even though this process is about to stop).
fn retire(self: *Daemon, cl: *Client) void {
    for (self.clients.items) |other| {
        if (other != cl and !other.dead) other.queueFrame(.gone, "");
    }
    // A handover leaves the workers running for the next broker to
    // adopt: no 'K', and the control-fd close at exit orphans them.
    if (!self.handing_over) {
        for (self.workers.items) |w| {
            if (!w.dead and !w.adopting) _ = controlSend(w.control_fd, "K", -1);
        }
    }
    self.running = false;
}

/// Why this daemon may not retire right now, or null when it holds
/// nothing anyone would lose. Clients merely connected do not count:
/// they get `.gone` and reconnect to the replacement.
fn busyReason(self: *Daemon, buf: []u8) ?[]const u8 {
    var workers: usize = 0;
    for (self.workers.items) |w| {
        if (!w.dead) workers += 1;
    }
    var jobs: usize = 0;
    for (self.fs_jobs.items) |j| {
        if (j.state == .running or j.state == .paused) jobs += 1;
    }
    const sessions = self.sessions.items.len + workers;
    const transfers = self.uploads.items.len + self.downloads.items.len;
    if (sessions == 0 and jobs == 0 and transfers == 0 and self.debug_jobs.items.len == 0 and self.channels.items.len == 0)
        return null;
    return std.fmt.bufPrint(buf, "busy: {d} session(s), {d} running job(s), {d} transfer(s), {d} debugger job(s), {d} open channel(s)", .{
        sessions, jobs, transfers, self.debug_jobs.items.len, self.channels.items.len,
    }) catch "busy";
}

/// `quit_idle`: retire ONLY if nothing is held at this very moment. The
/// check and the exit happen in one frame dispatch, so a session
/// spawned between a client's probe and its request is refused rather
/// than killed (the `.shutdown` path old daemons need is unconditional).
/// `{"handover":true}` (welcome flag `worker_handover`) retires a broker
/// that holds SESSIONS too: its workers are left running and the next
/// broker adopts them (daemon_adopt.zig). Old daemons ignore the field
/// and keep refusing a busy retire, which is the safe answer.
pub fn handleQuitIdle(self: *Daemon, cl: *Client, payload: []const u8) void {
    if (self.isWorker()) {
        cl.queueJson(.ok, .{ .ok = false, .@"error" = "a session worker never retires on request; ask the broker" });
        return;
    }
    var buf: [192]u8 = undefined;
    const Req = struct { handover: bool = false };
    const handover = if (payload.len == 0) false else blk: {
        const parsed = std.json.parseFromSlice(Req, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch break :blk false;
        defer parsed.deinit();
        break :blk parsed.value.handover;
    };
    if (handover) {
        if (daemon_adopt.handoverBlocker(self, &buf)) |reason| {
            cl.queueJson(.ok, .{ .ok = false, .@"error" = reason });
            return;
        }
        var kept: usize = 0;
        for (self.workers.items) |w| {
            if (!w.dead) kept += 1;
        }
        self.handing_over = true;
        log.info("handing over {d} session worker(s) to the next broker", .{kept});
        retire(self, cl);
        cl.queueJson(.ok, .{ .ok = true, .handover = true, .sessions = kept });
        return;
    }
    if (busyReason(self, &buf)) |reason| {
        cl.queueJson(.ok, .{ .ok = false, .@"error" = reason });
        return;
    }
    retire(self, cl);
    cl.queueJson(.ok, .{ .ok = true });
}

test "quit_idle retires an idle daemon in one step and refuses a busy one" {
    const t = std.testing;
    const a = t.allocator;
    var empty: [0]u8 = .{};
    var d = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..] };
    defer d.clients.deinit(a);
    defer d.workers.deinit(a);
    var requester = Client{ .allocator = a, .fd = -1, .id = 1 };
    defer requester.rbuf.deinit(a);
    defer requester.wbuf.deinit(a);
    defer requester.audio_wbuf.deinit(a);
    var bystander = Client{ .allocator = a, .fd = -1, .id = 2 };
    defer bystander.rbuf.deinit(a);
    defer bystander.wbuf.deinit(a);
    defer bystander.audio_wbuf.deinit(a);
    try d.clients.append(a, &requester);
    try d.clients.append(a, &bystander);

    // A live worker (the broker's view of a session) is the race the
    // frame exists to close: refused, and the daemon keeps running.
    var worker = Worker{
        .allocator = a,
        .name = @constCast("late"),
        .origin_name = @constCast("late"),
        .origin_id = "10000000000000000000000000000001".*,
        .pid = 123,
        .control_fd = -1,
    };
    try d.workers.append(a, &worker);
    handleQuitIdle(&d, &requester, "");
    try t.expect(d.running);
    var reply = (try wire.peelFrame(requester.wbuf.items)) orelse return error.TestUnexpectedResult;
    try t.expectEqual(wire.FrameType.ok, reply.frame.ftype);
    try t.expect(std.mem.indexOf(u8, reply.frame.payload, "\"ok\":false") != null);
    try t.expect(std.mem.indexOf(u8, reply.frame.payload, "1 session(s)") != null);
    try t.expectEqual(@as(usize, 0), bystander.wbuf.items.len);

    // A dead worker is on its way out and holds nothing.
    worker.dead = true;
    requester.wbuf.clearRetainingCapacity();
    handleQuitIdle(&d, &requester, "");
    try t.expect(!d.running);
    reply = (try wire.peelFrame(requester.wbuf.items)) orelse return error.TestUnexpectedResult;
    try t.expectEqual(wire.FrameType.ok, reply.frame.ftype);
    try t.expect(std.mem.indexOf(u8, reply.frame.payload, "\"ok\":true") != null);
    // The other client learns the exit is intentional.
    const gone = (try wire.peelFrame(bystander.wbuf.items)) orelse return error.TestUnexpectedResult;
    try t.expectEqual(wire.FrameType.gone, gone.frame.ftype);

    // A worker never answers for its broker.
    d.running = true;
    d.role = .worker;
    requester.wbuf.clearRetainingCapacity();
    handleQuitIdle(&d, &requester, "");
    try t.expect(d.running);
    reply = (try wire.peelFrame(requester.wbuf.items)) orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, reply.frame.payload, "\"ok\":false") != null);
}

pub fn findChannel(self: *Daemon, id: u32) ?*Channel {
    for (self.channels.items) |ch| {
        if (ch.id == id) return ch;
    }
    return null;
}
