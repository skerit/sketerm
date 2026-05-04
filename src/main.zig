// sketerm — terminal emulator entry point.

const std = @import("std");
const c = @import("c.zig").c;
const Window = @import("ui/window.zig").Window;

const APP_ID: [*:0]const u8 = "dev.sker.sketerm";
const VERSION = "0.1.0";

const App = struct {
    allocator: std.mem.Allocator,
    window: ?*Window = null,
    restore: bool = false,
    layout_path: ?[]const u8 = null,
    no_save: bool = false,
    debug_events: bool = false,
    debug_images: bool = false,
    config_path: ?[]const u8 = null,
};

const HELP_TEXT =
    \\sketerm — native GTK4 terminal emulator
    \\
    \\Usage: sketerm [OPTIONS]
    \\
    \\Options:
    \\  --restore             Load tabs from $XDG_STATE_HOME/sketerm/last.json
    \\  --layout <path>       Load tabs from a layout file (.json or .layout)
    \\                        (Without either flag, sketerm auto-loads
    \\                        $XDG_STATE_HOME/sketerm/default.json if
    \\                        present — see save_default_layout action.)
    \\  --no-save             Don't write last.json on exit
    \\  --config <path>       Load config from <path> instead of XDG default
    \\  --toggle              Show/hide the running instance (Quake mode).
    \\                        Bind your compositor's keyboard shortcut to
    \\                        `sketerm --toggle`. KWin: System Settings →
    \\                        Shortcuts → Custom Shortcuts. Wayland note:
    \\                        focus-stealing prevention may delay raise.
    \\  --debug-events        Print parser events to stderr
    \\  --debug-images        Print image upload + draw diagnostics to stderr
    \\  --help                Show this message
    \\  --version             Show version
    \\
    \\Keyboard shortcuts (built-in):
    \\  Ctrl+Shift+T          New tab
    \\  Ctrl+Shift+W          Close tab / pane
    \\  Ctrl+Tab              Next tab
    \\  Ctrl+Shift+Tab        Previous tab
    \\  Alt+1 .. Alt+9        Jump to tab N
    \\  Ctrl+Shift+D          Split horizontal
    \\  Ctrl+Shift+R          Split vertical
    \\  Ctrl+Shift+C          Copy selection
    \\  Ctrl+Shift+V          Paste
    \\  Ctrl+Shift+A          Copy whole visible screen
    \\                        (bind keybind.copy_scrollback for the
    \\                        full scrollback ring)
    \\  Ctrl+Shift+K          Clear screen + scrollback
    \\  Ctrl+Shift+F          Open scrollback search
    \\  Ctrl+I (in search)    Toggle case-insensitive override
    \\                          (default: smart-case — uppercase → CS)
    \\  Ctrl+R (in search)    Toggle regex mode (POSIX ERE)
    \\  Ctrl+Shift+S          Save current layout (last.json)
    \\  Ctrl+Shift+Alt+S      Save Layout As… (file picker)
    \\  (no default)          Save layout as default (auto-loads on
    \\                        next start, no --restore needed). Bind
    \\                        via keybind.save_default_layout.
    \\  Ctrl+Shift+Z          Re-open most recently closed tab
    \\  Ctrl+Shift+P          Pin / unpin current tab
    \\  Ctrl+Shift+Up/Down    Jump to prev/next OSC 133 prompt mark
    \\  Ctrl+Shift+Left/Right Cycle focus between panes in the tab
    \\  Ctrl+= / Ctrl+-       Increase / decrease font size
    \\  Ctrl+0                Reset font size
    \\  Ctrl+,                Open Preferences (also: right-click menu)
    \\  Shift+PgUp / PgDn     Scroll back / forward by one screenful
    \\  Ctrl+Shift+Home/End   Jump to scrollback top / live bottom
    \\
    \\Right-click for context menu (split / new tab / etc).
    \\Mouse wheel scrolls scrollback (10k lines default).
    \\
    \\Send SIGUSR1 to reload config without restart:
    \\    kill -USR1 $(pidof sketerm)
    \\
    \\Config: $XDG_CONFIG_HOME/sketerm/config.conf (or
    \\        ~/.config/sketerm/config.conf). See data/sample.conf.
    \\        Env vars below override values from the file.
    \\
    \\Environment:
    \\  SKETERM_FONT          Override font (absolute path to .ttf/.otf)
    \\  SKETERM_SCROLLBACK    Scrollback line capacity (default 10000)
    \\
    \\Layout file (.layout) — one tab per top-level line, 2-space indent.
    \\Inside a tab, use `pane <command...> [@ <cwd>]` for a single pane,
    \\or `hsplit` / `vsplit` followed by two indented children for splits
    \\(splits can nest). Lines beginning with `#` are comments. Example:
    \\
    \\    Dev
    \\      hsplit
    \\        pane bash @ /tmp
    \\        pane fish @ /home
    \\    Logs
    \\      pane less /var/log/syslog
    \\
    \\See data/sample.layout for a fuller example.
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

    // --help and --version exit before reaching GApplication so the
    // user gets output even with no display. Everything else is
    // forwarded to the primary instance via "command-line" so a
    // second `sketerm --toggle` invocation reaches the running app.
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            var stdout_buf: [4096]u8 = undefined;
            var stdout = std.fs.File.stdout().writer(&stdout_buf);
            stdout.interface.print("{s}", .{HELP_TEXT}) catch {};
            stdout.interface.flush() catch {};
            return 0;
        } else if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) {
            var stdout_buf: [128]u8 = undefined;
            var stdout = std.fs.File.stdout().writer(&stdout_buf);
            stdout.interface.print("sketerm {s}\n", .{VERSION}) catch {};
            stdout.interface.flush() catch {};
            return 0;
        }
    }

    // GApplication parses argv inside the "command-line" signal
    // handler (our `onCommandLine`). With HANDLES_COMMAND_LINE the
    // primary instance's signal fires for both its own startup
    // (is_remote=false) and any subsequent invocation
    // (is_remote=true) — that's what makes `sketerm --toggle`
    // reach a running window.
    const c_argv: [*c][*c]u8 = @ptrCast(@alignCast(std.os.argv.ptr));
    const argc: c_int = @intCast(std.os.argv.len);

    const app = c.adw_application_new(APP_ID, c.G_APPLICATION_HANDLES_COMMAND_LINE);
    defer c.g_object_unref(app);

    _ = c.g_signal_connect_data(
        app,
        "command-line",
        @ptrCast(&onCommandLine),
        null,
        null,
        c.G_CONNECT_DEFAULT,
    );
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

    // Register the `toggle` GAction on the application — second
    // instance's command-line handler invokes it via D-Bus when
    // --toggle is passed.
    const toggle_action = c.g_simple_action_new("toggle", null);
    _ = c.g_signal_connect_data(
        toggle_action,
        "activate",
        @ptrCast(&onToggleAction),
        null,
        null,
        c.G_CONNECT_DEFAULT,
    );
    c.g_action_map_add_action(@ptrCast(app), @ptrCast(toggle_action));
    c.g_object_unref(toggle_action);

    // Graceful shutdown on SIGTERM / SIGHUP / SIGINT — these
    // call g_application_quit which fires our "shutdown" signal,
    // letting saveLayoutQuietly run before exit.
    _ = c.g_unix_signal_add(c.SIGTERM, onSignalQuit, @ptrCast(app));
    _ = c.g_unix_signal_add(c.SIGHUP, onSignalQuit, @ptrCast(app));
    _ = c.g_unix_signal_add(c.SIGINT, onSignalQuit, @ptrCast(app));
    // SIGUSR1 → reload config — useful for `kill -USR1 $(pidof sketerm)`
    // from a script after editing config.conf. Same effect as the
    // reload_config keybind but from outside the app.
    _ = c.g_unix_signal_add(c.SIGUSR1, onSignalReloadConfig, null);

    const status = c.g_application_run(@ptrCast(app), argc, c_argv);
    return @intCast(status & 0xff);
}

