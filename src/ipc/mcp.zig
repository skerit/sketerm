//! `sketerm mcp` — Model Context Protocol server over stdio.
//!
//! Adapts MCP tool calls (JSON-RPC 2.0, one JSON object per line)
//! onto the GUI's remote-control socket so an AI assistant can drive
//! real terminal panes: read the rendered screen, type, press keys,
//! run commands and wait for the output to settle. Trust boundary is
//! the user-owned Unix socket — MCP adds no capability beyond what
//! `sketerm cli` already exposes.
//!
//! Transport: newline-delimited JSON on stdin/stdout (the MCP stdio
//! framing). Register in an assistant as:
//!   { "command": "sketerm", "args": ["mcp"] }

const std = @import("std");
const c = @import("../c.zig").c;
const clock = @import("../util/clock.zig");
const platform = @import("../util/platform.zig");
const protocol = @import("protocol.zig");
const ctlclient = @import("ctlclient.zig");
const muxclient = @import("../mux/client.zig");
pub const marks_mod = @import("../util/marks.zig");
const template = @import("../util/template.zig");
pub const png_util = @import("../util/png.zig");
pub const mcpassets = @import("mcpassets.zig");
pub const mcpfilter = @import("mcpfilter.zig");
pub const mcp_tools = @import("mcp_tools.zig");
pub const panelstore = @import("panelstore.zig");
const paneldrive = @import("paneldrive.zig");
const mcp_registry = @import("mcp_registry.zig");
pub const mcp_webgui = @import("mcp_webgui.zig");
const Config = @import("../config.zig").Config;
pub const shellquote = @import("../util/shellquote.zig");
pub const pattern = @import("../util/pattern.zig");
const mcp_app = @import("mcp_app.zig");
const mcp_files = @import("mcp_files.zig");
const mcp_panes = @import("mcp_panes.zig");
const mcp_term = @import("mcp_term.zig");
const mcp_caps = @import("mcp_caps.zig");
const mcp_ui = @import("mcp_ui.zig");
const mcp_testkit = @import("mcp_testkit.zig");
const FakeBackend = mcp_testkit.FakeBackend;
const Journal = mcp_app.Journal;
const LogDelta = mcp_app.LogDelta;
const MacroNudge = mcp_app.MacroNudge;
const reattachApps = mcp_app.reattachApps;

const MCP_HELP =
    \\Usage: sketerm mcp [--shared | --durable | --name NAME] [--socket PATH]
    \\                   [--log DIR] [--tools SPEC | --profile NAME] [--web-gui]
    \\
    \\Runs a Model Context Protocol server on stdio. Register it in an
    \\MCP client (Claude Code, etc.) as command "sketerm" with args
    \\["mcp"].
    \\
    \\Isolation (default): app tools run against a PRIVATE mux daemon
    \\under $XDG_RUNTIME_DIR/sketerm/mcp-*/ — the assistant cannot see
    \\or touch your real sessions or windows. The private daemon and
    \\its apps are torn down when the MCP server exits.
    \\  --durable      keep the private daemon (and its apps) running
    \\                 across MCP restarts as the instance named
    \\                 "default" (exactly `--name default`): a later
    \\                 `sketerm mcp --durable` finds it again
    \\  --name NAME    named durable instance; a later `sketerm mcp
    \\                 --name NAME` reconnects to the same daemon. A
    \\                 private daemon left with no apps and no clients
    \\                 for 2 minutes exits by itself (nothing is lost:
    \\                 profiles live in $XDG_STATE_HOME, the next tool
    \\                 call starts a fresh one)
    \\  --shared       OPT-IN to the user's real per-user daemon and
    \\                 running GUI (pre-isolation behavior): terminal
    \\                 tools drive live panes, apps share the daemon
    \\
    \\Terminal tools: list_terminals, read_screen, send_text,
    \\send_keys, run_command, wait_idle, new_tab, split_pane,
    \\focus_pane, close_pane. These need a GUI socket: --socket, or
    \\--shared (then $SKETERM_SOCKET / the single *.sock under
    \\$XDG_RUNTIME_DIR/sketerm/). Isolated mode without --socket
    \\leaves them disabled with a clear error.
    \\
    \\Live ui_* panels are independent of --shared: from a pane they
    \\follow SKETERM_SESSION to the exact SKETERM_MUX_SOCKET and relay
    \\to a compatible attached GUI. Sessionless/legacy use may pass an
    \\explicit --socket. App tools stay on the private MCP daemon.
    \\
    \\  --log DIR      trace everything to DIR: each session gets its
    \\                 own datetime subfolder DIR/YYYYMMDD-HHMMSS/
    \\                 holding every JSON-RPC request and response as
    \\                 one line in mcp-<pid>.jsonl (long lines
    \\                 truncated) and every inline screenshot as
    \\                 img-<pid>-NNNN.png (click/move-marked shots
    \\                 get a -click / -move filename suffix)
    \\
    \\Headless GUI-app tools (no GUI needed; apps render into the mux
    \\daemon, never on a screen): launch_app, list_apps, app_windows,
    \\screenshot_app (inline PNG), app_click, app_type, app_key,
    \\app_scroll, app_resize, app_wait, app_a11y_tree,
    \\app_perform_action, app_set_value, app_wait_for_element,
    \\close_app_window, close_app. SSH app launches (`host` param)
    \\always target the REMOTE host's daemon; isolation applies to
    \\local launches.
    \\
    \\Framebuffer-app helpers (games/custom UIs with no a11y tree):
    \\app_read_text + app_wait_text (OCR via runtime-loaded
    \\tesseract), app_template_save/app_templates + app_find_image /
    \\app_wait_image (pixel template matching), app_macro_save /
    \\app_macro_run / app_macros (recorded, replayable input macros;
    \\persisted in $XDG_STATE_HOME/sketerm).
    \\
    \\Headless terminal tools (isolated mode; real shells on the
    \\private daemon, no GUI): term_open, term_run, term_send_text,
    \\term_send_keys, term_read, term_wait_idle, term_resize,
    \\term_list, term_close.
    \\
    \\Every headless terminal (term_open, transfer/forward helpers) is
    \\automatically recorded as an asciicast v2 (.cast) file, replayable
    \\with asciinema: into the --log session folder when logging is on,
    \\else $XDG_STATE_HOME/sketerm/mcp-casts/<stamp>-<pid>/.
    \\  --no-record    disable the automatic terminal recordings
    \\
    \\Tool exposure: by default every tool is offered. Narrow it so one
    \\assistant sees only what it needs (several assistants can share
    \\one machine with different subsets).
    \\  --tools SPEC   comma/space separated terms:
    \\                   all            every tool
    \\                   all:ro         every non-mutating tool
    \\                   GROUP          a whole group
    \\                   GROUP:ro       that group's read-only tools
    \\                   TOOL           one tool by name
    \\                   -GROUP, -TOOL  deny (always wins)
    \\                 Groups: panes, app, term, files, net, browser,
    \\                 ui, core. `core` (capabilities) is always on.
    \\                 A spec with any allow term starts from nothing;
    \\                 a spec of only deny terms keeps everything else.
    \\                 Example: --tools "app, files:ro"
    \\  --profile NAME reuse a [mcp.NAME] section's `tools = ...` from
    \\                 config.conf
    \\  $SKETERM_MCP_TOOLS  same grammar; overrides --profile, and is
    \\                 overridden by --tools. Set it per project in
    \\                 .mcp.json's env block.
    \\Withheld tools are absent from tools/list AND refused by
    \\tools/call, with an error naming the term that would enable them.
    \\
    \\Your own browser for the web_* tools: by default (isolated) they
    \\run a PRIVATE sketerm-webengine with its own empty cookie jar, so
    \\the assistant is logged in nowhere. Grant it your real browser --
    \\ONLY the web_* tools; terminal/app/file/panel tools stay on the
    \\private daemon (this is not --shared):
    \\  --web-gui      highest precedence
    \\  $SKETERM_MCP_WEB_GUI=1|0  overrides config, overridden by the flag
    \\  web_gui = true in config.conf's [mcp] section (every run) or in
    \\                 the [mcp.NAME] section --profile NAME selects
    \\At the FIRST web call a running sketerm GUI is found (any live
    \\window can host a tab), or `sketerm web` is started detached and
    \\waited for; a GUI that disappears is found or started again on
    \\the next call. With no GUI reachable the call fails with
    \\'unavailable' -- never a private headless view. capabilities
    \\reports web_gui / web_gui_source / web_gui_transport.
    \\  $SKETERM_GUI_BIN  executable started as `<bin> web` when none
    \\                 is running (default: this sketerm binary)
    \\
;

/// Both live in `src/version.zig`: our own version so a release bump
/// moves every binary at once, and the MCP spec date so it is obvious
/// that the two are different things with different reasons to change.
const PROTOCOL_VERSION = @import("../version.zig").mcp_protocol;
const SERVER_VERSION = @import("../version.zig").string;

/// Pluggable side-effects so the dispatch logic unit-tests without a
/// GUI, sockets, or real sleeps.
pub const Backend = struct {
    ctx: *anyopaque,
    /// One JSON request line to the GUI socket → the JSON response
    /// line (caller frees). The line has no trailing newline.
    talk: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, line: []const u8) anyerror![]u8,
    /// The same exchange under a caller-owned remaining-time budget, with
    /// enough write-phase state to decide whether retrying could duplicate it.
    talkFor: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, line: []const u8, timeout_ms: i64) DirectTalkResult,
    sleepMs: *const fn (ctx: *anyopaque, ms: u32) void,
    nowMs: *const fn (ctx: *anyopaque) i64,
    /// A GUI answers on this backend. False only for the stand-in a
    /// server without a GUI socket runs with: pane tools then address
    /// headless terminals instead.
    gui_attached: bool = true,
};

/// A control-socket exchange's outcome, as `ctlclient` classifies it.
pub const DirectTalkFailure = ctlclient.Failure;
pub const DirectTalkResult = ctlclient.Result;

/// Parsed `sketerm mcp` flags. Pure so flag combos unit-test.
pub const Opts = struct {
    socket: ?[]const u8 = null,
    shared: bool = false,
    durable: bool = false,
    name: ?[]const u8 = null,
    log_dir: ?[]const u8 = null,
    no_record: bool = false,
    help: bool = false,
    /// `--tools <spec>`: mcpfilter grammar, highest precedence.
    tools: ?[]const u8 = null,
    /// `--profile <name>`: a `[mcp.<name>]` section in config.conf.
    profile: ?[]const u8 = null,
    /// `--web-gui`: the web_* tools may use the user's own browser
    /// (see mcp_webgui.zig); highest-precedence source of that grant.
    web_gui: bool = false,

    pub const ParseError = error{ UnknownFlag, MissingValue, BadName, SharedConflict };

    pub fn parse(args: []const []const u8) ParseError!Opts {
        var o = Opts{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--socket")) {
                if (i + 1 >= args.len) return error.MissingValue;
                i += 1;
                o.socket = args[i];
            } else if (std.mem.eql(u8, a, "--shared")) {
                o.shared = true;
            } else if (std.mem.eql(u8, a, "--durable")) {
                o.durable = true;
            } else if (std.mem.eql(u8, a, "--name")) {
                if (i + 1 >= args.len) return error.MissingValue;
                i += 1;
                if (!validInstanceName(args[i])) return error.BadName;
                o.name = args[i];
                o.durable = true; // a name exists to be found again
            } else if (std.mem.eql(u8, a, "--log")) {
                if (i + 1 >= args.len) return error.MissingValue;
                i += 1;
                o.log_dir = args[i];
            } else if (std.mem.eql(u8, a, "--tools")) {
                if (i + 1 >= args.len) return error.MissingValue;
                i += 1;
                o.tools = args[i];
            } else if (std.mem.eql(u8, a, "--profile")) {
                if (i + 1 >= args.len) return error.MissingValue;
                i += 1;
                if (!validInstanceName(args[i])) return error.BadName;
                o.profile = args[i];
            } else if (std.mem.eql(u8, a, "--no-record")) {
                o.no_record = true;
            } else if (std.mem.eql(u8, a, mcp_webgui.FLAG)) {
                o.web_gui = true;
            } else if (std.mem.eql(u8, a, "--help")) {
                o.help = true;
            } else {
                return error.UnknownFlag;
            }
        }
        if (o.shared and (o.durable or o.name != null)) return error.SharedConflict;
        // A durable instance is found again by NAME. Without one the dir
        // would be `mcp-tmp-<pid>`, which no later run can name and which
        // the startup orphan sweep reaps as soon as this pid is gone --
        // i.e. the exact opposite of durable.
        if (o.durable and o.name == null) o.name = DURABLE_DEFAULT_NAME;
        return o;
    }
};

/// Instance name of `--durable` without `--name` (documented in MCP_HELP
/// since the flag shipped).
pub const DURABLE_DEFAULT_NAME = "default";

fn validInstanceName(n: []const u8) bool {
    if (n.len == 0 or n.len > 48) return false;
    for (n) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_';
        if (!ok) return false;
    }
    return true;
}

