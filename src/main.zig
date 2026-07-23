// sketerm — terminal emulator entry point.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const platform = @import("util/platform.zig");
const Window = @import("ui/window.zig").Window;

comptime {
    // macOS: emit the NSAccessibility bridge's export callbacks into the
    // GUI binary so the ObjC shim (linked via build.zig addNsaxBridge)
    // resolves them. The AppKit pane frontend then calls a11y/nsax.zig's
    // newView/notifyChanged with no further build wiring. No-op on Linux,
    // where panes use the GtkAccessibleText (atspi.zig) bridge instead.
    if (builtin.os.tag == .macos) _ = @import("a11y/nsax.zig");
}

const APP_ID: [*:0]const u8 = "dev.sker.sketerm";
const VERSION = @import("version.zig").string;

const App = struct {
    allocator: std.mem.Allocator,
    window: ?*Window = null,
    restore: bool = false,
    layout_path: ?[]const u8 = null,
    no_save: bool = false,
    hold: bool = false,
    debug_events: bool = false,
    debug_images: bool = false,
    config_path: ?[]const u8 = null,
    /// `sketerm files [spec]`: open a file-browser tab (standalone
    /// launcher mode; a running instance gains the tab instead).
    files_request: bool = false,
    files_path: ?[]const u8 = null,
};

const HELP_TEXT =
    \\sketerm — native GTK4 terminal emulator
    \\
    \\Usage: sketerm [OPTIONS]
    \\
    \\Remote control:
    \\  sketerm cli <command>  Script the running instance over its
    \\                         Unix socket (list, send-text, get-text,
    \\                         new-tab, split, focus, close-pane,
    \\                         set-title). `sketerm cli --help` for
    \\                         details. Inside a sketerm pane,
    \\                         $SKETERM_SOCKET/$SKETERM_PANE_ID are
    \\                         preset; `--pane self` self-addresses.
    \\  sketerm mcp            Model Context Protocol server on stdio:
    \\                         lets an AI assistant drive terminals in
    \\                         the running instance (read screens, type,
    \\                         press keys, run commands). Register in an
    \\                         MCP client as command "sketerm", args
    \\                         ["mcp"]. `sketerm mcp --help` for details.
    \\
    \\Durable sessions (sketerm-mux):
    \\  sketerm mux [host]     TUI picker: attach / spawn / kill
    \\                         daemon-backed sessions that survive
    \\                         GUI restarts. With a host, manages the
    \\                         REMOTE daemon over SSH. Also: mux
    \\                         [host] list / attach <name> / new /
    \\                         kill <name>.
    \\  sketerm ssh <host>     mosh-style: durable remote shell on
    \\                         <host> as a tab in the running window.
    \\                         Needs key auth + sketerm-mux on the
    \\                         host; survives disconnects (reattach
    \\                         with `sketerm mux <host>`).
    \\  sketerm app [-u] <host> <command...>
    \\                         Run a remote GUI app with its windows
    \\                         on this desktop (this sketerm window
    \\                         renders them). Needs key auth and
    \\                         sketerm-mux on the remote.
    \\                         -u: mosh-style encrypted UDP with
    \\                         roaming.
    \\  sketerm doctor [host]  Health check: binary/daemon version skew,
    \\                         socket liveness, terminfo, capabilities.
    \\                         With a host, also probes the REMOTE
    \\                         daemon (SSH/UDP) for skew.
    \\
    \\Options:
    \\  --restore             Load tabs from $XDG_STATE_HOME/sketerm/last.json
    \\  --layout <path>       Load tabs from a layout file (.json or .layout)
    \\                        (Without either flag, sketerm auto-loads
    \\                        $XDG_STATE_HOME/sketerm/default.json if
    \\                        present — see save_default_layout action.)
    \\  --no-save             Don't write last.json on exit
    \\  --hold                Keep panes open after their command exits
    \\                        (overrides exit_action from config; handy
    \\                        with --layout one-shot commands)
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