fn onSignalQuit(user: ?*anyopaque) callconv(.c) c.gboolean {
    const app: *c.GApplication = @ptrCast(@alignCast(user.?));
    c.g_application_quit(app);
    return 0; // remove source
}

fn onSignalReloadConfig(_: ?*anyopaque) callconv(.c) c.gboolean {
    // g_unix_signal_add dispatches on the main thread; safe to
    // reach into Window from here.
    if (g_app.window) |win| win.reloadConfigFromDisk();
    return 1; // keep source — reload should be re-armable
}

/// HANDLES_COMMAND_LINE handler. Fires both for the primary instance
/// (with `is_remote=false`) and for every subsequent invocation
/// (`is_remote=true`). We parse argv either way.
fn onCommandLine(app: ?*c.GApplication, cmdline: ?*c.GApplicationCommandLine, _: ?*anyopaque) callconv(.c) c_int {
    var argc: c_int = 0;
    const argv_raw = c.g_application_command_line_get_arguments(cmdline, &argc);
    defer c.g_strfreev(argv_raw);

    var saw_toggle = false;
    var n: c_int = 0;
    while (n < argc) : (n += 1) {
        const a_raw = argv_raw[@intCast(n)];
        if (a_raw == null) break;
        const a = std.mem.span(@as([*:0]const u8, @ptrCast(a_raw)));
        if (std.mem.eql(u8, a, "--toggle")) {
            saw_toggle = true;
        } else if (std.mem.eql(u8, a, "--restore")) {
            g_app.restore = true;
        } else if (std.mem.eql(u8, a, "--layout") and n + 1 < argc) {
            n += 1;
            const v = std.mem.span(@as([*:0]const u8, @ptrCast(argv_raw[@intCast(n)])));
            g_app.layout_path = g_app.allocator.dupe(u8, v) catch null;
        } else if (std.mem.eql(u8, a, "--no-save")) {
            g_app.no_save = true;
        } else if (std.mem.eql(u8, a, "--debug-events")) {
            g_app.debug_events = true;
        } else if (std.mem.eql(u8, a, "--debug-images")) {
            g_app.debug_images = true;
        } else if (std.mem.eql(u8, a, "--config") and n + 1 < argc) {
            n += 1;
            const v = std.mem.span(@as([*:0]const u8, @ptrCast(argv_raw[@intCast(n)])));
            g_app.config_path = g_app.allocator.dupe(u8, v) catch null;
        }
    }

    if (saw_toggle) {
        // Activate the toggle action if a window already exists; if
        // we are the primary and no window yet, fall through to
        // activate so the first --toggle launches and shows.
        const has_window = c.g_application_get_is_registered(app) != 0 and g_app.window != null;
        if (has_window) {
            c.g_action_group_activate_action(@ptrCast(app), "toggle", null);
            return 0;
        }
    }

    // No --toggle (or first run): proceed with the normal activate
    // path so the window is created.
    c.g_application_activate(app);
    return 0;
}