/// `--log DIR` trace: one JSONL entry per MCP message plus every
/// inline screenshot as a standalone PNG so the trace stays small.
/// Each session logs into its own DIR/YYYYMMDD-HHMMSS/ subfolder.
pub const McpLog = struct {
    allocator: std.mem.Allocator,
    /// Owned per-session subdirectory (DIR/YYYYMMDD-HHMMSS).
    dir: []u8,
    file: *c.FILE,
    img_seq: u32 = 0,

    /// Longest raw payload kept verbatim per entry; base64 screenshot
    /// replies would otherwise dominate the file (the PNG is saved
    /// separately anyway).
    const LINE_MAX: usize = 4096;

    fn open(allocator: std.mem.Allocator, dir_arg: []const u8) ?McpLog {
        var z: [4096]u8 = undefined;
        const dir_z = std.fmt.bufPrintZ(&z, "{s}", .{dir_arg}) catch return null;
        _ = c.mkdir(dir_z.ptr, 0o700); // parent must exist; fopen below is the real check
        // Each session logs into its own datetime-named subfolder so
        // traces and screenshots of separate runs never interleave.
        var secs: c.time_t = @intCast(@divTrunc(clock.wallMs(), 1000));
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&secs, &tm);
        const sub = std.fmt.bufPrintZ(&z, "{s}/{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
            dir_arg,
            @as(u32, @intCast(@as(i64, tm.tm_year) + 1900)),
            @as(u32, @intCast(tm.tm_mon + 1)),
            @as(u32, @intCast(tm.tm_mday)),
            @as(u32, @intCast(tm.tm_hour)),
            @as(u32, @intCast(tm.tm_min)),
            @as(u32, @intCast(tm.tm_sec)),
        }) catch return null;
        _ = c.mkdir(sub.ptr, 0o700);
        const dir = allocator.dupe(u8, sub) catch return null;
        var pz: [4096]u8 = undefined;
        const path = std.fmt.bufPrintZ(&pz, "{s}/mcp-{d}.jsonl", .{ dir, c.getpid() }) catch {
            allocator.free(dir);
            return null;
        };
        const f = c.fopen(path.ptr, "a") orelse {
            allocator.free(dir);
            return null;
        };
        return .{ .allocator = allocator, .dir = dir, .file = f };
    }

    fn close(self: *McpLog) void {
        _ = c.fclose(self.file);
        self.allocator.free(self.dir);
    }

    pub fn stamp(buf: *[40]u8) []const u8 {
        const wall = clock.wallMs();
        var secs: c.time_t = @intCast(@divTrunc(wall, 1000));
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&secs, &tm);
        const ms: u32 = @intCast(@mod(wall, 1000));
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
            @as(u32, @intCast(@as(i64, tm.tm_year) + 1900)), @as(u32, @intCast(tm.tm_mon + 1)),
            @as(u32, @intCast(tm.tm_mday)),                  @as(u32, @intCast(tm.tm_hour)),
            @as(u32, @intCast(tm.tm_min)),                   @as(u32, @intCast(tm.tm_sec)),
            ms,
        }) catch buf[0..0];
    }

    fn emit(self: *McpLog, entry: []const u8) void {
        _ = c.fwrite(entry.ptr, 1, entry.len, self.file);
        _ = c.fputc('\n', self.file);
        _ = c.fflush(self.file);
    }

    /// Log one raw JSON-RPC message. `event` is "in" or "out".
    fn logMessage(self: *McpLog, event: []const u8, raw: []const u8) void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        var aw: std.Io.Writer.Allocating = .init(arena_state.allocator());
        const w = &aw.writer;
        var tbuf: [40]u8 = undefined;
        w.print("{{\"ts\":\"{s}\",\"event\":\"{s}\",\"line\":", .{ stamp(&tbuf), event }) catch return;
        var keep = @min(raw.len, LINE_MAX);
        // Never split a UTF-8 sequence — Stringify wants valid UTF-8.
        while (keep > 0 and (raw[keep - 1] & 0xC0) == 0x80) keep -= 1;
        std.json.Stringify.value(raw[0..keep], .{}, w) catch return;
        if (keep < raw.len) w.print(",\"truncated\":true,\"full_len\":{d}", .{raw.len}) catch return;
        w.writeAll("}") catch return;
        self.emit(aw.written());
    }

    /// Save an inline screenshot as img-<pid>-NNNN[-tag].png + a trace
    /// entry. `tag` names what triggered the shot ("click", "move");
    /// "" for plain captures.
    fn logImage(self: *McpLog, caption: []const u8, png: []const u8, tag: []const u8) void {
        self.img_seq += 1;
        var nbuf: [64]u8 = undefined;
        const fname = std.fmt.bufPrint(&nbuf, "img-{d}-{d:0>4}{s}{s}.png", .{
            c.getpid(),                   self.img_seq,
            if (tag.len > 0) "-" else "", tag,
        }) catch return;
        var z: [4096]u8 = undefined;
        const path = std.fmt.bufPrintZ(&z, "{s}/{s}", .{ self.dir, fname }) catch return;
        if (c.fopen(path.ptr, "wb")) |f| {
            _ = c.fwrite(png.ptr, 1, png.len, f);
            _ = c.fclose(f);
        }
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        var aw: std.Io.Writer.Allocating = .init(arena_state.allocator());
        const w = &aw.writer;
        var tbuf: [40]u8 = undefined;
        w.print("{{\"ts\":\"{s}\",\"event\":\"image\",\"file\":\"{s}\",\"bytes\":{d},\"caption\":", .{ stamp(&tbuf), fname, png.len }) catch return;
        std.json.Stringify.value(caption, .{}, w) catch return;
        w.writeAll("}") catch return;
        self.emit(aw.written());
    }

    /// Free-form marker entry (session start/stop, mode info).
    fn logNote(self: *McpLog, note: []const u8) void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        var aw: std.Io.Writer.Allocating = .init(arena_state.allocator());
        const w = &aw.writer;
        var tbuf: [40]u8 = undefined;
        w.print("{{\"ts\":\"{s}\",\"event\":\"note\",\"note\":", .{stamp(&tbuf)}) catch return;
        std.json.Stringify.value(note, .{}, w) catch return;
        w.writeAll("}") catch return;
        self.emit(aw.written());
    }
};

pub var mcp_log: ?McpLog = null;

/// Seconds an isolated instance's daemon may sit with no sessions and
/// no clients before it exits on its own (see `setupIsolation`'s caller).
const ISOLATED_IDLE_EXIT_SECS = "120";

/// The private daemon instance of an isolated (non `--shared`) run.
const Isolation = struct {
    /// $XDG_RUNTIME_DIR/sketerm/mcp-<name> or .../mcp-tmp-<pid> (owned).
    dir: []u8,
    /// `dir`/mux.sock (owned).
    sock: []u8,
    durable: bool,

    fn deinit(self: *Isolation, allocator: std.mem.Allocator) void {
        allocator.free(self.dir);
        allocator.free(self.sock);
    }
};

/// Create (or reuse) the isolated instance dir. The daemon itself is
/// autostarted lazily by the first app tool call.
fn setupIsolation(allocator: std.mem.Allocator, name: ?[]const u8, durable: bool) ?Isolation {
    const rt = platform.runtimeDir();
    var z_buf: [4096]u8 = undefined;
    const base = std.fmt.bufPrintZ(&z_buf, "{s}/sketerm", .{rt}) catch return null;
    _ = c.mkdir(base.ptr, 0o700);
    const dir = if (name) |n|
        std.fmt.allocPrint(allocator, "{s}/sketerm/mcp-{s}", .{ rt, n }) catch return null
    else
        std.fmt.allocPrint(allocator, "{s}/sketerm/mcp-tmp-{d}", .{ rt, c.getpid() }) catch return null;
    // No errdefer: `?Isolation` cannot return an error, so it would
    // never run. Both bail-outs below free `dir` explicitly.
    const dir_z = std.fmt.bufPrintZ(&z_buf, "{s}", .{dir}) catch {
        allocator.free(dir);
        return null;
    };
    _ = c.mkdir(dir_z.ptr, 0o700);
    const sock = std.fmt.allocPrint(allocator, "{s}/mux.sock", .{dir}) catch {
        allocator.free(dir);
        return null;
    };
    return .{ .dir = dir, .sock = sock, .durable = durable };
}

/// Ask the daemon at `sock` to shut down and wait (briefly) for it to
/// stop accepting connections. Best-effort.
fn shutdownDaemonAt(allocator: std.mem.Allocator, sock: []const u8) void {
    if (muxclient.Conn.connect(allocator, sock)) |conn| {
        var conn2 = conn;
        defer conn2.deinit();
        conn2.sendFrame(.shutdown, "") catch {};
    } else |_| return;
    var tries: u32 = 0;
    while (tries < 40) : (tries += 1) {
        _ = c.usleep(50_000);
        if (muxclient.Conn.connect(allocator, sock)) |probe| {
            var pc = probe;
            pc.deinit();
        } else |_| return;
    }
}

/// Reap ephemeral instances (mcp-tmp-<pid>) whose owning MCP process
/// is gone — a SIGKILLed server can't run its own teardown, so every
/// startup sweeps for orphans. Named (durable) instances are kept.
fn sweepStaleEphemeral(allocator: std.mem.Allocator) void {
    const rt = platform.runtimeDir();
    var base_buf: [4096]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "{s}/sketerm", .{rt}) catch return;
    const d = c.opendir(base.ptr) orelse return;
    defer _ = c.closedir(d);
    while (c.readdir(d)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.startsWith(u8, name, "mcp-tmp-")) continue;
        const pid = std.fmt.parseInt(c.pid_t, name["mcp-tmp-".len..], 10) catch continue;
        if (pid == c.getpid()) continue;
        const rc = c.kill(pid, 0);
        if (rc == 0 or std.posix.errno(rc) != .SRCH) continue;
        var path_buf: [4096]u8 = undefined;
        const sock = std.fmt.bufPrint(&path_buf, "{s}/{s}/mux.sock", .{ base, name }) catch continue;
        shutdownDaemonAt(allocator, sock);
        const dir = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base, name }) catch continue;
        @import("../util/pathz.zig").removeTree(dir);
    }
}

/// Central hard timeout — ONE watchdog covering EVERY tool call, not
/// per-tool special cases. If a call exceeds the cap, the watchdog
/// shuts down all mux connection fds registered for the call; every
/// bounded IO loop on them then errors within its own (much shorter)
/// deadline, the call returns an error, and the server keeps serving.
/// A backstop for wedges no per-path deadline anticipated — not a
/// substitute for them. Affected app sessions surface as exited/
/// disconnected afterwards: harsh, but strictly better than a hung
/// server an agent can neither cancel nor distinguish from "slow".
pub const Watchdog = struct {
    /// Guards started_ms/fds/fd_count against the check-then-shutdown in
    /// loop(): without it, a call ending right at the cap can race begin()
    /// resetting the state, aborting the NEXT call's connections at t=0.
    /// Uncontended in practice (the thread wakes once per second).
    /// pthread via libc: Zig 0.16 std.Thread has no Mutex.
    pub var mu: c.pthread_mutex_t = undefined;

    pub fn initLock() void {
        _ = c.pthread_mutex_init(&mu, null);
    }
    /// Monotonic ms when the in-flight call started; 0 = idle.
    pub var started_ms: i64 = 0;
    /// Conn fds snapshotted at call start. An fd closed AND reused
    /// mid-call could be shut down wrongly, but a wedged main thread
    /// cannot close fds, and normal calls finish far under the cap.
    pub var fds: [128]c_int = undefined;
    pub var fd_count: usize = 0;
    /// A panel connection may be established after begin().
    pub var dynamic_fd: muxclient.FdCancel = .{};
    /// The persistent fs connection is lazy and may be replaced mid-call.
    pub var fs_fd: muxclient.FdCancel = .{};
    pub var fired: std.atomic.Value(bool) = .init(false);
    pub var hard_ms: i64 = 150_000;

    pub fn begin() void {
        _ = c.pthread_mutex_lock(&mu);
        defer _ = c.pthread_mutex_unlock(&mu);
        fd_count = 0;
        // A previous call's panel connection is gone; the persistent fs
        // one is deliberately kept, but both stop latches must clear or
        // this call's publishes would be interrupted on arrival.
        dynamic_fd.release();
        dynamic_fd.arm();
        fs_fd.arm();
        for (mcp_app.app_state.apps.values()) |a| addFd(a.conn.fd);
        for (mcp_term.term_state.terms.values()) |t| addFd(t.conn.fd);
        if (panel_pool) |pool| {
            var panel_fds: [32]c_int = undefined;
            const count = pool.fds(&panel_fds);
            for (panel_fds[0..count]) |fd| addFd(fd);
        }
        for (mcp_term.forward_state.forwards.values()) |f| addFd(f.term.conn.fd);
        {
            // EVERY headless web helper's socket (one helper instance
            // per browser route), and the broker-profile connection
            // beside each. A wedged helper on any route must be
            // abortable, or the route it serves outlives the hard cap.
            var web_fds: [16]c_int = undefined;
            for (@import("mcp_web.zig").watchdogFds(&web_fds)) |fd| addFd(fd);
            var web_mux_fds: [16]c_int = undefined;
            for (@import("mcp_web.zig").watchdogMuxFds(&web_mux_fds)) |fd| addFd(fd);
        }
        fired.store(false, .release);
        started_ms = clock.nowMs();
    }

    pub fn addFd(fd: c_int) void {
        if (fd_count < fds.len) {
            fds[fd_count] = fd;
            fd_count += 1;
        }
    }

    pub fn end() void {
        _ = c.pthread_mutex_lock(&mu);
        defer _ = c.pthread_mutex_unlock(&mu);
        started_ms = 0;
    }

    pub fn cancelDynamicFds() void {
        dynamic_fd.stop();
        fs_fd.stop();
    }

    pub fn loop() void {
        while (true) {
            var ts = c.struct_timespec{ .tv_sec = 1, .tv_nsec = 0 };
            _ = c.nanosleep(&ts, null);
            _ = c.pthread_mutex_lock(&mu);
            const overdue = started_ms != 0 and !fired.load(.acquire) and clock.nowMs() - started_ms > hard_ms;
            if (overdue) {
                fired.store(true, .release);
                for (fds[0..fd_count]) |fd| _ = c.shutdown(fd, c.SHUT_RDWR);
                // A panel socket may have been created after begin() and can
                // still be in connect/hello/attach. Pool exposes that call's
                // fd atomically so the watchdog covers establishment too.
                cancelDynamicFds();
            }
            _ = c.pthread_mutex_unlock(&mu);
            if (overdue) {
                // stderr only: mcp_log is main-thread-owned (its
                // close at exit would race a note from this thread).
                _ = c.fputs("sketerm mcp: tool call exceeded the hard timeout; mux connections aborted to unwedge it\n", platform.stderr());
            }
        }
    }
};

