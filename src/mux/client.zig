//! Mux client connection: blocking helpers shared by the smoke
//! test, the TUI picker, and the GUI attach path (which switches
//! the fd to non-blocking and polls it from the GLib loop).

const std = @import("std");
const c = @import("../c.zig").c;
const wire = @import("wire.zig");
const daemon = @import("daemon.zig");

pub const Transport = enum { local, ssh, udp };
pub const RemoteMode = enum { auto, ssh, udp };

pub const RemoteSpec = struct {
    host: []const u8,
    mode: RemoteMode,

    pub fn parse(spec: []const u8) RemoteSpec {
        if (std.mem.startsWith(u8, spec, "udp:")) return .{ .host = spec[4..], .mode = .udp };
        if (std.mem.startsWith(u8, spec, "ssh:")) return .{ .host = spec[4..], .mode = .ssh };
        return .{ .host = spec, .mode = .auto };
    }
};

fn monotonicMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

/// Reap a bootstrap SSH that should exit immediately after announcing.
fn reapBootstrapChild(pid: c.pid_t) void {
    var status: c_int = 0;
    var deadline = monotonicMs() + 500;
    while (monotonicMs() < deadline) {
        const r = c.waitpid(pid, &status, c.WNOHANG);
        if (r == pid or (r < 0 and std.posix.errno(r) != .INTR)) return;
        _ = c.usleep(10_000);
    }
    _ = c.kill(pid, c.SIGTERM);
    deadline = monotonicMs() + 250;
    while (monotonicMs() < deadline) {
        const r = c.waitpid(pid, &status, c.WNOHANG);
        if (r == pid or (r < 0 and std.posix.errno(r) != .INTR)) return;
        _ = c.usleep(10_000);
    }
    _ = c.kill(pid, c.SIGKILL);
    while (true) {
        const r = c.waitpid(pid, &status, 0);
        if (r >= 0 or std.posix.errno(r) != .INTR) break;
    }
}

/// Resolve the sketerm-mux binary: sibling of our own executable
/// first (works for `zig build run` trees), then bare name ($PATH).
pub fn findMuxBinary(buf: *[4096:0]u8) [*:0]const u8 {
    const platform = @import("../util/platform.zig");
    if (platform.exePathZ(buf)) |exe_path| {
        if (std.mem.lastIndexOfScalar(u8, exe_path, '/')) |slash| {
            const dir_len = slash + 1;
            const want = "sketerm-mux";
            if (dir_len + want.len < buf.len) {
                @memcpy(buf[dir_len .. dir_len + want.len], want);
                buf[dir_len + want.len] = 0;
                if (c.access(buf, c.X_OK) == 0) return @ptrCast(buf);
            }
        }
    }
    return "sketerm-mux";
}

