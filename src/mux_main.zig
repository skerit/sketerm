// sketerm-mux — session daemon entry point.
//
// Lean binary: terminal core + poll loop, no GTK. Deploys to
// servers standalone; the GUI spawns it on demand locally.

const std = @import("std");
const daemon = @import("mux/daemon.zig");

const HELP =
    \\sketerm-mux — sketerm session daemon (durable panes)
    \\
    \\Usage: sketerm-mux [--socket PATH]
    \\       sketerm-mux --proxy
    \\       sketerm-mux --udp-listen [--udp-port LO:HI]
    \\
    \\Runs in the foreground, listening on PATH (default
    \\$XDG_RUNTIME_DIR/sketerm/mux.sock). Clients (the sketerm GUI or
    \\`sketerm mux ...`) connect over the socket to spawn, attach,
    \\and control sessions. Shells keep running while no client is
    \\attached; SIGTERM shuts down (and kills the sessions).
    \\
    \\--proxy bridges stdin/stdout to the daemon socket, starting the
    \\daemon if needed. This is the SSH transport: the sketerm GUI
    \\runs `ssh <host> sketerm-mux --proxy` and speaks the mux
    \\protocol over the SSH pipe — sessions live in the REMOTE
    \\daemon and survive the connection.
    \\
    \\--udp-listen is the mosh-style bootstrap (run via ssh): binds a
    \\UDP port, announces "SKETERM-UDP <port> <key>" on stdout, then
    \\detaches and serves encrypted datagrams. --udp-port pins the
    \\port to a firewall-open range (e.g. 60000:61000).
    \\
;

