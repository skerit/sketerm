// sketerm — terminal emulator entry point.
//
// M0: bare AdwApplication that opens an empty window.
// M1: also spawns a PTY running $SHELL on activation; PTY events
//     are decoded and printed to stderr for verification.
// Subsequent milestones add the grid + renderer + tabs/splits/...

const std = @import("std");
const c = @import("c.zig").c;
const Pty = @import("pty.zig").Pty;
const Terminal = @import("terminal.zig").Terminal;

const APP_ID: [*:0]const u8 = "dev.sker.sketerm";

const App = struct {
    allocator: std.mem.Allocator,
    terminal: ?*Terminal = null,
};

var g_app: App = undefined;

pub fn main() u8 {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    g_app = .{ .allocator = allocator };

    const argv = std.process.argsAlloc(allocator) catch return 1;
    defer std.process.argsFree(allocator, argv);

    var c_argv = allocator.alloc(?[*:0]u8, argv.len + 1) catch return 1;
    defer allocator.free(c_argv);
    for (argv, 0..) |arg, i| c_argv[i] = @constCast(arg.ptr);
    c_argv[argv.len] = null;

    const argc: c_int = @intCast(argv.len);
    const argv_ptr: [*c][*c]u8 = @ptrCast(c_argv.ptr);

    const app = c.adw_application_new(APP_ID, c.G_APPLICATION_DEFAULT_FLAGS);
    defer c.g_object_unref(app);

    _ = c.g_signal_connect_data(
        app,
        "activate",
        @ptrCast(&onActivate),
        null,
        null,
        c.G_CONNECT_DEFAULT,
    );
    _ = c.g_signal_connect_data(
        app,
        "shutdown",
        @ptrCast(&onShutdown),
        null,
        null,
        c.G_CONNECT_DEFAULT,
    );

    const status = c.g_application_run(@ptrCast(app), argc, argv_ptr);
    return @intCast(status & 0xff);
}

fn onActivate(app: ?*c.GtkApplication, _: ?*anyopaque) callconv(.c) void {
    const window = c.adw_application_window_new(app);
    c.gtk_window_set_title(@ptrCast(window), "sketerm");
    c.gtk_window_set_default_size(@ptrCast(window), 1000, 700);

    // M1: spawn $SHELL into a PTY; route events to stderr.
    const shell_env = c.getenv("SHELL");
    const shell: [*:0]const u8 = if (shell_env != null) @ptrCast(shell_env) else "/bin/bash";
    const argv = [_][*:0]const u8{shell};

    const pty = Pty.spawn(.{
        .argv = &argv,
        .rows = 24,
        .cols = 80,
    }) catch |err| {
        std.debug.print("sketerm: pty spawn failed: {s}\n", .{@errorName(err)});
        c.gtk_window_present(@ptrCast(window));
        return;
    };

    const term = Terminal.init(g_app.allocator, pty, 80, 24) catch |err| {
        std.debug.print("sketerm: terminal init failed: {s}\n", .{@errorName(err)});
        return;
    };
    term.debug_to_stderr = true;
    g_app.terminal = term;

    c.gtk_window_present(@ptrCast(window));
}

fn onShutdown(_: ?*c.GApplication, _: ?*anyopaque) callconv(.c) void {
    if (g_app.terminal) |t| {
        t.deinit();
        g_app.terminal = null;
    }
}