var quit_flag: bool = false;

fn onQuitSignal(_: c_int) callconv(.c) void {
    quit_flag = true;
}

/// SIGTERM/SIGINT must interrupt the blocking getline (no SA_RESTART)
/// so an ephemeral run still tears its private daemon down when the
/// MCP client kills us instead of closing stdin.
///
/// SIGPIPE must be neutered: a session worker dying (its app exited)
/// closes our attach socket, and the next write to it — e.g. an audio
/// `consumed` report inside a routine drain — would otherwise KILL the
/// whole MCP server silently (no core, no stderr), which the client
/// experiences as a forever-hanging tool call.
fn installQuitSignals() void {
    var sa: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
    platform.setSigHandler(&sa, onQuitSignal);
    sa.sa_flags = 0;
    _ = c.sigaction(c.SIGTERM, &sa, null);
    _ = c.sigaction(c.SIGINT, &sa, null);
    platform.ignoreSigpipe();
}

/// Owned strings backing the process-wide `policy` (its spec is
/// borrowed for the whole run, so it cannot live in a config arena
/// that is freed right after parsing).
const OwnedPolicy = struct { spec: []u8, source: []u8 };

/// The `[mcp.<name>]` record `--profile` names, or a printed
/// diagnostic and an error: silently running unrestricted would be the
/// worst outcome.
fn mcpProfileRecord(cfg: *const Config, name: []const u8) error{BadPolicy}!*const @import("../config.zig").McpProfile {
    return cfg.mcpProfile(name) orelse {
        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&msg_buf, "sketerm mcp: --profile {s}: no [mcp.{s}] section in config.conf\n  add one, e.g.:\n    [mcp.{s}]\n    tools = app, files:ro\n", .{ name, name, name }) catch "sketerm mcp: unknown --profile\n";
        _ = c.fputs(msg.ptr, platform.stderr());
        return error.BadPolicy;
    };
}

/// Resolve the tool exposure policy, lowest precedence first: the
/// bare `[mcp]` section, `[mcp.<name>]` from config.conf, then
/// $SKETERM_MCP_TOOLS, then `--tools`. Sets `policy`/`policy_source`;
/// returns the owned strings (null when nothing narrowed the tool
/// set). Every failure prints a complete diagnostic and returns an
/// error — a bad spec must never degrade into "everything" or into a
/// silently missing group.
fn resolveToolPolicy(allocator: std.mem.Allocator, opts: Opts, cfg: *const Config) error{BadPolicy}!?OwnedPolicy {
    var spec: []const u8 = "";
    var source: []const u8 = "none";
    var name_buf: [96]u8 = undefined;

    // The config records live as long as `cfg`, which outlives this
    // resolution; the survivors are duped below.
    if (cfg.mcp.tools.len > 0) {
        spec = cfg.mcp.tools;
        source = "config [mcp]";
    }
    if (opts.profile) |name| {
        const prof = try mcpProfileRecord(cfg, name);
        if (prof.tools.len > 0) {
            spec = prof.tools;
            source = std.fmt.bufPrint(&name_buf, "config [mcp.{s}]", .{name}) catch "config [mcp.*]";
        }
    }
    if (c.getenv("SKETERM_MCP_TOOLS")) |v| {
        spec = std.mem.span(@as([*:0]const u8, @ptrCast(v)));
        source = "SKETERM_MCP_TOOLS";
    }
    if (opts.tools) |t| {
        spec = t;
        source = "--tools";
    }

    var bad: []const u8 = "";
    mcpfilter.Policy.validate(spec, &bad) catch {
        var msg_buf: [1024]u8 = undefined;
        var groups_buf: [256]u8 = undefined;
        var gw = std.Io.Writer.fixed(&groups_buf);
        for (std.enums.values(mcpfilter.Group), 0..) |g, i| {
            if (i > 0) gw.writeAll(", ") catch {};
            gw.writeAll(g.name()) catch {};
        }
        const msg = std.fmt.bufPrintZ(&msg_buf, "sketerm mcp: bad tool policy term '{s}' (from {s})\n  spec: {s}\n  groups: {s}\n  terms: all | all:ro | GROUP | GROUP:ro | TOOL | -GROUP | -TOOL\n", .{ bad, source, spec, gw.buffered() }) catch "sketerm mcp: bad tool policy\n";
        _ = c.fputs(msg.ptr, platform.stderr());
        return error.BadPolicy;
    };

    const trimmed = std.mem.trim(u8, spec, " \t\r\n");
    if (trimmed.len == 0) return null;
    const owned_spec = allocator.dupe(u8, trimmed) catch return error.BadPolicy;
    const owned_source = allocator.dupe(u8, source) catch {
        allocator.free(owned_spec);
        return error.BadPolicy;
    };
    policy = .{ .spec = owned_spec };
    policy_source = owned_source;
    return .{ .spec = owned_spec, .source = owned_source };
}

/// The web_gui grant from its sources (`mcp_webgui.resolveGrant`),
/// with the `[mcp.<name>]` half read from the same record the tool
/// policy uses. A bad env value prints and errors, like a bad spec.
fn resolveWebGuiGrant(opts: Opts, cfg: *const Config) error{BadPolicy}!mcp_webgui.Grant {
    var prof_value: ?bool = null;
    var prof_name: []const u8 = "";
    if (opts.profile) |name| {
        const prof = try mcpProfileRecord(cfg, name);
        prof_value = prof.web_gui;
        prof_name = name;
    }
    const env: ?[]const u8 = if (c.getenv(mcp_webgui.ENV)) |v| std.mem.span(@as([*:0]const u8, @ptrCast(v))) else null;
    return mcp_webgui.resolveGrant(cfg.mcp.web_gui, prof_value, prof_name, env, opts.web_gui) catch {
        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&msg_buf, "sketerm mcp: bad {s} value '{s}' (use 1/true/yes/on or 0/false/no/off)\n", .{ mcp_webgui.ENV, env orelse "" }) catch "sketerm mcp: bad SKETERM_MCP_WEB_GUI value\n";
        _ = c.fputs(msg.ptr, platform.stderr());
        return error.BadPolicy;
    };
}

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const opts = Opts.parse(args) catch |err| {
        const msg = switch (err) {
            error.UnknownFlag => "sketerm mcp: unknown flag (see --help)\n",
            error.MissingValue => "sketerm mcp: flag needs a value\n",
            error.BadName => "sketerm mcp: --name/--profile must be 1-48 chars of [A-Za-z0-9_-]\n",
            error.SharedConflict => "sketerm mcp: --shared conflicts with --durable/--name\n",
        };
        _ = c.fputs(msg, platform.stderr());
        return 2;
    };
    if (opts.help) {
        _ = c.fputs(MCP_HELP, platform.stdout());
        return 0;
    }

    // Tool exposure policy and the web_gui grant, resolved BEFORE any
    // daemon or socket work: a typo must cost one clear line on
    // stderr, never a silently half-equipped server. One config load
    // serves both.
    var cfg = Config.load(allocator);
    defer cfg.deinit();
    const policy_owned = resolveToolPolicy(allocator, opts, &cfg) catch return 2;
    defer if (policy_owned) |p| {
        allocator.free(p.spec);
        allocator.free(p.source);
        policy = .unrestricted;
        policy_source = "none";
    };
    const web_gui_grant = resolveWebGuiGrant(opts, &cfg) catch return 2;

    if (opts.log_dir) |ld| {
        mcp_log = McpLog.open(allocator, ld) orelse {
            _ = c.fputs("sketerm mcp: cannot open --log dir (parent must exist and be writable)\n", platform.stderr());
            return 1;
        };
    }
    defer if (mcp_log) |*l| {
        l.logNote("mcp server exiting");
        l.close();
        mcp_log = null;
    };

    // Isolated (default): app tools get a private daemon; the user's
    // per-user daemon and GUI stay out of reach. --shared opts into
    // the real daemon + running GUI.
    var iso: ?Isolation = null;
    if (!opts.shared) {
        sweepStaleEphemeral(allocator);
        iso = setupIsolation(allocator, opts.name, opts.durable) orelse {
            _ = c.fputs("sketerm mcp: cannot create isolated runtime dir\n", platform.stderr());
            return 1;
        };
        // A private daemon with no sessions and no clients is nobody's:
        // let it retire itself (muxclient passes this to every daemon it
        // autostarts from this process). A durable instance still keeps
        // its apps -- the count is of SESSIONS, and the next tool call
        // simply autostarts a fresh broker. Without it every `--name`
        // ever used left an idle broker behind until reboot.
        _ = c.setenv(muxclient.Conn.IDLE_EXIT_ENV, ISOLATED_IDLE_EXIT_SECS, 1);
    }
    defer if (iso) |*i| i.deinit(allocator);

    // Fail fast on a socket path over the sun_path limit — otherwise
    // the daemon's bind fails only at the first app tool call, as an
    // opaque MuxDaemonUnreachable.
    if (iso) |i| {
        var probe: c.struct_sockaddr_un = undefined;
        @import("../mux/daemon.zig").fillSockaddrUn(&probe, i.sock) catch {
            var msg_buf: [4224]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&msg_buf, "sketerm mcp: socket path too long for a Unix socket ({d} chars, limit {d}):\n  {s}\npoint XDG_RUNTIME_DIR at a shorter path\n", .{ i.sock.len, probe.sun_path.len - 1, i.sock }) catch "sketerm mcp: socket path too long for a Unix socket\n";
            _ = c.fputs(msg.ptr, platform.stderr());
            return 1;
        };
    }

    // Publish MCP-process liveness independently of its lazily started mux
    // daemon. The held flock survives ordinary operation and is released by
    // the kernel even after SIGKILL, so doctor never has to guess by name.
    const shared_mux_sock = if (opts.shared)
        @import("../mux/daemon.zig").defaultSocketPath(allocator) catch null
    else
        null;
    defer if (shared_mux_sock) |path| allocator.free(path);
    var registry_lease: ?mcp_registry.Lease = null;
    const registry_sock = if (iso) |i| i.sock else shared_mux_sock orelse "";
    if (mcp_registry.Lease.acquire(allocator, .{
        .mode = if (opts.shared) .shared else if (opts.durable) .durable else .isolated,
        .name = opts.name orelse "",
        .profile = opts.profile orelse "",
        .log_dir = opts.log_dir orelse "",
        .mux_socket = registry_sock,
    })) |lease| {
        registry_lease = lease;
    } else |_| {
        _ = c.fputs("sketerm mcp: warning: cannot publish live-server metadata for `sketerm doctor`\n", platform.stderr());
    }
    defer if (registry_lease) |*lease| lease.deinit();

    // Terminal tools need a running GUI's socket. Shared mode resolves
    // it like `sketerm cli`; isolated mode only honors an EXPLICIT
    // --socket (no auto-discovery — that would pierce the isolation).
    const sock_path = if (opts.shared or opts.socket != null)
        @import("client.zig").resolveSocket(allocator, opts.socket)
    else
        null;
    defer if (sock_path) |p| allocator.free(p);
    var real = RealBackend{ .sock_path = sock_path orelse "" };
    defer real.client.deinit();
    var stub = StubBackend{};
    const backend = if (sock_path != null) real.asBackend() else Backend{
        .ctx = @ptrCast(&stub),
        .talk = StubBackend.talk,
        .talkFor = StubBackend.talkFor,
        .sleepMs = RealBackend.sleepMs,
        .nowMs = RealBackend.nowMs,
        .gui_attached = false,
    };
    var live_panel_pool = paneldrive.Pool.init(allocator);
    live_panel_pool.setWatchdogFd(&Watchdog.dynamic_fd);
    panel_pool = &live_panel_pool;
    defer {
        panel_pool = null;
        live_panel_pool.deinit();
    }
    mcp_app.app_state = .{
        .allocator = allocator,
        .mux_sock = if (iso) |i| i.sock else null,
        .keep_apps = if (iso) |i| i.durable else false,
    };
    defer mcp_app.app_state.deinit();
    defer Journal.deinitAll();
    defer LogDelta.deinitAll();
    defer MacroNudge.deinitAll();
    // Headless terminal tools run on the private daemon (isolated
    // mode only); --shared keeps the GUI-backed terminal tools.
    mcp_term.term_state = .{
        .allocator = allocator,
        .mux_sock = if (iso) |i| i.sock else null,
    };
    defer mcp_term.term_state.deinit();
    mcp_term.forward_state = .{ .allocator = allocator };
    defer mcp_term.forward_state.deinit();
    mcp_files.fs_state = .{ .allocator = allocator };
    defer mcp_files.fs_state.drop();
    mcp_term.rec_state = .{ .allocator = allocator, .enabled = !opts.no_record };
    defer mcp_term.rec_state.deinit();
    srv_mode = if (opts.shared) "shared" else if (iso != null and iso.?.durable) "durable" else "isolated";
    srv_gui_socket = sock_path != null;
    srv_gui_socket_source = if (sock_path == null)
        .none
    else if (opts.socket != null)
        .explicit
    else
        .discovered;

    // Named/durable instance: pick up app sessions still running on
    // the private daemon from a previous run.
    if (iso) |i| {
        if (i.durable) reattachApps(i.sock);
    }

    // Headless web fallback: with no GUI socket the web_* tools run
    // their own sketerm-webengine inside the instance dir (spawned
    // lazily on first use). Isolated/durable modes only — --shared
    // explicitly asks for the user's GUI and has no instance dir.
    if (iso) |i| {
        @import("mcp_web.zig").configureHeadless(allocator, i.dir, opts.name, i.sock);
    }
    defer @import("mcp_web.zig").shutdownHeadless();
    // The web_gui grant: the web_* tools alone may use the user's own
    // browser. With a server-wide GUI socket already attached (--shared
    // / --socket) they use it as they always did; otherwise the grant
    // arms its own lazy discover-or-spawn transport.
    srv_web_gui = web_gui_grant;
    if (web_gui_grant.granted and sock_path == null)
        mcp_webgui.configure(allocator, web_gui_grant, mcp_webgui.REAL_OPS);
    defer mcp_webgui.shutdown();

    installQuitSignals();

    // Central hard timeout (SKETERM_MCP_HARD_TIMEOUT_MS overrides;
    // min 30s so it always outlasts the per-path deadlines).
    if (c.getenv("SKETERM_MCP_HARD_TIMEOUT_MS")) |v| {
        const span = std.mem.span(@as([*:0]const u8, @ptrCast(v)));
        if (std.fmt.parseInt(i64, span, 10)) |ms| {
            Watchdog.hard_ms = @max(ms, 30_000);
        } else |_| {}
    }
    Watchdog.initLock();
    if (std.Thread.spawn(.{}, Watchdog.loop, .{})) |t| t.detach() else |_| {}

    // Project-level input-timing overrides (see Tuning). Logged so
    // the trace shows the effective defaults, not just the env.
    Tuning.load();
    if (mcp_log) |*l| {
        for (Tuning.all()) |item| {
            if (!item.overridden) continue;
            var tbuf: [160]u8 = undefined;
            const note = std.fmt.bufPrint(&tbuf, "tuning override: {s}={d} (via {s}; built-in {d})", .{
                item.name, item.value, item.env, item.built_in,
            }) catch continue;
            l.logNote(note);
        }
    }

    if (mcp_log) |*l| {
        if (!policy.isUnrestricted()) {
            var pbuf: [1024]u8 = undefined;
            const note = std.fmt.bufPrint(&pbuf, "tool policy: {s} (from {s})", .{ policy.spec, policy_source }) catch "tool policy set";
            l.logNote(note);
        }
        var nbuf: [512]u8 = undefined;
        const note = std.fmt.bufPrint(&nbuf, "mcp server started: pid={d} mode={s} name={s} gui_socket={s} web_gui={s} (from {s})", .{
            c.getpid(),
            if (opts.shared) "shared" else "isolated",
            opts.name orelse "-",
            sock_path orelse "-",
            yesNo(web_gui_grant.granted),
            web_gui_grant.source.name(),
        }) catch "mcp server started";
        l.logNote(note);
    }

    // stdin loop: one JSON-RPC message per line.
    var lineptr: [*c]u8 = null;
    var linecap: usize = 0;
    defer if (lineptr != null) c.free(lineptr);
    while (!quit_flag) {
        const n = c.getline(&lineptr, &linecap, platform.stdin());
        if (n < 0) break; // EOF or EINTR — client closed us down.
        var line: []const u8 = lineptr[0..@intCast(n)];
        line = std.mem.trim(u8, line, " \t\r\n");
        if (line.len == 0) continue;
        if (mcp_log) |*l| l.logMessage("in", line);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        Watchdog.begin();
        const reply = handleMessage(arena_state.allocator(), backend, line);
        Watchdog.end();
        if (Watchdog.fired.load(.acquire)) {
            // Main-thread, post-call: safe to touch the trace log.
            if (mcp_log) |*l| l.logNote("watchdog fired during the previous call: hard timeout exceeded, mux connections were aborted");
        }
        if (reply) |r| {
            if (mcp_log) |*l| l.logMessage("out", r);
            _ = c.fwrite(r.ptr, 1, r.len, platform.stdout());
            _ = c.fputc('\n', platform.stdout());
            _ = c.fflush(platform.stdout());
        }
    }

    // Ephemeral teardown: detach app viewers first (deinit is
    // idempotent; the deferred call becomes a no-op), then retire the
    // private daemon and remove its dir. Durable/named instances stay.
    // The web helper must die BEFORE the tree removal — a live CEF
    // keeps writing into its cache dir, leaving the dir un-removable.
    @import("mcp_web.zig").shutdownHeadless();
    mcp_term.forward_state.deinit();
    mcp_term.term_state.deinit();
    mcp_app.app_state.deinit();
    if (iso) |i| {
        if (!i.durable) {
            shutdownDaemonAt(allocator, i.sock);
            @import("../util/pathz.zig").removeTree(i.dir);
        }
    }
    return 0;
}