pub fn main(init: std.process.Init.Minimal) u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var sock_path: ?[]const u8 = null;
    const argv = init.args.vector;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = std.mem.span(argv[i]);
        if (std.mem.eql(u8, a, "--socket") and i + 1 < argv.len) {
            i += 1;
            sock_path = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, a, "--proxy")) {
            return runProxy(allocator);
        } else if (std.mem.eql(u8, a, "--udp-listen")) {
            // Optional: --udp-listen --udp-port 60000:61000 (firewalls
            // usually need a pinned range, like mosh's 60000-61000).
            var range: ?[2]u16 = null;
            if (i + 2 < argv.len and std.mem.eql(u8, std.mem.span(argv[i + 1]), "--udp-port")) {
                range = parsePortRange(std.mem.span(argv[i + 2])) orelse {
                    std.debug.print("sketerm-mux: bad --udp-port (want lo:hi)\n", .{});
                    return 2;
                };
            }
            return runUdpListen(allocator, range);
        } else if (std.mem.eql(u8, a, "--udp-connect") and i + 3 < argv.len) {
            return runUdpConnect(
                allocator,
                std.mem.span(argv[i + 1]),
                std.mem.span(argv[i + 2]),
                std.mem.span(argv[i + 3]),
            );
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("{s}", .{HELP});
            return 0;
        } else {
            std.debug.print("sketerm-mux: unknown argument: {s}\n", .{a});
            return 2;
        }
    }

    const path = if (sock_path) |p|
        allocator.dupe(u8, p) catch return 1
    else
        daemon.defaultSocketPath(allocator) catch return 1;
    defer allocator.free(path);

    const d = daemon.Daemon.init(allocator, path) catch |err| {
        std.debug.print("sketerm-mux: bind {s} failed: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    defer d.deinit();
    g_daemon = d;

    // SIGTERM/SIGINT → clean shutdown (socket unlink, child reap).
    installSignalHandlers();

    d.run() catch |err| {
        std.debug.print("sketerm-mux: fatal: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

/// --proxy: bridge stdin/stdout ↔ the local daemon socket, starting
/// the daemon when absent. Runs on the REMOTE side of an SSH pipe.
fn runProxy(allocator: std.mem.Allocator) u8 {
    const cc = @import("c.zig").c;
    _ = cc.signal(cc.SIGPIPE, cc.SIG_IGN);

    const path = daemon.defaultSocketPath(allocator) catch return 1;
    defer allocator.free(path);

    const client = @import("mux/client.zig");
    var conn = client.Conn.connect(allocator, path) catch blk: {
        // No daemon yet — start one (re-exec ourselves, detached via
        // double fork so it reparents to init and outlives the ssh).
        const pid = cc.fork();
        if (pid == 0) {
            _ = cc.setsid();
            if (cc.fork() == 0) {
                var self_buf: [4096:0]u8 = undefined;
                const n = cc.readlink("/proc/self/exe", &self_buf, self_buf.len - 1);
                if (n > 0) {
                    self_buf[@intCast(n)] = 0;
                    const argv0 = [_:null]?[*:0]const u8{ &self_buf, null };
                    _ = cc.execv(&self_buf, @ptrCast(@constCast(&argv0)));
                }
            }
            cc._exit(0);
        }
        var st: c_int = 0;
        _ = cc.waitpid(pid, &st, 0);
        var tries: u32 = 0;
        while (tries < 40) : (tries += 1) {
            _ = cc.usleep(50_000);
            if (client.Conn.connect(allocator, path)) |conn2| break :blk conn2 else |_| {}
        }
        std.debug.print("sketerm-mux --proxy: daemon unreachable\n", .{});
        return 1;
    };
    defer conn.deinit();

    // Byte pump: stdin → socket, socket → stdout. Either side's EOF
    // ends the bridge (the daemon treats it as client disconnect,
    // i.e. detach — sessions keep running).
    var fds = [_]cc.struct_pollfd{
        .{ .fd = 0, .events = cc.POLLIN, .revents = 0 },
        .{ .fd = conn.fd, .events = cc.POLLIN, .revents = 0 },
    };
    // Test hook: SKETERM_MUX_DELAY_MS sleeps before forwarding each
    // chunk in both directions, simulating a high-latency link
    // (RTT ≈ 2 × value) for predictive-echo testing.
    var delay_us: c_uint = 0;
    if (cc.getenv("SKETERM_MUX_DELAY_MS")) |v| {
        const span = std.mem.span(@as([*:0]const u8, @ptrCast(v)));
        if (std.fmt.parseInt(c_uint, span, 10)) |ms| delay_us = ms * 1000 else |_| {}
    }

    var buf: [32768]u8 = undefined;
    while (true) {
        if (cc.poll(&fds, fds.len, -1) < 0) continue;
        if (fds[0].revents & (cc.POLLIN | cc.POLLHUP) != 0) {
            const n = cc.read(0, &buf, buf.len);
            if (n <= 0) return 0;
            if (delay_us != 0) _ = cc.usleep(delay_us);
            if (!writeFull(conn.fd, buf[0..@intCast(n)])) return 0;
        }
        if (fds[1].revents & (cc.POLLIN | cc.POLLHUP) != 0) {
            const n = cc.read(conn.fd, &buf, buf.len);
            if (n <= 0) return 0;
            if (delay_us != 0) _ = cc.usleep(delay_us);
            if (!writeFull(1, buf[0..@intCast(n)])) return 0;
        }
        if (fds[0].revents & cc.POLLERR != 0 or fds[1].revents & cc.POLLERR != 0) return 0;
    }
}

fn writeFull(fd: c_int, bytes: []const u8) bool {
    const cc = @import("c.zig").c;
    var off: usize = 0;
    while (off < bytes.len) {
        const n = cc.write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) {
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            return false;
        }
        off += @intCast(n);
    }
    return true;
}

// ── UDP transport (mosh-style) ──────────────────────────────────

const rudp = @import("mux/rudp.zig");

fn parsePortRange(s: []const u8) ?[2]u16 {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return null;
    const lo = std.fmt.parseInt(u16, s[0..colon], 10) catch return null;
    const hi = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch return null;
    if (lo == 0 or hi < lo) return null;
    return .{ lo, hi };
}

/// Monotonic milliseconds (Zig 0.16 removed std.time.milliTimestamp).
fn nowMs() i64 {
    const cc = @import("c.zig").c;
    var ts: cc.struct_timespec = undefined;
    _ = cc.clock_gettime(cc.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

/// Emit context: sendto the (possibly roaming) peer.
const UdpOut = struct {
    fd: c_int,
    peer: cc_sockaddr_storage = undefined,
    peer_len: u32 = 0,

    fn emit(ctx: ?*anyopaque, dgram: []const u8) void {
        const cc = @import("c.zig").c;
        const self: *UdpOut = @ptrCast(@alignCast(ctx.?));
        if (self.peer_len == 0) return; // peer unknown yet
        _ = cc.sendto(self.fd, dgram.ptr, dgram.len, 0, @ptrCast(&self.peer), self.peer_len);
    }
};

const cc_sockaddr_storage = @import("c.zig").c.struct_sockaddr_storage;

/// `--udp-listen`: run on the REMOTE end via the ssh bootstrap.
/// Binds an ephemeral UDP port, prints "SKETERM-UDP <port> <key>"
/// for the client to read over the ssh pipe, then detaches from ssh
/// and bridges encrypted UDP ↔ the local daemon socket. One
/// instance per connection (the mosh-server model); exits on BYE or
/// daemon loss, NOT on network silence — that's the durability.
fn runUdpListen(allocator: std.mem.Allocator, port_range: ?[2]u16) u8 {
    const cc = @import("c.zig").c;
    _ = cc.signal(cc.SIGPIPE, cc.SIG_IGN);

    const udp_fd = cc.socket(cc.AF_INET, cc.SOCK_DGRAM | cc.SOCK_CLOEXEC, 0);
    if (udp_fd < 0) return 1;
    var bind_addr: cc.struct_sockaddr_in = std.mem.zeroes(cc.struct_sockaddr_in);
    bind_addr.sin_family = cc.AF_INET;
    bind_addr.sin_addr.s_addr = cc.INADDR_ANY;
    if (port_range) |r| {
        // Pinned range: first free port wins.
        var p: u32 = r[0];
        var bound = false;
        while (p <= r[1]) : (p += 1) {
            bind_addr.sin_port = std.mem.nativeToBig(u16, @intCast(p));
            if (cc.bind(udp_fd, @ptrCast(&bind_addr), @sizeOf(cc.struct_sockaddr_in)) == 0) {
                bound = true;
                break;
            }
        }
        if (!bound) {
            std.debug.print("sketerm-mux: no free UDP port in {d}:{d}\n", .{ r[0], r[1] });
            return 1;
        }
    } else {
        bind_addr.sin_port = 0;
        if (cc.bind(udp_fd, @ptrCast(&bind_addr), @sizeOf(cc.struct_sockaddr_in)) != 0) return 1;
    }
    var got_addr: cc.struct_sockaddr_in = undefined;
    var got_len: cc.socklen_t = @sizeOf(cc.struct_sockaddr_in);
    if (cc.getsockname(udp_fd, @ptrCast(&got_addr), &got_len) != 0) return 1;
    const port = std.mem.bigToNative(u16, got_addr.sin_port);

    var key: [rudp.KEY_LEN]u8 = undefined;
    if (cc.getentropy(&key, key.len) != 0) return 1;
    var hexbuf: [rudp.KEY_LEN * 2]u8 = undefined;
    const keyhex = rudp.keyToHex(key, &hexbuf);
    _ = cc.printf("SKETERM-UDP %u %.*s\n", @as(c_uint, port), @as(c_int, @intCast(keyhex.len)), keyhex.ptr);
    _ = cc.fflush(cc.stdout);

    // Detach from the ssh session: the bootstrap is done, the
    // connection now lives on UDP. Parent exits → ssh returns.
    const pid = cc.fork();
    if (pid < 0) return 1;
    if (pid > 0) return 0;
    _ = cc.setsid();
    _ = cc.close(0);
    _ = cc.close(1);
    _ = cc.close(2);

    // Daemon connection (start it if needed — same as --proxy).
    const unix_fd = connectDaemonRetry(allocator) orelse return 1;

    var chan = rudp.Channel.init(allocator, key, false);
    defer chan.deinit();
    var out = UdpOut{ .fd = udp_fd };
    // A bootstrap whose client never shows up must not squat the
    // port forever (abandoned `ssh host sketerm-mux --udp-listen`).
    // Once a client HAS authenticated, we wait indefinitely — that
    // persistence is what makes roaming + reattach work.
    return bridgeUdp(allocator, &chan, &out, udp_fd, unix_fd, unix_fd, true, nowMs() + 60_000, null);
}

/// `--udp-connect <ip> <port> <keyhex>`: run on the LOCAL side as a
/// transport child (socketpair on stdin/stdout, like --proxy).
fn runUdpConnect(allocator: std.mem.Allocator, host: []const u8, port_s: []const u8, keyhex: []const u8) u8 {
    const cc = @import("c.zig").c;
    _ = cc.signal(cc.SIGPIPE, cc.SIG_IGN);

    const key = rudp.keyFromHex(keyhex) orelse return 1;
    const port = std.fmt.parseInt(u16, port_s, 10) catch return 1;

    var host_z: [256:0]u8 = undefined;
    const hz = std.fmt.bufPrintZ(&host_z, "{s}", .{host}) catch return 1;
    var port_z: [8:0]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&port_z, "{d}", .{port}) catch return 1;

    var hints: cc.struct_addrinfo = std.mem.zeroes(cc.struct_addrinfo);
    hints.ai_family = cc.AF_UNSPEC;
    hints.ai_socktype = cc.SOCK_DGRAM;
    var res: ?*cc.struct_addrinfo = null;
    if (cc.getaddrinfo(hz.ptr, pz.ptr, &hints, &res) != 0 or res == null) {
        std.debug.print("sketerm-mux: cannot resolve {s}\n", .{host});
        return 1;
    }
    defer cc.freeaddrinfo(res);

    const ai = res.?;
    const udp_fd = cc.socket(ai.ai_family, cc.SOCK_DGRAM | cc.SOCK_CLOEXEC, 0);
    if (udp_fd < 0) return 1;

    var chan = rudp.Channel.init(allocator, key, true);
    defer chan.deinit();
    var out = UdpOut{ .fd = udp_fd };
    @memcpy(@as([*]u8, @ptrCast(&out.peer))[0..ai.ai_addrlen], @as([*]const u8, @ptrCast(ai.ai_addr))[0..ai.ai_addrlen]);
    out.peer_len = ai.ai_addrlen;

    // Say hello on the wire so the server learns our address before
    // any daemon traffic flows.
    _ = chan.tick(nowMs(), UdpOut.emit, @ptrCast(&out));

    // The client gives up when the server never proves key
    // possession: warn at 5s (likely a firewalled port), exit at 15s
    // so the GUI's blocking handshake fails instead of hanging.
    var warn_buf: [320]u8 = undefined;
    const warn_msg = std.fmt.bufPrint(
        &warn_buf,
        "sketerm-mux: no UDP reply from {s}:{d} after 5s — is the port blocked? Try plain `sketerm ssh {s}` or pin mux_udp_port_range to a firewall-open range.\n",
        .{ host, port, host },
    ) catch "sketerm-mux: no UDP reply after 5s — port blocked?\n";
    const start = nowMs();
    return bridgeUdp(allocator, &chan, &out, udp_fd, 0, 1, false, start + 15_000, .{
        .at = start + 5_000,
        .msg = warn_msg,
    });
}

/// Shared pump: encrypted UDP ↔ a local byte stream.
/// `roam` (server side): update out.peer from the source address of
/// every AUTHENTICATED datagram.
const UdpWarn = struct {
    at: i64,
    msg: []const u8,
};

fn bridgeUdp(
    allocator: std.mem.Allocator,
    chan: *rudp.Channel,
    out: *UdpOut,
    udp_fd: c_int,
    stream_in: c_int,
    stream_out: c_int,
    roam: bool,
    abandon_deadline: ?i64,
    warn: ?UdpWarn,
) u8 {
    const cc = @import("c.zig").c;
    var deliver: std.ArrayList(u8) = .empty;
    defer deliver.deinit(allocator);
    var ever_authenticated = false;
    var warned = false;

    while (true) {
        const now = nowMs();
        if (abandon_deadline) |dl| {
            if (!ever_authenticated and now > dl) {
                if (warn != null) _ = cc.fprintf(cc.stderr, "sketerm-mux: giving up on UDP transport\n");
                return 1;
            }
        }
        if (warn) |w| {
            if (!warned and !ever_authenticated and now > w.at) {
                warned = true;
                _ = cc.fwrite(w.msg.ptr, 1, w.msg.len, cc.stderr);
            }
        }
        const deadline = chan.tick(now, UdpOut.emit, @ptrCast(out));
        const timeout: c_int = if (deadline) |d|
            @intCast(@max(@as(i64, 10), @min(d - now, 3000)))
        else
            3000;

        var fds = [_]cc.struct_pollfd{
            .{ .fd = udp_fd, .events = cc.POLLIN, .revents = 0 },
            .{ .fd = stream_in, .events = cc.POLLIN, .revents = 0 },
        };
        if (cc.poll(&fds, fds.len, timeout) < 0) continue;
        const now2 = nowMs();

        if (fds[0].revents & cc.POLLIN != 0) {
            var dgram: [rudp.MAX_DGRAM + 64]u8 = undefined;
            var from: cc_sockaddr_storage = undefined;
            var from_len: cc.socklen_t = @sizeOf(cc_sockaddr_storage);
            const n = cc.recvfrom(udp_fd, &dgram, dgram.len, 0, @ptrCast(&from), &from_len);
            if (n > 0) {
                deliver.clearRetainingCapacity();
                const alive = chan.onDatagram(dgram[0..@intCast(n)], now2, &deliver, UdpOut.emit, @ptrCast(out)) catch true;
                if (chan.last_rx_authenticated) {
                    ever_authenticated = true;
                    if (roam) {
                        out.peer = from;
                        out.peer_len = from_len;
                    }
                }
                if (deliver.items.len > 0) {
                    if (!writeFull(stream_out, deliver.items)) {
                        chan.sendBye(now2, UdpOut.emit, @ptrCast(out));
                        return 0;
                    }
                }
                if (!alive) return 0; // peer said bye
            }
        }

        if (fds[1].revents & (cc.POLLIN | cc.POLLHUP) != 0) {
            var buf: [16384]u8 = undefined;
            const n = cc.read(stream_in, &buf, buf.len);
            if (n <= 0) {
                chan.sendBye(now2, UdpOut.emit, @ptrCast(out));
                return 0;
            }
            chan.send(buf[0..@intCast(n)], now2, UdpOut.emit, @ptrCast(out)) catch return 1;
        }
    }
}

/// Connect to the local daemon socket, starting the daemon when
/// absent (detached re-exec of /proc/self/exe). Shared by --proxy
/// and --udp-listen.
fn connectDaemonRetry(allocator: std.mem.Allocator) ?c_int {
    const cc = @import("c.zig").c;
    const client = @import("mux/client.zig");
    const path = daemon.defaultSocketPath(allocator) catch return null;
    defer allocator.free(path);

    if (client.Conn.connect(allocator, path)) |conn_v| {
        var conn = conn_v;
        const fd = conn.fd;
        conn.rbuf.deinit(conn.allocator); // keep fd, drop the wrapper
        return fd;
    } else |_| {}

    const pid = cc.fork();
    if (pid == 0) {
        _ = cc.setsid();
        if (cc.fork() == 0) {
            var self_buf: [4096:0]u8 = undefined;
            const n = cc.readlink("/proc/self/exe", &self_buf, self_buf.len - 1);
            if (n > 0) {
                self_buf[@intCast(n)] = 0;
                const argv0 = [_:null]?[*:0]const u8{ &self_buf, null };
                _ = cc.execv(&self_buf, @ptrCast(@constCast(&argv0)));
            }
        }
        cc._exit(0);
    }
    var st: c_int = 0;
    _ = cc.waitpid(pid, &st, 0);
    var tries: u32 = 0;
    while (tries < 40) : (tries += 1) {
        _ = cc.usleep(50_000);
        if (client.Conn.connect(allocator, path)) |conn_v| {
            var conn = conn_v;
            const fd = conn.fd;
            conn.rbuf.deinit(conn.allocator);
            return fd;
        } else |_| {}
    }
    return null;
}

var g_daemon: ?*daemon.Daemon = null;

fn onTerm(_: c_int) callconv(.c) void {
    if (g_daemon) |d| d.running = false;
}

fn installSignalHandlers() void {
    const cc = @import("c.zig").c;
    _ = cc.signal(cc.SIGTERM, onTerm);
    _ = cc.signal(cc.SIGINT, onTerm);
    // Writing to a client that vanished must not kill the daemon.
    _ = cc.signal(cc.SIGPIPE, cc.SIG_IGN);
}
