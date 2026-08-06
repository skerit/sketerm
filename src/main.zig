// sketerm — terminal emulator entry point.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const platform = @import("util/platform.zig");
const Window = @import("ui/window.zig").Window;
const viewer = @import("viewer.zig");

comptime {
    // macOS: emit the NSAccessibility bridge's export callbacks into the
    // GUI binary so the ObjC shim (linked via build.zig addNsaxBridge)
    // resolves them. The AppKit pane frontend then calls a11y/nsax.zig's
    // newView/notifyChanged with no further build wiring. No-op on Linux,
    // where panes use the GtkAccessibleText (atspi.zig) bridge instead.
    if (builtin.os.tag == .macos) _ = @import("a11y/nsax.zig");
}

const APP_ID: [*:0]const u8 = "dev.sker.sketerm";
/// `sketerm files` registers its OWN application identity, appended to
/// whichever base id applies. On Wayland the toplevel app_id and on X11
/// the WM_CLASS come from the process identity, not from any per-window
/// call, so a distinct GApplication is the only way the file manager
/// gets its own taskbar group, icon and window list. It also keeps the
/// two single-instance identities from competing for one window list.
const FILES_ID_SUFFIX = ".files";
const VERSION = @import("version.zig").string;
const files_entry = @import("filebrowser/entry.zig");
const editor_app = @import("editor_app.zig");