pub const Conn = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    transport: Transport = .local,
    rbuf: std.ArrayList(u8) = .empty,
    /// Complete frames queued by GUI main-loop producers. These are
    /// flushed incrementally without polling so backpressure cannot freeze
    /// GTK.
    wbuf: std.ArrayList(u8) = .empty,
    /// Message from the last daemon `.err` frame seen by `recvExpect`,
    /// so callers can surface the REAL reason ("no such session", …)
    /// instead of a bare `error.DaemonError`.
    last_err: [192]u8 = undefined,
    last_err_len: usize = 0,
    /// Bound on how long sendFrame waits for a full socket buffer to
    /// drain before failing (a wedged daemon must cost an error, not
    /// a hung caller).
    write_timeout_ms: c_int = 30_000,
    /// Selected core profile and the daemon's newest profile when advertised.
    proto: u32 = 1,
    server_proto: u32 = 1,
    snapshot_version: u8 = @import("snapshot.zig").LEGACY_SNAPSHOT_VERSION,

    pub fn connect(allocator: std.mem.Allocator, sock_path: []const u8) !Conn {
        const fd = @import("../util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        var addr: c.struct_sockaddr_un = undefined;
        try daemon.fillSockaddrUn(&addr, sock_path);
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return error.ConnectFailed;
        return .{ .allocator = allocator, .fd = fd };
    }

    /// Connect to a specific daemon socket and complete the
    /// hello/welcome probe (proto negotiation — without it the daemon
    /// treats the client as proto 1 and never streams app channels).
    /// NO autostart and no stale-daemon retire: a failed handshake is
    /// an error and never triggers daemon replacement.
    pub fn connectProbed(allocator: std.mem.Allocator, sock_path: []const u8) !Conn {
        const conn = try Conn.connect(allocator, sock_path);
        return probe(allocator, conn);
    }

    /// Connect to the local daemon, spawning it (sibling binary,
    /// $PATH fallback) and retrying for ~2s when it isn't running.
    /// Sends the hello/welcome probe like the remote transports do —
    /// it announces OUR proto version, which gates whether the
    /// daemon offers byte channels (Wayland app forwarding).
    pub fn connectLocalAutostart(allocator: std.mem.Allocator) !Conn {
        return connectLocalAutostartAt(allocator, null);
    }

    /// Like `connectLocalAutostart`, but against `sock_path` when given —
    /// a PRIVATE daemon instance (its aux sockets live next to the socket),
    /// used by `sketerm mcp` isolation. null = the shared per-user daemon.
    pub fn connectLocalAutostartAt(allocator: std.mem.Allocator, sock_path: ?[]const u8) !Conn {
        const path = if (sock_path) |p|
            try allocator.dupe(u8, p)
        else
            try daemon.defaultSocketPath(allocator);
        defer allocator.free(path);
        if (Conn.connect(allocator, path)) |conn| {
            return probe(allocator, conn);
        } else |_| {}

        // Process-isolation broker by default: each session runs in its own
        // worker process, so one shell's crash/OOM can't take down the daemon
        // or its siblings. SKETERM_NO_BROKER=1 falls back to the single-process
        // monolith (escape hatch if the broker ever misbehaves in the field).
        const use_broker = c.getenv("SKETERM_NO_BROKER") == null;
        // NUL-terminated socket arg for the child; prepared before fork
        // (no allocation between fork and exec).
        var sock_z_buf: [4096:0]u8 = undefined;
        const sock_z: ?[*:0]const u8 = if (sock_path != null)
            (std.fmt.bufPrintZ(&sock_z_buf, "{s}", .{path}) catch return error.BadPath).ptr
        else
            null;
        const pid = c.fork();
        if (pid == 0) {
            _ = c.setsid();
            var bin_buf: [4096:0]u8 = undefined;
            const bin = findMuxBinary(&bin_buf);
            var argv: [5:null]?[*:0]const u8 = .{ bin, null, null, null, null };
            var n: usize = 1;
            if (use_broker) {
                argv[n] = "--broker";
                n += 1;
            }
            if (sock_z) |z| {
                argv[n] = "--socket";
                argv[n + 1] = z;
            }
            _ = c.execvp(bin, @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        var tries: u32 = 0;
        while (tries < 40) : (tries += 1) {
            _ = c.usleep(50_000);
            if (Conn.connect(allocator, path)) |conn| {
                return probe(allocator, conn);
            } else |_| {}
        }
        return error.MuxDaemonUnreachable;
    }

    /// hello → welcome round trip; consumes the welcome so the
    /// stream is clean for the caller's own frames.
    pub fn probe(allocator: std.mem.Allocator, conn_in: Conn) !Conn {
        var conn = conn_in;
        errdefer conn.deinit();
        try conn.sendHello();
        // Bounded: a daemon that accepts but never answers (wedged,
        // swap-thrashing) must fail the connect, not hang the caller.
        const w = try conn.recvExpectFor(&.{.welcome}, 10_000);
        defer w.deinit(allocator);
        conn.applyWelcome(allocator, w.payload);
        return conn;
    }

    fn sendHello(self: *Conn) !void {
        try self.sendJson(.hello, .{
            .proto = wire.PROTO_VERSION,
            .min_proto = @as(u32, 1),
            .negotiation = @as(u8, 1),
            .snapshot_max = @import("snapshot.zig").SNAPSHOT_VERSION,
            .native_state_max = wire.NATIVE_STATE_VERSION,
            .audio = true,
            .winstream = true,
            .video = @import("build_options").video,
        });
    }

    fn applyWelcome(self: *Conn, allocator: std.mem.Allocator, payload: []const u8) void {
        self.proto = 0;
        self.server_proto = 0;
        self.snapshot_version = 0;
        const Probe = struct {
            proto: u32 = 1,
            server_proto: ?u32 = null,
            negotiation: u8 = 0,
            snapshot: u8 = 0,
        };
        if (std.json.parseFromSlice(Probe, allocator, payload, .{ .ignore_unknown_fields = true })) |parsed| {
            defer parsed.deinit();
            const reported = parsed.value.proto;
            self.proto = if (parsed.value.negotiation > 0)
                reported
            else if (reported >= 1 and reported <= wire.PROTO_VERSION)
                reported
            else
                0;
            self.server_proto = parsed.value.server_proto orelse reported;
            self.snapshot_version = if (parsed.value.snapshot > 0)
                @min(parsed.value.snapshot, @import("snapshot.zig").SNAPSHOT_VERSION)
            else if (self.proto >= 6)
                @import("snapshot.zig").SNAPSHOT_VERSION
            else
                @import("snapshot.zig").LEGACY_SNAPSHOT_VERSION;
        } else |_| {}
    }

    pub fn deinit(self: *Conn) void {
        _ = c.close(self.fd);
        self.fd = -1;
        self.rbuf.deinit(self.allocator);
        self.wbuf.deinit(self.allocator);
    }

    /// Connect to a remote daemon using the requested transport policy.
    pub fn connectRemote(allocator: std.mem.Allocator, spec: []const u8, port_range: ?[]const u8) !Conn {
        if (std.mem.startsWith(u8, spec, "sock:")) return connectProbed(allocator, spec[5..]);
        return connectRemoteUsing(allocator, spec, port_range, connectUdpAuto, connectUdp, connectSshWithRange);
    }

    const RemoteConnector = *const fn (std.mem.Allocator, []const u8, ?[]const u8) anyerror!Conn;

    fn connectSshWithRange(allocator: std.mem.Allocator, host: []const u8, _: ?[]const u8) !Conn {
        return connectSsh(allocator, host);
    }

    fn connectUdpAuto(allocator: std.mem.Allocator, host: []const u8, port_range: ?[]const u8) !Conn {
        return connectUdpFor(allocator, host, port_range, 6_000);
    }

    fn connectRemoteUsing(
        allocator: std.mem.Allocator,
        spec: []const u8,
        port_range: ?[]const u8,
        auto_udp_connect: RemoteConnector,
        forced_udp_connect: RemoteConnector,
        ssh_connect: RemoteConnector,
    ) !Conn {
        const remote = RemoteSpec.parse(spec);
        if (remote.host.len == 0) return error.BadPath;
        return switch (remote.mode) {
            .udp => forced_udp_connect(allocator, remote.host, port_range),
            .ssh => ssh_connect(allocator, remote.host, port_range),
            .auto => auto_udp_connect(allocator, remote.host, port_range) catch
                ssh_connect(allocator, remote.host, port_range),
        };
    }

    /// Mosh-style UDP transport: bootstrap over SSH (run
    /// `sketerm-mux --udp-listen` remotely, read its one-line
    /// "SKETERM-UDP <port> <key>" announcement, ssh exits), then
    /// spawn a local `sketerm-mux --udp-connect` bridge over a
    /// socketpair. Everything downstream is fd-agnostic, same as
    /// the plain SSH transport — but the live connection is
    /// encrypted UDP with roaming + retransmission (rudp.zig).
    pub fn connectUdp(allocator: std.mem.Allocator, host: []const u8, port_range: ?[]const u8) !Conn {
        return connectUdpFor(allocator, host, port_range, 20_000);
    }

    fn connectUdpFor(allocator: std.mem.Allocator, host: []const u8, port_range: ?[]const u8, timeout_ms: i64) !Conn {
        const deadline = monotonicMs() + timeout_ms;
        // 1. Bootstrap: ssh prints the announcement on a pipe.
        var host_z_buf: [256:0]u8 = undefined;
        const host_z = std.fmt.bufPrintZ(&host_z_buf, "{s}", .{host}) catch return error.BadPath;
        var pipe_fds: [2]c_int = undefined;
        if (c.pipe(&pipe_fds) != 0) return error.SocketFailed;
        for (pipe_fds) |fd| _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        const ssh_env = c.getenv("SKETERM_SSH");
        const ssh_bin: [*:0]const u8 = if (ssh_env != null) ssh_env else "ssh";

        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(pipe_fds[0]);
            _ = c.close(pipe_fds[1]);
            return error.ForkFailed;
        }
        if (pid == 0) {
            _ = c.dup2(pipe_fds[1], 1);
            _ = c.close(pipe_fds[0]);
            _ = c.close(pipe_fds[1]);
            var range_z_buf: [32:0]u8 = undefined;
            var argv = [_:null]?[*:0]const u8{
                ssh_bin, "-T", "-o", "BatchMode=yes", host_z.ptr, "sketerm-mux", "--udp-listen", null, null, null,
            };
            if (port_range) |r| {
                if (std.fmt.bufPrintZ(&range_z_buf, "{s}", .{r})) |rz| {
                    argv[7] = "--udp-port";
                    argv[8] = rz.ptr;
                } else |_| {}
            }
            _ = c.execvp(ssh_bin, @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        _ = c.close(pipe_fds[1]);

        // Read the announcement line with one absolute deadline; an
        // old remote binary or wedged SSH must reach the SSH fallback.
        var line_buf: [512]u8 = undefined;
        var line_len: usize = 0;
        var announce: ?[]const u8 = null;
        outer: while (line_len < line_buf.len) {
            const remain = deadline - monotonicMs();
            if (remain <= 0) break;
            var pfd = c.struct_pollfd{ .fd = pipe_fds[0], .events = c.POLLIN, .revents = 0 };
            const pr = c.poll(&pfd, 1, @intCast(@min(remain, 250)));
            if (pr < 0) {
                if (std.posix.errno(pr) == .INTR) continue;
                break;
            }
            if (pr == 0) continue;
            const n = c.read(pipe_fds[0], line_buf[line_len..].ptr, line_buf.len - line_len);
            if (n <= 0) break;
            line_len += @intCast(n);
            var start: usize = 0;
            while (std.mem.indexOfScalarPos(u8, line_buf[0..line_len], start, '\n')) |nl| {
                const line = line_buf[start..nl];
                if (std.mem.startsWith(u8, line, "SKETERM-UDP ")) {
                    announce = line;
                    break :outer;
                }
                start = nl + 1;
            }
            if (start > 0) {
                std.mem.copyForwards(u8, line_buf[0 .. line_len - start], line_buf[start..line_len]);
                line_len -= start;
            }
        }
        _ = c.close(pipe_fds[0]);
        reapBootstrapChild(pid);
        const ann = announce orelse return error.SshTransportFailed;

        // "SKETERM-UDP <port> <keyhex>"
        var it = std.mem.tokenizeScalar(u8, ann, ' ');
        _ = it.next(); // tag
        const port = it.next() orelse return error.SshTransportFailed;
        const keyhex = it.next() orelse return error.SshTransportFailed;

        // 2. Local UDP bridge child over a socketpair. UDP goes to
        // the bare hostname (strip any user@ ssh prefix).
        const bare_host = if (std.mem.indexOfScalar(u8, host, '@')) |at| host[at + 1 ..] else host;
        var mux_bin_buf: [4096:0]u8 = undefined;
        const mux_bin = findMuxBinary(&mux_bin_buf);
        var port_z_buf: [16:0]u8 = undefined;
        const port_z = std.fmt.bufPrintZ(&port_z_buf, "{s}", .{port}) catch return error.SshTransportFailed;
        var key_z_buf: [128:0]u8 = undefined;
        const key_z = std.fmt.bufPrintZ(&key_z_buf, "{s}", .{keyhex}) catch return error.SshTransportFailed;
        var bh_z_buf: [256:0]u8 = undefined;
        const bh_z = std.fmt.bufPrintZ(&bh_z_buf, "{s}", .{bare_host}) catch return error.BadPath;

        const argv2 = [_:null]?[*:0]const u8{
            mux_bin, "--udp-connect", bh_z.ptr, port_z.ptr, key_z.ptr, null,
        };
        var conn = try spawnOverSocketpair(allocator, mux_bin, &argv2);
        errdefer conn.deinit();

        conn.sendHello() catch return error.SshTransportFailed;
        const remain = deadline - monotonicMs();
        if (remain <= 0) return error.SshTransportFailed;
        const w = conn.recvExpectFor(&.{.welcome}, remain) catch return error.SshTransportFailed;
        defer w.deinit(allocator);
        conn.applyWelcome(allocator, w.payload);
        conn.transport = .udp;
        return conn;
    }

    /// Connect to a REMOTE host's daemon by running
    /// `ssh -T -o BatchMode=yes <host> sketerm-mux --proxy` over a
    /// socketpair (one fd both ways, so everything downstream is
    /// transport-agnostic). The child is double-forked — it reparents
    /// to init, no zombie to reap. Requires key/agent auth
    /// (BatchMode fails instead of prompting on the protocol pipe).
    /// $SKETERM_SSH overrides the ssh binary (tests fake a remote).
    pub fn connectSsh(allocator: std.mem.Allocator, host: []const u8) !Conn {
        // `sketerm app` opens TWO connections moments apart (the CLI to
        // spawn the session, then the GUI to attach). When the remote
        // sshd is slow to service new connections — a loaded box stalls
        // the banner/key exchange even though TCP connects instantly —
        // each fresh connection is a dice roll. Multiplexing (in
        // connectSshOnce) collapses them onto one master so only the
        // first pays that cost; this retry covers the master setup
        // itself stalling. Both together turn an intermittent failure
        // into a reliable connect.
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            if (connectSshOnce(allocator, host)) |conn| {
                return conn;
            } else |err| {
                if (attempt + 1 >= 3) return err;
                _ = c.usleep(400_000);
            }
        }
    }

    /// Single bounded connect attempt (~20s worst case) — pub for
    /// callers that must not pay connectSsh's 3x retry inline (e.g.
    /// termdrive's transparent reattach inside a drain path).
    pub fn connectSshOnce(allocator: std.mem.Allocator, host: []const u8) !Conn {
        var host_z_buf: [256:0]u8 = undefined;
        const host_z = std.fmt.bufPrintZ(&host_z_buf, "{s}", .{host}) catch return error.BadPath;
        const ssh_env = c.getenv("SKETERM_SSH");
        const ssh_bin: [*:0]const u8 = if (ssh_env != null) ssh_env else "ssh";

        // Connection multiplexing — only with the real ssh (a test rig
        // pointed at by $SKETERM_SSH keeps the plain positional argv).
        // ControlMaster=auto reuses an existing master or becomes one;
        // ControlPersist keeps it briefly after the spawning client
        // exits so the GUI's attach a beat later rides the same master
        // (instant — no second banner exchange). %C is a fixed-length
        // hash, so the socket path stays well under the sun_path limit.
        const mux = ssh_env == null;
        var argv_buf: [16]?[*:0]const u8 = undefined;
        var n: usize = 0;
        const push = struct {
            fn f(buf: *[16]?[*:0]const u8, i: *usize, v: ?[*:0]const u8) void {
                buf[i.*] = v;
                i.* += 1;
            }
        }.f;
        push(&argv_buf, &n, ssh_bin);
        push(&argv_buf, &n, "-T");
        // The proxy channel carries the mux binary protocol — never X11.
        // `-x` disables X11 forwarding so a user's `ForwardX11 yes` config
        // can't print "X11 forwarding request failed" onto the terminal
        // (and can't perturb the protocol pipe).
        push(&argv_buf, &n, "-x");
        push(&argv_buf, &n, "-o");
        push(&argv_buf, &n, "BatchMode=yes");
        if (mux) {
            push(&argv_buf, &n, "-o");
            push(&argv_buf, &n, "ControlMaster=auto");
            push(&argv_buf, &n, "-o");
            push(&argv_buf, &n, "ControlPath=~/.ssh/sketerm-%C");
            push(&argv_buf, &n, "-o");
            push(&argv_buf, &n, "ControlPersist=120");
        }
        push(&argv_buf, &n, host_z.ptr);
        push(&argv_buf, &n, "sketerm-mux");
        push(&argv_buf, &n, "--proxy");
        push(&argv_buf, &n, null);

        var conn = try spawnOverSocketpair(allocator, ssh_bin, @ptrCast(&argv_buf));
        errdefer conn.deinit();

        // Probe the bridge: hello → welcome proves ssh + remote
        // binary + daemon all came up before we hand the conn out.
        // Bound the welcome wait so a stalled banner surfaces as a
        // retryable error instead of hanging the blocking read forever.
        conn.sendHello() catch return error.SshTransportFailed;
        try waitReadable(conn.fd, 20_000);
        const w = conn.recvExpectFor(&.{.welcome}, 20_000) catch return error.SshTransportFailed;
        defer w.deinit(allocator);
        conn.applyWelcome(allocator, w.payload);
        conn.transport = .ssh;
        return conn;
    }

    /// Switch the fd to non-blocking so NO call on this connection can
    /// park forever: sendFrame bounds a full-buffer write with a
    /// write_timeout_ms poll (its EAGAIN path), and reads must go
    /// through recvFrameFor/recvExpectFor/fillAvailable — plain
    /// recvFrame's blocking read() would misread EAGAIN as a hangup.
    pub fn setNonBlocking(self: *Conn) void {
        const fl = c.fcntl(self.fd, c.F_GETFL);
        if (fl < 0) return;
        _ = c.fcntl(self.fd, c.F_SETFL, fl | c.O_NONBLOCK);
    }

    /// Poll `fd` for readability, bounded by `timeout_ms`. A timeout or
    /// poll error becomes a retryable SshTransportFailed.
    fn waitReadable(fd: c_int, timeout_ms: c_int) !void {
        var pfd = [_]c.struct_pollfd{.{ .fd = fd, .events = c.POLLIN, .revents = 0 }};
        while (true) {
            const r = c.poll(&pfd, 1, timeout_ms);
            if (r > 0) return;
            if (r < 0 and std.posix.errno(r) == .INTR) continue;
            return error.SshTransportFailed;
        }
    }

    /// Deliver one frame fully (bounded-blocking on backpressure) — the
    /// historical contract callers like Terminal.deinit's .kill rely on.
    /// When an upload backlog already sits in wbuf, the frame queues
    /// behind it and only the nonblocking flush runs; the upload pump
    /// (or a later flushQueuedFor) finishes the delivery.
    pub fn sendFrame(self: *Conn, ftype: wire.FrameType, payload: []const u8) !void {
        if (self.proto == 0 and ftype != .hello and ftype != .list)
            return error.NoSharedTerminalProfile;
        const had_backlog = self.wbuf.items.len > 0;
        try wire.appendFrame(&self.wbuf, self.allocator, ftype, payload);
        if (had_backlog) return self.flushQueued();
        return self.flushQueuedFor(self.write_timeout_ms);
    }

    /// Queue one complete frame and write only what the nonblocking fd
    /// accepts immediately. Partial writes remain resumable in `wbuf`.
    pub fn queueFrame(self: *Conn, ftype: wire.FrameType, payload: []const u8) !void {
        if (self.proto == 0 and ftype != .hello and ftype != .list)
            return error.NoSharedTerminalProfile;
        try wire.appendFrame(&self.wbuf, self.allocator, ftype, payload);
        try self.flushQueued();
    }

    pub fn flushQueued(self: *Conn) !void {
        var off: usize = 0;
        while (off < self.wbuf.items.len) {
            // MSG_NOSIGNAL: a dead peer must yield EPIPE, not a
            // process-killing SIGPIPE. macOS lacks the flag; callers
            // there rely on a SIGPIPE handler / GSocket's SO_NOSIGPIPE.
            const n = if (comptime @hasDecl(c, "MSG_NOSIGNAL"))
                c.send(self.fd, self.wbuf.items.ptr + off, self.wbuf.items.len - off, c.MSG_NOSIGNAL)
            else
                c.write(self.fd, self.wbuf.items.ptr + off, self.wbuf.items.len - off);
            if (n > 0) {
                off += @intCast(n);
                continue;
            }
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
            if (e == .AGAIN) break;
            return error.WriteFailed;
        }
        if (off > 0) {
            const rem = self.wbuf.items.len - off;
            std.mem.copyForwards(u8, self.wbuf.items[0..rem], self.wbuf.items[off..]);
            self.wbuf.shrinkRetainingCapacity(rem);
        }
    }

    /// Drain queued frames, waiting (bounded) for the fd on backpressure.
    /// Teardown-critical frames (.kill/.detach) queued behind an upload
    /// backlog must reach the daemon before the fd closes.
    pub fn flushQueuedFor(self: *Conn, timeout_ms: c_int) !void {
        while (true) {
            try self.flushQueued();
            if (self.wbuf.items.len == 0) return;
            var pfd = [_]c.struct_pollfd{.{ .fd = self.fd, .events = c.POLLOUT, .revents = 0 }};
            const r = c.poll(&pfd, 1, timeout_ms);
            if (r > 0) continue;
            if (r < 0 and std.posix.errno(r) == .INTR) continue;
            return error.WriteFailed;
        }
    }

    pub fn sendJson(self: *Conn, ftype: wire.FrameType, value: anytype) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try std.json.Stringify.value(value, .{}, &aw.writer);
        try self.sendFrame(ftype, aw.written());
    }

    /// Spawn `argv` with both stdio ends on one socketpair fd,
    /// double-forked so init reaps it (no zombies, child outlives
    /// nothing it shouldn't). Returns a Conn over our end.
    ///
    /// CLOEXEC on the pair is load-bearing: without it every transport
    /// spawned LATER inherits the sockets of every earlier one, so the peer
    /// of an old connection cannot see EOF until the last of those children
    /// exits - a dead GUI's durable sessions then stay "attached" on the
    /// daemon, streaming into a socket nobody reads. `dup2` clears CLOEXEC
    /// on the copy it makes, so the exec'd child still gets stdin/stdout.
    /// `setsid` keeps a terminal signal aimed at the spawner's process group
    /// (a Ctrl+C or SIGHUP in the shell that launched the GUI) from taking
    /// every session transport down with it.
    fn spawnOverSocketpair(allocator: std.mem.Allocator, bin: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) !Conn {
        var pair: [2]c_int = undefined;
        if (@import("../util/platform.zig").socketpairCloexec(&pair) != 0) return error.SocketFailed;
        errdefer {
            _ = c.close(pair[0]);
            _ = c.close(pair[1]);
        }
        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            if (c.fork() == 0) {
                _ = c.setsid();
                _ = c.dup2(pair[1], 0);
                _ = c.dup2(pair[1], 1);
                _ = c.close(pair[0]);
                _ = c.close(pair[1]);
                _ = c.execvp(bin, @ptrCast(@constCast(argv)));
            }
            c._exit(0);
        }
        var st: c_int = 0;
        _ = c.waitpid(pid, &st, 0);
        _ = c.close(pair[1]);
        return .{ .allocator = allocator, .fd = pair[0] };
    }

    /// Blocking read of the next complete frame. The returned
    /// payload is heap-owned by `allocator`; caller frees.
    pub const OwnedFrame = struct {
        ftype: wire.FrameType,
        payload: []u8,

        pub fn deinit(self: OwnedFrame, allocator: std.mem.Allocator) void {
            allocator.free(self.payload);
        }
    };

    pub fn recvFrame(self: *Conn) !OwnedFrame {
        while (true) {
            if (try self.takeFrame()) |owned| return owned;
            var tmp: [16384]u8 = undefined;
            const n = c.read(self.fd, &tmp, tmp.len);
            if (n <= 0) return error.Disconnected;
            try self.rbuf.appendSlice(self.allocator, tmp[0..@intCast(n)]);
        }
    }

    /// `recvFrame` with a deadline: error.Timeout when no COMPLETE
    /// frame arrived within `timeout_ms` (partial bytes stay buffered
    /// — inspect `pendingPartial` for a useful diagnostic).
    pub fn recvFrameFor(self: *Conn, timeout_ms: i64) !OwnedFrame {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        const deadline = @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000) + timeout_ms;
        while (true) {
            if (try self.takeFrame()) |owned| return owned;
            _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
            const remain = deadline - (@as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000));
            if (remain <= 0) return error.Timeout;
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            const pr = c.poll(&pfd, 1, @intCast(@min(remain, 100)));
            if (pr < 0 and std.posix.errno(pr) != .INTR) return error.Disconnected;
            if (pr <= 0) continue;
            var tmp: [16384]u8 = undefined;
            const n = c.read(self.fd, &tmp, tmp.len);
            if (n == 0) return error.Disconnected;
            if (n < 0) {
                const e = std.posix.errno(n);
                if (e == .AGAIN or e == .INTR) continue;
                return error.Disconnected;
            }
            try self.rbuf.appendSlice(self.allocator, tmp[0..@intCast(n)]);
        }
    }

    /// Half-arrived frame in the receive buffer, if any — for
    /// timeout diagnostics ("2.1 MB of an 8.3 MB frame buffered").
    pub fn pendingPartial(self: *const Conn) ?struct { expected: usize, have: usize } {
        const p = wire.partialInfo(self.rbuf.items) orelse return null;
        return .{ .expected = p.expected, .have = p.have };
    }

    /// Deadline-aware `recvExpect`; error.Timeout applies to the WHOLE
    /// wait, however many unrelated frames arrive meanwhile.
    pub fn recvExpectFor(self: *Conn, want: []const wire.FrameType, timeout_ms: i64) !OwnedFrame {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        const deadline = @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000) + timeout_ms;
        while (true) {
            _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
            const remain = deadline - (@as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000));
            if (remain <= 0) return error.Timeout;
            const f = try self.recvFrameFor(remain);
            for (want) |w| {
                if (f.ftype == w) return f;
            }
            if (f.ftype == .err) {
                const msg = errFieldOf(f.payload);
                const n = @min(msg.len, self.last_err.len);
                @memcpy(self.last_err[0..n], msg[0..n]);
                self.last_err_len = n;
                f.deinit(self.allocator);
                return error.DaemonError;
            }
            f.deinit(self.allocator);
        }
    }

    /// Peel one complete frame out of the read buffer, or null when what is
    /// buffered so far is only PART of a frame. Never touches the fd, so it
    /// cannot block.
    pub fn takeFrame(self: *Conn) !?OwnedFrame {
        const peeled = (try wire.peelFrame(self.rbuf.items)) orelse return null;
        const owned = try self.allocator.dupe(u8, peeled.frame.payload);
        const remaining = self.rbuf.items.len - peeled.consumed;
        std.mem.copyForwards(u8, self.rbuf.items[0..remaining], self.rbuf.items[peeled.consumed..]);
        self.rbuf.shrinkRetainingCapacity(remaining);
        // One big frame (a multi-MB window buffer) must not pin its
        // high-water capacity for the connection's lifetime.
        if (remaining == 0 and self.rbuf.capacity > (4 << 20))
            self.rbuf.clearAndFree(self.allocator);
        return .{ .ftype = peeled.frame.ftype, .payload = owned };
    }

    /// Top the read buffer up with whatever bytes have already arrived, without
    /// blocking. Returns false only if the peer hung up.
    ///
    /// This exists because recvFrame's read() BLOCKS: a big frame (an 8 MB window
    /// buffer, say) arrives in many chunks, so "the fd is readable" does NOT mean a
    /// whole frame is there. A caller that only wants what is already queued must
    /// not be made to wait for a tail that may never come.
    pub fn fillAvailable(self: *Conn) bool {
        // Byte budget: a peer that streams faster than we consume
        // (video-playing app at full tilt) keeps the fd readable
        // FOREVER — without a cap this loop never returns and the
        // caller's own deadline (checked between calls) never fires.
        var budget: usize = 4 << 20;
        while (true) {
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(&pfd, 1, 0) <= 0) return true;
            if ((pfd.revents & (c.POLLIN | c.POLLHUP)) == 0) return true;
            var tmp: [16384]u8 = undefined;
            const n = c.read(self.fd, &tmp, tmp.len);
            if (n <= 0) return false; // hung up
            self.rbuf.appendSlice(self.allocator, tmp[0..@intCast(n)]) catch return false;
            if (@as(usize, @intCast(n)) < tmp.len) return true; // drained the socket
            if (budget <= @as(usize, @intCast(n))) return true; // cap hit; rest next pump
            budget -= @intCast(n);
        }
    }

    /// Receive frames until one of `want` arrives; frames of other
    /// types are discarded (e.g. EVENTS noise while waiting for an
    /// OK). On an `err` frame (not in `want`) it stashes the daemon's
    /// message in `self.last_err` and returns `error.DaemonError` —
    /// read `lastErr()` to surface WHY instead of a bare error name.
    pub fn recvExpect(self: *Conn, want: []const wire.FrameType) !OwnedFrame {
        while (true) {
            const f = try self.recvFrame();
            for (want) |w| {
                if (f.ftype == w) return f;
            }
            if (f.ftype == .err) {
                const msg = errFieldOf(f.payload);
                const n = @min(msg.len, self.last_err.len);
                @memcpy(self.last_err[0..n], msg[0..n]);
                self.last_err_len = n;
                f.deinit(self.allocator);
                return error.DaemonError;
            }
            f.deinit(self.allocator);
        }
    }

    /// The message from the last `.err` frame `recvExpect` saw.
    pub fn lastErr(self: *const Conn) []const u8 {
        return self.last_err[0..self.last_err_len];
    }
};

