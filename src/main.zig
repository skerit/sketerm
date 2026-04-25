// sketerm — terminal emulator entry point.

const std = @import("std");
const c = @import("c.zig").c;
const Window = @import("ui/window.zig").Window;

const APP_ID: [*:0]const u8 = "dev.sker.sketerm";
const VERSION = "0.0.1";

const App = struct {
    allocator: std.mem.Allocator,
    window: ?*Window = null,
    restore: bool = false,
    layout_path: ?[]const u8 = null,
};

const HELP_TEXT =
    \\sketerm — native GTK4 terminal emulator
    \\
    \\Usage: sketerm [OPTIONS]
    \\
    \\Options:
    \\  --restore             Load tabs from $XDG_STATE_HOME/sketerm/last.json
    \\  --layout <path>       Load tabs from specific JSON layout file
    \\  --help                Show this message
    \\  --version             Show version
    \\
    \\Keyboard shortcuts (built-in):
    \\  Ctrl+Shift+T          New tab
    \\  Ctrl+Shift+W          Close tab / pane
    \\  Ctrl+Tab              Next tab
    \\  Ctrl+Shift+Tab        Previous tab
    \\  Ctrl+Shift+D          Split horizontal
    \\  Ctrl+Shift+R          Split vertical
    \\  Ctrl+Shift+C          Copy selection
    \\  Ctrl+Shift+V          Paste
    \\
    \\Right-click for context menu (split / new tab / etc).
    \\Mouse wheel scrolls scrollback (10k lines default).
    \\
;

var g_app: App = undefined;

pub fn main() u8 {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    g_app = .{ .allocator = allocator };

    const argv = std.process.argsAlloc(allocator) catch return 1;
    defer std.process.argsFree(allocator, argv);

    // Parse our own flags before handing to GTK (which would balk).
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--restore")) {
            g_app.restore = true;
        } else if (std.mem.eql(u8, a, "--layout") and i + 1 < argv.len) {
            i += 1;
            g_app.layout_path = argv[i];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("{s}", .{HELP_TEXT});
            return 0;
        } else if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) {
            std.debug.print("sketerm {s}\n", .{VERSION});
            return 0;
        }
    }

    // GTK gets argv[0] only (our flags would confuse it).
    var c_argv = allocator.alloc(?[*:0]u8, 2) catch return 1;
    defer allocator.free(c_argv);
    c_argv[0] = @constCast(argv[0].ptr);
    c_argv[1] = null;

    const argc: c_int = 1;
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

    // Graceful shutdown on SIGTERM / SIGHUP / SIGINT — these
    // call g_application_quit which fires our "shutdown" signal,
    // letting saveLayoutQuietly run before exit.
    _ = c.g_unix_signal_add(c.SIGTERM, onSignalQuit, @ptrCast(app));
    _ = c.g_unix_signal_add(c.SIGHUP, onSignalQuit, @ptrCast(app));
    _ = c.g_unix_signal_add(c.SIGINT, onSignalQuit, @ptrCast(app));

    const status = c.g_application_run(@ptrCast(app), argc, argv_ptr);
    return @intCast(status & 0xff);
}

fn onSignalQuit(user: ?*anyopaque) callconv(.c) c.gboolean {
    const app: *c.GApplication = @ptrCast(@alignCast(user.?));
    c.g_application_quit(app);
    return 0; // remove source
}

fn onActivate(app: ?*c.GtkApplication, _: ?*anyopaque) callconv(.c) void {
    const window = Window.init(g_app.allocator, app) catch |err| {
        std.debug.print("sketerm: window init failed: {s}\n", .{@errorName(err)});
        return;
    };
    g_app.window = window;

    var loaded = false;
    if (g_app.layout_path) |path| {
        loaded = window.loadLayoutFromPath(path) catch false;
    } else if (g_app.restore) {
        loaded = window.loadLayoutDefault() catch false;
    }

    if (!loaded) {
        window.newShellTab(null) catch |err| {
            std.debug.print("sketerm: spawn first tab failed: {s}\n", .{@errorName(err)});
            return;
        };
    }

    window.present();
}

fn onShutdown(_: ?*c.GApplication, _: ?*anyopaque) callconv(.c) void {
    if (g_app.window) |w| {
        w.saveLayoutQuietly();
        w.deinit();
        g_app.window = null;
    }
}