const App = struct {
    const Mode = enum { terminal, files, viewer, editor };

    allocator: std.mem.Allocator,
    /// The PRIMARY window of this process: it owns the control socket,
    /// the quake toggle and layout persistence, and it lives as long as
    /// the process. Every other window is secondary and reachable
    /// through `Window.liveWindows`, never through this field.
    primary: ?*Window = null,
    restore: bool = false,
    layout_path: ?[]const u8 = null,
    no_save: bool = false,
    hold: bool = false,
    debug_events: bool = false,
    debug_images: bool = false,
    config_path: ?[]const u8 = null,
    /// This process was launched as `sketerm files`: it serves the
    /// dedicated file-manager identity. Says nothing about browser
    /// FACES: a browser pane inside a terminal window is unrelated.
    mode: Mode = .terminal,
    /// Start location for the file-manager window (owned).
    files_path: ?[]const u8 = null,
    /// File selected after the next Files window's streamed listing arrives.
    files_reveal: ?[]const u8 = null,
    /// Ordered resource batch for the next standalone Viewer window.
    viewer_batch: ?viewer.Batch = null,
    /// Cast files (`sketerm play`) to open on the next activate, each
    /// in its own playback window. Owned specs.
    play_specs: ?[][]u8 = null,
    /// Documents (and optional caret) for the next standalone Editor
    /// window.
    editor_request: ?editor_app.Request = null,
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
    \\                         REMOTE daemon over UDP when reachable,
    \\                         with automatic SSH fallback. Also: mux
    \\                         [host] list / attach <name> / new /
    \\                         kill <name>.
    \\  sketerm ssh <host>     durable remote shell on
    \\                         <host> as a tab in the running window.
    \\                         Needs key auth + sketerm-mux on the
    \\                         host; survives disconnects (reattach
    \\                         with `sketerm mux <host>`).
    \\  sketerm run [--size WxH] <command...>
    \\                         Run a GUI app headlessly against a
    \\                         private Wayland display (no screen
    \\                         needed) — the Xvfb/xvfb-run
    \\                         replacement. Inherits stdio, waits,
    \\                         exits with the command's status;
    \\                         rootless X11 via Xwayland when
    \\                         installed. Sugar for `sketerm-mux
    \\                         display run -- <command...>`; see
    \\                         `sketerm-mux display --help` for
    \\                         persistent displays.
    \\  sketerm app [-u] <host> <command...>
    \\                         Run a GUI app on <host> (localhost
    \\                         works) with its windows on this
    \\                         desktop (this sketerm window renders
    \\                         them); with no window open it keeps
    \\                         running headlessly for a later attach.
    \\                         Needs key auth and sketerm-mux on the
    \\                         remote.
    \\                         -u: force encrypted roaming UDP instead
    \\                         of automatic UDP/SSH selection.
    \\  sketerm files [spec]   File browser as its OWN application
    \\                         ("Sketerm Files", own icon and taskbar
    \\                         entry, id dev.sker.sketerm.files): each
    \\                         invocation opens a browser window there,
    \\                         never touching a running terminal.
    \\                         spec = /path, host:/path, udp:host:/path,
    \\                         local:/path or a file:// URI (a file
    \\                         opens its parent directory).
    \\  sketerm files --here [spec]
    \\                         Turn the pane you typed this in INTO a
    \\                         browser (its shell stays underneath, one
    \\                         toolbar click away). Talks to the running
    \\                         terminal over its socket; needs to be run
    \\                         from inside a sketerm pane.
    \\  sketerm files --tab [spec]
    \\                         Browser tab in the WINDOW that owns the
    \\                         pane you typed this in. Same requirement.
    \\                         Both default to the pane's own directory,
    \\                         on the pane's own host. Both need a LOCAL
    \\                         pane: inside a durable REMOTE shell the
    \\                         window's socket is on the other machine,
    \\                         and they say so instead of guessing.
    \\  sketerm edit [files...] Text editor as its OWN application
    \\                         ("Sketerm Editor", own icon and taskbar
    \\                         entry, id dev.sker.sketerm.editor): each
    \\                         invocation opens an editor window with
    \\                         those documents. Files may be /path,
    \\                         host:/path or file:// URIs; remote files
    \\                         load and save through the daemon.
    \\                         --line N[:col] places the caret.
    \\  sketerm edit --here|--tab [files...]
    \\                         Editor face in the pane you typed this
    \\                         in (--here) or a new tab of that pane's
    \\                         window (--tab), like `sketerm files`.
    \\                         Needs to be run from inside a pane.
    \\  sketerm play <file.cast> Play back an asciicast v2/v3 recording
    \\                         in a terminal-rendered window with a
    \\                         transport bar (pause/seek/speed).
    \\                         host:/path plays a recording that lives
    \\                         on a remote host's daemon. Keyboard:
    \\                         Space pause, Left/Right seek 5s (Shift:
    \\                         30s), R restart, Q close.
    \\  sketerm view [images...] Image viewer as its OWN application
    \\                         ("Sketerm Viewer", own icon and taskbar
    \\                         entry). Local, file:// and host:/path
    \\                         resources share the daemon preview and
    \\                         ranged-read pipeline; no FUSE mount.
    \\  sketerm mount <host>[:/path] <mountpoint>
    \\                         FUSE-mount a host's files so LOCAL apps
    \\                         open them via the kernel (ranged reads,
    \\                         write-through; fusermount3 -u to stop).
    \\  sketerm portal         xdg-desktop-portal FileChooser backend
    \\                         serving the native sketerm picker to any
    \\                         portal-using app. OPT-IN: see docs/portal.md
    \\                         (portals.conf + the shipped .portal file);
    \\                         normally D-Bus-activated, not run by hand.
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
    \\Saving config.conf applies it immediately (config_auto_reload).
    \\With that off, reload on demand:
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