test "transport fd is close-on-exec so it cannot leak into a later child" {
    // Regression: socketpair() without SOCK_CLOEXEC handed every transport
    // socket to every child spawned afterwards (proxy N held N-1 foreign
    // sockets, confirmed via /proc/<pid>/fd). The peer of an old connection
    // then cannot see EOF until the last of those children exits, so a dead
    // GUI's durable sessions stay attached on the daemon.
    const a = std.testing.allocator;
    var conn = try Conn.spawnOverSocketpair(a, "/bin/true", &[_:null]?[*:0]const u8{ "/bin/true", null });
    defer conn.deinit();
    const flags = c.fcntl(conn.fd, c.F_GETFD);
    try std.testing.expect(flags >= 0);
    try std.testing.expect(flags & c.FD_CLOEXEC != 0);
}

test "remote transport specs default to auto and preserve forced modes" {
    const t = std.testing;
    const automatic = RemoteSpec.parse("user@box");
    try t.expectEqual(RemoteMode.auto, automatic.mode);
    try t.expectEqualStrings("user@box", automatic.host);
    const udp = RemoteSpec.parse("udp:user@box");
    try t.expectEqual(RemoteMode.udp, udp.mode);
    try t.expectEqualStrings("user@box", udp.host);
    const ssh = RemoteSpec.parse("ssh:user@box");
    try t.expectEqual(RemoteMode.ssh, ssh.mode);
    try t.expectEqualStrings("user@box", ssh.host);
}

