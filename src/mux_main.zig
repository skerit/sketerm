// sketerm-mux — session daemon entry point.
//
// Lean binary: terminal core + poll loop, no GTK. Deploys to
// servers standalone; the GUI spawns it on demand locally.

const std = @import("std");
const c = @import("c.zig").c;
const daemon = @import("mux/daemon.zig");
const platform = @import("util/platform.zig");
const VERSION = @import("version.zig").string;

/// SIGPIPE "ignore" via a no-op handler. The libc `SIG_IGN` macro
/// fails translate-c (function-pointer cast) and its raw value (1)
/// violates fn-pointer alignment on aarch64-macos. For SIGPIPE the
/// no-op handler is equivalent: write() still returns EPIPE, the
/// process just doesn't die.
fn sigNoop(_: c_int) callconv(.c) void {}
const sig_ign = &sigNoop;

const HELP =
    \\sketerm-mux — sketerm session daemon (durable panes)
    \\
    \\Usage: sketerm-mux [--socket PATH] [--idle-exit SECS]
    \\       sketerm-mux --proxy
    \\       sketerm-mux --udp-listen [--udp-port LO:HI]
    \\       sketerm-mux display <create|run|inspect|list|destroy> ...
    \\       sketerm-mux --version
    \\
    \\Runs in the foreground, listening on PATH (default
    \\$XDG_RUNTIME_DIR/sketerm/mux.sock). Clients (the sketerm GUI or
    \\`sketerm mux ...`) connect over the socket to spawn, attach,
    \\and control sessions. Shells keep running while no client is
    \\attached; SIGTERM shuts down (and kills the sessions).
    \\--idle-exit SECS makes the daemon exit by itself once it has held
    \\no session and no client for that long (private MCP instances).
    \\$SKETERM_MUX_LIFETIME_FD=N names an inherited pipe read end; the
    \\daemon (and every worker it forks) shuts down when it hits EOF,
    \\i.e. when the process holding the write end is gone. Test rigs
    \\set it so nothing they start outlives them.
    \\
    \\--proxy bridges stdin/stdout to the daemon socket, starting the
    \\daemon if needed. This is the SSH transport: the sketerm GUI
    \\runs `ssh <host> sketerm-mux --proxy` and speaks the mux
    \\protocol over the SSH pipe — sessions live in the REMOTE
    \\daemon and survive the connection.
    \\
    \\`display` manages EXTERNAL display sessions: a named session whose
    \\child is a keeper process, existing only to own a Wayland display
    \\an outside program (a browser under test automation, say) renders
    \\into. `display create --json` prints the environment to export;
    \\never derive those socket paths yourself. A human can attach the
    \\normal sketerm GUI to the same session later and take over.
    \\
    \\--udp-listen is the mosh-style bootstrap (run via ssh): binds a
    \\UDP port, announces "SKETERM-UDP <port> <key>" on stdout, then
    \\detaches and serves encrypted datagrams. --udp-port pins the
    \\port to a firewall-open range (e.g. 60000:61000). A client that
    \\sends "SKETERM-PUNCH <port>" on stdin gets NAT hole-punch
    \\probes aimed at its $SSH_CONNECTION address.
    \\
;