pub fn main(init: std.process.Init.Minimal) u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    @import("util/profile.zig").init();

    g_app = .{ .allocator = allocator };

    // --help and --version exit before reaching GApplication so the
    // user gets output even with no display. Everything else is
    // forwarded to the primary instance via "command-line" so a
    // second `sketerm --toggle` invocation reaches the running app.
    const argv = init.args.vector;

    // `sketerm cli ...` is the remote-control client: pure socket
    // talk, never enters GApplication (no display, no D-Bus
    // round-trip to the primary instance).
    if (argv.len >= 2 and std.mem.eql(u8, std.mem.span(argv[1]), "cli")) {
        const cli_args = allocator.alloc([]const u8, argv.len - 2) catch return 1;
        defer allocator.free(cli_args);
        for (argv[2..], 0..) |a, n| cli_args[n] = std.mem.span(a);
        return @import("ipc/client.zig").run(allocator, cli_args);
    }

    // `sketerm mcp` — Model Context Protocol server on stdio; lets an
    // AI assistant drive the running instance through the same socket
    // the cli uses. Blocking stdio loop, no GApplication.
    if (argv.len >= 2 and std.mem.eql(u8, std.mem.span(argv[1]), "mcp")) {
        const mcp_args = allocator.alloc([]const u8, argv.len - 2) catch return 1;
        defer allocator.free(mcp_args);
        for (argv[2..], 0..) |a, n| mcp_args[n] = std.mem.span(a);
        return @import("ipc/mcp.zig").run(allocator, mcp_args);
    }

    // `sketerm app <host> <command...>` — run a remote GUI app with
    // its windows on this desktop (Wayland forwarding). No
    // GApplication; the process becomes the forwarder.
    if (argv.len >= 2 and std.mem.eql(u8, std.mem.span(argv[1]), "app")) {
        const app_args = allocator.alloc([]const u8, argv.len - 2) catch return 1;
        defer allocator.free(app_args);
        for (argv[2..], 0..) |a, n| app_args[n] = std.mem.span(a);
        return @import("remoteapp.zig").run(allocator, app_args);
    }

    // `sketerm mux ...` — durable-session manager (TUI picker with
    // no further arguments). Also socket-only; no GApplication.
    if (argv.len >= 2 and std.mem.eql(u8, std.mem.span(argv[1]), "mux")) {
        const mux_args = allocator.alloc([]const u8, argv.len - 2) catch return 1;
        defer allocator.free(mux_args);
        for (argv[2..], 0..) |a, n| mux_args[n] = std.mem.span(a);
        return @import("ipc/mux_cli.zig").run(allocator, mux_args);
    }

    // `sketerm doctor [host]` — health check; socket-only, no
    // GApplication.
    if (argv.len >= 2 and std.mem.eql(u8, std.mem.span(argv[1]), "doctor")) {
        const doc_args = allocator.alloc([]const u8, argv.len - 2) catch return 1;
        defer allocator.free(doc_args);
        for (argv[2..], 0..) |a, n| doc_args[n] = std.mem.span(a);
        return @import("doctor.zig").run(allocator, doc_args);
    }

    // `sketerm ssh [-u] <host>` — mosh-style: open a durable remote
    // shell on <host> as a tab in the running window. Sugar for
    // `sketerm mux [udp:]<host> new`. -u picks the encrypted UDP
    // transport (lower latency, roams across network changes).
    if (argv.len >= 3 and std.mem.eql(u8, std.mem.span(argv[1]), "ssh")) {
        const use_udp = std.mem.eql(u8, std.mem.span(argv[2]), "-u");
        if (use_udp and argv.len < 4) return 2;
        var host_raw: []const u8 = std.mem.span(argv[if (use_udp) 3 else 2]);
        // [domain.<name>] resolution: a bare name from config.conf
        // expands to its host (transport prefix included).
        var cfg = @import("config.zig").Config.load(allocator);
        defer cfg.deinit();
        const domain_spec = cfg.resolveDomain(host_raw, allocator);
        defer if (domain_spec) |s| allocator.free(s);
        if (domain_spec) |s| host_raw = s;
        var host_buf: [300]u8 = undefined;
        const host: []const u8 = if (use_udp and !std.mem.startsWith(u8, host_raw, "udp:"))
            std.fmt.bufPrint(&host_buf, "udp:{s}", .{host_raw}) catch return 2
        else
            host_raw;
        const ssh_args = [_][]const u8{ host, "new" };
        return @import("ipc/mux_cli.zig").run(allocator, &ssh_args);
    }

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = std.mem.span(argv[i]);
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            _ = c.fputs(HELP_TEXT, platform.stdout());
            return 0;
        } else if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) {
            _ = c.fprintf(platform.stdout(), "sketerm %s\n", @as([*:0]const u8, VERSION));
            return 0;
        }
    }

    // GApplication parses argv inside the "command-line" signal
    // handler (our `onCommandLine`). With HANDLES_COMMAND_LINE the
    // primary instance's signal fires for both its own startup
    // (is_remote=false) and any subsequent invocation
    // (is_remote=true) — that's what makes `sketerm --toggle`
    // reach a running window.
    const c_argv: [*c][*c]u8 = @ptrCast(@alignCast(@constCast(argv.ptr)));
    const argc: c_int = @intCast(argv.len);

    // SKETERM_APP_ID overrides the GApplication ID so a second instance
    // can run alongside the primary one (debug / profiling). Must be a
    // valid reverse-DNS-style name; GLib aborts otherwise.
    var app_id_buf: [256:0]u8 = undefined;
    const app_id: [*:0]const u8 = blk: {
        const raw = c.getenv("SKETERM_APP_ID");
        if (raw == null) break :blk APP_ID;
        const env = std.mem.span(raw);
        if (env.len == 0 or env.len >= app_id_buf.len) break :blk APP_ID;
        @memcpy(app_id_buf[0..env.len], env);
        app_id_buf[env.len] = 0;
        break :blk @ptrCast(&app_id_buf);
    };

    const app = c.adw_application_new(app_id, c.G_APPLICATION_HANDLES_COMMAND_LINE);
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
            // Free the prior dupe — `--toggle` re-enters command-line
            // handling on every secondary invocation, and without this
            // the path leaks once per call.
            if (g_app.layout_path) |old| g_app.allocator.free(old);
            g_app.layout_path = g_app.allocator.dupe(u8, v) catch null;
        } else if (std.mem.eql(u8, a, "--no-save")) {
            g_app.no_save = true;
        } else if (std.mem.eql(u8, a, "--hold")) {
            g_app.hold = true;
        } else if (std.mem.eql(u8, a, "--debug-events")) {
            g_app.debug_events = true;
        } else if (std.mem.eql(u8, a, "--debug-images")) {
            g_app.debug_images = true;
        } else if (std.mem.eql(u8, a, "files")) {
            g_app.files_request = true;
            if (n + 1 < argc) {
                const peek = std.mem.span(@as([*:0]const u8, @ptrCast(argv_raw[@intCast(n + 1)])));
                if (peek.len > 0 and peek[0] != '-') {
                    n += 1;
                    if (g_app.files_path) |old| g_app.allocator.free(old);
                    g_app.files_path = g_app.allocator.dupe(u8, peek) catch null;
                }
            }
        } else if (std.mem.eql(u8, a, "--config") and n + 1 < argc) {
            n += 1;
            const v = std.mem.span(@as([*:0]const u8, @ptrCast(argv_raw[@intCast(n)])));
            if (g_app.config_path) |old| g_app.allocator.free(old);
            g_app.config_path = g_app.allocator.dupe(u8, v) catch null;
        }
    }

    // `sketerm files` against a RUNNING instance: open the browser
    // tab there and present, no second window.
    if (g_app.files_request and g_app.window != null) {
        g_app.files_request = false;
        openFilesTab();
        c.g_application_activate(app);
        return 0;
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
    // Make the bundled symbolic icons (sketerm-split-*-symbolic) resolvable.
    // Installed builds find them under /usr/share/icons/hicolor (a default
    // search path); for `zig build run` the CWD is the repo root, so add
    // data/icons too. A non-existent path is harmless.
    if (c.gdk_display_get_default()) |display| {
        const theme = c.gtk_icon_theme_get_for_display(display);
        c.gtk_icon_theme_add_search_path(theme, "data/icons");
    }

    // Honour --config path if provided, otherwise let Window.init use
    // the default XDG-search loader.
    const Config = @import("config.zig").Config;
    const cfg_override: ?Config = if (g_app.config_path) |p|
        Config.loadWithOverride(g_app.allocator, p)
    else
        null;
    const window = Window.initWithConfig(g_app.allocator, app, cfg_override, true) catch |err| {
        std.debug.print("sketerm: window init failed: {s}\n", .{@errorName(err)});
        return;
    };
    window.debug_events = g_app.debug_events;
    window.debug_images = g_app.debug_images;
    window.hold_override = g_app.hold;
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

    if (!loaded and !g_app.files_request) {
        window.newShellTab(null) catch |err| {
            std.debug.print("sketerm: spawn first tab failed: {s}\n", .{@errorName(err)});
            return;
        };
    }

    if (g_app.files_request) {
        g_app.files_request = false;
        openFilesTab();
    }

    window.present();
}

/// Open a browser tab in the current window, honoring the optional
/// `sketerm files <spec>` start location.
fn openFilesTab() void {
    const win = g_app.window orelse return;
    win.newBrowserTabAt(g_app.files_path) catch |err| {
        std.debug.print("sketerm: files tab failed: {s}\n", .{@errorName(err)});
    };
    if (g_app.files_path) |p| {
        g_app.allocator.free(p);
        g_app.files_path = null;
    }
}

fn onShutdown(_: ?*c.GApplication, _: ?*anyopaque) callconv(.c) void {
    if (g_app.window) |w| {
        if (!g_app.no_save) w.saveLayoutQuietly();
        w.deinit();
        g_app.window = null;
    }
}