fn onToggleAction(_: *c.GSimpleAction, _: ?*c.GVariant, _: ?*anyopaque) callconv(.c) void {
    const win = g_app.window orelse return;
    win.toggleQuake();
}

fn onActivate(app: ?*c.GtkApplication, _: ?*anyopaque) callconv(.c) void {
    // Honour --config path if provided, otherwise let Window.init use
    // the default XDG-search loader.
    const Config = @import("config.zig").Config;
    const cfg_override: ?Config = if (g_app.config_path) |p|
        Config.loadWithOverride(g_app.allocator, p)
    else
        null;
    const window = Window.initWithConfig(g_app.allocator, app, cfg_override) catch |err| {
        std.debug.print("sketerm: window init failed: {s}\n", .{@errorName(err)});
        return;
    };
    window.debug_events = g_app.debug_events;
    window.debug_images = g_app.debug_images;
    g_app.window = window;

    var loaded = false;
    if (g_app.layout_path) |path| {
        loaded = window.loadLayoutFromPath(path) catch false;
    } else if (g_app.restore) {
        loaded = window.loadLayoutDefault() catch false;
    } else {
        // No explicit flag: try the user's saved default.json. Silent
        // no-op when the file isn't there (fresh install).
        loaded = window.loadDefaultLayoutIfPresent() catch false;
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
        if (!g_app.no_save) w.saveLayoutQuietly();
        w.deinit();
        g_app.window = null;
    }
}