/// Replace a stale idle local daemon at startup, then wait (bounded)
/// until a fresh one answers so the window's first session spawn
/// cannot race the old daemon's exit.
fn upgradeLocalDaemon(allocator: std.mem.Allocator) void {
    const muxclient = @import("mux/client.zig");
    var conn = muxclient.Conn.connectLocalAutostart(allocator) catch return;
    const upgraded = conn.upgradeStaleIdle(allocator);
    conn.deinit();
    if (!upgraded) return;
    var tries: u32 = 0;
    while (tries < 20) : (tries += 1) {
        _ = c.usleep(50_000);
        if (muxclient.Conn.connectLocalAutostart(allocator)) |fresh_conn| {
            var m = fresh_conn;
            const fresh = !m.buildStale();
            m.deinit();
            if (fresh) return;
        } else |_| {}
    }
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    @import("util/profile.zig").init();
    // Post-mortem trail + SIGPIPE neutering. A GUI death takes every
    // attached session's viewer with it, and a stripped ReleaseFast build
    // otherwise leaves NO evidence anywhere of what it was doing.
    @import("util/crashlog.zig").install();

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

    // `sketerm mount <host>[:/path] <mountpoint>` — FUSE mount of a
    // host's files (local apps open remote files through the kernel).
    // Foreground; no GApplication.
    if (argv.len >= 2 and std.mem.eql(u8, std.mem.span(argv[1]), "mount")) {
        const m_args = allocator.alloc([]const u8, argv.len - 2) catch return 1;
        defer allocator.free(m_args);
        for (argv[2..], 0..) |a, n| m_args[n] = std.mem.span(a);
        return @import("fsmount.zig").run(allocator, m_args);
    }

    // `sketerm run [opts] <command...>` — xvfb-run-shaped synchronous
    // headless GUI run: sugar for `sketerm-mux display run [opts] --
    // <command...>` (the `--` is inserted when absent). No
    // GApplication; exits with the command's status.
    if (argv.len >= 2 and std.mem.eql(u8, std.mem.span(argv[1]), "run")) {
        const rest = allocator.alloc([]const u8, argv.len - 2) catch return 1;
        defer allocator.free(rest);
        for (argv[2..], 0..) |a, n| rest[n] = std.mem.span(a);
        const display = @import("mux/display.zig");
        var full: std.ArrayList([]const u8) = .empty;
        defer full.deinit(allocator);
        full.append(allocator, "run") catch return 1;
        if (display.runCommandStart(rest)) |start| {
            full.appendSlice(allocator, rest[0..start]) catch return 1;
            full.append(allocator, "--") catch return 1;
            full.appendSlice(allocator, rest[start..]) catch return 1;
        } else {
            full.appendSlice(allocator, rest) catch return 1;
        }
        return display.run(allocator, full.items);
    }

    // `sketerm portal` — opt-in xdg-desktop-portal FileChooser backend:
    // its own hold()-ed GApplication owning the impl.portal bus name,
    // serving the native picker to sandboxed/portal-using apps. Never
    // selected unless the user lists it in portals.conf (docs/portal.md).
    if (argv.len >= 2 and std.mem.eql(u8, std.mem.span(argv[1]), "portal")) {
        return @import("ui/portal.zig").run(allocator);
    }

    // `sketerm doctor [host]` — health check; socket-only, no
    // GApplication.
    if (argv.len >= 2 and std.mem.eql(u8, std.mem.span(argv[1]), "doctor")) {
        const doc_args = allocator.alloc([]const u8, argv.len - 2) catch return 1;
        defer allocator.free(doc_args);
        for (argv[2..], 0..) |a, n| doc_args[n] = std.mem.span(a);
        return @import("doctor.zig").run(allocator, doc_args);
    }

    // `sketerm ssh [-u] <host>` — open a durable remote
    // shell on <host> as a tab in the running window. Sugar for
    // `sketerm mux [udp:|ssh:]<host> new`. Bare hosts automatically
    // probe UDP then fall back to SSH; -u forces encrypted UDP.
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
        const host: []const u8 = if (use_udp) blk: {
            const remote = @import("mux/client.zig").RemoteSpec.parse(host_raw);
            break :blk std.fmt.bufPrint(&host_buf, "udp:{s}", .{remote.host}) catch return 2;
        } else host_raw;
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

    // `sketerm files ...`: three different programs behind one word.
    if (filesRequest(allocator, argv)) |req| {
        if (req.help) {
            _ = c.fputs(HELP_TEXT, platform.stdout());
            return 0;
        }
        switch (req.mode) {
            // --here / --tab act on an EXISTING terminal pane: pure
            // socket clients over the running terminal's control socket.
            // They must never register a GApplication: a second app
            // identity would open a window of its own instead of
            // touching the pane the user asked about.
            .here, .tab => {
                if (req.reveal != null) {
                    _ = c.fputs("sketerm files: --select is only supported for dedicated Files windows\n", platform.stderr());
                    return 2;
                }
                return @import("ipc/client.zig").browserInPane(
                    allocator,
                    req.mode == .here,
                    req.spec,
                );
            },
            // The dedicated file manager: its own identity, from here on
            // an ordinary GApplication run.
            .window => {
                g_app.mode = .files;
                Window.setFilesIdentity();
                if (req.spec) |s| g_app.files_path = allocator.dupe(u8, s) catch null;
                if (req.reveal) |s| g_app.files_reveal = allocator.dupe(u8, s) catch null;
            },
        }
    }

    // `sketerm edit ...`: the same three-programs-behind-one-word shape
    // as `sketerm files`.
    if (editorRequest(allocator, argv)) |parsed| {
        var req = parsed;
        defer req.deinit();
        if (req.help) {
            _ = c.fputs(HELP_TEXT, platform.stdout());
            return 0;
        }
        switch (req.mode) {
            // --here / --tab act on an EXISTING pane: pure socket
            // clients over the running terminal's control socket, never
            // a second app identity of our own.
            .here, .tab => {
                if (req.specs.len > 1)
                    _ = c.fputs("sketerm edit: --here/--tab open ONE file; opening the first (use plain `sketerm edit` for several)\n", platform.stderr());
                if (req.position != null)
                    _ = c.fputs("sketerm edit: --line applies to standalone editor windows only\n", platform.stderr());
                return @import("ipc/client.zig").editorInPane(
                    allocator,
                    req.mode == .here,
                    if (req.specs.len > 0) req.specs[0] else null,
                );
            },
            // The dedicated editor: its own identity, an ordinary
            // GApplication run from here on.
            .window => g_app.mode = .editor,
        }
    }

    if (viewerRequest(allocator, argv)) {
        g_app.mode = .viewer;
    }

    // A leftover local daemon from before a binary upgrade keeps
    // serving old code to every client forever. At process start —
    // before this GUI spawns any session of its own — a stale AND
    // idle daemon is asked to exit and the fresh binary takes over.
    // Busy daemons (real sessions = the user's running work) are
    // never touched; the browser status line reports them instead.
    upgradeLocalDaemon(allocator);

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
    // valid reverse-DNS-style name; GLib aborts otherwise. Files mode
    // appends its suffix to whichever base applies, so a test rig's
    // isolated id keeps isolating both identities.
    var app_id_buf: [256:0]u8 = undefined;
    const app_id: [*:0]const u8 = blk: {
        var base: []const u8 = std.mem.span(APP_ID);
        if (c.getenv("SKETERM_APP_ID")) |raw| {
            const env = std.mem.span(raw);
            const longest_suffix = @max(FILES_ID_SUFFIX.len, @max(viewer.ID_SUFFIX.len, editor_app.ID_SUFFIX.len));
            if (env.len > 0 and env.len < app_id_buf.len - longest_suffix) base = env;
        }
        const suffix: []const u8 = switch (g_app.mode) {
            .terminal => "",
            .files => FILES_ID_SUFFIX,
            .viewer => viewer.ID_SUFFIX,
            .editor => editor_app.ID_SUFFIX,
        };
        const id = std.fmt.bufPrintZ(&app_id_buf, "{s}{s}", .{ base, suffix }) catch break :blk APP_ID;
        break :blk id.ptr;
    };

    // Keep every fallback identity channel aligned with GApplication.
    // GTK normally gets the Wayland app_id from GApplication, while
    // AT-SPI Name and X11 WM_CLASS still follow the program name.
    c.g_set_prgname(app_id);
    c.g_set_application_name(switch (g_app.mode) {
        .terminal => "sketerm",
        .files => "Sketerm Files",
        .viewer => viewer.APP_NAME,
        .editor => editor_app.APP_NAME,
    });

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

/// Parse argv as a `sketerm files ...` invocation, or null when it is
/// not one. Result slices point into argv, which outlives the process's
/// use of them.
fn filesRequest(allocator: std.mem.Allocator, argv: []const [*:0]const u8) ?files_entry.Request {
    const args = allocator.alloc([]const u8, argv.len) catch return null;
    defer allocator.free(args);
    for (argv, 0..) |a, n| args[n] = std.mem.span(a);
    return files_entry.parse(args);
}

/// Parse argv as a `sketerm edit ...` invocation, or null when it is
/// not one. Relative file arguments resolve against the invoking
/// shell's cwd (this process's, at this point in startup); the
/// forwarded-invocation path in onCommandLine re-parses against the
/// cwd GApplication hands it instead.
fn editorRequest(allocator: std.mem.Allocator, argv: []const [*:0]const u8) ?editor_app.Request {
    const args = allocator.alloc([]const u8, argv.len) catch return null;
    defer allocator.free(args);
    for (argv, 0..) |a, n| args[n] = std.mem.span(a);
    var cwd_buf: [4096:0]u8 = undefined;
    const cwd: ?[]const u8 = if (c.getcwd(&cwd_buf, cwd_buf.len) != null)
        std.mem.span(@as([*:0]const u8, &cwd_buf))
    else
        null;
    return editor_app.collect(allocator, args, cwd) catch null;
}

fn viewerRequest(allocator: std.mem.Allocator, argv: []const [*:0]const u8) bool {
    const args = allocator.alloc([]const u8, argv.len) catch return false;
    defer allocator.free(args);
    for (argv, 0..) |arg, index| args[index] = std.mem.span(arg);
    return viewer.invocationStart(args) != null;
}

fn onSignalQuit(user: ?*anyopaque) callconv(.c) c.gboolean {
    const app: *c.GApplication = @ptrCast(@alignCast(user.?));
    c.g_application_quit(app);
    return 0; // remove source
}

fn onSignalReloadConfig(_: ?*anyopaque) callconv(.c) c.gboolean {
    // g_unix_signal_add dispatches on the main thread; safe to
    // reach into Window from here. Every window has its own Config, so
    // every window reloads; a secondary window used to keep the old one.
    const primary = g_app.primary orelse return 1;
    const app = c.gtk_window_get_application(@ptrCast(primary.app_window));
    if (Window.liveWindows(g_app.allocator, app)) |wins| {
        defer g_app.allocator.free(wins);
        for (wins) |w| w.reloadConfigFromDisk();
        if (wins.len == 0) primary.reloadConfigFromDisk();
    } else |_| primary.reloadConfigFromDisk();
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
        } else if (std.mem.eql(u8, a, "--config") and n + 1 < argc) {
            n += 1;
            const v = std.mem.span(@as([*:0]const u8, @ptrCast(argv_raw[@intCast(n)])));
            if (g_app.config_path) |old| g_app.allocator.free(old);
            g_app.config_path = g_app.allocator.dupe(u8, v) catch null;
            // Every later re-read (reload_config, SIGUSR1, the file
            // watcher) must go to the same file this flag names.
            @import("ui/winconfig.zig").setConfigPathOverride(g_app.config_path);
        }
    }

    // A `sketerm files [spec]` forwarded into the running FILE-MANAGER
    // instance: remember the requested location so activate opens a
    // window there. Only this identity ever grows a browser window from
    // the command line -- a terminal instance is left alone.
    if (g_app.mode == .files) {
        const args = g_app.allocator.alloc([]const u8, @intCast(argc)) catch return 1;
        defer g_app.allocator.free(args);
        for (0..@intCast(argc)) |index| {
            const raw = argv_raw[index] orelse break;
            args[index] = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        }
        const request = files_entry.parse(args);
        if (g_app.files_path) |old| g_app.allocator.free(old);
        if (g_app.files_reveal) |old| g_app.allocator.free(old);
        g_app.files_path = if (request) |req| if (req.spec) |s| g_app.allocator.dupe(u8, s) catch null else null else null;
        g_app.files_reveal = if (request) |req| if (req.reveal) |s| g_app.allocator.dupe(u8, s) catch null else null else null;
    } else if (g_app.mode == .editor) {
        const args = g_app.allocator.alloc([]const u8, @intCast(argc)) catch return 1;
        defer g_app.allocator.free(args);
        for (0..@intCast(argc)) |index| {
            const raw = argv_raw[index] orelse break;
            args[index] = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        }
        const cwd_raw = c.g_application_command_line_get_cwd(cmdline);
        const cwd: ?[]const u8 = if (cwd_raw != null) std.mem.span(@as([*:0]const u8, @ptrCast(cwd_raw))) else null;
        if (g_app.editor_request) |*old| old.deinit();
        g_app.editor_request = editor_app.collect(g_app.allocator, args, cwd) catch |err| {
            g_app.editor_request = null;
            var message: [192:0]u8 = undefined;
            const text = std.fmt.bufPrintZ(&message, "sketerm: cannot open Editor documents: {s}\n", .{@errorName(err)}) catch
                "sketerm: cannot open Editor documents\n";
            c.g_application_command_line_printerr_literal(cmdline, text.ptr);
            return 1;
        };
    } else if (g_app.mode == .viewer) {
        const args = g_app.allocator.alloc([]const u8, @intCast(argc)) catch return 1;
        defer g_app.allocator.free(args);
        for (0..@intCast(argc)) |index| {
            const raw = argv_raw[index] orelse break;
            args[index] = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        }
        const cwd_raw = c.g_application_command_line_get_cwd(cmdline);
        const cwd: ?[]const u8 = if (cwd_raw != null) std.mem.span(@as([*:0]const u8, @ptrCast(cwd_raw))) else null;
        if (viewer.collect(g_app.allocator, args, cwd)) |batch| {
            if (g_app.viewer_batch) |*old| old.deinit();
            g_app.viewer_batch = batch;
        } else |err| {
            if (g_app.viewer_batch) |*old| old.deinit();
            g_app.viewer_batch = null;
            var message: [192:0]u8 = undefined;
            const text = std.fmt.bufPrintZ(&message, "sketerm: cannot open Viewer resources: {s}\n", .{@errorName(err)}) catch
                "sketerm: cannot open Viewer resources\n";
            c.g_application_command_line_printerr_literal(cmdline, text.ptr);
            return 1;
        }
    }

    // `sketerm play <file.cast> ...`: queue cast-playback windows for
    // this activate. Terminal identity (no suffix), so a forwarded
    // invocation opens its window in the running instance.
    if (g_app.mode == .terminal and argc >= 2) {
        const first = argv_raw[1];
        if (first != null and std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(first))), "play")) {
            const cwd_raw = c.g_application_command_line_get_cwd(cmdline);
            const cwd: ?[]const u8 = if (cwd_raw != null) std.mem.span(@as([*:0]const u8, @ptrCast(cwd_raw))) else null;
            var specs: std.ArrayList([]u8) = .empty;
            var n2: usize = 2;
            while (n2 < @as(usize, @intCast(argc))) : (n2 += 1) {
                const raw = argv_raw[n2] orelse break;
                const arg = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
                if (arg.len == 0 or arg[0] == '-') continue;
                const owned = resolvePlaySpec(g_app.allocator, arg, cwd) catch continue;
                specs.append(g_app.allocator, owned) catch {
                    g_app.allocator.free(owned);
                    continue;
                };
            }
            if (specs.items.len == 0) {
                specs.deinit(g_app.allocator);
                c.g_application_command_line_printerr_literal(cmdline, "usage: sketerm play <file.cast>\n");
                return 1;
            }
            freePlaySpecs();
            g_app.play_specs = specs.toOwnedSlice(g_app.allocator) catch null;
        }
    }

    if (saw_toggle) {
        // Activate the toggle action if a window already exists; if
        // we are the primary and no window yet, fall through to
        // activate so the first --toggle launches and shows.
        const has_window = c.g_application_get_is_registered(app) != 0 and g_app.primary != null;
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
    // Quake mode is a property of the PRIMARY window (it owns the
    // socket and the toggle action); secondary windows are ordinary.
    const win = g_app.primary orelse return;
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

    if (g_app.mode == .editor) {
        var req = takeEditorRequest();
        defer req.deinit();
        _ = @import("ui/editorwin.zig").EditorWindow.open(g_app.allocator, app, req, g_app.config_path) catch |err|
            std.debug.print("sketerm: editor window failed: {s}\n", .{@errorName(err)});
        return;
    }

    if (g_app.mode == .viewer) {
        var batch = takeViewerBatch();
        if (@import("ui/viewer.zig").ViewerWindow.open(g_app.allocator, app, batch)) |_| {
            // Ownership moved into the window.
        } else |err| {
            batch.deinit();
            std.debug.print("sketerm: viewer window failed: {s}\n", .{@errorName(err)});
        }
        return;
    }

    // `sketerm play`: cast-playback windows only — never a terminal
    // window of their own, whether or not one already exists.
    if (takePlaySpecs()) |specs| {
        defer {
            for (specs) |s| g_app.allocator.free(s);
            g_app.allocator.free(specs);
        }
        for (specs) |spec| {
            _ = @import("ui/castview.zig").CastView.open(g_app.allocator, app, spec) catch |err|
                std.debug.print("sketerm play: could not open '{s}': {s}\n", .{ spec, @errorName(err) });
        }
        return;
    }

    // Launching an already-running identity again = one more window,
    // the normal GApplication behaviour. It MUST be a secondary window:
    // a second is_primary window would quit the whole app when closed
    // and would take over "the primary". (This used to build a second
    // primary and overwrite g_app.window with it.)
    if (g_app.primary) |primary| {
        if (g_app.mode == .files) {
            const spec = takeFilesPath();
            defer if (spec) |s| g_app.allocator.free(s);
            const reveal = takeFilesReveal();
            defer if (reveal) |s| g_app.allocator.free(s);
            _ = primary.openFilesWindow(spec, reveal) catch |err|
                std.debug.print("sketerm: files window failed: {s}\n", .{@errorName(err)});
        } else {
            _ = primary.openShellWindow() catch |err|
                std.debug.print("sketerm: window failed: {s}\n", .{@errorName(err)});
        }
        return;
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
    // The file manager never touches the terminal's saved layout:
    // last.json / default.json describe ONE window of terminal tabs and
    // belong to the terminal identity. So files mode neither saves nor
    // restores a layout; its own state (per-folder view memory,
    // registers, saved queries) is the browser's, and persists already.
    window.save_on_close = !g_app.no_save and g_app.mode != .files;
    window.debug_images = g_app.debug_images;
    window.hold_override = g_app.hold;
    g_app.primary = window;

    var loaded = false;
    if (g_app.mode == .files) {
        // no layout in files mode -- see save_on_close above
    } else if (g_app.layout_path) |path| {
        loaded = window.loadLayoutFromPath(path) catch false;
    } else if (g_app.restore) {
        loaded = window.loadLayoutDefault() catch false;
    } else {
        // No explicit flag: try the user's saved default.json. Silent
        // no-op when the file isn't there (fresh install).
        loaded = window.loadDefaultLayoutIfPresent() catch false;
    }

    if (g_app.mode == .files) {
        // The browser tab IS the window's content: no stray shell tab.
        const spec = takeFilesPath();
        defer if (spec) |s| g_app.allocator.free(s);
        const reveal = takeFilesReveal();
        defer if (reveal) |s| g_app.allocator.free(s);
        window.newBrowserTabFromReveal(null, spec, reveal) catch |err| {
            std.debug.print("sketerm: files tab failed: {s}\n", .{@errorName(err)});
            return;
        };
    } else if (!loaded) {
        window.newShellTab(null) catch |err| {
            std.debug.print("sketerm: spawn first tab failed: {s}\n", .{@errorName(err)});
            return;
        };
    }

    window.present();
}

/// Take the pending `sketerm files [spec]` start location OUT of the
/// app state: ownership moves to the caller (which frees it), so a
/// later invocation with no spec cannot inherit this one's.
fn takeFilesPath() ?[]const u8 {
    const p = g_app.files_path;
    g_app.files_path = null;
    return p;
}

fn takeFilesReveal() ?[]const u8 {
    const value = g_app.files_reveal;
    g_app.files_reveal = null;
    return value;
}

fn takeEditorRequest() editor_app.Request {
    const req = g_app.editor_request orelse return editor_app.Request.empty(g_app.allocator);
    g_app.editor_request = null;
    return req;
}

/// Resolve one `sketerm play` argument: host:/path specs pass through,
/// relative local paths resolve against the invoking cwd.
fn resolvePlaySpec(allocator: std.mem.Allocator, arg: []const u8, cwd: ?[]const u8) ![]u8 {
    const loc = @import("filebrowser/paths.zig").parseSpec(arg);
    if (loc.host != null or !loc.current_host) return allocator.dupe(u8, arg);
    if (loc.path.len > 0 and (loc.path[0] == '/' or loc.path[0] == '~'))
        return allocator.dupe(u8, loc.path);
    const base = cwd orelse ".";
    if (std.mem.eql(u8, base, "/")) return std.fmt.allocPrint(allocator, "/{s}", .{loc.path});
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, loc.path });
}