/// Backend when no GUI is running: terminal tools fail with a clear
/// message; app tools never route through it.
const StubBackend = struct {
    fn talk(ctx: *anyopaque, allocator: std.mem.Allocator, line: []const u8) anyerror![]u8 {
        _ = ctx;
        _ = allocator;
        _ = line;
        return error.NoGuiSocket;
    }

    fn talkFor(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: i64) DirectTalkResult {
        return .{ .failure = .{ .err = error.NoGuiSocket, .delivery = .pre_delivery } };
    }
};

pub const RealBackend = struct {
    sock_path: [:0]const u8,
    /// The one connection to `sock_path`, kept across tool calls.
    client: ctlclient.Persistent = .init(std.heap.c_allocator),

    /// The dispatch table over this socket. `self` must outlive it.
    pub fn asBackend(self: *RealBackend) Backend {
        return .{
            .ctx = @ptrCast(self),
            .talk = talk,
            .talkFor = talkFor,
            .sleepMs = sleepMs,
            .nowMs = nowMs,
        };
    }

    /// Bound on one untimed exchange: a wedged GUI must cost a described
    /// error, never a hung tool call.
    const TALK_TIMEOUT_MS: i64 = 30_000;

    fn talk(ctx: *anyopaque, allocator: std.mem.Allocator, line: []const u8) anyerror![]u8 {
        return switch (talkFor(ctx, allocator, line, TALK_TIMEOUT_MS)) {
            .reply => |reply| reply,
            .failure => |f| f.err,
        };
    }

    /// Deadline-bounded exchange whose failure keeps its delivery phase.
    pub fn talkFor(ctx: *anyopaque, allocator: std.mem.Allocator, line: []const u8, timeout_ms: i64) DirectTalkResult {
        const self: *RealBackend = @ptrCast(@alignCast(ctx));
        return self.client.exchange(allocator, self.sock_path, line, timeout_ms);
    }

    fn sleepMs(_: *anyopaque, ms: u32) void {
        var ts: c.struct_timespec = .{
            .tv_sec = ms / 1000,
            .tv_nsec = @as(c_long, ms % 1000) * 1_000_000,
        };
        _ = c.nanosleep(&ts, null);
    }

    fn nowMs(_: *anyopaque) i64 {
        return clock.nowMs();
    }
};

// ── JSON-RPC dispatch ─────────────────────────────────────────────

/// Handle one message line. Returns the response line (no trailing
/// newline, arena-allocated) or null for notifications. Never throws:
/// internal failures become JSON-RPC error responses.
pub fn handleMessage(arena: std.mem.Allocator, backend: Backend, line: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch {
        return rpcError(arena, .null, -32700, "parse error");
    };
    if (parsed != .object) return rpcError(arena, .null, -32600, "invalid request");
    const obj = parsed.object;
    const id: std.json.Value = obj.get("id") orelse .null;
    const method_v = obj.get("method") orelse return rpcError(arena, id, -32600, "missing method");
    if (method_v != .string) return rpcError(arena, id, -32600, "bad method");
    const method = method_v.string;
    const params: std.json.Value = obj.get("params") orelse .null;
    const is_notification = obj.get("id") == null;

    if (std.mem.eql(u8, method, "initialize")) {
        // Echo the client's protocol version when it sent one — we
        // speak plain tools-only MCP, compatible across revisions.
        var ver: []const u8 = PROTOCOL_VERSION;
        if (params == .object) {
            if (params.object.get("protocolVersion")) |v| {
                if (v == .string) ver = v.string;
            }
        }
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        w.writeAll("{\"protocolVersion\":") catch return null;
        std.json.Stringify.value(ver, .{}, w) catch return null;
        w.print(",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"sketerm\",\"version\":\"{s}\"}}}}", .{SERVER_VERSION}) catch return null;
        return rpcResult(arena, id, aw.written());
    }
    if (std.mem.startsWith(u8, method, "notifications/")) return null;
    if (std.mem.eql(u8, method, "ping")) {
        return rpcResult(arena, id, "{}");
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        const tools = renderedToolsJson(arena) catch return null;
        const result = std.fmt.allocPrint(arena, "{{\"tools\":{s}}}", .{tools}) catch return null;
        return rpcResult(arena, id, result);
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        if (params != .object) return rpcError(arena, id, -32602, "tools/call needs params");
        const name_v = params.object.get("name") orelse return rpcError(arena, id, -32602, "missing tool name");
        if (name_v != .string) return rpcError(arena, id, -32602, "bad tool name");
        const args: std.json.Value = params.object.get("arguments") orelse .null;
        // Enforcement, not presentation: a client that learned the name
        // from documentation must be refused here too.
        if (!policy.allows(name_v.string)) {
            if (is_notification) return null;
            const msg = withheldMessage(arena, name_v.string) catch return null;
            return rpcResult(arena, id, errRes(arena, .refused, msg) catch return null);
        }
        const outcome = callTool(arena, backend, name_v.string, args) catch |err| {
            const msg = std.fmt.allocPrint(arena, "tool failed: {s}", .{@errorName(err)}) catch return null;
            return rpcResult(arena, id, errRes(arena, .failed, msg) catch return null);
        };
        if (is_notification) return null;
        return rpcResult(arena, id, outcome);
    }
    if (is_notification) return null;
    return rpcError(arena, id, -32601, "method not found");
}

/// Every call goes through the tool table: `mcp_tools.route` names the
/// group, and each group handler switches exhaustively over that group's
/// tools, so a table entry without a handler does not compile.
fn callTool(arena: std.mem.Allocator, backend: Backend, name: []const u8, args: std.json.Value) ![]const u8 {
    const routed = mcp_tools.route(name) orelse return errRes(arena, .unknown_tool, "unknown tool");
    return switch (routed) {
        .panes => |tool| mcp_panes.panesTool(arena, backend, tool, args),
        .app => |tool| mcp_app.appTool(arena, tool, args),
        .term => |tool| mcp_term.termTool(arena, tool, args),
        .files => |tool| mcp_files.filesTool(arena, tool, args),
        .net => |tool| mcp_term.forwardTool(arena, tool, args),
        // mcp_web.zig resolves its own tool names.
        .browser => |tool| @import("mcp_web.zig").webTool(arena, backend, @tagName(tool), args),
        .ui => |tool| mcp_ui.uiTool(arena, backend, tool, args),
        .core => |tool| switch (tool) {
            .capabilities => mcp_caps.capabilitiesTool(arena, backend),
        },
    };
}

/// Refusal text for a tool the policy withholds. Deliberately NOT
/// "method not found": that reads as a missing feature and costs the
/// assistant a round of guessing. It says the tool exists, that the
/// operator restricted this connection, and the exact term that would
/// bring it back.
fn withheldMessage(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const meta = mcpfilter.lookup(name) orelse return std.fmt.allocPrint(
        arena,
        "tool '{s}' is not enabled for this connection (and is not a known sketerm tool). This MCP server runs with the tool policy \"{s}\"; call `capabilities` to see which groups are available.",
        .{ name, policy.spec },
    );
    return std.fmt.allocPrint(
        arena,
        "tool '{s}' EXISTS but is not enabled for this connection: this MCP server was started with the tool policy \"{s}\" (from {s}), which withholds it. This is an operator decision, not a missing feature or a bug — do not retry. To enable it, the server must be restarted with `--tools {s}` (whole group) or `--tools {s}` (that one tool). `capabilities` reports the active policy and the suppressed groups.",
        .{ name, policy.spec, policy_source, meta.group.name(), name },
    );
}

fn rpcResult(arena: std.mem.Allocator, id: std.json.Value, result_json: []const u8) ?[]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return null;
    std.json.Stringify.value(id, .{}, w) catch return null;
    w.writeAll(",\"result\":") catch return null;
    w.writeAll(result_json) catch return null;
    w.writeAll("}") catch return null;
    return aw.written();
}

fn rpcError(arena: std.mem.Allocator, id: std.json.Value, code: i32, msg: []const u8) ?[]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return null;
    std.json.Stringify.value(id, .{}, w) catch return null;
    w.print(",\"error\":{{\"code\":{d},\"message\":", .{code}) catch return null;
    std.json.Stringify.value(msg, .{}, w) catch return null;
    w.writeAll("}}") catch return null;
    return aw.written();
}

