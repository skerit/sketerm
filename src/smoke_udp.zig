//! End-to-end smoke for the UDP transport + NAT hole punch.
//!
//! Runs the REAL pieces against an isolated in-process daemon: a fake
//! ssh (SKETERM_SSH) execs the freshly built `sketerm-mux --udp-listen`
//! (argv[1], via SKETERM_MUX_BIN) with a loopback $SSH_CONNECTION, and
//! `Conn.connectUdp` drives the whole bootstrap — punch line on ssh
//! stdin, inherited pre-bound socket, bridge child, rudp handshake.
//!
//! Stage 2 is the punch proof: the fake ssh rewrites the announcement
//! to a WRONG port, so the client's hellos go into a void — exactly
//! what a NAT that drops unsolicited inbound looks like. The connect
//! can then only succeed via the server's pre-aimed authenticated
//! probe plus client-side roaming. Before the punch existed this
//! scenario timed out. `zig build smoke-udp`.

const std = @import("std");
const c = @import("c.zig").c;
const daemon_mod = @import("mux/daemon.zig");
const client_mod = @import("mux/client.zig");

fn fail(msg: []const u8) noreturn {
    std.debug.print("smoke-udp: FAIL: {s}\n", .{msg});
    std.process.exit(1);
}

fn sigNoop(_: c_int) callconv(.c) void {}

fn daemonMain(d: *daemon_mod.Daemon) void {
    d.run() catch |err| {
        std.debug.print("smoke-udp: daemon error: {s}\n", .{@errorName(err)});
    };
}

fn writeScript(path: [:0]const u8, body: []const u8) void {
    const f = c.fopen(path.ptr, "w") orelse fail("script open");
    if (c.fwrite(body.ptr, 1, body.len, f) != body.len) fail("script write");
    _ = c.fclose(f);
    if (c.chmod(path.ptr, 0o755) != 0) fail("script chmod");
}

fn connectStage(allocator: std.mem.Allocator, label: []const u8) void {
    var conn = client_mod.Conn.connectUdp(allocator, "smoke-udp-host", null) catch |err| {
        std.debug.print("smoke-udp: {s}: connectUdp failed: {s}\n", .{ label, @errorName(err) });
        std.process.exit(1);
    };
    defer conn.deinit();
    if (conn.transport != .udp) fail("transport is not udp");
    // A second round-trip beyond the internal hello/welcome proves the
    // stream carries traffic both ways after the handshake.
    conn.sendFrame(.list, "") catch fail("list send");
    const w = conn.recvExpectFor(&.{.welcome}, 10_000) catch fail("list reply");
    w.deinit(allocator);
    std.debug.print("smoke-udp: {s} ok\n", .{label});
}

