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
const Pane = @import("ui/pane.zig").Pane;

const APP_ID: [*:0]const u8 = "dev.sker.sketerm";

const App = struct {
    allocator: std.mem.Allocator,
    terminal: ?*Terminal = null,
    pane: ?*Pane = null,
    window: ?*c.GtkWidget = null,
    title_buf: [256]u8 = undefined,
};

fn onTitle(ctx: ?*anyopaque, title: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    const window = app.window orelse return;
    const n = @min(title.len, app.title_buf.len - 1);
    @memcpy(app.title_buf[0..n], title[0..n]);
    app.title_buf[n] = 0;
    c.gtk_window_set_title(@ptrCast(window), @ptrCast(&app.title_buf));
}

fn onClipboardSet(ctx: ?*anyopaque, text: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    const window = app.window orelse return;
    const display = c.gtk_widget_get_display(window);
    const clip = c.gdk_display_get_clipboard(display);
    // Allocate null-terminated copy.
    const cstr = app.allocator.allocSentinel(u8, text.len, 0) catch return;
    defer app.allocator.free(cstr);
    @memcpy(cstr, text);
    c.gdk_clipboard_set_text(clip, cstr.ptr);
}

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

    // Set TERM and COLORTERM in the child env so apps detect us correctly.
    const term_env: [*:0]const u8 = "TERM=xterm-256color";
    const colorterm_env: [*:0]const u8 = "COLORTERM=truecolor";
    const term_program: [*:0]const u8 = "TERM_PROGRAM=sketerm";
    const extra_env = [_][*:0]const u8{ term_env, colorterm_env, term_program };
    _ = extra_env; // pty.spawn doesn't yet honor extra_env; setenv'd in spawn directly.

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
    g_app.terminal = term;

    // Wire title and clipboard callbacks.
    g_app.window = window;
    term.user_ctx = @ptrCast(&g_app);
    term.on_title = onTitle;
    term.on_clipboard_set = onClipboardSet;

    const pane = Pane.init(g_app.allocator, term) catch |err| {
        std.debug.print("sketerm: pane init failed: {s}\n", .{@errorName(err)});
        return;
    };
    g_app.pane = pane;

    c.adw_application_window_set_content(@ptrCast(window), pane.widget());
    c.gtk_window_present(@ptrCast(window));
}

fn onShutdown(_: ?*c.GApplication, _: ?*anyopaque) callconv(.c) void {
    if (g_app.pane) |p| {
        p.deinit();
        g_app.pane = null;
    }
    if (g_app.terminal) |t| {
        t.deinit();
        g_app.terminal = null;
    }
}