/// PNG dimensions from the IHDR chunk, which every PNG opens with.
/// THE image-metadata read: every tool that returns pixels reports
/// width/height from here rather than re-parsing the header.
pub fn pngSize(bytes: []const u8) ?struct { w: u32, h: u32 } {
    if (bytes.len < 24) return null;
    if (!std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return null;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    return .{
        .w = std.mem.readInt(u32, bytes[16..20], .big),
        .h = std.mem.readInt(u32, bytes[20..24], .big),
    };
}

/// THE tool-failure vocabulary: every isError result names one of
/// these. Facts ride the member (retryable); exhaustive switches only.
pub const ErrCode = enum {
    invalid_args,
    not_found,
    unavailable,
    timeout,
    refused,
    conflict,
    io_failed,
    unknown_tool,
    failed,

    pub fn retryable(self: ErrCode) bool {
        return switch (self) {
            .timeout, .unavailable, .io_failed => true,
            .invalid_args, .not_found, .refused, .conflict, .unknown_tool, .failed => false,
        };
    }
};

/// The uniform error result: message in the text lane, machine shape
/// in structuredContent, isError set.
pub fn errRes(arena: std.mem.Allocator, code: ErrCode, msg: []const u8) ![]const u8 {
    return errResDetails(arena, code, msg, @as(?u8, null));
}

/// Optional typed evidence belongs to the error, not a second error-shaped
/// result builder in each tool family. The ordinary error contract is unchanged.
pub fn errResDetails(arena: std.mem.Allocator, code: ErrCode, msg: []const u8, details: anytype) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(msg, .{}, w);
    try w.writeAll("}],\"structuredContent\":{\"error\":{\"code\":\"");
    try w.writeAll(@tagName(code));
    try w.writeAll("\",\"message\":");
    try std.json.Stringify.value(msg, .{}, w);
    try w.writeAll(",\"retryable\":");
    try w.writeAll(if (code.retryable()) "true" else "false");
    if (details != null) {
        try w.writeAll(",\"details\":");
        try std.json.Stringify.value(details, .{ .emit_null_optional_fields = false }, w);
    }
    try w.writeAll("}},\"isError\":true}");
    return aw.written();
}

/// Renders a value for the human text lane: bare strings, plain
/// numbers, true/false — never JSON syntax.
fn textValue(w: *std.Io.Writer, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => try w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => try w.print("{d}", .{value}),
        .float, .comptime_float => try w.print("{d}", .{value}),
        .optional => if (value) |v| try textValue(w, v) else try w.writeAll("null"),
        .@"enum" => try w.writeAll(@tagName(value)),
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                try w.writeAll(value);
            } else if (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8) {
                try w.writeAll(value);
            } else {
                try w.print("{any}", .{value});
            }
        },
        else => try w.print("{any}", .{value}),
    }
}

/// Two-lane tool-result builder: machine facts accumulate into
/// structuredContent, token-efficient prose into ONE text content
/// block (never JSON). NDJSON-safe: the serialized result carries no
/// raw newline.
pub const Res = struct {
    arena: std.mem.Allocator,
    sc: std.Io.Writer.Allocating,
    tl: std.Io.Writer.Allocating,
    has_structured: bool = false,

    pub fn init(arena: std.mem.Allocator) Res {
        return .{ .arena = arena, .sc = .init(arena), .tl = .init(arena) };
    }

    fn scKey(self: *Res, name: []const u8) !void {
        const w = &self.sc.writer;
        if (self.has_structured) try w.writeAll(",");
        self.has_structured = true;
        try w.writeAll("\"");
        try w.writeAll(name);
        try w.writeAll("\":");
    }

    fn textLine(self: *Res) !*std.Io.Writer {
        const w = &self.tl.writer;
        if (self.tl.written().len != 0) try w.writeAll("\n");
        return w;
    }

    /// Structured fact plus an auto "name: value" text line.
    pub fn field(self: *Res, name: []const u8, value: anytype) !void {
        try self.fact(name, value);
        const w = try self.textLine();
        try w.writeAll(name);
        try w.writeAll(": ");
        try textValue(w, value);
    }

    /// Structured fact only — for what a human does not need repeated.
    pub fn fact(self: *Res, name: []const u8, value: anytype) !void {
        try self.scKey(name);
        try std.json.Stringify.value(value, .{}, &self.sc.writer);
    }

    /// Verbatim pre-serialized JSON fact (payloads); no text line.
    pub fn raw(self: *Res, name: []const u8, json: []const u8) !void {
        try self.scKey(name);
        try self.sc.writer.writeAll(json);
    }

    /// Free-form line for the text lane only.
    pub fn text(self: *Res, line: []const u8) !void {
        const w = try self.textLine();
        try w.writeAll(line);
    }

    pub fn textf(self: *Res, comptime fmt: []const u8, args: anytype) !void {
        const w = try self.textLine();
        try w.print(fmt, args);
    }

    pub fn finish(self: *Res) ![]const u8 {
        return self.finishWithImages(&.{}, null);
    }

    /// The accumulated facts as one JSON object — for a builder that
    /// produces an ELEMENT (one app in a list) rather than a result.
    pub fn structuredJson(self: *Res) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{{{s}}}", .{self.sc.written()});
    }

    /// finish plus inline PNG content blocks after the text block.
    /// `tags` (parallel to `pngs`) names the --log trace files.
    pub fn finishWithImages(self: *Res, pngs: []const []const u8, tags: ?[]const []const u8) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(self.arena);
        const w = &aw.writer;
        const t = self.tl.written();
        try w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
        try std.json.Stringify.value(if (t.len == 0) "ok" else t, .{}, w);
        try w.writeAll("}");
        const enc = std.base64.standard.Encoder;
        for (pngs, 0..) |p, i| {
            if (mcp_log) |*l| l.logImage(t, p, if (tags) |ts| (if (i < ts.len) ts[i] else "") else "");
            const b64 = try self.arena.alloc(u8, enc.calcSize(p.len));
            _ = enc.encode(b64, p);
            try w.writeAll(",{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"");
            try w.writeAll(b64);
            try w.writeAll("\"}");
        }
        try w.writeAll("]");
        if (self.has_structured) {
            try w.writeAll(",\"structuredContent\":{");
            try w.writeAll(self.sc.written());
            try w.writeAll("}");
        }
        try w.writeAll("}");
        return aw.written();
    }
};

// ── Tools ─────────────────────────────────────────────────────────
//
// The advertised list is not written here: `mcp_tools.TOOLS` is the one
// table, and it generates both the tools/list JSON and the policy
// classification. This file only renders it (timing tokens, filtering).

// ── input-timing tuning (env-overridable defaults) ────────────────
//
// A chronically slow app is a property of the PROJECT, not of one
// tool call — these let a project's .mcp.json env block declare it
// once (e.g. SKETERM_MCP_TIMEOUT_MS=15000). The SAME struct feeds
// the runtime defaults AND the rendered tools/list descriptions
// (renderedToolsJson), so the default the assistant reads is by
// construction the default the server uses — they cannot drift.
//
// min_change_pct deliberately has NO entry here: it decides the
// dead/live VERDICT rather than a timing bound, and an invisible
// non-zero default would fabricate "NO repaint" verdicts on normal
// apps. It stays per-call.
/// Bound on catching the app mirror up to the LIVE frame at tool
/// entry (appdrive.drainLive): backlog consumption + the daemon's
/// post-drain replay. Not a Tuning item — it bounds internal
/// convergence, not an input-timing behavior.
pub const CATCHUP_MS: i64 = 2_500;

/// Ceiling on any caller-supplied wait, app side. The central Watchdog
/// aborts a tool call at `Watchdog.hard_ms` (150s) and MCP hosts
/// commonly background a call at 120s, so accepting a larger
/// `timeout_ms` verbatim promises a wait that can never happen. Every
/// app tool clamps to this and the schemas say so.
pub const WAIT_CAP_MS: i64 = 120_000;

/// The one clamp for a caller-supplied `timeout_ms`. Every wait goes
/// through it: a tool that took the value verbatim promised a wait the
/// watchdog cancels, and on the pane tools it also blocked the
/// single-threaded loop for the whole of it.
pub fn waitCap(requested: ?i64, default_ms: i64) i64 {
    return std.math.clamp(requested orelse default_ms, 0, WAIT_CAP_MS);
}

pub const Tuning = struct {
    const Item = struct {
        name: []const u8,
        value: i64,
        built_in: i64,
        env: [:0]const u8,
        min: i64,
        max: i64,
        overridden: bool = false,
    };
    /// Click press→release span. Human clicks run 50-150ms; an
    /// instantaneous click is exactly the regime where edge-polling
    /// apps collapse press+release into one sample.
    pub var hold_ms: Item = .{ .name = "hold_ms", .value = 100, .built_in = 100, .env = "SKETERM_MCP_HOLD_MS", .min = 0, .max = 10_000 };
    pub var settle_ms: Item = .{ .name = "settle_ms", .value = 250, .built_in = 250, .env = "SKETERM_MCP_SETTLE_MS", .min = 0, .max = 30_000 };
    /// Post-input repaint wait when the wait is defaulted-on.
    pub var timeout_ms: Item = .{ .name = "timeout_ms", .value = 1_500, .built_in = 1_500, .env = "SKETERM_MCP_TIMEOUT_MS", .min = 100, .max = 30_000 };
    /// Extra app_click attempts when no qualifying repaint arrives.
    pub var click_retry: Item = .{ .name = "click_retry", .value = 0, .built_in = 0, .env = "SKETERM_MCP_CLICK_RETRY", .min = 0, .max = 5 };

    pub fn all() [4]*Item {
        return .{ &hold_ms, &settle_ms, &timeout_ms, &click_retry };
    }

    pub fn load() void {
        for (all()) |item| loadOne(item);
    }

    pub fn loadOne(item: *Item) void {
        const v = c.getenv(item.env.ptr) orelse return;
        const span = std.mem.span(@as([*:0]const u8, @ptrCast(v)));
        const parsed = std.fmt.parseInt(i64, span, 10) catch return;
        item.value = std.math.clamp(parsed, item.min, item.max);
        item.overridden = true;
    }

    /// Post-input wait budget when wait_change/settle_ms was passed
    /// explicitly: never below the historical 5s, raised further by
    /// an env override.
    pub fn explicitTimeout() i64 {
        return @max(timeout_ms.value, 5_000);
    }

    /// tools/list description fragment. An overridden value says so
    /// AND names the built-in — "someone tuned this deliberately"
    /// carries information the bare number does not.
    pub fn defText(buf: []u8, item: *const Item) []const u8 {
        if (!item.overridden)
            return std.fmt.bufPrint(buf, "default {d}", .{item.value}) catch "default ?";
        return std.fmt.bufPrint(buf, "default {d} — PROJECT OVERRIDE via {s}, built-in {d}", .{ item.value, item.env, item.built_in }) catch "default ?";
    }
};

/// Process-wide tool exposure policy — resolved once at startup from
/// (lowest to highest precedence) a `[mcp.<name>]` config section,
/// $SKETERM_MCP_TOOLS, and `--tools`. Held like Tuning: one place both
/// tools/list and tools/call read, so presentation and enforcement can
/// never disagree.
pub var policy: mcpfilter.Policy = .unrestricted;
/// Where `policy.spec` came from, for the capabilities report.
pub var policy_source: []const u8 = "none";

fn replaceAll(arena: std.mem.Allocator, haystack: []const u8, needle: []const u8, repl: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, haystack, needle) == null) return haystack;
    var aw: std.Io.Writer.Allocating = .init(arena);
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |i| {
        try aw.writer.writeAll(rest[0..i]);
        try aw.writer.writeAll(repl);
        rest = rest[i + needle.len ..];
    }
    try aw.writer.writeAll(rest);
    return aw.written();
}

/// The policy-filtered tool list with the %..._DEF% timing tokens
/// replaced by the EFFECTIVE defaults (env overrides included), so the
/// description the assistant reads always states the value the server
/// will use.
fn renderedToolsJson(arena: std.mem.Allocator) ![]const u8 {
    var buf: [128]u8 = undefined;
    // Filter FIRST: the policy decides which entries exist, substitution
    // then rewrites only the survivors.
    var out = try mcpfilter.filterToolsJson(arena, policy);
    out = try replaceAll(arena, out, "%HOLD_DEF%", Tuning.defText(&buf, &Tuning.hold_ms));
    out = try replaceAll(arena, out, "%SETTLE_DEF%", Tuning.defText(&buf, &Tuning.settle_ms));
    out = try replaceAll(arena, out, "%TIMEOUT_DEF%", Tuning.defText(&buf, &Tuning.timeout_ms));
    out = try replaceAll(arena, out, "%RETRY_DEF%", Tuning.defText(&buf, &Tuning.click_retry));
    return out;
}

pub fn argInt(args: std.json.Value, key: []const u8) ?i64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .integer => v.integer,
        else => null,
    };
}

pub fn argStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .string => v.string,
        else => null,
    };
}

/// One argument as its raw JSON value, for the few arguments whose type
/// is not a scalar (an array of urls).
pub fn argValue(args: std.json.Value, key: []const u8) ?std.json.Value {
    if (args != .object) return null;
    return args.object.get(key);
}

pub fn argBool(args: std.json.Value, key: []const u8) bool {
    if (args != .object) return false;
    const v = args.object.get(key) orelse return false;
    return switch (v) {
        .bool => v.bool,
        else => false,
    };
}

pub fn argFloat(args: std.json.Value, key: []const u8) ?f64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        else => null,
    };
}

pub fn reqLine(arena: std.mem.Allocator, req: protocol.Request) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(req, .{}, &aw.writer);
    return aw.written();
}

/// Issue one IPC request; returns the raw JSON response line.
pub fn ipc(arena: std.mem.Allocator, backend: Backend, req: protocol.Request) ![]u8 {
    const line = try reqLine(arena, req);
    return backend.talk(backend.ctx, arena, line);
}

