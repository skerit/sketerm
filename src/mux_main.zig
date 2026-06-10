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
    \\
    \\Runs in the foreground, listening on PATH (default
    \\$XDG_RUNTIME_DIR/sketerm/mux.sock). Clients (the sketerm GUI or
    \\`sketerm mux ...`) connect over the socket to spawn, attach,
    \\and control sessions. Shells keep running while no client is
    \\attached; SIGTERM shuts down (and kills the sessions).
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