fn takePlaySpecs() ?[][]u8 {
    const specs = g_app.play_specs;
    g_app.play_specs = null;
    return specs;
}

fn freePlaySpecs() void {
    if (g_app.play_specs) |specs| {
        for (specs) |s| g_app.allocator.free(s);
        g_app.allocator.free(specs);
    }
    g_app.play_specs = null;
}

fn takeViewerBatch() viewer.Batch {
    const batch = g_app.viewer_batch orelse return viewer.Batch.empty(g_app.allocator);
    g_app.viewer_batch = null;
    return batch;
}

fn onShutdown(app: ?*c.GApplication, _: ?*anyopaque) callconv(.c) void {
    if (g_app.viewer_batch) |*batch| batch.deinit();
    g_app.viewer_batch = null;
    freePlaySpecs();
    if (g_app.editor_request) |*req| req.deinit();
    g_app.editor_request = null;
    // The editor owns no panes, no daemon sessions and no layout: its
    // windows tear themselves down through their own destroy handlers.
    if (g_app.mode == .editor) return;
    if (g_app.files_path) |path| g_app.allocator.free(path);
    g_app.files_path = null;
    if (g_app.files_reveal) |path| g_app.allocator.free(path);
    g_app.files_reveal = null;
    if (g_app.mode == .viewer) {
        @import("ui/hostmount.zig").shutdownAll();
        return;
    }
    // Every live window, not just the primary: a secondary window (tab
    // drag-out, repeat launch) owns real panes and GUI-owned daemon
    // sessions, and skipping it leaked both. GTK destroys the windows
    // AFTER this handler, so detach our handlers first, or the
    // destroy calls back into freed Window state.
    //
    // Only the PRIMARY window's layout is saved: last.json holds one
    // window's tabs (layout.Layout has no window dimension), so writing
    // several would just leave the last one standing. Multi-window
    // layout persistence needs a format change and is not attempted
    // here.
    const gtk_app: ?*c.GtkApplication = @ptrCast(@alignCast(app));
    if (Window.liveWindows(g_app.allocator, gtk_app)) |wins| {
        defer g_app.allocator.free(wins);
        for (wins) |w| shutdownWindow(w);
    } else |_| {
        if (g_app.primary) |w| shutdownWindow(w);
    }
    g_app.primary = null;
    // After the windows: a FUSE mount can still be serving a file an
    // application opened from a pane, and the panes are what own those
    // opens. A crash instead leaves the next start's sweep to clean up.
    @import("ui/hostmount.zig").shutdownAll();
}

fn shutdownWindow(w: *Window) void {
    if (w.is_primary and w.save_on_close and !g_app.no_save and !w.layout_saved_final) {
        w.saveLayoutQuietly();
        w.layout_saved_final = true;
    }
    w.detachWindowSignals();
    w.deinit();
}