pub const IpcDelivery = enum { ordinary, pre_delivery, uncertain_delivery };

pub const IpcReply = struct {
    ok: bool,
    /// Parsed response object (arena-owned).
    value: std.json.Value,
    /// Error message when !ok.
    err: []const u8,
    delivery: IpcDelivery = .ordinary,
    /// The failure's structured code, when the GUI (or this server,
    /// for a failure it produced itself) supplied one.
    code: ?protocol.ErrorCode = null,
};

/// A GUI refusal as one of the shared codes: its structured
/// `error_code` when it carries one, else its prose, which is all a GUI
/// older than the code vocabulary sends.
pub fn guiErrCode(reply: IpcReply) ErrCode {
    if (reply.code) |code| return switch (code) {
        .invalid_request, .event_epoch_required, .invalid_event_epoch, .invalid_request_token => .invalid_args,
        .not_found => .not_found,
        .unknown_command, .unsupported => .refused,
        .unavailable => .unavailable,
        .conflict, .event_epoch_mismatch, .request_token_conflict => .conflict,
        .failed => .failed,
    };
    return legacyGuiErrCode(reply.err);
}

/// The text classification for a GUI that predates `error_code`. Keep it
/// for as long as such GUIs may answer; never extend it for new errors.
fn legacyGuiErrCode(msg: []const u8) ErrCode {
    const has = struct {
        fn f(m: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, m, needle) != null;
        }
    }.f;
    if (has(msg, "no such") or has(msg, "no completed command zone") or has(msg, "not live") or has(msg, "no longer present"))
        return .not_found;
    if (has(msg, "unknown command") or has(msg, "unknown panel command")) return .refused;
    if (has(msg, "unavailable") or has(msg, "unreachable") or has(msg, "no compatible GUI")) return .unavailable;
    if (has(msg, "requires") or has(msg, "must be")) return .invalid_args;
    return .failed;
}

pub fn ipcParsed(arena: std.mem.Allocator, backend: Backend, req: protocol.Request) !IpcReply {
    const resp = try ipc(arena, backend, req);
    return parseIpcReply(arena, resp);
}

pub fn parseIpcReply(arena: std.mem.Allocator, resp: []const u8) IpcReply {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, resp, .{}) catch
        return .{ .ok = false, .value = .null, .err = "bad IPC response" };
    if (v != .object) return .{ .ok = false, .value = .null, .err = "bad IPC response" };
    const ok = if (v.object.get("ok")) |o| (o == .bool and o.bool) else false;
    const err: []const u8 = if (v.object.get("error")) |e|
        (if (e == .string) e.string else "unknown error")
    else
        "unknown error";
    var delivery: IpcDelivery = .ordinary;
    if (v.object.get("failure_class")) |failure_class| {
        if (failure_class == .string) {
            if (std.mem.eql(u8, failure_class.string, "pre_delivery")) delivery = .pre_delivery;
            if (std.mem.eql(u8, failure_class.string, "uncertain_delivery")) delivery = .uncertain_delivery;
        }
    }
    return .{ .ok = ok, .value = v, .err = err, .delivery = delivery, .code = if (ok) null else protocol.errorCodeOf(v) };
}

/// Server mode facts for the `capabilities` preflight tool.
pub var srv_mode: []const u8 = "isolated";
pub var srv_gui_socket: bool = false;

/// Whether a SERVER-WIDE direct GUI control socket is attached
/// (--shared / --socket): every GUI-backed tool uses it. The web tools
/// additionally consult `mcp_webgui` (their own, grant-scoped socket).
pub fn guiSocketAttached() bool {
    return srv_gui_socket;
}
pub const GuiSocketSource = enum { none, explicit, discovered };
pub var srv_gui_socket_source: GuiSocketSource = .none;
/// The resolved web_gui grant, granted or not, for `capabilities`.
pub var srv_web_gui: mcp_webgui.Grant = .{};

/// The web tools' GUI transport as `capabilities` reports it: the
/// server-wide socket when one is attached, else the grant's own.
pub fn webGuiTransport() mcp_webgui.Transport {
    if (srv_gui_socket) return switch (srv_gui_socket_source) {
        .explicit => .explicit,
        .discovered => .discovered,
        .none => .none,
    };
    return mcp_webgui.transport();
}
/// Independent from mcp_app.app_state: live panels follow their owning mux session,
/// while app tools keep using the MCP instance's private daemon.
pub var panel_pool: ?*paneldrive.Pool = null;

/// Last `n` lines of `text`, trailing blank lines dropped.
pub fn tailLines(text: []const u8, n: usize) []const u8 {
    var end = text.len;
    while (end > 0 and (text[end - 1] == '\n' or text[end - 1] == ' ')) end -= 1;
    var lines: usize = 0;
    var i = end;
    while (i > 0) {
        i -= 1;
        if (text[i] == '\n') {
            lines += 1;
            if (lines == n) return text[i + 1 .. end];
        }
    }
    return text[0..end];
}

pub fn appErr(arena: std.mem.Allocator, msg: []const u8) ![]const u8 {
    return errRes(arena, .failed, msg);
}

pub fn yesNo(v: bool) []const u8 {
    return if (v) "yes" else "no";
}

// ── file_* tools (fsdrive against the app daemon) ─────────────────

/// The bytes half of `paneScreenshot`: a caller that wants to build its
/// own two-lane result around the image needs the PNG, not a finished
/// content block.
pub fn paneScreenshotPng(
    arena: std.mem.Allocator,
    backend: Backend,
    pane: ?u32,
) !union(enum) { png: []const u8, err: []const u8 } {
    const path_z = std.fmt.allocPrint(arena, "/tmp/sketerm-shot-{d}-{d}.png\x00", .{ c.getpid(), backend.nowMs(backend.ctx) }) catch return error.OutOfMemory;
    const path = path_z[0 .. path_z.len - 1];
    const reply = try ipcParsed(arena, backend, .{ .cmd = "screenshot", .pane = pane, .data = path });
    if (!reply.ok) return .{ .err = reply.err };
    const f = c.fopen(path_z.ptr, "rb") orelse return .{ .err = "screenshot file vanished" };
    defer _ = c.fclose(f);
    _ = c.fseek(f, 0, c.SEEK_END);
    const len: usize = @intCast(@max(0, c.ftell(f)));
    _ = c.fseek(f, 0, c.SEEK_SET);
    const buf = arena.alloc(u8, len) catch return error.OutOfMemory;
    const rd = c.fread(buf.ptr, 1, len, f);
    _ = c.unlink(path_z.ptr);
    if (rd != len) return .{ .err = "short read of screenshot" };
    return .{ .png = buf };
}

pub fn objInt(v: ?std.json.Value, key: []const u8) i64 {
    const o = v orelse return 0;
    if (o != .object) return 0;
    const x = o.object.get(key) orelse return 0;
    return if (x == .integer) x.integer else 0;
}

pub fn objStr(v: std.json.Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const x = v.object.get(key) orelse return "";
    return if (x == .string) x.string else "";
}

pub fn objBool(v: std.json.Value, key: []const u8) bool {
    if (v != .object) return false;
    const x = v.object.get(key) orelse return false;
    return x == .bool and x.bool;
}

test "the no-JSON text rule is scoped to a result's own prose" {
    const t = std.testing;
    // Prose only: the whole lane is checked.
    try t.expectEqualStrings("window 1: 1x1", textProse("window 1: 1x1"));
    // A payload behind a divider is exempt — screen text, transcripts
    // and log lines legitimately carry braces.
    try t.expectEqualStrings("2 line(s)", textProse("2 line(s)\n--- log ---\n1 {\"a\":1}\n2 }{"));
    // So is a blank-line separated payload.
    try t.expectEqualStrings("header", textProse("header\n\n{\"raw\":true}"));
    // A result that is nothing but a payload has no prose to check.
    try t.expectEqualStrings("", textProse("--- steps ---\nstep 1: {ok}"));
}

test "initialize / tools list / unknown method" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeBackend{ .responses = &.{}, .allocator = std.testing.allocator };
    defer fake.deinit();
    const b = fake.backend();

    const init_resp = handleMessage(arena, b,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, init_resp, "\"protocolVersion\":\"2025-03-26\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_resp, "\"name\":\"sketerm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_resp, "\"id\":1") != null);

    // Notification: no response.
    try std.testing.expect(handleMessage(arena, b,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ) == null);

    const tools = handleMessage(arena, b,
        \\{"jsonrpc":"2.0","id":"t","method":"tools/list"}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"run_command\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"send_keys\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "\"id\":\"t\"") != null);

    const unknown = handleMessage(arena, b,
        \\{"jsonrpc":"2.0","id":2,"method":"bogus/method"}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, unknown, "-32601") != null);

    const junk = handleMessage(arena, b, "not json").?;
    try std.testing.expect(std.mem.indexOf(u8, junk, "-32700") != null);
}

test "the advertised tool list is well-formed JSON" {
    // The schemas in mcp_tools.TOOLS are hand-written JSON text; a
    // mis-nested brace in one of them breaks tools/list for EVERY tool,
    // and the failure is invisible until a client refuses to load the
    // server.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const saved_policy = policy;
    policy = .unrestricted;
    defer policy = saved_policy;
    const rendered = try renderedToolsJson(arena);
    // MCP stdio framing is one JSON object per line.
    try std.testing.expect(std.mem.indexOfScalar(u8, rendered, '\n') == null);
    // Every %..._DEF% placeholder must have been substituted.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "_DEF%") == null);
    // Panels do not require --shared any more; no ui_ description may ask
    // for it, and none may be left describing a GUI socket as mandatory.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--shared") == null);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, rendered, .{});
    try std.testing.expect(parsed == .array);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(std.testing.allocator);
    var ui_count: usize = 0;
    for (parsed.array.items) |t| {
        try std.testing.expect(t == .object);
        const nm = t.object.get("name") orelse return error.MissingName;
        try std.testing.expect(nm == .string);
        try std.testing.expect(t.object.get("description") != null);
        if (std.mem.startsWith(u8, nm.string, "ui_")) ui_count += 1;
        const schema = t.object.get("inputSchema") orelse return error.MissingSchema;
        try std.testing.expect(schema == .object);
        try std.testing.expect(schema.object.get("properties") != null);
        // A duplicate name silently shadows in every MCP client.
        try std.testing.expect(!seen.contains(nm.string));
        try seen.put(std.testing.allocator, nm.string, {});
    }
    try std.testing.expectEqual(@as(usize, 8), ui_count);
    try std.testing.expect(seen.contains("ui_show"));
    try std.testing.expect(seen.contains("ui_show_files"));
    try std.testing.expect(seen.contains("ui_save"));
    try std.testing.expect(seen.contains("app_wait_log"));
}

test "every tool declaration is well-formed at the table level" {
    // The old drift test (TOOLS_JSON vs TOOL_META) is structurally
    // impossible now that one table feeds both. What is still worth
    // asserting is what a hand-written entry can get wrong.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(std.testing.allocator);
    for (mcp_tools.TOOLS) |t| {
        if (seen.contains(t.name)) {
            std.debug.print("duplicate tool entry for '{s}'\n", .{t.name});
            return error.DuplicateTool;
        }
        try seen.put(std.testing.allocator, t.name, {});
        try std.testing.expect(t.description.len > 0);
        // A schema without a properties map advertises a tool no client
        // can call with arguments.
        try std.testing.expect(std.mem.indexOf(u8, t.input_schema, "\"properties\"") != null);
        // Wave 3 is SHIPPED: every tool declares a structured result,
        // and it is a JSON object with a properties map.
        const os = t.output_schema orelse {
            std.debug.print("'{s}' declares no output schema\n", .{t.name});
            return error.MissingOutputSchema;
        };
        try std.testing.expect(std.mem.indexOf(u8, os, "\"properties\"") != null);
        // The policy layer sees exactly the same tools.
        try std.testing.expect(mcpfilter.lookup(t.name) != null);
    }
    try std.testing.expectEqual(mcp_tools.TOOLS.len, mcpfilter.TOOL_META.len);
}

test "a policy filters tools/list and refuses tools/call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeBackend{ .responses = &.{"{\"ok\":true}"}, .allocator = std.testing.allocator };
    defer fake.deinit();

    const saved = policy;
    const saved_src = policy_source;
    policy = .{ .spec = "app:ro" };
    policy_source = "test";
    defer {
        policy = saved;
        policy_source = saved_src;
    }

    const listed = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"screenshot_app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"capabilities\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"app_click\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"run_command\"") == null);

    // Enforcement: a name learned elsewhere is still refused, and the
    // refusal names the term that would enable it.
    const refused = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run_command","arguments":{"command":"ls"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, refused, "\"isError\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, refused, "EXISTS but is not enabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, refused, "--tools panes") != null);
    // Nothing reached the backend.
    try std.testing.expectEqual(@as(usize, 0), fake.requests.items.len);
    // (capabilities' policy block needs the process-wide rec/app state
    // a real server sets up — smoke-mcp asserts it end to end.)
}

test "mcp Opts parses --tools and --profile" {
    const o = try Opts.parse(&.{ "--tools", "app, files:ro", "--profile", "readonly" });
    try std.testing.expectEqualStrings("app, files:ro", o.tools.?);
    try std.testing.expectEqualStrings("readonly", o.profile.?);
    try std.testing.expectError(error.MissingValue, Opts.parse(&.{"--tools"}));
    try std.testing.expectError(error.BadName, Opts.parse(&.{ "--profile", "no spaces" }));
}