fn fakeUdpSuccess(allocator: std.mem.Allocator, host: []const u8, _: ?[]const u8) !Conn {
    if (!std.mem.eql(u8, host, "box")) return error.BadPath;
    return .{ .allocator = allocator, .fd = -1, .transport = .udp };
}

fn fakeUdpFailure(_: std.mem.Allocator, _: []const u8, _: ?[]const u8) !Conn {
    return error.SshTransportFailed;
}

fn fakeSshSuccess(allocator: std.mem.Allocator, host: []const u8, _: ?[]const u8) !Conn {
    if (!std.mem.eql(u8, host, "box")) return error.BadPath;
    return .{ .allocator = allocator, .fd = -1, .transport = .ssh };
}

test "automatic remote transport prefers UDP and falls back to SSH" {
    const t = std.testing;
    const udp = try Conn.connectRemoteUsing(t.allocator, "box", null, fakeUdpSuccess, fakeUdpSuccess, fakeSshSuccess);
    try t.expectEqual(Transport.udp, udp.transport);
    const ssh = try Conn.connectRemoteUsing(t.allocator, "box", null, fakeUdpFailure, fakeUdpFailure, fakeSshSuccess);
    try t.expectEqual(Transport.ssh, ssh.transport);
}

test "explicit remote transport never falls back" {
    const t = std.testing;
    try t.expectError(
        error.SshTransportFailed,
        Conn.connectRemoteUsing(t.allocator, "udp:box", null, fakeUdpFailure, fakeUdpFailure, fakeSshSuccess),
    );
    const ssh = try Conn.connectRemoteUsing(t.allocator, "ssh:box", null, fakeUdpSuccess, fakeUdpSuccess, fakeSshSuccess);
    try t.expectEqual(Transport.ssh, ssh.transport);
}