pub fn main(init: std.process.Init.Minimal) u8 {
    _ = c.signal(c.SIGPIPE, &sigNoop);
    // This binary hosts a daemon; answer the keeper re-exec like the
    // other smoke rigs do.
    if (@import("mux/keep.zig").wanted(init.args.vector)) return @import("mux/keep.zig").serve();

    const argv = init.args.vector;
    if (argv.len < 2) {
        std.debug.print("smoke-udp: usage: smoke-udp <path-to-sketerm-mux>\n", .{});
        return 2;
    }

    var gpa_state: std.heap.DebugAllocator(.{ .safety = true }) = .{};
    defer if (gpa_state.deinit() == .leak) {
        std.debug.print("smoke-udp: FAIL — leaked memory (see GPA report above)\n", .{});
        std.process.exit(1);
    };
    const allocator = gpa_state.allocator();

    // Isolated runtime dir: the --udp-listen child resolves the daemon
    // socket through $XDG_RUNTIME_DIR, so pointing it here keeps the
    // whole run away from the user's real daemon.
    var dir_buf: [128:0]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/sketerm-smoke-udp-{d}", .{c.getpid()}) catch unreachable;
    var sub_buf: [160:0]u8 = undefined;
    const sub = std.fmt.bufPrintZ(&sub_buf, "{s}/sketerm", .{dir}) catch unreachable;
    _ = c.mkdir(dir.ptr, 0o700);
    _ = c.mkdir(sub.ptr, 0o700);
    _ = c.setenv("XDG_RUNTIME_DIR", dir.ptr, 1);
    _ = c.setenv("SKETERM_MUX_BIN", argv[1], 1);

    var sock_buf: [200]u8 = undefined;
    const sock_path = std.fmt.bufPrint(&sock_buf, "{s}/mux.sock", .{sub}) catch unreachable;

    const d = daemon_mod.Daemon.init(allocator, sock_path) catch fail("daemon init");
    const th = std.Thread.spawn(.{}, daemonMain, .{d}) catch fail("thread spawn");

    // Fake ssh #1: straight pass-through. -G answers like OpenSSH so
    // the config-resolution step targets loopback; the bootstrap execs
    // the real daemon binary with a loopback $SSH_CONNECTION.
    var ssh1_buf: [160:0]u8 = undefined;
    const ssh1 = std.fmt.bufPrintZ(&ssh1_buf, "{s}/fake-ssh", .{dir}) catch unreachable;
    writeScript(ssh1,
        \\#!/bin/sh
        \\if [ "$1" = "-G" ]; then printf 'hostname 127.0.0.1\n'; exit 0; fi
        \\export SSH_CONNECTION="127.0.0.1 12345 127.0.0.1 22"
        \\exec "$SKETERM_MUX_BIN" --udp-listen
        \\
    );

    // Fake ssh #2: rewrites the announced port to a hole 7 above the
    // real one. The client aims its hellos there (void), so only the
    // server's punch probe + client roaming can complete the connect.
    var ssh2_buf: [160:0]u8 = undefined;
    const ssh2 = std.fmt.bufPrintZ(&ssh2_buf, "{s}/fake-ssh-natted", .{dir}) catch unreachable;
    writeScript(ssh2,
        \\#!/bin/sh
        \\if [ "$1" = "-G" ]; then printf 'hostname 127.0.0.1\n'; exit 0; fi
        \\export SSH_CONNECTION="127.0.0.1 12345 127.0.0.1 22"
        \\line=$("$SKETERM_MUX_BIN" --udp-listen)
        \\set -- $line
        \\echo "SKETERM-UDP $(($2 + 7)) $3"
        \\
    );

    // Fake ssh #3: emulates a real login shell — it RUNS the remote
    // command it is given (deploy phases hand it the single word `sh`,
    // the bootstrap hands it the exec of the deployed binary) against
    // an isolated $HOME. With SKETERM_MUX_PORTABLE set, connectUdp
    // deploys the real mux via the sh-on-stdin path and then boots
    // from the DEPLOYED copy.
    var home2_buf: [176:0]u8 = undefined;
    const home2 = std.fmt.bufPrintZ(&home2_buf, "{s}/home", .{dir}) catch unreachable;
    _ = c.mkdir(home2.ptr, 0o700);
    var ssh3_buf: [176:0]u8 = undefined;
    const ssh3 = std.fmt.bufPrintZ(&ssh3_buf, "{s}/fake-ssh-login", .{dir}) catch unreachable;
    var ssh3_body_buf: [512]u8 = undefined;
    const ssh3_body = std.fmt.bufPrint(&ssh3_body_buf,
        \\#!/bin/sh
        \\if [ "$1" = "-G" ]; then printf 'hostname 127.0.0.1\n'; exit 0; fi
        \\HOME={s}; export HOME
        \\export SSH_CONNECTION="127.0.0.1 12345 127.0.0.1 22"
        \\for a in "$@"; do cmd="$a"; done
        \\exec sh -c "$cmd"
        \\
    , .{home2}) catch unreachable;
    writeScript(ssh3, ssh3_body);

    _ = c.setenv("SKETERM_SSH", ssh1.ptr, 1);
    connectStage(allocator, "direct UDP connect");

    _ = c.setenv("SKETERM_SSH", ssh2.ptr, 1);
    connectStage(allocator, "hole-punched connect (wrong announced port)");

    _ = c.setenv("SKETERM_SSH", ssh3.ptr, 1);
    _ = c.setenv("SKETERM_MUX_PORTABLE", argv[1], 1);
    connectStage(allocator, "auto-deployed connect (emulated login shell)");
    _ = c.unsetenv("SKETERM_MUX_PORTABLE");
    {
        // The bootstrap above must have run the DEPLOYED binary: the
        // content-addressed copy exists in the isolated $HOME.
        const hash = @import("util/filehash.zig").sha256File(std.mem.span(argv[1])) orelse fail("hash artifact");
        var dep_buf: [320:0]u8 = undefined;
        const dep = std.fmt.bufPrintZ(&dep_buf, "{s}/.cache/sketerm/mux/sketerm-mux-{s}", .{ home2, &hash.hex }) catch unreachable;
        var st: c.struct_stat = undefined;
        if (c.stat(dep.ptr, &st) != 0) fail("deployed binary missing");
        if (@as(u64, @intCast(st.st_size)) != hash.size) fail("deployed binary size mismatch");
        _ = c.unlink(dep.ptr);
    }

    // Connection-ticket brokering: a live UDP connection mints a
    // sibling listener over its own sealed channel, and the second
    // connect dials it while ssh REFUSES to run anything but -G
    // (config resolution never connects) — proof the ticket path
    // needs no bootstrap.
    {
        _ = c.setenv("SKETERM_SSH", ssh1.ptr, 1);
        var conn = client_mod.Conn.connectUdp(allocator, "smoke-udp-host", null) catch fail("ticket stage connect");
        defer conn.deinit();
        if (!conn.udp_tickets) fail("welcome does not advertise udp_ticket");
        const ticket = conn.requestUdpTicket(null, 15_000) catch fail("ticket mint over live UDP conn");

        var ssh4_buf: [176:0]u8 = undefined;
        const ssh4 = std.fmt.bufPrintZ(&ssh4_buf, "{s}/fake-ssh-refuse", .{dir}) catch unreachable;
        writeScript(ssh4,
            \\#!/bin/sh
            \\if [ "$1" = "-G" ]; then printf 'hostname 127.0.0.1\n'; exit 0; fi
            \\echo "smoke-udp: ssh ran during a ticket connect" >&2
            \\exit 1
            \\
        );
        _ = c.setenv("SKETERM_SSH", ssh4.ptr, 1);
        var conn2 = client_mod.Conn.connectUdpTicket(allocator, "smoke-udp-host", ticket) catch fail("ticket connect");
        defer conn2.deinit();
        if (conn2.transport != .udp) fail("ticket transport is not udp");
        conn2.sendFrame(.list, "") catch fail("ticket list send");
        (conn2.recvExpectFor(&.{.welcome}, 10_000) catch fail("ticket list reply")).deinit(allocator);
        _ = c.unlink(ssh4.ptr);
        std.debug.print("smoke-udp: brokered ticket connect (no ssh bootstrap) ok\n", .{});
    }

    // Clean daemon shutdown so the leak check means something.
    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("shutdown connect");
    conn.sendFrame(.shutdown, "") catch fail("shutdown send");
    conn.deinit();
    th.join();
    d.deinit();

    _ = c.unlink(ssh1.ptr);
    _ = c.unlink(ssh2.ptr);
    std.debug.print("smoke-udp: PASS\n", .{});
    return 0;
}