test "mcp flag parsing: isolation modes" {
    const t = std.testing;
    // Default: isolated, ephemeral.
    const def = try Opts.parse(&.{});
    try t.expect(!def.shared and !def.durable and def.name == null);
    // --name implies durable.
    const named = try Opts.parse(&.{ "--name", "agent-1" });
    try t.expect(named.durable);
    try t.expectEqualStrings("agent-1", named.name.?);
    // --durable alone IS the instance named "default": a durable
    // instance is looked up by name, so an unnamed one would land in a
    // mcp-tmp-<pid> dir nothing can find again and the startup sweep
    // reaps. An explicit --name after --durable still wins.
    const dur = try Opts.parse(&.{"--durable"});
    try t.expect(dur.durable);
    try t.expectEqualStrings(DURABLE_DEFAULT_NAME, dur.name.?);
    const dur_named = try Opts.parse(&.{ "--durable", "--name", "agent-2" });
    try t.expectEqualStrings("agent-2", dur_named.name.?);
    const named_dur = try Opts.parse(&.{ "--name", "agent-3", "--durable" });
    try t.expectEqualStrings("agent-3", named_dur.name.?);
    // --shared excludes isolation flags.
    try t.expectError(error.SharedConflict, Opts.parse(&.{ "--shared", "--durable" }));
    try t.expectError(error.SharedConflict, Opts.parse(&.{ "--shared", "--name", "x" }));
    // --socket still parses in both modes.
    const sock = try Opts.parse(&.{ "--socket", "/tmp/x.sock", "--shared" });
    try t.expect(sock.shared);
    try t.expectEqualStrings("/tmp/x.sock", sock.socket.?);
    // --log works alongside every mode.
    const logged = try Opts.parse(&.{ "--log", "/tmp/trace", "--durable" });
    try t.expectEqualStrings("/tmp/trace", logged.log_dir.?);
    try t.expect(logged.durable);
    // --web-gui composes with every mode and defaults off.
    try t.expect(!def.web_gui);
    try t.expect((try Opts.parse(&.{ "--web-gui", "--name", "w" })).web_gui);
    try t.expect((try Opts.parse(&.{ "--shared", "--web-gui" })).web_gui);
    // --no-record composes with every mode.
    try t.expect(!(try Opts.parse(&.{"--shared"})).no_record);
    try t.expect((try Opts.parse(&.{ "--no-record", "--durable" })).no_record);
    try t.expectError(error.MissingValue, Opts.parse(&.{"--log"}));
    // Errors.
    try t.expectError(error.MissingValue, Opts.parse(&.{"--name"}));
    try t.expectError(error.BadName, Opts.parse(&.{ "--name", "a/b" }));
    try t.expectError(error.BadName, Opts.parse(&.{ "--name", "" }));
    try t.expectError(error.UnknownFlag, Opts.parse(&.{"--bogus"}));
}

test "mcp isolation dir: durable is named, ephemeral is pid-based" {
    const t = std.testing;
    const allocator = t.allocator;

    const saved = if (c.getenv("XDG_RUNTIME_DIR")) |v|
        try allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(v))))
    else
        null;
    defer if (saved) |s| allocator.free(s);
    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&root_buf, "/tmp/sk-mcp-iso-{d}", .{c.getpid()});
    _ = c.mkdir(root.ptr, 0o700);
    _ = c.setenv("XDG_RUNTIME_DIR", root.ptr, 1);
    defer {
        if (saved) |s| {
            var z: [4096]u8 = undefined;
            if (std.fmt.bufPrintZ(&z, "{s}", .{s})) |sz| {
                _ = c.setenv("XDG_RUNTIME_DIR", sz.ptr, 1);
            } else |_| {}
        } else _ = c.unsetenv("XDG_RUNTIME_DIR");
        var cmd: [256]u8 = undefined;
        if (std.fmt.bufPrintZ(&cmd, "rm -rf -- '{s}'", .{root})) |cz| _ = c.system(cz.ptr) else |_| {}
    }

    // `--durable` alone must land in a dir a later run can find again.
    const dur = try Opts.parse(&.{"--durable"});
    var iso = setupIsolation(allocator, dur.name, dur.durable).?;
    defer iso.deinit(allocator);
    try t.expect(iso.durable);
    try t.expect(std.mem.endsWith(u8, iso.dir, "/sketerm/mcp-default"));
    try t.expect(std.mem.endsWith(u8, iso.sock, "/sketerm/mcp-default/mux.sock"));
    // ... and must NOT be swept as an orphan the way mcp-tmp-<pid> is.
    try t.expect(std.mem.indexOf(u8, iso.dir, "mcp-tmp-") == null);

    // The default (ephemeral) instance keeps its pid-based dir.
    const def = try Opts.parse(&.{});
    var eph = setupIsolation(allocator, def.name, def.durable).?;
    defer eph.deinit(allocator);
    try t.expect(!eph.durable);
    var want: [64]u8 = undefined;
    try t.expect(std.mem.endsWith(u8, eph.dir, try std.fmt.bufPrint(&want, "/mcp-tmp-{d}", .{c.getpid()})));
}

test "mcp log: entries and screenshot files land in the dir" {
    const t = std.testing;
    var dbuf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dbuf, "/tmp/sketerm-mcplog-test-{d}", .{c.getpid()});

    var log = McpLog.open(t.allocator, dir) orelse return error.OpenFailed;
    // Per-session subfolder: <dir>/YYYYMMDD-HHMMSS.
    const session_dir = try t.allocator.dupe(u8, log.dir);
    defer t.allocator.free(session_dir);
    try t.expect(session_dir.len == dir.len + 1 + 15);
    try t.expect(std.mem.startsWith(u8, session_dir, dir));
    try t.expectEqual(@as(u8, '-'), session_dir[dir.len + 1 + 8]);
    for (session_dir[dir.len + 1 ..], 0..) |ch, i| {
        if (i == 8) continue; // the dash
        try t.expect(ch >= '0' and ch <= '9');
    }
    log.logNote("hello");
    log.logMessage("in", "{\"method\":\"ping\"}");
    // Oversized payload gets truncated, with the real length recorded.
    const big = try t.allocator.alloc(u8, McpLog.LINE_MAX + 100);
    defer t.allocator.free(big);
    @memset(big, 'x');
    log.logMessage("out", big);
    log.logImage("shot of app 1", "\x89PNG-fake-bytes", "");
    log.logImage("post-click shot", "\x89PNG-click-bytes", "click");
    log.close();

    var pbuf: [512]u8 = undefined;
    const jsonl_z = try std.fmt.bufPrintZ(&pbuf, "{s}/mcp-{d}.jsonl", .{ session_dir, c.getpid() });
    const f = c.fopen(jsonl_z.ptr, "r") orelse return error.NoLogFile;
    var content: [16384]u8 = undefined;
    const n = c.fread(&content, 1, content.len, f);
    _ = c.fclose(f);
    const text = content[0..n];

    try t.expect(std.mem.indexOf(u8, text, "\"event\":\"note\",\"note\":\"hello\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"event\":\"in\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"truncated\":true,\"full_len\":4196") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"event\":\"image\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"caption\":\"shot of app 1\"") != null);
    // Every entry parses as standalone JSON.
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |entry| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        _ = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), entry, .{});
    }

    // The PNG bytes were written out verbatim, into the session dir.
    const img_z = try std.fmt.bufPrintZ(&pbuf, "{s}/img-{d}-0001.png", .{ session_dir, c.getpid() });
    const imgf = c.fopen(img_z.ptr, "r") orelse return error.NoImageFile;
    var ibuf: [64]u8 = undefined;
    const in = c.fread(&ibuf, 1, ibuf.len, imgf);
    _ = c.fclose(imgf);
    try t.expectEqualStrings("\x89PNG-fake-bytes", ibuf[0..in]);

    // A tagged shot gets the "-click" filename suffix.
    var cbuf: [512]u8 = undefined;
    const click_z = try std.fmt.bufPrintZ(&cbuf, "{s}/img-{d}-0002-click.png", .{ session_dir, c.getpid() });
    const clickf = c.fopen(click_z.ptr, "r") orelse return error.NoClickImageFile;
    const cn = c.fread(&ibuf, 1, ibuf.len, clickf);
    _ = c.fclose(clickf);
    try t.expectEqualStrings("\x89PNG-click-bytes", ibuf[0..cn]);
    try t.expect(std.mem.indexOf(u8, text, "-click.png") != null);
    _ = c.unlink(click_z.ptr);

    _ = c.unlink(img_z.ptr);
    const jsonl_z2 = try std.fmt.bufPrintZ(&pbuf, "{s}/mcp-{d}.jsonl", .{ session_dir, c.getpid() });
    _ = c.unlink(jsonl_z2.ptr);
    const sub_z = try std.fmt.bufPrintZ(&pbuf, "{s}", .{session_dir});
    _ = c.rmdir(sub_z.ptr);
    const dir_z = try std.fmt.bufPrintZ(&pbuf, "{s}", .{dir});
    _ = c.rmdir(dir_z.ptr);
}

test "instance name validation" {
    const t = std.testing;
    try t.expect(validInstanceName("default"));
    try t.expect(validInstanceName("Agent_2-b"));
    try t.expect(!validInstanceName("has space"));
    try t.expect(!validInstanceName("dot.dot"));
    try t.expect(!validInstanceName("a" ** 49));
}

test "replaceAll substitutes every occurrence" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.expectEqualStrings("a1b1c", try replaceAll(arena, "aXbXc", "X", "1"));
    // No occurrence: the input slice comes back untouched.
    const same = "nothing here";
    try t.expect((try replaceAll(arena, same, "X", "1")).ptr == same.ptr);
    try t.expectEqualStrings("longer text", try replaceAll(arena, "S text", "S", "longer"));
}

test "tuning defText: built-in vs project override" {
    const t = std.testing;
    var buf: [128]u8 = undefined;
    var item: Tuning.Item = .{ .name = "hold_ms", .value = 100, .built_in = 100, .env = "SKETERM_MCP_HOLD_MS", .min = 0, .max = 10_000 };
    try t.expectEqualStrings("default 100", Tuning.defText(&buf, &item));
    item.value = 250;
    item.overridden = true;
    try t.expectEqualStrings("default 250 — PROJECT OVERRIDE via SKETERM_MCP_HOLD_MS, built-in 100", Tuning.defText(&buf, &item));
}

test "tuning load reads and clamps env overrides" {
    const t = std.testing;
    // Restore the global regardless of outcome — other tests read it.
    defer {
        Tuning.hold_ms.value = Tuning.hold_ms.built_in;
        Tuning.hold_ms.overridden = false;
        _ = c.unsetenv("SKETERM_MCP_HOLD_MS");
    }
    _ = c.setenv("SKETERM_MCP_HOLD_MS", "250", 1);
    Tuning.loadOne(&Tuning.hold_ms);
    try t.expectEqual(@as(i64, 250), Tuning.hold_ms.value);
    try t.expect(Tuning.hold_ms.overridden);
    // Out-of-range values clamp instead of poisoning the default.
    _ = c.setenv("SKETERM_MCP_HOLD_MS", "999999", 1);
    Tuning.loadOne(&Tuning.hold_ms);
    try t.expectEqual(@as(i64, 10_000), Tuning.hold_ms.value);
    // Garbage is ignored (value keeps the last good state).
    _ = c.setenv("SKETERM_MCP_HOLD_MS", "not-a-number", 1);
    Tuning.hold_ms.value = Tuning.hold_ms.built_in;
    Tuning.hold_ms.overridden = false;
    Tuning.loadOne(&Tuning.hold_ms);
    try t.expectEqual(@as(i64, 100), Tuning.hold_ms.value);
    try t.expect(!Tuning.hold_ms.overridden);
}

test "renderedToolsJson resolves every timing token" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try renderedToolsJson(arena);
    // No token survives rendering.
    try t.expect(std.mem.indexOf(u8, out, "_DEF%") == null);
    // Effective built-in defaults are stated in the descriptions.
    try t.expect(std.mem.indexOf(u8, out, "\"hold_ms\"") != null);
    try t.expect(std.mem.indexOf(u8, out, "(default 100; max 10000)") != null);
    try t.expect(std.mem.indexOf(u8, out, "(default 0; max 5)") != null);
    // The rendered list is still valid JSON.
    _ = try std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{});
}

test "tools/list states an override in the description" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    Tuning.timeout_ms.value = 15_000;
    Tuning.timeout_ms.overridden = true;
    defer {
        Tuning.timeout_ms.value = Tuning.timeout_ms.built_in;
        Tuning.timeout_ms.overridden = false;
    }
    var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
    defer fake.deinit();
    const tools = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":"t2","method":"tools/list"}
    ).?;
    try t.expect(std.mem.indexOf(u8, tools, "default 15000 — PROJECT OVERRIDE via SKETERM_MCP_TIMEOUT_MS, built-in 1500") != null);
    try t.expect(std.mem.indexOf(u8, tools, "_DEF%") == null);
}

test "Res: two lanes — field auto-text, fact/raw quiet, textf, finish shape" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var r = Res.init(arena);
    try r.textf("opened view {d}: {s}", .{ 12, "Example Domain" });
    try r.field("url", @as([]const u8, "https://example.com"));
    try r.field("settled", true);
    try r.fact("revision", @as(u32, 7));
    try r.raw("snapshot", "{\"k\":1}");
    const out = try r.finish();

    // Whole result parses as JSON.
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, out, .{});
    const obj = parsed.value.object;
    const content = obj.get("content").?.array;
    try t.expectEqual(@as(usize, 1), content.items.len);
    const text = content.items[0].object.get("text").?.string;
    // Text lane: bare, no JSON syntax, auto lines for field() only.
    try t.expectEqualStrings(
        "opened view 12: Example Domain\nurl: https://example.com\nsettled: true",
        text,
    );
    try t.expect(std.mem.indexOfScalar(u8, text, '{') == null);
    const sc = obj.get("structuredContent").?.object;
    try t.expectEqualStrings("https://example.com", sc.get("url").?.string);
    try t.expect(sc.get("settled").?.bool);
    try t.expectEqual(@as(i64, 7), sc.get("revision").?.integer);
    try t.expectEqual(@as(i64, 1), sc.get("snapshot").?.object.get("k").?.integer);
    try t.expect(obj.get("isError") == null);
    // NDJSON: multi-line text lane never leaks a raw newline.
    try t.expect(std.mem.indexOfScalar(u8, out, '\n') == null);
}