test "welcome records older and future daemon profiles without rejecting either" {
    const a = std.testing.allocator;
    var conn = Conn{ .allocator = a, .fd = -1 };
    conn.applyWelcome(a, "{\"proto\":5}");
    try std.testing.expectEqual(@as(u32, 5), conn.proto);
    try std.testing.expectEqual(@as(u32, 5), conn.server_proto);
    conn.applyWelcome(a, "{\"proto\":6,\"server_proto\":9,\"negotiation\":1}");
    try std.testing.expectEqual(@as(u32, 6), conn.proto);
    try std.testing.expectEqual(@as(u32, 9), conn.server_proto);
    conn.applyWelcome(a, "{\"proto\":0,\"server_proto\":9,\"negotiation\":1}");
    try std.testing.expectEqual(@as(u32, 0), conn.proto);
    conn.applyWelcome(a, "{\"proto\":9}");
    try std.testing.expectEqual(@as(u32, 0), conn.proto);
    try std.testing.expectEqual(@as(u32, 9), conn.server_proto);
    try std.testing.expectError(error.NoSharedTerminalProfile, conn.sendFrame(.attach, "{}"));
    try std.testing.expectError(error.NoSharedTerminalProfile, conn.queueFrame(.kill, "{}"));
    conn.applyWelcome(a, "{");
    try std.testing.expectEqual(@as(u32, 0), conn.proto);
}

/// Pull the `error` string out of a daemon err payload (`{"error":"…"}`)
/// without a full JSON parse. Falls back to the raw payload.
fn errFieldOf(payload: []const u8) []const u8 {
    const key = "\"error\":\"";
    const i = std.mem.indexOf(u8, payload, key) orelse return payload;
    const rest = payload[i + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return payload;
    return rest[0..end];
}