pub fn main(init: std.process.Init.Minimal) u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var sock_path: ?[]const u8 = null;
    var broker_mode = false;
    var idle_exit_ms: i64 = 0;
    const argv = init.args.vector;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = std.mem.span(argv[i]);
        if (std.mem.eql(u8, a, "--socket") and i + 1 < argv.len) {
            i += 1;
            sock_path = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, a, "--broker")) {
            // Process-isolation mode: hold no sessions; fork one worker per
            // session and hand client fds to workers (Firefox-style).
            broker_mode = true;
        } else if (std.mem.eql(u8, a, "--idle-exit") and i + 1 < argv.len) {
            // Exit once no session and no client has existed for this many
            // seconds. Opt-in: a per-user daemon lives client-less for days
            // by design; an MCP instance's private daemon should not.
            i += 1;
            const secs = std.fmt.parseInt(u32, std.mem.span(argv[i]), 10) catch {
                std.debug.print("sketerm-mux: bad --idle-exit '{s}' (want whole seconds)\n", .{std.mem.span(argv[i])});
                return 2;
            };
            idle_exit_ms = @as(i64, secs) * 1000;
        } else if (std.mem.eql(u8, a, "--job")) {
            // Internal: file-job helper (spawned by the daemon; spec on
            // stdin, JSON-lines progress on stdout). One process per
            // copy/delete_tree/hash operation — kill = cancel.
            return @import("mux/fsjob.zig").serve(allocator);
        } else if (std.mem.eql(u8, a, "--keep")) {
            // Internal: the keeper child of a display session. Blocks
            // on stdin (its PTY) and exits at EOF, so the PTY machinery
            // is exactly what it is for a shell — no special case in
            // the daemon, and killing the session kills this.
            const cc = @import("c.zig").c;
            _ = cc.signal(cc.SIGPIPE, sig_ign);
            return @import("mux/keep.zig").serve();
        } else if (std.mem.eql(u8, a, "display")) {
            // Everything after the keyword belongs to the subcommand.
            var rest: std.ArrayList([]const u8) = .empty;
            defer rest.deinit(allocator);
            // Preserve a global `--socket PATH` parsed before `display`.
            // A display-local option comes later and therefore wins.
            if (sock_path) |path| {
                rest.append(allocator, "--socket") catch return 1;
                rest.append(allocator, path) catch return 1;
            }
            var j: usize = i + 1;
            while (j < argv.len) : (j += 1) rest.append(allocator, std.mem.span(argv[j])) catch return 1;
            return @import("mux/display.zig").run(allocator, rest.items);
        } else if (std.mem.eql(u8, a, "--proxy")) {
            return runProxy(allocator);
        } else if (std.mem.eql(u8, a, "--udp-listen")) {
            // Optional: --udp-port 60000:61000 (firewalls usually need a
            // pinned range, like mosh's 60000-61000) and --socket PATH
            // (bridge to a specific daemon instance — the udp-ticket
            // broker passes its own socket; the ssh bootstrap never does).
            var range: ?[2]u16 = null;
            var listen_sock: ?[]const u8 = null;
            var j = i + 1;
            while (j < argv.len) : (j += 1) {
                const arg = std.mem.span(argv[j]);
                if (std.mem.eql(u8, arg, "--udp-port") and j + 1 < argv.len) {
                    j += 1;
                    range = parsePortRange(std.mem.span(argv[j])) orelse {
                        std.debug.print("sketerm-mux: bad --udp-port (want lo:hi)\n", .{});
                        return 2;
                    };
                } else if (std.mem.eql(u8, arg, "--socket") and j + 1 < argv.len) {
                    j += 1;
                    listen_sock = std.mem.span(argv[j]);
                } else {
                    std.debug.print("sketerm-mux: unknown --udp-listen argument: {s}\n", .{arg});
                    return 2;
                }
            }
            return runUdpListen(allocator, range, listen_sock);
        } else if (std.mem.eql(u8, a, "--udp-connect") and i + 3 < argv.len) {
            // Optional 4th arg: an inherited pre-bound socket fd — the
            // port the client announced in its punch line. Old binaries
            // ignore trailing args here, so version skew degrades to a
            // punchless (= previous) connect instead of an error.
            return runUdpConnect(
                allocator,
                std.mem.span(argv[i + 1]),
                std.mem.span(argv[i + 2]),
                std.mem.span(argv[i + 3]),
                if (i + 4 < argv.len) std.mem.span(argv[i + 4]) else null,
            );
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("{s}", .{HELP});
            return 0;
        } else if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) {
            // stdout, not std.debug.print's stderr: this is the scriptable
            // skew check, and `sketerm --version` prints to stdout too.
            _ = c.fprintf(platform.stdout(), "sketerm-mux %s\n", @as([*:0]const u8, VERSION));
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

    // Resolved BEFORE the socket is bound: a refused fence must not leave
    // a half-started instance squatting the path.
    const lifetime = @import("util/lifetime.zig");
    const lifetime_fd = lifetime.inherited() catch {
        std.debug.print("sketerm-mux: {s} names a descriptor this process does not hold; refusing to start unfenced\n", .{lifetime.ENV});
        return 2;
    };

    const d = daemon.Daemon.init(allocator, path) catch |err| {
        std.debug.print("sketerm-mux: bind {s} failed: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    d.is_broker = broker_mode;
    d.idle_exit_ms = idle_exit_ms;
    d.lifetime_fd = lifetime_fd;
    // The autostart knob travelled in OUR environment; the shells and
    // apps this daemon spawns must not carry it on to daemons THEY start.
    _ = c.unsetenv(@import("mux/client.zig").Conn.IDLE_EXIT_ENV);
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
    _ = cc.signal(cc.SIGPIPE, sig_ign);

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
                if (platform.selfExecPathZ(&self_buf)) |_| {
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
const punch = @import("mux/punch.zig");

fn parsePortRange(s: []const u8) ?[2]u16 {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return null;
    const lo = std.fmt.parseInt(u16, s[0..colon], 10) catch return null;
    const hi = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch return null;
    if (lo == 0 or hi < lo) return null;
    return .{ lo, hi };
}

/// Monotonic milliseconds (Zig 0.16 removed std.time.milliTimestamp).
const nowMs = @import("util/clock.zig").nowMs;

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
fn runUdpListen(allocator: std.mem.Allocator, port_range: ?[2]u16, sock_path: ?[]const u8) u8 {
    const cc = @import("c.zig").c;
    _ = cc.signal(cc.SIGPIPE, sig_ign);

    var udp_fd = platform.socketCloexec(cc.AF_INET, cc.SOCK_DGRAM, 0);
    // Park the socket above the stdio range: when the spawner has fds
    // 0-2 closed (a detached daemon minting a udp ticket), the socket
    // lands there and the post-announce `close(0..2)` detach below
    // would destroy it — announced port, nobody listening.
    if (udp_fd >= 0 and udp_fd < 3) {
        const moved = cc.fcntl(udp_fd, cc.F_DUPFD_CLOEXEC, @as(c_int, 3));
        _ = cc.close(udp_fd);
        udp_fd = if (moved >= 0) moved else -1;
    }
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
    // fflush(NULL) = flush ALL streams (POSIX) — portable across
    // libcs where `stdout` is a macro/inline fn translate-c mangles.
    _ = cc.fflush(null);

    // Hole punch: a new client announces its own UDP port on stdin
    // and $SSH_CONNECTION names the address it connected from.
    // Pre-aiming the channel there turns the first keepalive tick
    // into the probe that opens THIS side's NAT, so the client's
    // retransmitted hello can get in even when the announced port is
    // not reachable from outside; roaming latches the true source
    // once a packet authenticates. See punch.zig for the timing —
    // this wait is normally instant, never longer than 2s.
    var punch_target: ?punch.Endpoint = null;
    {
        var lbuf: [64]u8 = undefined;
        if (punch.readLine(0, 2_000, &lbuf)) |line| {
            if (punch.parseLine(line)) |client_port| {
                if (cc.getenv("SSH_CONNECTION")) |sc| {
                    punch_target = punch.clientEndpoint(std.mem.span(sc), client_port);
                }
            }
        }
    }

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
    const unix_fd = connectDaemonRetry(allocator, sock_path) orelse return 1;

    var chan = rudp.Channel.init(allocator, key, false);
    defer chan.deinit();
    var out = UdpOut{ .fd = udp_fd };
    if (punch_target) |ep| {
        var pa: cc.struct_sockaddr_in = std.mem.zeroes(cc.struct_sockaddr_in);
        pa.sin_family = cc.AF_INET;
        pa.sin_port = std.mem.nativeToBig(u16, ep.port);
        pa.sin_addr.s_addr = std.mem.bytesToValue(u32, &ep.ip);
        @memcpy(@as([*]u8, @ptrCast(&out.peer))[0..@sizeOf(cc.struct_sockaddr_in)], @as([*]const u8, @ptrCast(&pa))[0..@sizeOf(cc.struct_sockaddr_in)]);
        out.peer_len = @sizeOf(cc.struct_sockaddr_in);
    }
    // A bootstrap whose client never shows up must not squat the port
    // forever. An authenticated but abandoned peer gets the same roaming
    // grace as the local bridge, then retires so stale viewers do not leak.
    return bridgeUdp(allocator, &chan, &out, udp_fd, unix_fd, unix_fd, true, nowMs() + 60_000, null, 30_000);
}

/// `--udp-connect <ip> <port> <keyhex> [fd]`: run on the LOCAL side
/// as a transport child (socketpair on stdin/stdout, like --proxy).
/// `fd` is an inherited pre-bound UDP socket — its port is what the
/// client's punch line announced, so using it (instead of a fresh
/// socket) is what makes the remote's punch target real.
fn runUdpConnect(allocator: std.mem.Allocator, host: []const u8, port_s: []const u8, keyhex: []const u8, fd_s: ?[]const u8) u8 {
    const cc = @import("c.zig").c;
    _ = cc.signal(cc.SIGPIPE, sig_ign);

    const key = rudp.keyFromHex(keyhex) orelse return 1;
    const port = std.fmt.parseInt(u16, port_s, 10) catch return 1;

    var host_z: [256:0]u8 = undefined;
    const hz = std.fmt.bufPrintZ(&host_z, "{s}", .{host}) catch return 1;
    var port_z: [8:0]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&port_z, "{d}", .{port}) catch return 1;

    var hints: cc.struct_addrinfo = std.mem.zeroes(cc.struct_addrinfo);
    // --udp-listen currently binds IPv4, so do not select an IPv6 AAAA
    // result first (notably localhost -> ::1) for an unreachable peer.
    hints.ai_family = cc.AF_INET;
    hints.ai_socktype = cc.SOCK_DGRAM;
    var res: ?*cc.struct_addrinfo = null;
    if (cc.getaddrinfo(hz.ptr, pz.ptr, &hints, &res) != 0 or res == null) {
        std.debug.print("sketerm-mux: cannot resolve {s}\n", .{host});
        return 1;
    }
    defer cc.freeaddrinfo(res);

    const ai = res.?;
    const udp_fd = blk: {
        if (fd_s) |s| {
            if (std.fmt.parseInt(c_int, s, 10)) |fd| {
                if (cc.fcntl(fd, cc.F_GETFD) >= 0) break :blk fd;
            } else |_| {}
        }
        break :blk platform.socketCloexec(ai.ai_family, cc.SOCK_DGRAM, 0);
    };
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
    // roam=true on the CLIENT side too: a hole-punch probe from a
    // NATed server arrives from its SNAT source, which need not be
    // the announced port. Only authenticated packets may re-aim us,
    // same rule as the server side.
    return bridgeUdp(allocator, &chan, &out, udp_fd, 0, 1, true, start + 15_000, .{
        .at = start + 5_000,
        .msg = warn_msg,
    }, 30_000);
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
    authenticated_timeout_ms: ?i64,
) u8 {
    const cc = @import("c.zig").c;
    const queue_limit = 8 << 20;
    var deliver: std.ArrayList(u8) = .empty;
    defer deliver.deinit(allocator);
    var stream_pending: std.ArrayList(u8) = .empty;
    defer stream_pending.deinit(allocator);
    const stream_flags = cc.fcntl(stream_out, cc.F_GETFL, @as(c_int, 0));
    if (stream_flags >= 0) _ = cc.fcntl(stream_out, cc.F_SETFL, stream_flags | cc.O_NONBLOCK);
    var ever_authenticated = false;
    var last_authenticated_ms: i64 = 0;
    var warned = false;

    while (true) {
        const now = nowMs();
        if (abandon_deadline) |dl| {
            if (!ever_authenticated and now > dl) {
                if (warn != null) std.debug.print("sketerm-mux: giving up on UDP transport\n", .{});
                return 1;
            }
        }
        if (authenticated_timeout_ms) |limit| {
            if (ever_authenticated and now - last_authenticated_ms >= limit) {
                std.debug.print("sketerm-mux: authenticated UDP peer silent for {d}s; reconnecting\n", .{@divTrunc(limit, 1000)});
                return 1;
            }
        }
        if (warn) |w| {
            if (!warned and !ever_authenticated and now > w.at) {
                warned = true;
                // raw write(2) to fd 2 — `stderr` is a macro/inline
                // fn on Darwin's libc that translate-c mangles.
                _ = cc.write(2, w.msg.ptr, w.msg.len);
            }
        }
        const deadline = chan.tick(now, UdpOut.emit, @ptrCast(out));
        const timeout: c_int = if (deadline) |d|
            @intCast(@max(@as(i64, 10), @min(d - now, 3000)))
        else
            3000;

        var fds = [_]cc.struct_pollfd{
            .{ .fd = udp_fd, .events = cc.POLLIN, .revents = 0 },
            .{ .fd = stream_in, .events = if (chan.queuedBytes() < queue_limit) cc.POLLIN else 0, .revents = 0 },
            .{ .fd = stream_out, .events = if (stream_pending.items.len > 0) cc.POLLOUT else 0, .revents = 0 },
        };
        if (cc.poll(&fds, fds.len, timeout) < 0) continue;
        const now2 = nowMs();

        if (fds[0].revents & (cc.POLLERR | cc.POLLNVAL) != 0 or
            fds[1].revents & (cc.POLLERR | cc.POLLNVAL) != 0 or
            fds[2].revents & (cc.POLLERR | cc.POLLNVAL) != 0)
        {
            return 1;
        }

        if (stream_pending.items.len > 0 and fds[2].revents & cc.POLLOUT != 0) {
            if (!flushStreamPending(&stream_pending, stream_out)) return 0;
        }

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
                    last_authenticated_ms = now2;
                    if (roam) {
                        out.peer = from;
                        out.peer_len = from_len;
                    }
                }
                if (deliver.items.len > 0) {
                    if (stream_pending.items.len + deliver.items.len > queue_limit) {
                        chan.sendBye(now2, UdpOut.emit, @ptrCast(out));
                        return 1;
                    }
                    stream_pending.appendSlice(allocator, deliver.items) catch return 1;
                    if (!flushStreamPending(&stream_pending, stream_out)) return 0;
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

fn flushStreamPending(pending: *std.ArrayList(u8), fd: c_int) bool {
    const cc = @import("c.zig").c;
    var off: usize = 0;
    while (off < pending.items.len) {
        const n = cc.write(fd, pending.items.ptr + off, pending.items.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        if (n < 0) {
            const err = std.posix.errno(n);
            if (err == .INTR) continue;
            if (err == .AGAIN) break;
        }
        return false;
    }
    @import("mux/wire.zig").compactConsumed(pending, off);
    return true;
}

/// Connect to the local daemon socket, starting the daemon when
/// absent (detached re-exec of /proc/self/exe). Shared by --proxy
/// and --udp-listen. A non-null `sock_path` targets a SPECIFIC
/// instance (the udp-ticket broker's own socket) and never
/// autostarts: replacing a private daemon with a fresh default one
/// would silently connect the ticket holder to the wrong daemon.
fn connectDaemonRetry(allocator: std.mem.Allocator, sock_path: ?[]const u8) ?c_int {
    const cc = @import("c.zig").c;
    const client = @import("mux/client.zig");
    const path = if (sock_path) |p|
        allocator.dupe(u8, p) catch return null
    else
        daemon.defaultSocketPath(allocator) catch return null;
    defer allocator.free(path);

    if (client.Conn.connect(allocator, path)) |conn_v| {
        var conn = conn_v;
        const fd = conn.fd;
        conn.rbuf.deinit(conn.allocator); // keep fd, drop the wrapper
        return fd;
    } else |_| {}
    if (sock_path != null) return null;

    const pid = cc.fork();
    if (pid == 0) {
        _ = cc.setsid();
        if (cc.fork() == 0) {
            var self_buf: [4096:0]u8 = undefined;
            if (platform.selfExecPathZ(&self_buf)) |_| {
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
    _ = cc.signal(cc.SIGPIPE, sig_ign);
}
