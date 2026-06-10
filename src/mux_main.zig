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
    var buf: [32768]u8 = undefined;
    while (true) {
        if (cc.poll(&fds, fds.len, -1) < 0) continue;
        if (fds[0].revents & (cc.POLLIN | cc.POLLHUP) != 0) {
            const n = cc.read(0, &buf, buf.len);
            if (n <= 0) return 0;
            if (!writeFull(conn.fd, buf[0..@intCast(n)])) return 0;
        }
        if (fds[1].revents & (cc.POLLIN | cc.POLLHUP) != 0) {
            const n = cc.read(conn.fd, &buf, buf.len);
            if (n <= 0) return 0;
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