test "Res: empty text lane falls back to 'ok'; no fields omit structuredContent" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var r = Res.init(arena);
    try r.fact("count", @as(u32, 3));
    const out = try r.finish();
    try t.expect(std.mem.indexOf(u8, out, "\"text\":\"ok\"") != null);
    try t.expect(std.mem.indexOf(u8, out, "\"structuredContent\":{\"count\":3}") != null);

    var plain = Res.init(arena);
    try plain.text("terminal closed");
    const pout = try plain.finish();
    try t.expect(std.mem.indexOf(u8, pout, "structuredContent") == null);
    try t.expect(std.mem.indexOf(u8, pout, "\"text\":\"terminal closed\"") != null);
}

test "GUI refusals are typed by their error_code, and by prose only for older GUIs" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A current GUI states the code; the prose no longer decides it.
    const coded = parseIpcReply(arena, "{\"ok\":false,\"error\":\"something unforeseen\",\"error_code\":\"not_found\"}");
    try t.expectEqual(protocol.ErrorCode.not_found, coded.code.?);
    try t.expectEqual(ErrCode.not_found, guiErrCode(coded));
    const unsupported = parseIpcReply(arena, "{\"ok\":false,\"error\":\"pane has no daemon session\",\"error_code\":\"unsupported\"}");
    try t.expectEqual(ErrCode.refused, guiErrCode(unsupported));
    // Every code maps: the switch in guiErrCode is exhaustive, and a code
    // from a NEWER GUI parses as none and falls back to the prose.
    const future = parseIpcReply(arena, "{\"ok\":false,\"error\":\"no such pane\",\"error_code\":\"from_the_future\"}");
    try t.expect(future.code == null);
    try t.expectEqual(ErrCode.not_found, guiErrCode(future));
    // An older GUI: prose only.
    const legacy = parseIpcReply(arena, "{\"ok\":false,\"error\":\"unknown panel command\"}");
    try t.expect(legacy.code == null);
    try t.expectEqual(ErrCode.refused, guiErrCode(legacy));
    try t.expectEqual(ErrCode.failed, guiErrCode(parseIpcReply(arena, "{\"ok\":false,\"error\":\"attach failed: x\"}")));
    // A success carries no code even if a field of that name rides along.
    try t.expect(parseIpcReply(arena, "{\"ok\":true,\"error_code\":\"not_found\"}").code == null);
}

test "errRes: uniform shape, code tag, retryable fact" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const nf = try errRes(arena, .not_found, "no web view with id 4");
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, nf, .{});
    const obj = parsed.value.object;
    try t.expect(obj.get("isError").?.bool);
    try t.expectEqualStrings(
        "no web view with id 4",
        obj.get("content").?.array.items[0].object.get("text").?.string,
    );
    const e = obj.get("structuredContent").?.object.get("error").?.object;
    try t.expectEqualStrings("not_found", e.get("code").?.string);
    try t.expectEqualStrings("no web view with id 4", e.get("message").?.string);
    try t.expect(!e.get("retryable").?.bool);

    const to = try errRes(arena, .timeout, "did not settle");
    try t.expect(std.mem.indexOf(u8, to, "\"code\":\"timeout\"") != null);
    try t.expect(std.mem.indexOf(u8, to, "\"retryable\":true") != null);

    // appErr rides the same shape with the migration-default code.
    const ae = try appErr(arena, "boom");
    try t.expect(std.mem.indexOf(u8, ae, "\"code\":\"failed\"") != null);
    try t.expect(std.mem.indexOf(u8, ae, "\"isError\":true") != null);
}

/// Test helper: assert a migrated tool result speaks BOTH lanes and
/// that its structuredContent matches the tool's declared outputSchema
/// — every `required` key present, no key the schema does not declare.
/// The text lane must be non-empty and newline-escaped (NDJSON).
///
/// The no-JSON rule is scoped to the result's OWN prose — everything
/// before the first payload divider (a `--- name ---` line) or blank
/// line. A legitimate payload (screen text, a step transcript, OCR
/// output, an app's own log) may contain braces, and refusing those
/// would push real content out of the lane that exists to carry it.
/// The prose head of a text lane: everything before the first payload
/// divider (`--- name ---`) or blank line. THE scope of the no-JSON
/// rule — see expectToolResultShape.
pub fn textProse(text: []const u8) []const u8 {
    var end = text.len;
    if (std.mem.indexOf(u8, text, "\n--- ")) |at| end = @min(end, at);
    if (std.mem.indexOf(u8, text, "\n\n")) |at| end = @min(end, at);
    if (std.mem.startsWith(u8, text, "--- ")) return "";
    return text[0..end];
}

/// Test helper: the `result` object of a JSON-RPC reply, re-serialized
/// so `expectToolResultShape` can check it exactly as a client sees it.
pub fn rpcToolResult(arena: std.mem.Allocator, rpc: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, rpc, .{});
    const result = parsed.object.get("result") orelse return error.NoRpcResult;
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(result, .{}, &aw.writer);
    return aw.written();
}

pub fn expectToolResultShape(arena: std.mem.Allocator, tool: []const u8, result: []const u8) !std.json.Value {
    const t = std.testing;
    try t.expect(std.mem.indexOfScalar(u8, result, '\n') == null);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, result, .{});
    const obj = parsed.object;
    const content = obj.get("content") orelse return error.NoContentBlock;
    const text = content.array.items[0].object.get("text").?.string;
    try t.expect(text.len > 0);
    const prose = textProse(text);
    if (std.mem.indexOfScalar(u8, prose, '{') != null) {
        std.debug.print("{s}: JSON syntax in the text lane's prose: {s}\n", .{ tool, prose });
        return error.JsonInTextLane;
    }
    const sc = (obj.get("structuredContent") orelse return error.NoStructuredContent).object;

    // Validate the advertised contract, not the success-only table fragment.
    const advertised = for (mcp_tools.TOOLS, mcp_tools.TOOL_JSON) |def, json| {
        if (std.mem.eql(u8, def.name, tool)) break try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    } else return error.UnknownTool;
    const output_schema = advertised.object.get("outputSchema") orelse return error.NoOutputSchema;
    const branches = output_schema.object.get("oneOf").?.array.items;
    const is_error = if (obj.get("isError")) |flag| blk: {
        if (flag != .bool) return error.InvalidErrorFlag;
        break :blk flag.bool;
    } else false;
    if (is_error != (sc.get("error") != null)) return error.ErrorFlagMismatch;
    if (is_error) {
        const value = sc.get("error").?;
        if (value != .object) return error.InvalidErrorShape;
        const error_schema = branches[1].object.get("properties").?.object.get("error").?.object;
        const error_props = error_schema.get("properties").?.object;
        for (error_schema.get("required").?.array.items) |key| {
            const field = value.object.get(key.string) orelse return error.MissingRequiredField;
            const kind = error_props.get(key.string).?.object.get("type").?.string;
            if (!std.mem.eql(u8, kind, @tagName(field)) and
                !(std.mem.eql(u8, kind, "boolean") and field == .bool)) return error.InvalidErrorShape;
        }
        // Error evidence is intentionally open; success checks below stay strict.
        return parsed;
    }
    const schema = branches[0].object;
    if (schema.get("required")) |req| {
        for (req.array.items) |key| {
            if (sc.get(key.string) == null) {
                std.debug.print("{s}: structuredContent lacks required '{s}'\n", .{ tool, key.string });
                return error.MissingRequiredField;
            }
        }
    }
    const props = schema.get("properties").?.object;
    var it = sc.iterator();
    while (it.next()) |e| {
        if (props.get(e.key_ptr.*) == null) {
            std.debug.print("{s}: structuredContent key '{s}' is not in the output schema\n", .{ tool, e.key_ptr.* });
            return error.UndeclaredField;
        }
    }
    return parsed;
}

test "advertised tool results accept shared errors and evidence without weakening success" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 1. Every tool can fail before it has any success facts, not just web_open.
    for (std.enums.values(ErrCode)) |code| {
        const result = try errRes(arena, code, "operation could not start");
        for (mcp_tools.TOOLS) |def| {
            const parsed = try expectToolResultShape(arena, def.name, result);
            try t.expectEqual(@as(usize, 1), parsed.object.get("structuredContent").?.object.count());
        }
    }

    // 2. Startup diagnostics and certificate refusals retain their evidence.
    const diagnostic = try errResDetails(arena, .unavailable, "helper failed to start", @as(?struct {
        id: []const u8,
        stage: []const u8,
    }, .{ .id = "attempt-1", .stage = "hello" }));
    const failed = try expectToolResultShape(arena, "web_open", diagnostic);
    const details = failed.object.get("structuredContent").?.object.get("error").?.object.get("details").?.object;
    try t.expectEqualStrings("attempt-1", details.get("id").?.string);
    try t.expectEqualStrings("hello", details.get("stage").?.string);

    var cert = Res.init(arena);
    try cert.text("certificate refused");
    try cert.fact("error", .{ .code = "refused", .message = "certificate refused", .retryable = false });
    try cert.fact("cert", .{ .state = "refused", .fingerprint = "fingerprint" });
    const cert_result = try cert.finish();
    var cert_json = try std.json.parseFromSliceLeaky(std.json.Value, arena, cert_result, .{});
    try cert_json.object.put(arena, "isError", .{ .bool = true });
    const refused = try expectToolResultShape(arena, "web_open", try std.json.Stringify.valueAlloc(arena, cert_json, .{}));
    try t.expectEqualStrings("fingerprint", refused.object.get("structuredContent").?.object.get("cert").?.object.get("fingerprint").?.string);

    // 3. Missing and malformed error members cannot escape via a permissive
    // success schema (read_screen requires only `headless`).
    for ([_][]const u8{
        "{\"code\":\"failed\",\"message\":\"failure\"}",
        "{\"code\":\"failed\",\"retryable\":false}",
        "{\"message\":\"failure\",\"retryable\":false}",
    }) |error_json| {
        const result = try std.fmt.allocPrint(arena, "{{\"content\":[{{\"type\":\"text\",\"text\":\"failure\"}}],\"structuredContent\":{{\"error\":{s}}},\"isError\":true}}", .{error_json});
        try t.expectError(error.MissingRequiredField, expectToolResultShape(arena, "read_screen", result));
    }
    for ([_][]const u8{
        "null",
        "{\"code\":7,\"message\":\"failure\",\"retryable\":false}",
        "{\"code\":\"failed\",\"message\":false,\"retryable\":false}",
        "{\"code\":\"failed\",\"message\":\"failure\",\"retryable\":\"false\"}",
    }) |error_json| {
        const result = try std.fmt.allocPrint(arena, "{{\"content\":[{{\"type\":\"text\",\"text\":\"failure\"}}],\"structuredContent\":{{\"error\":{s}}},\"isError\":true}}", .{error_json});
        try t.expectError(error.InvalidErrorShape, expectToolResultShape(arena, "read_screen", result));
    }

    // 4. Success still needs its declared fields and refuses undeclared ones.
    const empty = "{\"content\":[{\"type\":\"text\",\"text\":\"opened\"}],\"structuredContent\":{}}";
    try t.expectError(error.MissingRequiredField, expectToolResultShape(arena, "web_open", empty));
    _ = try expectToolResultShape(arena, "read_screen", "{\"content\":[{\"type\":\"text\",\"text\":\"screen\"}],\"structuredContent\":{\"headless\":false}}");
    var success = Res.init(arena);
    try success.fact("headless", false);
    try success.fact("invented", true);
    try t.expectError(error.UndeclaredField, expectToolResultShape(arena, "read_screen", try success.finish()));

    var opened = Res.init(arena);
    try opened.fact("backend", "headless");
    try opened.fact("origin", "null");
    try opened.fact("url", "about:blank");
    try opened.fact("title", "");
    try opened.fact("loading", false);
    try opened.fact("settled", true);
    try opened.fact("open_views", @as(u32, 1));
    try opened.fact("route", "direct");
    const opened_json = try expectToolResultShape(arena, "web_open", try opened.finish());
    try t.expectEqualStrings("about:blank", opened_json.object.get("structuredContent").?.object.get("url").?.string);

    // 5. An error-shaped success or a success-shaped error is never accepted.
    _ = cert_json.object.swapRemove("isError");
    try t.expectError(error.ErrorFlagMismatch, expectToolResultShape(arena, "read_screen", try std.json.Stringify.valueAlloc(arena, cert_json, .{})));
    var empty_json = try std.json.parseFromSliceLeaky(std.json.Value, arena, empty, .{});
    try empty_json.object.put(arena, "isError", .{ .bool = true });
    try t.expectError(error.ErrorFlagMismatch, expectToolResultShape(arena, "read_screen", try std.json.Stringify.valueAlloc(arena, empty_json, .{})));
}

test "the server entry point is analyzed by the unit build" {
    // `run` is reached only from main.zig, which the test roots never
    // compile: without this reference a broken entry point surfaces in
    // the first full build instead of here.
    _ = &run;
}
