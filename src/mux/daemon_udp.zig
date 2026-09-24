//! UDP connection tickets (`udp_ticket_req` -> `udp_ticket`): minting
//! a single-use sibling `--udp-listen` on this host so a NEW client
//! connects without an ssh bootstrap. Split out of daemon_serve.zig.

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
            argv[n] = selfexec.BINARY;
            argv[n + 1] = selfexec.Mode.udp_listen.flag().?.ptr;
            n += 2;
            if (range) |r| {
                argv[n] = "--udp-port";
                argv[n + 1] = r.ptr;
                n += 2;
            }
            argv[n] = selfexec.SOCKET_FLAG;
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

test "a ticket port range is exactly the lo:hi shape --udp-port takes" {
    const t = std.testing;
    try t.expect(validTicketRange("60000:61000"));
    try t.expect(validTicketRange("1:1"));
    try t.expect(!validTicketRange(""));
    try t.expect(!validTicketRange("60000"));
    try t.expect(!validTicketRange(":61000"));
    try t.expect(!validTicketRange("60000:"));
    try t.expect(!validTicketRange("60000:61000:62000"));
    try t.expect(!validTicketRange("60000:61k"));
    try t.expect(!validTicketRange(" 60000:61000"));
}

test "a ticket refusal is answered on the udp_ticket frame the client waits for" {
    const t = std.testing;
    const a = t.allocator;
    var cl = Client{ .allocator = a, .fd = -1 };
    defer cl.rbuf.deinit(a);
    defer cl.wbuf.deinit(a);
    defer cl.audio_wbuf.deinit(a);
    udpTicketErr(&cl, "no listener binary");
    const reply = (try wire.peelFrame(cl.wbuf.items)) orelse return error.TestUnexpectedResult;
    try t.expectEqual(wire.FrameType.udp_ticket, reply.frame.ftype);
    try t.expect(std.mem.indexOf(u8, reply.frame.payload, "\"ok\":false") != null);
    try t.expect(std.mem.indexOf(u8, reply.frame.payload, "no listener binary") != null);
}
