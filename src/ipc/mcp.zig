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
const appdrive = @import("appdrive.zig");
const termdrive = @import("termdrive.zig");
const fsdrive = @import("fsdrive.zig");
const muxclient = @import("../mux/client.zig");
pub const marks_mod = @import("../util/marks.zig");
const template = @import("../util/template.zig");
const ocr = @import("../util/ocr.zig");
pub const png_util = @import("../util/png.zig");
pub const mcpassets = @import("mcpassets.zig");
pub const mcpfilter = @import("mcpfilter.zig");
pub const mcp_tools = @import("mcp_tools.zig");
pub const panelstore = @import("panelstore.zig");
const paneldrive = @import("paneldrive.zig");
const panelrpc = @import("../mux/panelrpc.zig");
const mcp_registry = @import("mcp_registry.zig");
const paneldoc = @import("../ui/panel/doc.zig");
pub const shellquote = @import("../util/shellquote.zig");
pub const pattern = @import("../util/pattern.zig");
const wire = @import("../mux/wire.zig");

const MCP_HELP =
    \\Usage: sketerm mcp [--shared | --durable | --name NAME] [--socket PATH]
    \\                   [--log DIR] [--tools SPEC | --profile NAME]
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
};

const DirectTalkFailure = struct {
    err: anyerror,
    delivery: enum { pre_delivery, uncertain_delivery },
};

pub const DirectTalkResult = union(enum) {
    reply: []u8,
    failure: DirectTalkFailure,
};

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
const McpLog = struct {
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

    fn stamp(buf: *[40]u8) []const u8 {
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

var mcp_log: ?McpLog = null;

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
    var mu: c.pthread_mutex_t = undefined;

    fn initLock() void {
        _ = c.pthread_mutex_init(&mu, null);
    }
    /// Monotonic ms when the in-flight call started; 0 = idle.
    var started_ms: i64 = 0;
    /// Conn fds snapshotted at call start. An fd closed AND reused
    /// mid-call could be shut down wrongly, but a wedged main thread
    /// cannot close fds, and normal calls finish far under the cap.
    var fds: [128]c_int = undefined;
    var fd_count: usize = 0;
    /// A panel connection may be established after begin().
    var dynamic_fd: muxclient.FdCancel = .{};
    /// The persistent fs connection is lazy and may be replaced mid-call.
    var fs_fd: muxclient.FdCancel = .{};
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
        for (app_state.apps.values()) |a| addFd(a.conn.fd);
        for (term_state.terms.values()) |t| addFd(t.conn.fd);
        if (panel_pool) |pool| {
            var panel_fds: [32]c_int = undefined;
            const count = pool.fds(&panel_fds);
            for (panel_fds[0..count]) |fd| addFd(fd);
        }
        for (forward_state.forwards.values()) |f| addFd(f.term.conn.fd);
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

    fn addFd(fd: c_int) void {
        if (fd_count < fds.len) {
            fds[fd_count] = fd;
            fd_count += 1;
        }
    }

    fn end() void {
        _ = c.pthread_mutex_lock(&mu);
        defer _ = c.pthread_mutex_unlock(&mu);
        started_ms = 0;
    }

    fn cancelDynamicFds() void {
        dynamic_fd.stop();
        fs_fd.stop();
    }

    fn loop() void {
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

/// Resolve the tool exposure policy, lowest precedence first:
/// `[mcp.<name>]` from config.conf, then $SKETERM_MCP_TOOLS, then
/// `--tools`. Sets `policy`/`policy_source`; returns the owned strings
/// (null when nothing narrowed the tool set). Every failure prints a
/// complete diagnostic and returns an error — a bad spec must never
/// degrade into "everything" or into a silently missing group.
fn resolveToolPolicy(allocator: std.mem.Allocator, opts: Opts) error{BadPolicy}!?OwnedPolicy {
    var spec: []const u8 = "";
    var source: []const u8 = "none";
    var name_buf: [96]u8 = undefined;
    var cfg_spec: []u8 = &.{};
    defer allocator.free(cfg_spec);

    if (opts.profile) |name| {
        var cfg = @import("../config.zig").Config.load(allocator);
        defer cfg.deinit();
        const prof = cfg.mcpProfile(name) orelse {
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&msg_buf, "sketerm mcp: --profile {s}: no [mcp.{s}] section in config.conf\n  add one, e.g.:\n    [mcp.{s}]\n    tools = app, files:ro\n", .{ name, name, name }) catch "sketerm mcp: unknown --profile\n";
            _ = c.fputs(msg.ptr, platform.stderr());
            return error.BadPolicy;
        };
        // The record dies with the config arena below.
        cfg_spec = allocator.dupe(u8, prof.tools) catch return error.BadPolicy;
        spec = cfg_spec;
        source = std.fmt.bufPrint(&name_buf, "config [mcp.{s}]", .{name}) catch "config [mcp.*]";
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

    // Tool exposure policy, resolved BEFORE any daemon or socket work:
    // a typo must cost one clear line on stderr, never a silently
    // half-equipped server.
    const policy_owned = resolveToolPolicy(allocator, opts) catch return 2;
    defer if (policy_owned) |p| {
        allocator.free(p.spec);
        allocator.free(p.source);
        policy = .unrestricted;
        policy_source = "none";
    };

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
    var stub = StubBackend{};
    const backend = if (sock_path != null) Backend{
        .ctx = @ptrCast(&real),
        .talk = RealBackend.talk,
        .talkFor = RealBackend.talkFor,
        .sleepMs = RealBackend.sleepMs,
        .nowMs = RealBackend.nowMs,
    } else Backend{
        .ctx = @ptrCast(&stub),
        .talk = StubBackend.talk,
        .talkFor = StubBackend.talkFor,
        .sleepMs = RealBackend.sleepMs,
        .nowMs = RealBackend.nowMs,
    };
    var live_panel_pool = paneldrive.Pool.init(allocator);
    live_panel_pool.setWatchdogFd(&Watchdog.dynamic_fd);
    panel_pool = &live_panel_pool;
    defer {
        panel_pool = null;
        live_panel_pool.deinit();
    }
    app_state = .{
        .allocator = allocator,
        .mux_sock = if (iso) |i| i.sock else null,
        .keep_apps = if (iso) |i| i.durable else false,
    };
    defer app_state.deinit();
    defer Journal.deinitAll();
    defer LogDelta.deinitAll();
    defer MacroNudge.deinitAll();
    // Headless terminal tools run on the private daemon (isolated
    // mode only); --shared keeps the GUI-backed terminal tools.
    term_state = .{
        .allocator = allocator,
        .mux_sock = if (iso) |i| i.sock else null,
    };
    defer term_state.deinit();
    forward_state = .{ .allocator = allocator };
    defer forward_state.deinit();
    fs_state = .{ .allocator = allocator };
    defer fs_state.drop();
    rec_state = .{ .allocator = allocator, .enabled = !opts.no_record };
    defer rec_state.deinit();
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
        const note = std.fmt.bufPrint(&nbuf, "mcp server started: pid={d} mode={s} name={s} gui_socket={s}", .{
            c.getpid(),
            if (opts.shared) "shared" else "isolated",
            opts.name orelse "-",
            sock_path orelse "-",
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
    forward_state.deinit();
    term_state.deinit();
    app_state.deinit();
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

const RealBackend = struct {
    sock_path: [:0]const u8,

    fn talk(ctx: *anyopaque, allocator: std.mem.Allocator, line: []const u8) anyerror![]u8 {
        const self: *RealBackend = @ptrCast(@alignCast(ctx));
        const client = c.g_socket_client_new();
        defer c.g_object_unref(client);
        // A wedged GUI must cost a bounded error, never a hung tool
        // call (the timeout applies to connect and all stream IO).
        c.g_socket_client_set_timeout(client, 30);
        const addr = c.g_unix_socket_address_new(self.sock_path.ptr);
        defer c.g_object_unref(addr);
        var gerr: [*c]c.GError = null;
        const conn = c.g_socket_client_connect(client, @ptrCast(@alignCast(addr)), null, &gerr);
        if (conn == null) {
            if (gerr != null) c.g_error_free(gerr);
            return error.ConnectFailed;
        }
        defer c.g_object_unref(conn);

        const out_stream = c.g_io_stream_get_output_stream(@ptrCast(conn));
        var written: c.gsize = 0;
        var werr: [*c]c.GError = null;
        const with_nl = try std.fmt.allocPrint(allocator, "{s}\n", .{line});
        defer allocator.free(with_nl);
        if (c.g_output_stream_write_all(out_stream, with_nl.ptr, with_nl.len, &written, null, &werr) == 0) {
            if (werr != null) c.g_error_free(werr);
            return error.WriteFailed;
        }
        const din = c.g_data_input_stream_new(c.g_io_stream_get_input_stream(@ptrCast(conn)));
        defer c.g_object_unref(din);
        var rlen: c.gsize = 0;
        var rerr: [*c]c.GError = null;
        const resp = c.g_data_input_stream_read_line(din, &rlen, null, &rerr);
        if (resp == null) {
            if (rerr != null) c.g_error_free(rerr);
            return error.NoResponse;
        }
        defer c.g_free(resp);
        return allocator.dupe(u8, resp[0..rlen]);
    }

    fn pollUntil(fd: c_int, events: c_short, deadline_ms: i64) !void {
        while (true) {
            const remain = deadline_ms - clock.nowMs();
            if (remain <= 0) return error.Timeout;
            var pfd = c.struct_pollfd{ .fd = fd, .events = events, .revents = 0 };
            const rc = c.poll(&pfd, 1, @intCast(@min(remain, 100)));
            if (rc < 0 and std.posix.errno(rc) == .INTR) continue;
            if (rc > 0 and pfd.revents & events != 0) return;
            if (rc < 0 or pfd.revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0)
                return error.Disconnected;
        }
    }

    /// Millisecond-deadline direct GUI exchange used by ui_wait_event.
    fn talkFor(ctx: *anyopaque, allocator: std.mem.Allocator, line: []const u8, timeout_ms: i64) DirectTalkResult {
        const self: *RealBackend = @ptrCast(@alignCast(ctx));
        const deadline = clock.nowMs() + @max(timeout_ms, 0);
        if (deadline - clock.nowMs() <= 0) return directFailure(error.Timeout, false);
        const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return directFailure(error.SocketFailed, false);
        defer _ = c.close(fd);
        const flags = c.fcntl(fd, c.F_GETFL);
        if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) != 0)
            return directFailure(error.NonBlockingFailed, false);
        var addr: c.struct_sockaddr_un = undefined;
        @import("../mux/daemon.zig").fillSockaddrUn(&addr, self.sock_path) catch |err|
            return directFailure(err, false);
        if (deadline - clock.nowMs() <= 0) return directFailure(error.Timeout, false);
        const connected = c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un));
        if (connected != 0) {
            const e = std.posix.errno(connected);
            if (e != .INPROGRESS and e != .AGAIN and e != .ALREADY)
                return directFailure(error.ConnectFailed, false);
            pollUntil(fd, c.POLLOUT, deadline) catch |err| return directFailure(err, false);
        }
        var so_error: c_int = 0;
        var so_len: c.socklen_t = @sizeOf(c_int);
        if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &so_error, &so_len) != 0 or so_error != 0)
            return directFailure(error.ConnectFailed, false);

        const request = std.fmt.allocPrint(allocator, "{s}\n", .{line}) catch |err|
            return directFailure(err, false);
        defer allocator.free(request);
        var sent: usize = 0;
        while (sent < request.len) {
            if (deadline - clock.nowMs() <= 0) return directFailure(error.Timeout, sent > 0);
            const n = if (comptime @hasDecl(c, "MSG_NOSIGNAL"))
                c.send(fd, request.ptr + sent, request.len - sent, c.MSG_NOSIGNAL)
            else
                c.write(fd, request.ptr + sent, request.len - sent);
            if (n > 0) {
                sent += @intCast(n);
                continue;
            }
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
            if (e != .AGAIN) return directFailure(error.WriteFailed, sent > 0);
            pollUntil(fd, c.POLLOUT, deadline) catch |err| return directFailure(err, sent > 0);
        }

        var response: std.ArrayList(u8) = .empty;
        defer response.deinit(allocator);
        while (true) {
            if (std.mem.indexOfScalar(u8, response.items, '\n')) |end| {
                const owned = allocator.dupe(u8, response.items[0..end]) catch |err|
                    return directFailure(err, true);
                return .{ .reply = owned };
            }
            if (response.items.len >= (16 << 20)) return directFailure(error.ResponseTooLarge, true);
            var buf: [16 << 10]u8 = undefined;
            const n = c.read(fd, &buf, buf.len);
            if (n > 0) {
                response.appendSlice(allocator, buf[0..@intCast(n)]) catch |err|
                    return directFailure(err, true);
                continue;
            }
            if (n == 0) return directFailure(error.NoResponse, true);
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
            if (e != .AGAIN) return directFailure(error.NoResponse, true);
            pollUntil(fd, c.POLLIN, deadline) catch |err| return directFailure(err, true);
        }
    }

    fn directFailure(err: anyerror, started: bool) DirectTalkResult {
        return .{ .failure = .{
            .err = err,
            .delivery = if (started) .uncertain_delivery else .pre_delivery,
        } };
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
    var settle_ms: Item = .{ .name = "settle_ms", .value = 250, .built_in = 250, .env = "SKETERM_MCP_SETTLE_MS", .min = 0, .max = 30_000 };
    /// Post-input repaint wait when the wait is defaulted-on.
    var timeout_ms: Item = .{ .name = "timeout_ms", .value = 1_500, .built_in = 1_500, .env = "SKETERM_MCP_TIMEOUT_MS", .min = 100, .max = 30_000 };
    /// Extra app_click attempts when no qualifying repaint arrives.
    pub var click_retry: Item = .{ .name = "click_retry", .value = 0, .built_in = 0, .env = "SKETERM_MCP_CLICK_RETRY", .min = 0, .max = 5 };

    fn all() [4]*Item {
        return .{ &hold_ms, &settle_ms, &timeout_ms, &click_retry };
    }

    fn load() void {
        for (all()) |item| loadOne(item);
    }

    fn loadOne(item: *Item) void {
        const v = c.getenv(item.env.ptr) orelse return;
        const span = std.mem.span(@as([*:0]const u8, @ptrCast(v)));
        const parsed = std.fmt.parseInt(i64, span, 10) catch return;
        item.value = std.math.clamp(parsed, item.min, item.max);
        item.overridden = true;
    }

    /// Post-input wait budget when wait_change/settle_ms was passed
    /// explicitly: never below the historical 5s, raised further by
    /// an env override.
    fn explicitTimeout() i64 {
        return @max(timeout_ms.value, 5_000);
    }

    /// tools/list description fragment. An overridden value says so
    /// AND names the built-in — "someone tuned this deliberately"
    /// carries information the bare number does not.
    fn defText(buf: []u8, item: *const Item) []const u8 {
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
var policy_source: []const u8 = "none";

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

fn reqLine(arena: std.mem.Allocator, req: protocol.Request) ![]const u8 {
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
};

pub fn ipcParsed(arena: std.mem.Allocator, backend: Backend, req: protocol.Request) !IpcReply {
    const resp = try ipc(arena, backend, req);
    return parseIpcReply(arena, resp);
}

fn parseIpcReply(arena: std.mem.Allocator, resp: []const u8) IpcReply {
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
    return .{ .ok = ok, .value = v, .err = err, .delivery = delivery };
}

fn paneFromArgs(args: std.json.Value) ?u32 {
    const p = argInt(args, "pane") orelse return null;
    if (p < 0 or p > std.math.maxInt(u32)) return null;
    return @intCast(p);
}

/// Poll `screen-info` until `seq` stops changing for quiet_ms.
/// Returns true when settled, false on timeout.
fn waitIdle(arena: std.mem.Allocator, backend: Backend, pane: ?u32, timeout_ms: i64, quiet_ms: i64) !bool {
    const start = backend.nowMs(backend.ctx);
    var last_seq: ?i64 = null;
    var last_change = start;
    while (true) {
        const reply = try ipcParsed(arena, backend, .{ .cmd = "screen-info", .pane = pane });
        if (!reply.ok) return error.NoSuchPane;
        const screen = reply.value.object.get("screen") orelse return error.BadReply;
        const seq = (if (screen == .object) screen.object.get("seq") else null) orelse return error.BadReply;
        if (seq != .integer) return error.BadReply;

        const now = backend.nowMs(backend.ctx);
        if (last_seq == null or seq.integer != last_seq.?) {
            last_seq = seq.integer;
            last_change = now;
        } else if (now - last_change >= quiet_ms) {
            return true;
        }
        if (now - start >= timeout_ms) return false;
        backend.sleepMs(backend.ctx, 50);
    }
}

/// A pane's rendered grid plus the metadata the GUI reports about it.
const ScreenRead = struct {
    /// The `screen` object of the GUI's screen-info reply.
    info: std.json.Value,
    text: []const u8,
    scrollback: u32,
};

/// Read a pane's screen text and its grid metadata.
fn readScreen(arena: std.mem.Allocator, backend: Backend, pane: ?u32, scrollback: u32) !ScreenRead {
    const info = try ipcParsed(arena, backend, .{ .cmd = "screen-info", .pane = pane });
    if (!info.ok) return error.NoSuchPane;
    const text_reply = try ipcParsed(arena, backend, .{ .cmd = "get-text", .pane = pane, .scrollback = scrollback });
    if (!text_reply.ok) return error.NoSuchPane;
    const text = (if (text_reply.value.object.get("text")) |t|
        (if (t == .string) t.string else "")
    else
        "");
    return .{
        .info = info.value.object.get("screen") orelse .null,
        .text = text,
        .scrollback = scrollback,
    };
}

/// The screen-info vocabulary, written into a result ONCE: every pane
/// tool that reports on a grid emits this same set.
fn addScreenFacts(res: *Res, screen: ScreenRead) !void {
    const rows = objInt(screen.info, "rows");
    const cols = objInt(screen.info, "cols");
    try res.fact("rows", rows);
    try res.fact("cols", cols);
    try res.fact("cursor_row", objInt(screen.info, "cursor_row"));
    try res.fact("cursor_col", objInt(screen.info, "cursor_col"));
    try res.fact("alt_screen", objBool(screen.info, "alt_screen"));
    try res.fact("view_offset", objInt(screen.info, "view_offset"));
    try res.fact("app_cursor_keys", objBool(screen.info, "app_cursor_keys"));
    try res.fact("sync_output", objBool(screen.info, "sync_output"));
    try res.fact("title", objStr(screen.info, "title"));
    try res.fact("seq", objInt(screen.info, "seq"));
    if (screen.scrollback > 0) try res.fact("scrollback", screen.scrollback);
    const title = objStr(screen.info, "title");
    try res.textf("{d}x{d} grid, cursor at row {d} col {d}{s}{s}{s}", .{
        cols,
        rows,
        objInt(screen.info, "cursor_row"),
        objInt(screen.info, "cursor_col"),
        if (objBool(screen.info, "alt_screen")) ", alt screen" else "",
        if (title.len > 0) ", title " else "",
        title,
    });
}

// ── forwarded-app tools (headless GUI apps via the mux daemon) ────

/// Long-lived registry of launched app sessions (module state: MCP
/// serves one assistant on stdio; tool calls are sequential).
const AppState = struct {
    allocator: std.mem.Allocator,
    apps: std.AutoArrayHashMapUnmanaged(u32, *appdrive.App) = .empty,
    next_id: u32 = 1,
    ready: bool = true,
    /// Socket of the private (isolated) daemon local app launches
    /// target; null = the shared per-user daemon.
    mux_sock: ?[]const u8 = null,
    /// Durable instance: on exit, detach from app sessions instead of
    /// killing them (they outlive the MCP process for reconnect).
    keep_apps: bool = false,

    /// Idempotent: run() calls it explicitly before retiring an
    /// ephemeral daemon, and again via defer.
    fn deinit(self: *AppState) void {
        if (!self.ready) return;
        for (self.apps.values()) |app| {
            if (self.keep_apps) app.detach() else app.deinit();
        }
        self.apps.deinit(self.allocator);
        self.apps = .empty;
        self.ready = false;
    }
};

pub var app_state: AppState = .{ .allocator = undefined, .ready = false };

/// Registry of headless SHELL sessions (term_*) on the private daemon,
/// parallel to AppState. Only used in isolated mode; in --shared mode
/// the GUI-backed terminal tools are used instead.
const TermState = struct {
    allocator: std.mem.Allocator,
    terms: std.AutoArrayHashMapUnmanaged(u32, *termdrive.Term) = .empty,
    next_id: u32 = 1,
    /// Isolated daemon socket (null = feature off; term tools then
    /// error, directing the user to the GUI-backed terminal tools).
    mux_sock: ?[]const u8 = null,

    fn deinit(self: *TermState) void {
        for (self.terms.values()) |t| t.deinit();
        self.terms.deinit(self.allocator);
        self.terms = .empty;
    }
};

pub var term_state: TermState = .{ .allocator = undefined };

/// Lazy fsdrive connection for the file_* tools — same daemon as the
/// app tools (private in isolated mode, per-user with --shared). One
/// connection serves every call; a lost daemon drops it so the next
/// call reconnects.
const FsState = struct {
    allocator: std.mem.Allocator,
    fs: ?fsdrive.Fs = null,

    fn get(self: *FsState) ?*fsdrive.Fs {
        if (self.fs == null) {
            const conn = muxclient.Conn.connectLocalAutostartAt(self.allocator, app_state.mux_sock) catch return null;
            if (!self.adoptConn(conn)) return null;
        }
        return &self.fs.?;
    }

    fn adoptConn(self: *FsState, conn_in: muxclient.Conn) bool {
        var conn = conn_in;
        // The hello is already complete. Switch before any fs request or
        // potentially large fs_write so Conn's deadline polls can work.
        conn.setNonBlockingChecked() catch {
            conn.deinit();
            return false;
        };
        const armed = Watchdog.fs_fd.publish(conn.fd) catch false;
        if (!armed) {
            // Either the dup failed or the watchdog already fired: an
            // uncancellable connection must not become the live one.
            conn.deinit();
            return false;
        }
        self.fs = fsdrive.Fs.initConn(self.allocator, conn);
        return true;
    }

    fn drop(self: *FsState) void {
        Watchdog.fs_fd.release();
        if (self.fs) |*f| f.deinit();
        self.fs = null;
    }
};

var fs_state: FsState = .{ .allocator = undefined };

test "watchdog fs cancellation follows a replacement connection during one call" {
    const t = std.testing;
    Watchdog.fs_fd.release();
    Watchdog.fs_fd.arm();
    Watchdog.initLock();
    Watchdog.begin();
    defer Watchdog.end();

    var state = FsState{ .allocator = t.allocator };
    defer state.drop();
    var first: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &first));
    defer _ = c.close(first[1]);
    const first_fd = first[0];
    try t.expect(state.adoptConn(.{ .allocator = t.allocator, .fd = first[0] }));
    const flags = c.fcntl(state.fs.?.pollFd(), c.F_GETFL);
    try t.expect(flags >= 0 and flags & c.O_NONBLOCK != 0);
    try t.expect(Watchdog.fs_fd.fd.load(.acquire) >= 0);

    state.drop();
    try t.expectEqual(@as(c_int, -1), Watchdog.fs_fd.fd.load(.acquire));
    var replacement: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &replacement));
    defer _ = c.close(replacement[1]);
    try t.expectEqual(first_fd, replacement[0]);
    try t.expect(state.adoptConn(.{ .allocator = t.allocator, .fd = replacement[0] }));

    const Cancel = struct {
        fn run() void {
            _ = c.usleep(50_000);
            Watchdog.cancelDynamicFds();
        }
    };
    const canceler = try std.Thread.spawn(.{}, Cancel.run, .{});
    defer canceler.join();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const start = clock.nowMs();
    try t.expectError(
        fsdrive.Error.NotConnected,
        state.fs.?.statPath(arena_state.allocator(), "/tmp/watchdog-no-reply"),
    );
    try t.expect(clock.nowMs() - start < 500);
    try t.expectEqual(@as(c_int, -1), Watchdog.fs_fd.fd.load(.acquire));

    state.drop();
    try t.expect(!state.adoptConn(.{ .allocator = t.allocator, .fd = -1 }));
    try t.expectEqual(@as(c_int, -1), Watchdog.fs_fd.fd.load(.acquire));
}

/// Server mode facts for the `capabilities` preflight tool.
var srv_mode: []const u8 = "isolated";
var srv_gui_socket: bool = false;

/// Whether a direct GUI control socket is attached — the web tools'
/// backend selector (GUI views vs the owned headless helper).
pub fn guiSocketAttached() bool {
    return srv_gui_socket;
}
const GuiSocketSource = enum { none, explicit, discovered };
var srv_gui_socket_source: GuiSocketSource = .none;
/// Independent from app_state: live panels follow their owning mux session,
/// while app tools keep using the MCP instance's private daemon.
var panel_pool: ?*paneldrive.Pool = null;

/// Automatic asciicast recording of every headless terminal the MCP
/// server spawns (term_open, new_tab fallback, transfer/forward
/// helpers) — the terminal counterpart of the --log message trace.
/// Daemon-side recording via the rec_start wire frame, finalized with
/// each session; --no-record disables.
const RecState = struct {
    allocator: std.mem.Allocator,
    enabled: bool = true,
    /// Created lazily on the first spawn; null until then (and stays
    /// null when creation fails — recording then silently stays off,
    /// never blocking terminal work).
    dir: ?[]u8 = null,
    aux_counter: u32 = 0,
    /// term id → cast path, for term_list / term_open replies.
    casts: std.AutoArrayHashMapUnmanaged(u32, []u8) = .empty,

    fn deinit(self: *RecState) void {
        for (self.casts.values()) |p| self.allocator.free(p);
        self.casts.deinit(self.allocator);
        self.casts = .empty;
        if (self.dir) |d| self.allocator.free(d);
        self.dir = null;
    }
};

pub var rec_state: RecState = .{ .allocator = undefined };

/// The recordings directory, created on first use: the --log session
/// folder when logging is on (casts sit next to the message trace),
/// else $XDG_STATE_HOME/sketerm/mcp-casts/<stamp>-<pid>/.
fn recDir() ?[]const u8 {
    if (!rec_state.enabled) return null;
    if (rec_state.dir) |d| return d;
    const a = rec_state.allocator;
    if (mcp_log) |l| {
        rec_state.dir = a.dupe(u8, l.dir) catch return null;
        return rec_state.dir;
    }
    var base_buf: [4096]u8 = undefined;
    const state_base: []const u8 = if (c.getenv("XDG_STATE_HOME")) |sh|
        std.mem.span(@as([*:0]const u8, @ptrCast(sh)))
    else if (c.getenv("HOME")) |home|
        std.fmt.bufPrint(&base_buf, "{s}/.local/state", .{std.mem.span(@as([*:0]const u8, @ptrCast(home)))}) catch return null
    else
        return null;
    var stamp_buf: [40]u8 = undefined;
    const stamp = McpLog.stamp(&stamp_buf);
    const dir = std.fmt.allocPrint(a, "{s}/sketerm/mcp-casts/{s}-{d}", .{ state_base, stamp, c.getpid() }) catch return null;
    // mkdir -p, leaf included: this call replaced mcp_browser.mkdirs
    // when the CDP set was deleted — without it recording is silently
    // off on any fresh state dir.
    var probe: [4096]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&probe, "{s}", .{dir}) catch {
        a.free(dir);
        return null;
    };
    var i: usize = 1;
    while (i <= dir_z.len) : (i += 1) {
        if (i != dir_z.len and probe[i] != '/') continue;
        const save = probe[i];
        probe[i] = 0;
        _ = c.mkdir(&probe, 0o700);
        probe[i] = save;
    }
    if (c.access(dir_z.ptr, c.W_OK) != 0) {
        a.free(dir);
        return null;
    }
    rec_state.dir = dir;
    return rec_state.dir;
}

/// Start recording a REGISTERED terminal; returns the cast path (kept
/// in rec_state for term_list) or null when recording is off.
pub fn recordRegisteredTerm(t: *termdrive.Term, term_id: u32) ?[]const u8 {
    const dir = recDir() orelse return null;
    const a = rec_state.allocator;
    const path = std.fmt.allocPrint(a, "{s}/term-{d}.cast", .{ dir, term_id }) catch return null;
    t.startRecording(path);
    rec_state.casts.put(a, term_id, path) catch {
        a.free(path);
        return null;
    };
    return rec_state.casts.get(term_id);
}

/// Record an UNREGISTERED helper terminal (scp/ssh/forward).
pub fn recordAuxTerm(t: *termdrive.Term, label: []const u8) void {
    const dir = recDir() orelse return;
    const a = rec_state.allocator;
    rec_state.aux_counter += 1;
    const path = std.fmt.allocPrint(a, "{s}/aux-{d}-{s}.cast", .{ dir, rec_state.aux_counter, label }) catch return;
    defer a.free(path);
    t.startRecording(path);
}

/// One structured SSH port forward: an owned `ssh -N -L` headless
/// terminal plus its spec, so it can be health-checked and respawned.
pub const Forward = struct {
    id: u32,
    host: []u8,
    local_port: u16,
    remote_host: []u8,
    remote_port: u16,
    term: *termdrive.Term,
    reconnects: u32 = 0,
};

const ForwardState = struct {
    allocator: std.mem.Allocator,
    forwards: std.AutoArrayHashMapUnmanaged(u32, *Forward) = .empty,
    next_id: u32 = 1,

    pub fn removeOne(self: *ForwardState, f: *Forward) void {
        _ = self.forwards.swapRemove(f.id);
        f.term.deinit();
        self.allocator.free(f.host);
        self.allocator.free(f.remote_host);
        self.allocator.destroy(f);
    }

    fn deinit(self: *ForwardState) void {
        for (self.forwards.values()) |f| {
            f.term.deinit();
            self.allocator.free(f.host);
            self.allocator.free(f.remote_host);
            self.allocator.destroy(f);
        }
        self.forwards.deinit(self.allocator);
        self.forwards = .empty;
    }
};

pub var forward_state: ForwardState = .{ .allocator = undefined };

pub fn forwardFromArgs(args: std.json.Value) ?*Forward {
    if (argInt(args, "forward")) |id| {
        if (id < 0) return null;
        return forward_state.forwards.get(@intCast(id));
    }
    if (forward_state.forwards.count() == 1) return forward_state.forwards.values()[0];
    return null;
}

pub fn termFromArgs(args: std.json.Value) ?*termdrive.Term {
    if (argInt(args, "term")) |id| {
        if (id < 0) return null;
        return term_state.terms.get(@intCast(id));
    }
    if (term_state.terms.count() == 1) return term_state.terms.values()[0];
    return null;
}

pub fn termIdOf(t: *termdrive.Term) u32 {
    var it = term_state.terms.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == t) return e.key_ptr.*;
    }
    return 0;
}

pub fn commandCompletionResult(
    arena: std.mem.Allocator,
    result: termdrive.CommandCompletion,
    command_sent: bool,
    output: ?[]const u8,
    output_kind: ?[]const u8,
    reason: ?[]const u8,
) ![]const u8 {
    var r = Res.init(arena);
    try r.fact("state", @tagName(result.state));
    try r.fact("command_sent", command_sent);
    try r.fact("exit_status", result.exit_status);
    try r.fact("timed_out", result.timed_out);
    try r.fact("completion_source", @tagName(result.source));
    // A soft failure (running/unsupported/timed out) is a FACT here,
    // not a tool error: isError stays false and the text lane says so.
    if (result.exit_status) |status| {
        try r.textf("{s}: exit {d} ({s})", .{ @tagName(result.state), status, @tagName(result.source) });
    } else {
        try r.textf("{s}{s} ({s})", .{
            @tagName(result.state),
            if (result.timed_out) ", timed out" else "",
            @tagName(result.source),
        });
    }
    if (!command_sent) try r.text("the command was NOT sent");
    if (reason) |text| {
        try r.fact("reason", text);
        try r.text(text);
    }
    if (output_kind) |kind| try r.fact("output_kind", kind);
    if (output) |text| {
        try r.fact("output", text);
        try r.textf("--- {s} ---", .{output_kind orelse "output"});
        try r.text(text);
    }
    return r.finish();
}

/// Reconnect a durable instance to app sessions still running on its
/// private daemon, so `list_apps` etc. see them after an MCP restart.
/// Best-effort: no daemon (or none attachable) just means no apps.
fn reattachApps(sock: []const u8) void {
    const a = app_state.allocator;
    const refs = appdrive.listAppSessions(a, sock) catch return;
    defer {
        for (refs) |r| a.free(r.name);
        a.free(refs);
    }
    for (refs) |r| {
        const origin_id = r.originId();
        const app = appdrive.App.attachExisting(
            a,
            r.name,
            null,
            sock,
            if (origin_id.len > 0) origin_id else null,
        ) catch continue;
        app.pid = r.pid;
        const id = app_state.next_id;
        app_state.next_id += 1;
        app_state.apps.put(a, id, app) catch {
            app.detach();
            continue;
        };
        // Let the attach replay build the windows before the first
        // tool call reads them (bounded; frames are already in flight).
        _ = app.waitFirstWindow(1500);
    }
}

pub fn appFromArgs(args: std.json.Value) ?*appdrive.App {
    const id = argInt(args, "app") orelse {
        // Single-app convenience: omit `app` when only one exists.
        if (app_state.apps.count() == 1) return app_state.apps.values()[0];
        // Several sessions, but only one still running: an exited app
        // lingers in the table until close_app and must not make a
        // live drive ambiguous.
        var live: ?*appdrive.App = null;
        var live_n: usize = 0;
        for (app_state.apps.values()) |a| {
            if (a.exited) continue;
            live_n += 1;
            live = a;
        }
        return if (live_n == 1) live else null;
    };
    if (id < 0) return null;
    return app_state.apps.get(@intCast(id));
}

/// "app 7 (alive, 2 windows), app 8 (exited, status 0)" — the roster
/// an app-selection error needs to be actionable.
fn appRoster(arena: std.mem.Allocator) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    var it = app_state.apps.iterator();
    var first = true;
    while (it.next()) |e| {
        if (!first) w.writeAll(", ") catch return aw.written();
        first = false;
        const a = e.value_ptr.*;
        var painted: usize = 0;
        for (a.windows.items) |win| {
            if (win.frames > 0) painted += 1;
        }
        if (a.exited) {
            w.print("app {d} (exited, status {d})", .{ e.key_ptr.*, a.exit_status }) catch return aw.written();
        } else {
            w.print("app {d} (alive, {d} window(s))", .{ e.key_ptr.*, painted }) catch return aw.written();
        }
    }
    return aw.written();
}

pub const AppSelect = union(enum) { app: *appdrive.App, err: []const u8 };

/// Resolve the `app` argument, keeping apart the three failure modes
/// the old single "unknown app" message conflated: no sessions at all,
/// an id that does not exist, and an OMITTED id with several
/// candidates. The last one used to read exactly like a crashed app,
/// which is a costly thing to misdiagnose mid-drive.
pub fn appSelect(arena: std.mem.Allocator, args: std.json.Value) AppSelect {
    if (appFromArgs(args)) |a| return .{ .app = a };
    if (app_state.apps.count() == 0)
        return .{ .err = "no app sessions exist — start one with launch_app (this is NOT a crash: nothing was ever launched in this server)" };
    const roster = appRoster(arena);
    if (argInt(args, "app")) |id| {
        const msg = std.fmt.allocPrint(arena, "no app has id {d} (it was closed, or the id is from another MCP server). Known: {s}", .{ id, roster }) catch return .{ .err = "no app with that id" };
        return .{ .err = msg };
    }
    const msg = std.fmt.allocPrint(arena, "'app' was not specified and several sessions are alive — this is AMBIGUOUS, not a dead app. Pass app:<id>. Known: {s}", .{roster}) catch
        return .{ .err = "'app' is ambiguous — pass app:<id> (list them with list_apps)" };
    return .{ .err = msg };
}

pub fn appIdOf(app: *appdrive.App) u32 {
    var it = app_state.apps.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == app) return e.key_ptr.*;
    }
    return 0;
}

/// Human name for the common fatal signals (exit_status = -signo).
pub fn signalName(signo: i32) []const u8 {
    return switch (signo) {
        1 => "SIGHUP",
        2 => "SIGINT",
        4 => "SIGILL",
        6 => "SIGABRT",
        7 => "SIGBUS",
        8 => "SIGFPE",
        9 => "SIGKILL",
        11 => "SIGSEGV",
        13 => "SIGPIPE",
        15 => "SIGTERM",
        else => "signal",
    };
}

/// Signals whose death means "the app crashed" (as opposed to being
/// told to stop).
fn crashSignal(signo: i32) bool {
    return switch (signo) {
        4, 6, 7, 8, 11 => true, // ILL, ABRT, BUS, FPE, SEGV
        else => false,
    };
}

/// Human-readable death suffix for an exit status; "" for plain codes.
/// Shell-wrapped commands (string `command`) report a child's signal
/// death as exit 128+signo — decode that too, flagged as inferred.
pub fn exitSuffix(arena: std.mem.Allocator, status: i32) ![]const u8 {
    if (status < 0)
        return std.fmt.allocPrint(arena, " = killed by {s} (signal {d})", .{ signalName(-status), -status });
    if (status >= 129 and status <= 128 + 31)
        return std.fmt.allocPrint(arena, " (= 128+{d}: the wrapping shell reports the app was killed by {s})", .{ status - 128, signalName(status - 128) });
    return "";
}

fn signalNumber(name: []const u8) ?i32 {
    const names = [_]struct { name: []const u8, number: i32 }{
        .{ .name = "SIGHUP", .number = 1 },
        .{ .name = "SIGINT", .number = 2 },
        .{ .name = "SIGILL", .number = 4 },
        .{ .name = "SIGABRT", .number = 6 },
        .{ .name = "SIGBUS", .number = 7 },
        .{ .name = "SIGFPE", .number = 8 },
        .{ .name = "SIGKILL", .number = 9 },
        .{ .name = "SIGSEGV", .number = 11 },
        .{ .name = "SIGPIPE", .number = 13 },
        .{ .name = "SIGTERM", .number = 15 },
    };
    for (names) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.number;
    }
    return null;
}

/// Recover an inferior signal from gdb/valgrind output when the wrapper survives it.
fn debuggerSignal(log_json: []const u8) ?i32 {
    const prefixes = [_][]const u8{
        "Program received signal ",
        "Process terminating with default action of signal ",
    };
    for (prefixes) |prefix| {
        const at = std.mem.indexOf(u8, log_json, prefix) orelse continue;
        const rest = log_json[at + prefix.len ..];
        if (prefix[0] == 'P' and std.mem.startsWith(u8, prefix, "Process ")) {
            const open = std.mem.indexOfScalar(u8, rest, '(') orelse continue;
            const close_rel = std.mem.indexOfScalar(u8, rest[open + 1 ..], ')') orelse continue;
            const close = open + 1 + close_rel;
            if (signalNumber(rest[open + 1 .. close])) |sig| return sig;
            continue;
        }
        var end: usize = 0;
        while (end < rest.len and ((rest[end] >= 'A' and rest[end] <= 'Z') or (rest[end] >= '0' and rest[end] <= '9'))) end += 1;
        if (signalNumber(rest[0..end])) |sig| return sig;
    }
    return null;
}

const AppStopReason = enum { process_exit, client_disconnected, last_toplevel_destroyed };

pub const AppStop = struct {
    reason: AppStopReason,
    exit_status: ?i32 = null,
    signal: ?i32 = null,

    pub fn reasonName(self: AppStop) []const u8 {
        return switch (self.reason) {
            .process_exit => "process_exit",
            .client_disconnected => "client_disconnected",
            .last_toplevel_destroyed => "last_toplevel_destroyed",
        };
    }
};

/// Join process exit and GUI disappearance into one interaction-stop verdict.
pub fn probeAppStop(app: *appdrive.App, settle_ms: i64) ?AppStop {
    if (!app.exited and !app.presentationGone()) return null;
    if (!app.exited and settle_ms > 0) _ = app.settleExit(settle_ms);

    // A live debugger wrapper still has an indexed daemon-side log.
    // Fetch it now so the inferior's signal wins over the wrapper's
    // eventual status 0. Failure still leaves an honest disconnect.
    if (!app.exited and app.presentationGone() and debuggerSignal(app.log_buf.items) == null) {
        const fetched = app.logGet("{\"tail\":80,\"from_id\":0,\"id\":0,\"max_chars\":300}", 1_000) catch null;
        if (fetched) |f| app.allocator.free(f.json);
    }
    const inferred_signal = debuggerSignal(app.log_buf.items);
    if (app.exited) {
        const status_signal: ?i32 = if (app.exit_status < 0)
            -app.exit_status
        else if (app.exit_status >= 129 and app.exit_status <= 159)
            app.exit_status - 128
        else
            null;
        return .{
            .reason = .process_exit,
            .exit_status = app.exit_status,
            .signal = inferred_signal orelse status_signal,
        };
    }
    const reason: AppStopReason = switch (app.presentation_gone.?) {
        .client_disconnected => .client_disconnected,
        .last_toplevel_destroyed => .last_toplevel_destroyed,
    };
    return .{ .reason = reason, .signal = inferred_signal };
}

pub fn appStopText(arena: std.mem.Allocator, stop: AppStop, context: []const u8) ![]const u8 {
    if (stop.signal) |sig| {
        return std.fmt.allocPrint(arena, "app EXITED during {s} ({s}, signal {d}) - see app_log for the backtrace", .{ context, signalName(sig), sig });
    }
    if (stop.exit_status) |status| {
        return std.fmt.allocPrint(arena, "app exited during {s} (status {d})", .{ context, status });
    }
    return std.fmt.allocPrint(arena, "app EXITED/disconnected during {s} ({s}; exit status unavailable) - see app_log for details", .{ context, stop.reasonName() });
}

/// The daemon's log_get reply / pre-exit log stash, JSON shape.
pub const LogLineJ = struct {
    id: u64 = 0,
    t: i64 = 0,
    text: []const u8 = "",
    truncated: bool = false,
    cut: bool = false,
    marker: bool = false,
};
pub const LogReplyJ = struct {
    next_id: u64 = 0,
    dropped: u64 = 0,
    markers_dropped: u64 = 0,
    lines: []const LogLineJ = &.{},
};

/// Compile the `pattern` (alias `grep`) argument of a log tool.
/// `.none` = the caller passed neither, so nothing is filtered.
pub const LogFilter = union(enum) {
    none,
    m: pattern.Matcher,
    err: []const u8,
};

pub fn logFilterFrom(arena: std.mem.Allocator, args: std.json.Value) LogFilter {
    const pat = argStr(args, "pattern") orelse argStr(args, "grep") orelse return .none;
    const ci = if (args == .object and args.object.get("ignore_case") != null)
        argBool(args, "ignore_case")
    else
        true;
    const m = pattern.compile(arena, pat, ci) catch |err| return .{ .err = switch (err) {
        pattern.Error.BadPattern => std.fmt.allocPrint(
            arena,
            "cannot compile pattern \"{s}\". The syntax is a documented SUBSET of regex: literal text, . [a-z] [^x] classes, * + ? quantifiers, ^ $ anchors and top-level | alternation. There are no groups, so ( and ) are literal characters.",
            .{pat},
        ) catch "bad pattern",
        else => "out of memory compiling the pattern",
    } };
    return .{ .m = m };
}

/// Fetch a slice of the app's log ring and parse it. `from_id` 0 =
/// the last `tail` lines.
pub fn logFetchLines(
    arena: std.mem.Allocator,
    app: *appdrive.App,
    from_id: u64,
    tail: i64,
    max_chars: i64,
    timeout_ms: i64,
) !struct { reply: LogReplyJ, stale: bool } {
    const req = try std.fmt.allocPrint(
        arena,
        "{{\"tail\":{d},\"from_id\":{d},\"id\":0,\"max_chars\":{d}}}",
        .{ tail, from_id, max_chars },
    );
    const fetch = try app.logGet(req, timeout_ms);
    defer app_state.allocator.free(fetch.json);
    const parsed = std.json.parseFromSliceLeaky(LogReplyJ, arena, fetch.json, .{
        .ignore_unknown_fields = true,
    }) catch return error.Malformed;
    return .{ .reply = parsed, .stale = fetch.stale };
}

/// Per-app high-water mark of log ids already handed to an input
/// tool's `include_log_delta`. The crash-hunting loop is invariably
/// click → look → app_log → diff against last time; this collapses it
/// into the click call.
const LogDelta = struct {
    var seen: std.AutoArrayHashMapUnmanaged(u32, u64) = .empty;

    fn get(id: u32) ?u64 {
        return seen.get(id);
    }
    fn set(id: u32, v: u64) void {
        seen.put(app_state.allocator, id, v) catch {};
    }
    fn deinitAll() void {
        seen.deinit(app_state.allocator);
        seen = .empty;
    }
};

/// "\nlog +N line(s) since the previous input: …" for an input tool
/// called with include_log_delta:true; "" otherwise. The FIRST call
/// for an app only establishes the baseline (dumping the whole
/// pre-existing log into a click reply would bury the delta it exists
/// to show) — read history with app_log.
pub fn logDeltaNote(arena: std.mem.Allocator, app: *appdrive.App, args: std.json.Value) []const u8 {
    if (!argBool(args, "include_log_delta")) return "";
    const MAX_SHOWN = 40;
    const app_id = appIdOf(app);
    const prev = LogDelta.get(app_id);
    const from: u64 = if (prev) |p| p + 1 else 0;
    const got = logFetchLines(arena, app, from, 500, 300, 3_000) catch
        return "\nlog delta: unavailable (the daemon's log reply did not arrive in time — read it with app_log)";
    const r = got.reply;
    if (r.next_id > 0) LogDelta.set(app_id, r.next_id - 1);
    if (prev == null)
        return std.fmt.allocPrint(
            arena,
            "\nlog delta: baseline set at line {d} — the NEXT input with include_log_delta reports what the app printed in between (use app_log for the history before this point)",
            .{if (r.next_id > 0) r.next_id - 1 else 0},
        ) catch "";
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    var n: usize = 0;
    var shown: usize = 0;
    for (r.lines) |l| {
        if (l.id < from) continue;
        n += 1;
        if (shown >= MAX_SHOWN) continue;
        shown += 1;
        w.print("\n  {d} {s}{s}", .{ l.id, l.text, if (l.cut or l.truncated) " [+]" else "" }) catch break;
    }
    if (n == 0) return "\nlog delta: no new lines since the previous input";
    return std.fmt.allocPrint(arena, "\nlog delta: +{d} line(s) since the previous input{s}:{s}", .{
        n,
        if (n > shown) std.fmt.allocPrint(arena, " (newest {d} shown; read the rest with app_log)", .{shown}) catch "" else "",
        aw.written(),
    }) catch "";
}

/// Last `n` non-marker lines from the app's stashed log ring (the
/// daemon pushes the final log ahead of `.exit`), newline-joined.
/// Null when no stash exists or it holds no output lines — unlike the
/// grid mirror these lines are escape-free and never wrapped.
pub fn logStashTail(arena: std.mem.Allocator, app: *appdrive.App, n: usize) ?[]const u8 {
    if (app.log_buf.items.len == 0) return null;
    const parsed = std.json.parseFromSliceLeaky(LogReplyJ, arena, app.log_buf.items, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    if (parsed.lines.len == 0) return null;
    var kept: usize = 0;
    var start = parsed.lines.len;
    while (start > 0 and kept < n) {
        if (!parsed.lines[start - 1].marker) kept += 1;
        start -= 1;
    }
    var aw: std.Io.Writer.Allocating = .init(arena);
    var wrote = false;
    for (parsed.lines[start..]) |l| {
        if (l.marker) continue;
        if (wrote) aw.writer.writeAll("\n") catch return null;
        aw.writer.writeAll(l.text) catch return null;
        wrote = true;
    }
    if (!wrote) return null;
    return aw.written();
}

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

/// THE app-state vocabulary, in both lanes: `appFacts` writes the
/// machine facts into a `Res`, `appSummaryText` renders the same story
/// as prose. Every app tool that reports on its app calls
/// `addAppSummary` (both) — nothing spells an app fact by hand.
///
/// The two halves are deliberately one function pair: an exit reported
/// in structuredContent but missing from the text (or the reverse) is
/// the failure mode that made the old JSON-in-text summary safe.
pub fn appFacts(res: *Res, arena: std.mem.Allocator, app: *appdrive.App, with_windows: bool) !void {
    try res.fact("app", appIdOf(app));
    try res.fact("session", app.name);
    // The daemon-host pid: a debugger handle (`gdb -p`). For a string
    // command this is the wrapping /bin/sh, not the app itself.
    if (app.pid != 0 and !app.exited) try res.fact("pid", app.pid);
    const inferred_signal = debuggerSignal(app.log_buf.items);
    var crashed = false;
    try res.fact("exited", app.exited);
    if (app.exited) {
        try res.fact("exit_status", app.exit_status);
        // decodeStatus convention: negative = killed by that signal.
        if (app.exit_status < 0) {
            try res.fact("signaled", true);
            try res.fact("signal", -app.exit_status);
            try res.fact("signal_name", signalName(-app.exit_status));
            crashed = crashSignal(-app.exit_status);
        } else if (app.exit_status >= 129 and app.exit_status <= 128 + 31) {
            // A string `command` runs under /bin/sh, which reports a
            // child killed by signal N as exit 128+N.
            try res.fact("likely_signal", app.exit_status - 128);
            try res.fact("likely_signal_name", signalName(app.exit_status - 128));
            try res.fact("exit_status_note", try std.fmt.allocPrint(
                arena,
                "exit {d} = 128+{d}: shell-wrapped commands report signal deaths this way",
                .{ app.exit_status, app.exit_status - 128 },
            ));
            crashed = crashSignal(app.exit_status - 128);
        }
    } else if (app.presentation_gone) |reason| {
        try res.fact("app_gone", true);
        try res.fact("disconnect_reason", @tagName(reason));
    }
    if (inferred_signal) |sig| {
        try res.fact("debugger_caught_signal", true);
        try res.fact("inferior_signal", sig);
        try res.fact("inferior_signal_name", signalName(sig));
        if (crashSignal(sig)) crashed = true;
        // A debug wrapper survives the fault it catches and exits 0, so
        // the raw exit_status above describes GDB/valgrind, not the
        // app. Reading that as a clean exit is the whole trap.
        if (app.exited and app.exit_status >= 0) {
            try res.fact("exit_status_is_wrapper", true);
            try res.fact("exit_status_note", try std.fmt.allocPrint(
                arena,
                "exit_status {d} belongs to the DEBUG WRAPPER, which survived the fault; the app itself died on {s} (signal {d}) — inferior_signal is authoritative here",
                .{ app.exit_status, signalName(sig), sig },
            ));
        }
    }
    if (crashed) try res.fact("crashed", true);
    if (with_windows) {
        try res.raw("windows", try windowsJson(arena, app));
        const primary_id = firstToplevelId(app);
        if (primary_id != 0) try res.fact("primary_window", primary_id);
    }
    // An app that died is otherwise a dead end — inline what it
    // printed so one call shows WHY. The log-ring stash (pushed by
    // the daemon ahead of `.exit`) is preferred: escape-free FULL
    // lines, never wrapped at the grid width, includes scrolled-off
    // output. The rendered-grid tail is only the fallback.
    if (app.exited or app.presentationGone()) {
        if (recentOutput(arena, app)) |out| {
            try res.fact("recent_output", out.text);
            try res.fact("recent_output_source", out.source);
        }
        if (std.mem.indexOf(u8, app.log_buf.items, "Sanitizer") != null or
            std.mem.indexOf(u8, app.log_buf.items, "runtime error:") != null)
            try res.fact("sanitizer_report", true);
    }
}

/// The window array of `appFacts`, as verbatim JSON.
fn windowsJson(arena: std.mem.Allocator, app: *appdrive.App) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("[");
    var first = true;
    const primary_id = firstToplevelId(app);
    for (app.windows.items) |win| {
        if (win.frames == 0) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{{\"window\":{d},\"w\":{d},\"h\":{d},\"scale\":{d},\"frames\":{d}", .{ win.id, win.w, win.h, win.scale, win.frames });
        // The default target for window-less tool calls: the most
        // recently painted non-popup toplevel (see firstToplevelId).
        if (win.id == primary_id) try w.writeAll(",\"primary\":true");
        if (win.popup) try w.writeAll(",\"popup\":true");
        if (win.title) |t| {
            try w.writeAll(",\"title\":");
            try std.json.Stringify.value(t, .{}, w);
        }
        if (win.app_id) |aid| {
            try w.writeAll(",\"app_id\":");
            try std.json.Stringify.value(aid, .{}, w);
        }
        try w.writeAll("}");
    }
    try w.writeAll("]");
    return aw.written();
}

const RecentOutput = struct { text: []const u8, source: []const u8 };

/// What a dead app last printed: the indexed log stash if the daemon
/// pushed one, else the rendered grid tail.
fn recentOutput(arena: std.mem.Allocator, app: *appdrive.App) ?RecentOutput {
    if (logStashTail(arena, app, 15)) |tail_text|
        return .{ .text = tail_text, .source = "app_log" };
    const text = app.output(false) catch return null;
    defer app_state.allocator.free(text);
    const tail = tailLines(text, 25);
    if (tail.len == 0) return null;
    return .{ .text = arena.dupe(u8, tail) catch return null, .source = "terminal_grid" };
}

/// Prose half of `appFacts`: identity, exit/disconnect verdict, the
/// window list, and (for a dead app) what it last printed — the
/// payload behind a `--- recent output ---` divider.
pub fn appSummaryText(arena: std.mem.Allocator, app: *appdrive.App) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("app {d} ({s})", .{ appIdOf(app), app.name });
    if (app.pid != 0 and !app.exited) try w.print(" pid {d}", .{app.pid});
    if (app.exited) {
        try w.print(" EXITED, status {d}{s}", .{ app.exit_status, try exitSuffix(arena, app.exit_status) });
    } else if (app.presentation_gone) |reason| {
        try w.print(" GONE from the compositor ({s})", .{@tagName(reason)});
    }
    if (debuggerSignal(app.log_buf.items)) |sig| {
        try w.print("\nthe debug wrapper caught {s} (signal {d}) — backtrace in app_log", .{ signalName(sig), sig });
        if (app.exited and app.exit_status >= 0)
            try w.writeAll("; the exit status above belongs to the WRAPPER, not the app");
    }
    if (std.mem.indexOf(u8, app.log_buf.items, "Sanitizer") != null or
        std.mem.indexOf(u8, app.log_buf.items, "runtime error:") != null)
        try w.writeAll("\na sanitizer wrote a report to stderr — read it in full with app_log");
    const primary_id = firstToplevelId(app);
    var shown: usize = 0;
    for (app.windows.items) |win| {
        if (win.frames == 0) continue;
        shown += 1;
        try w.print("\nwindow {d}: {d}x{d} scale {d} frame {d}", .{ win.id, win.w, win.h, win.scale, win.frames });
        if (win.id == primary_id) try w.writeAll(" primary");
        if (win.popup) try w.writeAll(" popup");
        if (win.title) |t| try w.print(" title={s}", .{t});
    }
    if (shown == 0) try w.writeAll("\nno rendered window");
    if (app.exited or app.presentationGone()) {
        if (recentOutput(arena, app)) |out|
            try w.print("\n--- recent output ({s}) ---\n{s}", .{ out.source, out.text });
    }
    return aw.written();
}

/// Both lanes of the app state at once — the one call every app tool
/// makes to report on its app.
pub fn addAppSummary(res: *Res, arena: std.mem.Allocator, app: *appdrive.App) !void {
    try appFacts(res, arena, app, true);
    try res.text(try appSummaryText(arena, app));
}

pub fn appErr(arena: std.mem.Allocator, msg: []const u8) ![]const u8 {
    return errRes(arena, .failed, msg);
}

/// Screenshot caption: window identity + how to map image coordinates
/// back to app_click surface coordinates (crop origin + scale). One
/// line; anything else a caller wants to say is its own text line.
pub fn screenshotCaption(arena: std.mem.Allocator, app: *appdrive.App, win_id: u32, shot: appdrive.App.Shot) ![]const u8 {
    const win = app.winById(win_id) orelse return error.OutOfMemory;
    const coord_note = if (shot.scale == 1.0 and shot.ox == 0 and shot.oy == 0)
        try std.fmt.allocPrint(arena, "coordinates for app_click are this image's pixel coordinates", .{})
    else if (shot.ox == 0 and shot.oy == 0)
        try std.fmt.allocPrint(
            arena,
            "image is {d}x{d} for a {d}x{d} surface: MULTIPLY image coordinates by {d:.3} before app_click",
            .{ shot.img_w, shot.img_h, win.w, win.h, shot.scale },
        )
    else
        try std.fmt.allocPrint(
            arena,
            "cropped at ({d},{d}): MULTIPLY image coordinates by {d:.3} then ADD ({d},{d}) before app_click",
            .{ shot.ox, shot.oy, shot.scale, shot.ox, shot.oy },
        );
    return std.fmt.allocPrint(
        arena,
        "window {d}: {d}x{d} (scale {d}) frame {d}{s}{s} — {s}{s}",
        .{
            win.id,
            win.w,
            win.h,
            win.scale,
            // Freshness receipt: the window's commit counter for THESE
            // pixels. Assert against it with screenshot_app min_frame
            // instead of hoping a capture is not stale.
            shot.frame,
            if (win.title != null) " title=" else "",
            win.title orelse "",
            coord_note,
            // Set only when drainLive timed out: the frame stream is
            // still catching up, so pixels may lag the app.
            if (app.behind or app.lagging) " [WARNING: frame stream still catching up — this capture may lag the app; retry with wait_change or stable_ms]" else "",
        },
    );
}

// ── a11y tree helpers (element-targeted tools) ───────────────────

/// Fetch + parse the app's a11y tree into a Value (arena-owned), or
/// an error string to hand the assistant.
const A11yFetch = union(enum) {
    tree: std.json.Value,
    err: []const u8,
};

pub fn a11yFetch(arena: std.mem.Allocator, app: *appdrive.App, timeout_ms: i64) A11yFetch {
    const raw = app.a11yTree(timeout_ms) catch |err| return .{ .err = switch (err) {
        appdrive.Error.Timeout => "timed out reading the accessibility tree",
        else => "accessibility read failed",
    } };
    defer app_state.allocator.free(raw);
    const copy = arena.dupe(u8, raw) catch return .{ .err = "oom" };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, copy, .{}) catch
        return .{ .err = "malformed accessibility reply" };
    if (parsed != .object) return .{ .err = "malformed accessibility reply" };
    if (parsed.object.get("error")) |e| {
        if (e == .string) return .{ .err = e.string };
        return .{ .err = "accessibility error" };
    }
    const tree = parsed.object.get("tree") orelse return .{ .err = "no tree in reply" };
    return .{ .tree = tree };
}

/// Deepest nesting level below `node` (0 = no children).
fn a11yDepth(node: std.json.Value) u32 {
    if (node != .object) return 0;
    const kids = node.object.get("children") orelse return 0;
    if (kids != .array) return 0;
    var best: u32 = 0;
    for (kids.array.items) |k| best = @max(best, a11yDepth(k) + 1);
    return best;
}

/// True when the reply is the AT-SPI registry with only childless
/// application entries under it — nothing on the bus published a
/// single widget. A toolkit app always nests at least a window under
/// its application node, so this stays a conservative test: it never
/// calls a real (if shallow) tree "missing", it only recognises the
/// unmistakably empty case that otherwise reads as "you asked too
/// early".
pub fn a11yTreeIsBare(arena: std.mem.Allocator, reply_json: []const u8) bool {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, reply_json, .{}) catch return false;
    if (parsed != .object) return false;
    const tree = parsed.object.get("tree") orelse return false;
    return a11yDepth(tree) <= 1;
}

/// DFS for the first node matching `role` (when non-null) and/or a
/// case-insensitive `name` substring (when non-null).
pub fn a11yFindMatch(node: std.json.Value, role: ?i64, name_sub: ?[]const u8) ?std.json.Value {
    if (node != .object) return null;
    var ok = true;
    if (role) |r| {
        const nr = node.object.get("role") orelse std.json.Value{ .integer = -1 };
        if (nr != .integer or nr.integer != r) ok = false;
    }
    if (ok) {
        if (name_sub) |sub| {
            const nn = node.object.get("name") orelse std.json.Value{ .string = "" };
            if (nn != .string or std.ascii.indexOfIgnoreCase(nn.string, sub) == null) ok = false;
        } else if (role == null) ok = false; // no criteria = no match
    }
    if (ok) return node;
    if (node.object.get("children")) |kids| {
        if (kids == .array) for (kids.array.items) |k| {
            if (a11yFindMatch(k, role, name_sub)) |hit| return hit;
        };
    }
    return null;
}

/// One-line JSON of a node WITHOUT its children (summary for replies).
pub fn a11yNodeSummary(arena: std.mem.Allocator, node: std.json.Value) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{");
    var first = true;
    if (node == .object) {
        var it = node.object.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, "children")) continue;
            if (!first) try w.writeAll(",");
            first = false;
            try std.json.Stringify.value(e.key_ptr.*, .{}, w);
            try w.writeAll(":");
            try std.json.Stringify.value(e.value_ptr.*, .{}, w);
        }
    }
    try w.writeAll("}");
    return aw.written();
}

/// Tools that inject input into / query a RUNNING app — pointless
/// (or a dangling wait) once it exited.
pub fn needsLiveApp(name: []const u8) bool {
    const live = [_][]const u8{
        "app_click",          "app_drag",          "app_type",
        "app_key",            "app_scroll",        "app_resize",
        "app_mouse_move",     "app_clipboard_get", "app_clipboard_set",
        "app_perform_action", "app_set_value",     "app_wait_for_element",
        "app_a11y_tree",      "app_record_start",  "close_app_window",
        "app_read_text",      "app_wait_text",     "app_find_image",
        "app_wait_image",     "app_macro_run",     "app_hover_map",
        "app_backtrace",      "app_watch",
    };
    for (live) |l| {
        if (std.mem.eql(u8, name, l)) return true;
    }
    return false;
}

/// The PRIMARY content window (0 = none rendered yet): among painted
/// non-popup windows, the most recently committed one — a game keeps
/// painting its render surface while its outer frame window sits
/// static. Commits within 1s of each other tie; larger area wins the
/// tie, so a multi-window app at rest still yields its main window.
pub fn firstToplevelId(app: *appdrive.App) u32 {
    var best: ?*appdrive.Window = null;
    for (app.windows.items) |win| {
        if (win.popup or win.frames == 0) continue;
        const b = best orelse {
            best = win;
            continue;
        };
        const newer = win.last_commit_ms > b.last_commit_ms + 1000;
        const older = win.last_commit_ms + 1000 < b.last_commit_ms;
        const bigger = @as(i64, win.w) * win.h > @as(i64, b.w) * b.h;
        if (newer or (!older and bigger)) best = win;
    }
    return if (best) |b| b.id else 0;
}

/// A plain synthesized click honoring the project's hold default —
/// every click the server invents (template match, OCR match) goes
/// through this so an edge-polling app sees the same human-like
/// press-to-release span as an explicit app_click.
pub fn clickTuned(app: *appdrive.App, win_id: u32, x: f64, y: f64, button: u32) appdrive.Error!void {
    return app.clickEx(win_id, x, y, button, Tuning.hold_ms.value, 1);
}

/// Click-and-settle: captured BEFORE injecting input so the post-input
/// wait can tell "the app repainted in response" from "the frame on
/// screen predates the input" — the old idle-only wait returned
/// instantly-quiet on an app that takes a moment to react, so a
/// post-click screenshot was frequently the PRE-click frame.
/// A window silent for this long at the moment an input is injected was
/// not made silent BY that input. Well past any ordinary idle gap (an
/// unfocused static UI commits nothing), so it only fires when the app
/// really has stopped drawing.
pub const APP_QUIET_HANG_MS: i64 = 3_000;

pub const PostInputWait = struct {
    ref: ?appdrive.App.FrameRef,
    wait: bool,
    timeout_ms: i64,
    settle_ms: i64,
    min_pct: f64,
    t0: i64,
    /// Optional {x,y,w,h} rect: min_change_pct/settle percentages are
    /// gauged inside it only (assert "THIS viewport repainted").
    region: ?appdrive.App.Region = null,
    /// Set by finish(): a qualifying post-input frame arrived. Lets
    /// callers (app_click auto-retry) branch on the verdict without
    /// parsing the caption note.
    repainted: bool = false,
    /// Set by finish(): the process exited or its final GUI vanished.
    stop: ?AppStop = null,
    /// The target window's commit counter at the instant BEFORE the
    /// input was injected. Reported back with every input so a later
    /// screenshot_app {"min_frame": N} is PROVABLY post-input rather
    /// than hoped to be — the fix for captures silently lagging whole
    /// screens behind the drive.
    frame_at_input: u64 = 0,
    /// Monotonic ms of the window's last commit BEFORE the input, and
    /// the moment the input was injected. Together they answer a
    /// question the old single no-repaint message collapsed: was the
    /// window painting when the input arrived? If it had already gone
    /// quiet for seconds, the input did not kill it — the app was
    /// ALREADY not painting, and reading that as "the click missed"
    /// costs the entire diagnosis of a hang.
    last_commit_before: i64 = 0,
    injected_at: i64 = 0,

    /// `want_shot` = a post-input screenshot was requested; wait_change
    /// then defaults ON (pass wait_change:false to capture immediately).
    pub fn begin(args: std.json.Value, app: *appdrive.App, win_id: u32, want_shot: bool) PostInputWait {
        const min_pct: f64 = argFloat(args, "min_change_pct") orelse 0;
        // Default settle (Tuning.settle_ms): the FIRST post-input
        // frame is often a partial mid-repaint — capture only once
        // painting pauses. An explicit settle_ms:0 opts out.
        const settle_ms: i64 = std.math.clamp(argInt(args, "settle_ms") orelse Tuning.settle_ms.value, 0, 30_000);
        const settle_explicit = args == .object and args.object.get("settle_ms") != null;
        const explicit: ?bool = if (args == .object)
            (if (args.object.get("wait_change")) |v| (v == .bool and v.bool) else null)
        else
            null;
        const wait = explicit orelse (want_shot or settle_explicit);
        // Catch the mirror up FIRST: a frame already queued on the
        // socket predates the input and must not satisfy the wait.
        // drainLive (not the 100ms-boxed drain): the baseline must be
        // the LIVE frame, incl. a pending daemon-side resync.
        if (wait) _ = app.drainLive(CATCHUP_MS);
        // Defaulted-on waits stay short (a no-op click costs at most
        // Tuning.timeout_ms); an explicit wait_change/settle gets a
        // real budget.
        const timeout_ms: i64 = std.math.clamp(
            argInt(args, "timeout_ms") orelse @as(i64, if (explicit != null or settle_explicit) Tuning.explicitTimeout() else Tuning.timeout_ms.value),
            100,
            30_000,
        );
        return .{
            .ref = if (wait) app.frameRef(win_id, min_pct > 0) else null,
            .wait = wait,
            .timeout_ms = timeout_ms,
            .settle_ms = settle_ms,
            .min_pct = min_pct,
            .region = regionFrom(args),
            .t0 = clock.nowMs(),
            .frame_at_input = app.frameCount(win_id),
            .last_commit_before = app.lastCommitMs(win_id),
            .injected_at = clock.nowMs(),
        };
    }

    /// How long the window had ALREADY been silent when the input was
    /// injected (-1 = unknown: it has never painted, or no baseline was
    /// taken because no wait was requested).
    pub fn quietBeforeMs(self: *const PostInputWait) i64 {
        if (!self.wait or self.last_commit_before == 0) return -1;
        return self.injected_at - self.last_commit_before;
    }

    /// " [frame N at input, M now]" — the handle a caller passes back
    /// as screenshot_app {"min_frame": N} to demand pixels committed
    /// strictly after this input.
    pub fn frameNote(self: *const PostInputWait, arena: std.mem.Allocator, app: *appdrive.App, win_id: u32) []const u8 {
        const now = app.frameCount(win_id);
        if (now == 0 and self.frame_at_input == 0) return "";
        return std.fmt.allocPrint(
            arena,
            " [window {d} frame {d} at input, {d} now — pass min_frame:{d} to screenshot_app for a provably post-input capture]",
            .{ win_id, self.frame_at_input, now, self.frame_at_input },
        ) catch "";
    }

    /// Run AFTER the input. Returns a caption note ("" = nothing to
    /// report); a dry wait yields an explicit NO-repaint note so a
    /// dead click is structurally distinct from a late frame.
    pub fn finish(self: *PostInputWait, arena: std.mem.Allocator, app: *appdrive.App, win_id: u32) ![]const u8 {
        defer if (self.ref) |*r| r.deinit(app.allocator);
        if (!self.wait or self.ref == null) {
            _ = app.waitIdle(200, 2_000);
            if (probeAppStop(app, 1_000)) |stop| {
                self.stop = stop;
                const detail = try appStopText(arena, stop, "the post-input wait");
                return try std.fmt.allocPrint(arena, " - {s}", .{detail});
            }
            return "";
        }
        if (app.waitChangeSince(win_id, &self.ref.?, self.timeout_ms, self.min_pct, self.region)) {
            self.repainted = true;
            const elapsed = clock.nowMs() - self.t0;
            if (self.settle_ms > 0) {
                const remain = @max(self.timeout_ms - elapsed, 500);
                _ = if (self.min_pct > 0)
                    app.waitVisualSettle(win_id, self.settle_ms, remain, self.min_pct, self.region)
                else
                    app.waitWindowSettle(win_id, self.settle_ms, remain);
            } else {
                // Let a multi-frame transition finish before capture.
                _ = app.waitIdle(150, 1_000);
            }
            if (probeAppStop(app, 1_000)) |stop| {
                self.stop = stop;
                const detail = try appStopText(arena, stop, "the post-input settle");
                return try std.fmt.allocPrint(arena, " - {s}", .{detail});
            }
            return try std.fmt.allocPrint(arena, " — window repainted {d}ms after the input{s}{s}", .{
                elapsed,
                if (self.settle_ms > 0) " and settled" else "",
                if (self.region != null and self.min_pct > 0) " (change gauged inside the given region)" else "",
            });
        }
        // The wait primitives bail promptly on exit but return the same
        // false as a dead click — distinguish here, with the signal.
        // A vanished window usually means teardown raced ahead of the
        // .exit frame: give that frame a bounded moment to land.
        if (app.windowGone(win_id) and !app.presentationGone()) _ = app.settleExit(1_000);
        if (probeAppStop(app, 1_000)) |stop| {
            self.stop = stop;
            const detail = try appStopText(arena, stop, "the post-input wait");
            return try std.fmt.allocPrint(arena, " - {s}", .{detail});
        }
        const scoped: []const u8 = if (self.region != null and self.min_pct > 0) " in the given region" else "";
        // The daemon's commit counter already knew whether this window
        // was painting BEFORE the input, so say which failure this is
        // rather than leading with the input caveat. An app that had
        // gone silent seconds earlier was not killed by this click, and
        // the first evidence of a hang must not read as a dead click.
        const quiet = self.quietBeforeMs();
        if (quiet >= APP_QUIET_HANG_MS) {
            return try std.fmt.allocPrint(
                arena,
                " — APP LIVENESS WARNING, not an input problem: window {d} had ALREADY not painted for {d}ms when the input was injected, and it has not painted since. The input was delivered; the app is not drawing. Take a backtrace (app_backtrace) before assuming the coordinates were wrong",
                .{ win_id, quiet },
            );
        }
        if (quiet >= 0) {
            return try std.fmt.allocPrint(
                arena,
                " — NO repaint{s} within {d}ms after the input, although the window WAS painting {d}ms earlier: the input may have hit a dead area, or the app reacts without redrawing (any frame shown predates the input)",
                .{ scoped, self.timeout_ms, quiet },
            );
        }
        return try std.fmt.allocPrint(
            arena,
            " — NO repaint{s} within {d}ms after the input: it may have hit a dead area, or the app reacts without redrawing (any frame shown predates the input)",
            .{ scoped, self.timeout_ms },
        );
    }
};

/// Facts + one prose line for a captured window frame: what the image
/// shows and how to map its pixels back to app_click coordinates.
/// The caller owns the `window` fact (it already has one on every input
/// path, and a key written twice is a broken JSON object).
pub fn addShotFacts(
    res: *Res,
    arena: std.mem.Allocator,
    app: *appdrive.App,
    win_id: u32,
    shot: appdrive.App.Shot,
) !void {
    try res.fact("frame", shot.frame);
    try res.fact("image_w", shot.img_w);
    try res.fact("image_h", shot.img_h);
    try res.fact("image_scale", shot.scale);
    if (shot.ox != 0 or shot.oy != 0) {
        try res.fact("crop_x", shot.ox);
        try res.fact("crop_y", shot.oy);
    }
    try res.text(try screenshotCaption(arena, app, win_id, shot));
}

/// Shared tail for app_key/app_type/app_drag/app_scroll: finish the
/// post-input wait, then answer with a screenshot (when asked) or a
/// text result carrying the repaint note. `res` already holds the
/// tool's own facts; the common input facts are added here.
pub fn inputResult(
    arena: std.mem.Allocator,
    app: *appdrive.App,
    args: std.json.Value,
    win_id: u32,
    piw: *PostInputWait,
    desc: []const u8,
    res: *Res,
) ![]const u8 {
    const note = try piw.finish(arena, app, win_id);
    try res.fact("window", win_id);
    // Every input hands back the frame counter it acted at — the only
    // way a later capture can be asserted (not assumed) newer.
    try res.fact("frame_at_input", piw.frame_at_input);
    try res.fact("frame_now", app.frameCount(win_id));
    try res.fact("repainted", piw.repainted);
    try res.textf("{s}{s}", .{ desc, note });
    if (piw.stop != null) {
        // Skip the screenshot attempt (it would fail as "no pixels
        // yet?" and mask the crash) — report the exit with full detail.
        try addAppSummary(res, arena, app);
        return res.finish();
    }
    const frame_note = piw.frameNote(arena, app, win_id);
    if (frame_note.len > 0) try res.text(frame_note);
    const delta = logDeltaNote(arena, app, args);
    if (delta.len > 0) try res.text(delta);
    const nudge = macroNudge(arena, app);
    if (nudge.len > 0) try res.text(nudge);
    if (argBool(args, "screenshot") and win_id != 0) {
        const max_px: u32 = @intCast(std.math.clamp(argInt(args, "max_px") orelse 1568, 0, 8192));
        const shot = app.screenshotPng(win_id, max_px, null, 1) catch {
            try res.fact("screenshot_failed", true);
            try res.text("the post-input screenshot failed (no pixels yet?)");
            return res.finish();
        };
        defer app_state.allocator.free(shot.png);
        try addShotFacts(res, arena, app, win_id, shot);
        return res.finishWithImages(&.{shot.png}, null);
    }
    return res.finish();
}

/// Fixed-length array of numbers out of a JSON value ([x,y], …).
pub fn numArray(v: std.json.Value, comptime n: usize) ?[n]f64 {
    if (v != .array or v.array.items.len != n) return null;
    var out: [n]f64 = undefined;
    for (v.array.items, 0..) |item, i| {
        out[i] = switch (item) {
            .integer => |iv| @floatFromInt(iv),
            .float => |fv| fv,
            else => return null,
        };
    }
    return out;
}

/// One app_actions screenshot: draws (and consumes) the pending step
/// marks, stores the PNG, writes the report line. Returns false when
/// the capture failed (the caller decides whether that is fatal).
pub fn actionsCapture(
    arena: std.mem.Allocator,
    app: *appdrive.App,
    w: *std.Io.Writer,
    pngs: *std.ArrayList([]const u8),
    tags: *std.ArrayList([]const u8),
    pending: *std.ArrayList(marks_mod.Mark),
    wid: u32,
    max_px: u32,
    prefix: []const u8,
) !bool {
    const marks_n = pending.items.len;
    // Trace-filename tag: what the marks in this shot depict.
    var tag: []const u8 = "";
    for (pending.items) |m| {
        if (m.kind == .click) {
            tag = "click";
            break;
        }
        tag = "move";
    }
    const shot = app.screenshotPngMarked(wid, max_px, null, 1, pending.items) catch {
        return false;
    };
    pngs.append(arena, shot.png) catch {
        app_state.allocator.free(shot.png);
        return error.OutOfMemory;
    };
    tags.append(arena, tag) catch return error.OutOfMemory;
    pending.clearRetainingCapacity();
    if (shot.scale == 1.0) {
        try w.print("{s}: screenshot #{d} of window {d} ({d}x{d})", .{ prefix, pngs.items.len, wid, shot.img_w, shot.img_h });
    } else {
        try w.print("{s}: screenshot #{d} of window {d} — image {d}x{d}, MULTIPLY its coordinates by {d:.3} for clicks", .{ prefix, pngs.items.len, wid, shot.img_w, shot.img_h, shot.scale });
    }
    if (marks_n > 0) try w.print(" [{d} marker(s) drawn: red crosshair = click, cyan = move/hover, number = step]", .{marks_n});
    try w.writeAll("\n");
    return true;
}

pub fn reportActionStop(arena: std.mem.Allocator, w: *std.Io.Writer, step: usize, context: []const u8, stop: AppStop) !void {
    const detail = try appStopText(arena, stop, context);
    try w.print("step {d}: {s}; remaining steps skipped\n", .{ step, detail });
}

// ── input journal, macros, template matching, OCR ─────────────────

/// Per-app journal of successfully injected input steps (canonical
/// step JSON, the app_actions vocabulary). app_macro_save snapshots
/// its tail into a named replayable macro — "record what I just did".
pub const Journal = struct {
    const Entry = struct { step: []u8, t: i64 };
    const MAX_ENTRIES = 400;
    var map: std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(Entry)) = .empty;

    /// Best-effort: OOM just loses the entry.
    pub fn record(app_id: u32, step_json: []const u8) void {
        if (app_id == 0 or step_json.len == 0) return;
        const a = app_state.allocator;
        const gop = map.getOrPut(a, app_id) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const copy = a.dupe(u8, step_json) catch return;
        gop.value_ptr.append(a, .{ .step = copy, .t = clock.nowMs() }) catch {
            a.free(copy);
            return;
        };
        while (gop.value_ptr.items.len > MAX_ENTRIES) {
            const old = gop.value_ptr.orderedRemove(0);
            a.free(old.step);
        }
    }

    pub fn entriesOf(app_id: u32) []Entry {
        const list = map.getPtr(app_id) orelse return &.{};
        return list.items;
    }

    fn deinitAll() void {
        const a = app_state.allocator;
        for (map.values()) |*list| {
            for (list.items) |e| a.free(e.step);
            list.deinit(a);
        }
        map.deinit(a);
        map = .empty;
    }
};

/// One-shot pointer at app_macro_save, emitted once an app has
/// accumulated enough journalled input for replay to pay off. The
/// crash-hunting loop is fix → rebuild → RE-DRIVE THE IDENTICAL PATH
/// → compare, and hand-driving makes each repro only APPROXIMATELY
/// identical — which is exactly wrong when the question is "same
/// crash, same registers, before and after". The macro tools existed
/// but were only discoverable by reading the full tool list, so the
/// nudge lands at the moment the repetition becomes visible.
const MacroNudge = struct {
    const AT = 12;
    var done: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;

    fn deinitAll() void {
        done.deinit(app_state.allocator);
        done = .empty;
    }
};

pub fn macroNudge(arena: std.mem.Allocator, app: *appdrive.App) []const u8 {
    const id = appIdOf(app);
    if (id == 0 or MacroNudge.done.contains(id)) return "";
    const n = Journal.entriesOf(id).len;
    if (n < MacroNudge.AT) return "";
    MacroNudge.done.put(app_state.allocator, id, {}) catch return "";
    return std.fmt.allocPrint(
        arena,
        "\n[{d} input steps recorded for this app: app_macro_save {{\"app\":{d},\"name\":\"...\"}} snapshots them (last_steps:N for just the tail) and app_macro_run replays the identical path after a rebuild — worth it when you are about to drive the same route again]",
        .{ n, id },
    ) catch "";
}

/// Format-and-record one journal step for `app` (bounded; an
/// overlong step is dropped, not truncated into invalid JSON).
pub fn journalStep(app: *appdrive.App, comptime fmt: []const u8, fmt_args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, fmt_args) catch return;
    Journal.record(appIdOf(app), s);
}

/// Journal a step whose payload needs real JSON escaping (type text).
/// `extra_raw` is appended verbatim inside the object ("" = none),
/// e.g. ",\"hold_ms\":500".
pub fn journalStepJson(app: *appdrive.App, arena: std.mem.Allocator, key: []const u8, text: []const u8, extra_raw: []const u8) void {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.print("{{\"{s}\":", .{key}) catch return;
    std.json.Stringify.value(text, .{}, w) catch return;
    w.writeAll(extra_raw) catch return;
    w.writeAll("}") catch return;
    Journal.record(appIdOf(app), aw.written());
}

/// Optional {"region":{x,y,w,h}} sub-object of a tool/step arg.
pub fn regionFrom(v: std.json.Value) ?appdrive.App.Region {
    if (v != .object) return null;
    return regionOf(v.object.get("region") orelse return null);
}

/// Parse one region value. The documented shape is {x,y,w,h}; the
/// four-number array [x,y,w,h] is accepted too because it is the
/// shape callers reach for, and rejecting it bought nothing but a
/// parse error that pointed at the wrong thing.
pub fn regionOf(r: std.json.Value) ?appdrive.App.Region {
    var x: i64 = 0;
    var y: i64 = 0;
    var w: i64 = 0;
    var h: i64 = 0;
    switch (r) {
        .object => {
            x = argInt(r, "x") orelse 0;
            y = argInt(r, "y") orelse 0;
            w = argInt(r, "w") orelse return null;
            h = argInt(r, "h") orelse return null;
        },
        .array => {
            const q = numArray(r, 4) orelse return null;
            x = @intFromFloat(q[0]);
            y = @intFromFloat(q[1]);
            w = @intFromFloat(q[2]);
            h = @intFromFloat(q[3]);
        },
        else => return null,
    }
    if (x < 0 or y < 0 or w <= 0 or h <= 0) return null;
    return .{ .x = @intCast(x), .y = @intCast(y), .w = @intCast(w), .h = @intCast(h) };
}

const Needle = struct { px: []u8, w: u32, h: u32, name: []const u8 };

/// Resolve a template reference: "template" (a saved name) or
/// "image_b64" (inline PNG). Pixels land in the arena.
pub fn resolveNeedle(arena: std.mem.Allocator, v: std.json.Value) !union(enum) { needle: Needle, err: []const u8 } {
    if (argStr(v, "template")) |name| {
        const bytes = mcpassets.load(arena, .template, name) catch |err| return .{ .err = switch (err) {
            mcpassets.Error.NotFound => try std.fmt.allocPrint(arena, "no saved template \"{s}\" (save one with app_template_save; list with app_templates)", .{name}),
            mcpassets.Error.BadName => "invalid template name (letters, digits, . _ - only, max 64)",
            mcpassets.Error.OutOfMemory => return error.OutOfMemory,
            else => "template load failed",
        } };
        const dec = png_util.decodeRgba(arena, bytes) catch
            return .{ .err = "stored template is not a decodable image" };
        return .{ .needle = .{ .px = dec.rgba, .w = dec.w, .h = dec.h, .name = name } };
    }
    if (argStr(v, "image_b64")) |b64| {
        const decoder = std.base64.standard.Decoder;
        const max = decoder.calcSizeForSlice(b64) catch return .{ .err = "image_b64 is not valid base64" };
        const raw = try arena.alloc(u8, max);
        decoder.decode(raw, b64) catch return .{ .err = "image_b64 is not valid base64" };
        const dec = png_util.decodeRgba(arena, raw) catch
            return .{ .err = "image_b64 does not decode as an image" };
        return .{ .needle = .{ .px = dec.rgba, .w = dec.w, .h = dec.h, .name = "(inline)" } };
    }
    return .{ .err = "pass 'template' (a saved template name) or 'image_b64' (inline PNG)" };
}

/// One template hit in SURFACE coordinates (center included — the
/// click point).
pub const FoundMatch = struct { x: u32, y: u32, cx: u32, cy: u32, score: f64 };

/// Match `needle` against a window's current pixels. `.err` is a
/// human message (no pixels / bad template); an empty `.matches`
/// slice just means "not there right now".
pub fn findInWindow(
    arena: std.mem.Allocator,
    app: *appdrive.App,
    win_id: u32,
    region: ?appdrive.App.Region,
    needle: Needle,
    min_score: f64,
    max_matches: usize,
) !union(enum) { matches: []FoundMatch, err: []const u8 } {
    const shot = app.snapshotRgba(win_id, region) catch
        return .{ .err = "no rendered pixels in that window (yet?)" };
    defer app_state.allocator.free(shot.px);
    const ms = template.find(arena, shot.px, shot.w, shot.h, needle.px, needle.w, needle.h, .{
        .min_score = min_score,
        .max_matches = max_matches,
    }) catch |err| switch (err) {
        template.Error.BadTemplate => return .{ .err = "template is unusable (empty or fully transparent)" },
        template.Error.OutOfMemory => return error.OutOfMemory,
    };
    const out = try arena.alloc(FoundMatch, ms.len);
    for (ms, 0..) |m, i| {
        out[i] = .{
            .x = shot.ox + m.x,
            .y = shot.oy + m.y,
            .cx = shot.ox + m.x + needle.w / 2,
            .cy = shot.oy + m.y + needle.h / 2,
            .score = m.score,
        };
    }
    return .{ .matches = out };
}

pub const OcrOut = struct { text: []u8, words: []ocr.Word, scale: u32 };

/// OCR a window (optionally a region), word boxes mapped back to
/// SURFACE coordinates. scale_req 0 = auto (upscale small captures;
/// game bitmap fonts need it). Results live in the arena.
pub fn ocrWindow(
    arena: std.mem.Allocator,
    app: *appdrive.App,
    win_id: u32,
    region: ?appdrive.App.Region,
    scale_req: u32,
    psm: i32,
    lang: []const u8,
) !union(enum) { out: OcrOut, err: []const u8 } {
    const shot = app.snapshotRgba(win_id, region) catch
        return .{ .err = "no rendered pixels in that window (yet?)" };
    defer app_state.allocator.free(shot.px);
    // Upscaling is a REPAIR for tiny fonts, not a free improvement:
    // measured on an ordinary GTK dialog, nearest-neighbour 2x-3x made
    // Tesseract read NOTHING where the native-scale image read the label
    // correctly. The old auto rule (4096/longest edge, clamped to 3)
    // fired on every window under ~1365px — i.e. nearly all of them —
    // so the default silently hurt the common case to help the rare one.
    // Auto now means "native first, upscale only if that found nothing".
    // An explicit `scale` from the caller is still honoured verbatim.
    const auto = scale_req == 0;
    var scale: u32 = if (auto) 1 else @min(scale_req, 8);
    var px: []const u8 = shot.px;
    var w = shot.w;
    var h = shot.h;
    if (scale > 1) {
        px = png_util.upscaleRgba(arena, shot.px, w, h, scale) catch return error.OutOfMemory;
        w *= scale;
        h *= scale;
    }
    var res = ocr.recognize(arena, px, w, h, .{ .lang = lang, .psm = psm }) catch |err| return .{ .err = switch (err) {
        ocr.Error.Unavailable => "OCR unavailable: libtesseract was not found on this machine. Install tesseract plus a language pack (e.g. tesseract-data-eng) — sketerm loads it at runtime, no rebuild needed.",
        ocr.Error.InitFailed => "tesseract loaded but could not initialize the language — install its traineddata (e.g. tesseract-data-eng) or set TESSDATA_PREFIX",
        ocr.Error.OutOfMemory => return error.OutOfMemory,
        else => "text recognition failed",
    } };
    // Nothing legible at native scale: this is the tiny-font case the
    // upscale exists for, so pay for it now rather than by default.
    if (auto and res.words.len == 0) {
        const up = std.math.clamp(4096 / @max(1, @max(shot.w, shot.h)), 1, 3);
        if (up > 1) {
            if (png_util.upscaleRgba(arena, shot.px, shot.w, shot.h, up)) |big| {
                if (ocr.recognize(arena, big, shot.w * up, shot.h * up, .{ .lang = lang, .psm = psm })) |res2| {
                    if (res2.words.len > 0) {
                        res = res2;
                        scale = up;
                    }
                } else |_| {}
            } else |_| {}
        }
    }
    for (res.words) |*wd| {
        wd.x = shot.ox + wd.x / scale;
        wd.y = shot.oy + wd.y / scale;
        wd.w = @max(1, wd.w / scale);
        wd.h = @max(1, wd.h / scale);
    }
    return .{ .out = .{ .text = res.text, .words = res.words, .scale = scale } };
}

/// Bounding box of a run of consecutive OCR words matching the
/// space-separated query, case-insensitive (each query token must
/// appear in its word). Null = no run (the query may still occur in
/// the plain text with different word splits).
pub fn findWordRun(words: []const ocr.Word, query: []const u8) ?struct { x: u32, y: u32, w: u32, h: u32 } {
    var toks: [8][]const u8 = undefined;
    var ntok: usize = 0;
    var it = std.mem.tokenizeScalar(u8, query, ' ');
    while (it.next()) |t| {
        if (ntok == toks.len) break;
        toks[ntok] = t;
        ntok += 1;
    }
    if (ntok == 0) return null;
    if (words.len < ntok) return null;
    var i: usize = 0;
    outer: while (i + ntok <= words.len) : (i += 1) {
        for (toks[0..ntok], 0..) |tok, j| {
            if (std.ascii.indexOfIgnoreCase(words[i + j].text, tok) == null) continue :outer;
        }
        var x0 = words[i].x;
        var y0 = words[i].y;
        var x1 = words[i].x + words[i].w;
        var y1 = words[i].y + words[i].h;
        for (words[i .. i + ntok]) |wd| {
            x0 = @min(x0, wd.x);
            y0 = @min(y0, wd.y);
            x1 = @max(x1, wd.x + wd.w);
            y1 = @max(y1, wd.y + wd.h);
        }
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
    return null;
}

const LaunchArgv = union(enum) {
    ok: struct {
        /// True when the caller supplied explicit argv pieces (array
        /// command, or string command + args) — safe to rewrite
        /// (ozone-flag injection); a bare shell string is not.
        argv_form: bool,
    },
    err: []const u8,
};

/// Build launch_app's argv into `argv` from `command` (string or argv
/// array) plus the optional `args` array. A string command normally
/// runs via `/bin/sh -c`; WITH extra args it becomes the bare
/// EXECUTABLE instead (argv[0], not shell-parsed) — callers pairing a
/// string with args mean "binary plus its arguments", and the old
/// schema silently dropped `args`, launching apps with argc==1.
pub fn buildLaunchArgv(arena: std.mem.Allocator, argv: *std.ArrayList([]const u8), args: std.json.Value) !LaunchArgv {
    var extra: std.ArrayList([]const u8) = .empty;
    defer extra.deinit(arena);
    var cmd_is_array = false;
    if (args == .object) {
        if (args.object.get("args")) |ea| {
            if (ea != .array) return .{ .err = "'args' must be an array of strings" };
            for (ea.array.items) |item| {
                if (item != .string) return .{ .err = "'args' must be an array of strings" };
                try extra.append(arena, item.string);
            }
        }
        if (args.object.get("command")) |cmd| switch (cmd) {
            .string => if (extra.items.len > 0) {
                try argv.append(arena, cmd.string);
            } else {
                try argv.append(arena, "/bin/sh");
                try argv.append(arena, "-c");
                try argv.append(arena, cmd.string);
            },
            .array => {
                cmd_is_array = true;
                for (cmd.array.items) |item| {
                    if (item != .string) return .{ .err = "command array must be strings" };
                    try argv.append(arena, item.string);
                }
            },
            else => {},
        };
    }
    if (argv.items.len == 0) return .{ .err = "launch_app requires 'command' (string or argv array)" };
    try argv.appendSlice(arena, extra.items);
    return .{ .ok = .{ .argv_form = cmd_is_array or extra.items.len > 0 } };
}

const DebugWrap = union(enum) { note: []const u8, err: []const u8 };

/// Prepend launch_app's debug:"gdb"/"valgrind" wrapper onto argv; the
/// wrapper's report goes to the PTY = app_log (works for string
/// commands too: the wrapper follows /bin/sh's exec). `gdb_commands`
/// entries become extra -ex commands run AT THE CRASH POINT, after the
/// automatic bt full + info registers.
pub fn applyDebugWrap(arena: std.mem.Allocator, argv: *std.ArrayList([]const u8), args: std.json.Value) !DebugWrap {
    const eql = std.mem.eql;
    const dm = argStr(args, "debug") orelse {
        if (args == .object and args.object.get("gdb_commands") != null)
            return .{ .err = "'gdb_commands' requires debug:\"gdb\"" };
        return .{ .note = "" };
    };
    var wrapped: std.ArrayList([]const u8) = .empty;
    defer wrapped.deinit(arena);
    var note: []const u8 = undefined;
    if (eql(u8, dm, "gdb")) {
        try wrapped.appendSlice(arena, &.{
            "gdb",                                "-q",                                 "-batch",
            // Batch mode runs these in order and quits after the last
            // one. That makes NUISANCE SIGNALS fatal to the whole
            // exercise: a threaded app that takes a SIGPIPE or one of
            // glibc's real-time thread signals stops gdb there, the
            // reporting commands run against that harmless stop, and
            // gdb exits long before the crash under investigation.
            // Passing them through is what makes a backtrace show up
            // reliably rather than roughly one run in five.
            "-ex",                                "handle SIGPIPE nostop noprint pass", "-ex",
            "handle SIG32 nostop noprint pass",   "-ex",                                "handle SIG33 nostop noprint pass",
            "-ex",                                "handle SIG34 nostop noprint pass",   "-ex",
            "handle SIGCHLD nostop noprint pass", "-ex",                                "set pagination off",
            "-ex",                                "set confirm off",                    "-ex",
            "set print thread-events off",        "-ex",                                "run",
            // The faulting thread is often NOT the one gdb selects, and
            // a worker-thread crash is exactly the case a single
            // `bt full` reports uselessly.
            "-ex",                                "thread apply all bt full",           "-ex",
            "info threads",                       "-ex",                                "info registers",
        });
        var n_extra: usize = 0;
        if (args == .object) if (args.object.get("gdb_commands")) |gc| {
            if (gc != .array) return .{ .err = "'gdb_commands' must be an array of strings" };
            if (gc.array.items.len > 64) return .{ .err = "'gdb_commands': at most 64 commands" };
            for (gc.array.items) |item| {
                if (item != .string or item.string.len == 0 or item.string.len > 1000)
                    return .{ .err = "'gdb_commands' entries must be non-empty strings (max 1000 chars)" };
                try wrapped.appendSlice(arena, &.{ "-ex", item.string });
                n_extra += 1;
            }
        };
        try wrapped.append(arena, "--args");
        note = if (n_extra > 0)
            try std.fmt.allocPrint(arena, "\ndebug wrapper: gdb — the reported pid is gdb, not the app; on a crash ALL threads' backtraces, registers, and your {d} extra gdb command(s) land in app_log. NOTE: exit_status will be GDB's (usually 0) even for a crash — the app's real fate is reported as inferior_signal / crashed, read from the backtrace.", .{n_extra})
        else
            "\ndebug wrapper: gdb — the reported pid is gdb, not the app; on a crash ALL threads' backtraces land in app_log. NOTE: exit_status will be GDB's (usually 0) even for a crash — the app's real fate is reported as inferior_signal / crashed, read from the backtrace.";
    } else if (eql(u8, dm, "valgrind")) {
        if (args == .object and args.object.get("gdb_commands") != null)
            return .{ .err = "'gdb_commands' only applies to debug:\"gdb\"" };
        try wrapped.appendSlice(arena, &.{ "valgrind", "--track-origins=yes" });
        note = "\ndebug wrapper: valgrind — the reported pid is valgrind; its report lands in app_log when the app exits";
    } else {
        return .{ .err = "'debug' must be \"gdb\" or \"valgrind\"" };
    }
    try wrapped.appendSlice(arena, argv.items);
    argv.clearRetainingCapacity();
    try argv.appendSlice(arena, wrapped.items);
    return .{ .note = note };
}

// ── Capabilities preflight ────────────────────────────────────────

/// PATH search; arena-owned absolute path or null.
fn findExecutable(arena: std.mem.Allocator, exe: []const u8) ?[]const u8 {
    const path_env = c.getenv("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, std.mem.span(@as([*:0]const u8, @ptrCast(path_env))), ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [4096]u8 = undefined;
        const full_z = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, exe }) catch continue;
        if (c.access(full_z.ptr, c.X_OK) == 0) {
            return arena.dupe(u8, full_z) catch null;
        }
    }
    return null;
}

const BROWSER_CANDIDATES = [_][]const u8{
    "chromium", "chromium-browser", "google-chrome-stable", "google-chrome", "chrome", "brave", "brave-browser", "vivaldi-stable", "vivaldi", "microsoft-edge-stable", "microsoft-edge",
};

/// Basename-prefix match for the Chromium family (incl. Electron).
pub fn chromiumFamily(arg0: []const u8) bool {
    const base = std.fs.path.basename(arg0);
    const prefixes = [_][]const u8{ "chromium", "chrome", "google-chrome", "brave", "vivaldi", "microsoft-edge", "opera", "electron" };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, base, p)) return true;
    }
    return false;
}

pub fn findBrowserBinary(arena: std.mem.Allocator) ?[]const u8 {
    for (BROWSER_CANDIDATES) |cand| {
        if (findExecutable(arena, cand)) |p| return p;
    }
    return null;
}

/// `sketerm-webengine` as both backends would find it (the shared
/// findbin lookup: $SKETERM_WEB_BIN, next to our executable, dev
/// tree), then $PATH. What the `web_*` tools ultimately depend on, so
/// `capabilities` reports it.
fn webHelperPath(arena: std.mem.Allocator) ?[]const u8 {
    var buf: [4096:0]u8 = undefined;
    if (@import("../web/findbin.zig").find(&buf)) |p| {
        return arena.dupe(u8, std.mem.span(p)) catch null;
    }
    return findExecutable(arena, "sketerm-webengine");
}

/// The preflight: what this server can actually do right now. Facts
/// only in structuredContent — every `*_hint` prose field this used to
/// carry either states something the tool's own description already
/// says, or is a SITUATIONAL note, which is one line of the text lane.
fn capabilitiesTool(arena: std.mem.Allocator, backend: Backend) ![]const u8 {
    var res = Res.init(arena);
    // headless_gui is what launch_app actually depends on (the mux
    // daemon), and it is effectively always true. gui_socket was once
    // read as "no GUI here", steering assistants back to Xvfb — the
    // two are independent, which the text lane says in one line.
    const headless_terms = term_state.mux_sock != null;
    try res.fact("mode", srv_mode);
    try res.fact("headless_gui", app_state.ready);
    try res.fact("gui_socket", srv_gui_socket);
    try res.fact("gui_socket_source", @tagName(srv_gui_socket_source));
    try res.fact("headless_terminals", headless_terms);
    try res.fact("transfers_and_forwards", headless_terms);
    try res.textf("mode {s}: headless GUI apps {s}, headless terminals {s}, transfers/forwards {s}", .{
        srv_mode,
        yesNo(app_state.ready),
        yesNo(headless_terms),
        yesNo(headless_terms),
    });
    try res.textf("direct GUI control socket: {s} ({s}) — independent of headless GUI apps and of relayed panels", .{
        yesNo(srv_gui_socket),
        @tagName(srv_gui_socket_source),
    });
    if (!std.mem.eql(u8, srv_mode, "shared"))
        try res.text("this server talks to its own PRIVATE mux daemon: sessions here are invisible to the user's `sketerm mux list` / `sketerm app`, and apps started there are invisible here (run with --shared to join the user's daemon)");

    // Panel delivery is independent of gui_socket: an isolated MCP can
    // relay to the GUI attached to its inherited origin session.
    const panel_session = panelstore.resolveSession(.absent);
    var panel_transport = UiTransport.init(arena, backend, panel_session);
    defer panel_transport.deinit();
    // A preflight must stay cheap and must not write anything: probe the
    // relay under a short deadline of its own, and report the store by
    // whether its scope RESOLVES. Whether the state dir is writable is the
    // business of the call that actually writes (ui_save says so exactly).
    const panel_reply = panel_transport.talkFor(.{
        .cmd = "panel-list",
        .session = uiWireSession(panel_session),
    }, UI_CAPABILITY_PROBE_MS);
    const panels_ready = panel_reply.ok;
    const panel_store = uiStoreScope(&panel_transport, UI_CAPABILITY_PROBE_MS);
    const panel_store_ready = panel_store.err.len == 0;
    const panel_store_scope_name: []const u8 = if (panel_store.err.len > 0)
        "unavailable"
    else switch (panel_store.scope) {
        .sessionless => "sessionless",
        .session => "session",
        .origin => "origin",
    };
    const panel_state_name: []const u8 = if (panels_ready)
        "ready"
    else if (panel_transport.failure) |failure|
        switch (failure.kind) {
            .legacy_daemon => "legacy_daemon",
            .unsupported => "unsupported_daemon",
            .no_compatible_gui => "no_compatible_gui",
            .no_such_session => "session_unavailable",
            .origin_unreachable => "origin_unreachable",
            .origin_timeout => "origin_timeout",
            .attach_failed => "session_unavailable",
            .identity_mismatch => "identity_mismatch",
            .malformed_attach => "malformed_attach_metadata",
            .malformed_welcome => "malformed_daemon_welcome",
            .request_too_large => "request_too_large",
            .allocation_failed => "pre_delivery_allocation_failed",
            .send_pre_delivery => "send_pre_delivery",
            .delivery_uncertain => "delivery_uncertain",
            .reply_timeout => "viewer_timeout",
            .disconnected => "viewer_disconnected",
            .malformed_reply => "malformed_reply",
        }
    else if (std.mem.indexOf(u8, panel_reply.err, "no compatible GUI") != null)
        "no_compatible_gui"
    else if (panel_session == null and !srv_gui_socket)
        "no_session_origin"
    else
        "unavailable";
    try res.fact("panels", panels_ready);
    try res.fact("panels_store", panel_store_ready);
    {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.print("{{\"state\":\"{s}\",\"scope\":\"{s}\"", .{
            if (panel_store_ready) "ready" else "unavailable",
            panel_store_scope_name,
        });
        if (!panel_store_ready) {
            try w.writeAll(",\"error\":");
            try std.json.Stringify.value(panel_store.err, .{}, w);
            try w.writeAll(",\"reason\":\"identity_validation_failed\"");
        }
        try w.writeAll("}");
        try res.raw("panel_store", aw.written());
    }
    {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("{\"selected\":");
        try std.json.Stringify.value(panel_transport.selected(), .{}, w);
        try w.writeAll(",\"source\":");
        try std.json.Stringify.value(panel_transport.source(), .{}, w);
        try w.writeAll(",\"state\":");
        try std.json.Stringify.value(panel_state_name, .{}, w);
        try w.writeAll(",\"session\":");
        try std.json.Stringify.value(panel_session, .{}, w);
        if (!panels_ready) {
            try w.writeAll(",\"error\":");
            try std.json.Stringify.value(panel_reply.err, .{}, w);
        }
        try w.writeAll("}");
        try res.raw("panel_transport", aw.written());
    }
    try res.textf("panels: live {s} ({s}, transport {s}), saved {s} (scope {s})", .{
        if (panels_ready) "ready" else "unavailable",
        panel_state_name,
        panel_transport.selected(),
        if (panel_store_ready) "ready" else "unavailable",
        panel_store_scope_name,
    });
    if (!panels_ready)
        try res.text("live ui_* calls need either an origin session relay (SKETERM_SESSION plus SKETERM_MUX_SOCKET, or the connect-only default daemon fallback) or an explicit direct GUI socket. Store-only ui_save/ui_panels/ui_delete stay available while panels_store is true");
    if (!panel_store_ready)
        try res.text("saved-panel persistence is unavailable because the exact origin identity could not be resolved; ui_save/ui_delete return the same failure and ui_panels reports saved_error. Exact origins never downgrade to reusable session storage");

    const ocr_ok = ocr.available();
    try res.fact("ocr", ocr_ok);
    if (!ocr_ok)
        try res.text("app_read_text/app_wait_text need libtesseract — install tesseract + tesseract-data-eng on THIS machine");

    const helper = webHelperPath(arena);
    const web_backend: []const u8 = if (helper == null)
        "none"
    else if (srv_gui_socket)
        "gui"
    else if (std.mem.eql(u8, srv_mode, "shared"))
        "none"
    else if (@import("mcp_web.zig").sessionInfo() != null)
        "session"
    else
        "headless";
    const web_ok = helper != null and !std.mem.eql(u8, web_backend, "none");
    if (helper) |wp| try res.fact("web_helper", wp) else try res.raw("web_helper", "null");
    try res.fact("web", web_ok);
    try res.fact("web_backend", web_backend);
    if (@import("mcp_web.zig").sessionInfo()) |ws| try res.fact("web_session", ws);
    // Watch-along: the private daemon socket and whether the web session
    // shows pixels. Both are facts a human needs to find the assistant's
    // browser from their own GUI; the text lane says where to look.
    const web_watch = @import("mcp_web.zig").presenterActive();
    try res.fact("web_watch", web_watch);
    if (app_state.mux_sock) |ms| try res.fact("mux_socket", ms) else try res.raw("mux_socket", "null");
    if (@import("mcp_web.zig").sessionInfo()) |ws| {
        if (app_state.mux_sock) |ms| {
            try res.textf("the user can watch this browser: session {s} on {s}{s}", .{
                ws,
                ms,
                if (web_watch) " (pages are presented as windows; a viewer holding the controller lease can drive them)" else " (audio and lifetime only: the helper did not arm its presenter)",
            });
        }
    }
    // Per-tab network routes: which kinds `web_open route:` can honour
    // here. A refused route must be explicable from a preflight, never
    // discovered by trying it.
    {
        const routes = @import("mcp_web.zig").routeCapability(web_ok);
        try res.fact("web_routes", routes.name());
        try res.text(routes.describe());
    }
    // The discoverability half of fail-closed: without this, a
    // web_open that refuses a profile reads as a bug rather than as a
    // capability this server does not have.
    {
        const profiles = @import("mcp_web.zig").profileCapability(arena);
        try res.fact("web_profiles", profiles.available);
        // Certificate errors are FACTS on every web result, and a
        // headless view answers them itself (fail closed, fingerprint
        // opt-in). A consumer must not have to hang once to learn that.
        try res.fact("web_cert_facts", true);
        try res.fact("web_accept_cert", !srv_gui_socket);
        try res.text(if (srv_gui_socket)
            "certificate errors: the user's interstitial decides; results carry cert facts while a load is held"
        else
            "certificate errors fail closed in headless views and are reported as cert facts; web_open accept_cert trusts one fingerprint for one view");
        if (profiles.store.len > 0) try res.fact("web_profile_store", profiles.store);
        if (profiles.available)
            try res.text("named browsing profiles are available (web_open profile:\"name\"); each keeps its own cookie jar across MCP restarts")
        else if (profiles.reason.len > 0)
            try res.textf("named browsing profiles are unavailable: {s}", .{profiles.reason});
    }
    // Engine lifecycle, as a FACT: a consumer once had to infer "is the
    // engine broker-owned" from profile side effects. Every capability
    // the server gains is reported here from day one.
    if (web_ok and !srv_gui_socket) {
        const eng = @import("mcp_web.zig").engineCapability();
        try res.fact("web_engine_broker", eng.broker_lane);
        try res.fact("web_engine_owner", eng.owner.name());
        if (eng.broker_lane)
            try res.textf("browser engine lifecycle: broker-owned (the mux daemon spawns sketerm-webengine and keeps it through client restarts; owner now: {s})", .{eng.owner.name()})
        else
            try res.textf("browser engine lifecycle: client-spawned (exits with its last client; owner now: {s})", .{eng.owner.name()});
    }
    if (helper == null)
        try res.text("sketerm-webengine is not installed next to the sketerm binary — the web_* tools have nothing to drive, in any mode (build it with: zig build fetch-cef && zig build web)")
    else if (std.mem.eql(u8, web_backend, "none"))
        try res.text("--shared mode drives the user's GUI, but no GUI control socket was found; start the sketerm GUI (or run without --shared, where the web_* tools work headlessly with no GUI at all)")
    else
        try res.textf("web: {s} backend", .{web_backend});

    try res.fact("ssh", findExecutable(arena, "ssh") != null);
    try res.fact("scp", findExecutable(arena, "scp") != null);
    try res.fact("mux_tor", true);
    try res.text("mux Tor transport: supported via tor:<ssh-alias>; forced SOCKS5 remote DNS, with no UDP or direct fallback");
    if (rec_state.enabled) {
        if (recDir()) |d| try res.fact("terminal_recordings", d) else try res.raw("terminal_recordings", "null");
        try res.text("every headless terminal is auto-recorded as an asciicast v2 .cast file there (replay with asciinema play)");
    } else try res.raw("terminal_recordings", "null");

    // Effective input-timing defaults, with any env override marked —
    // config-set defaults must never be invisible state.
    {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("{");
        var any_override = false;
        for (Tuning.all(), 0..) |item, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("\"{s}\":{{\"value\":{d},\"built_in\":{d},\"overridden\":{}}}", .{ item.name, item.value, item.built_in, item.overridden });
            if (item.overridden) any_override = true;
        }
        try w.writeAll("}");
        try res.raw("input_tuning", aw.written());
        if (any_override)
            try res.text("some input-timing defaults were overridden via SKETERM_MCP_* env (project .mcp.json); the tools/list descriptions already state the effective values");
    }

    // Tool exposure. A missing tool must be explicable from inside the
    // session: without this an assistant reads a filtered tools/list as
    // "sketerm cannot do that" and goes looking for workarounds.
    {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("{\"spec\":");
        try std.json.Stringify.value(policy.spec, .{}, w);
        try w.print(",\"source\":\"{s}\",\"restricted\":{},\"groups_available\":[", .{ policy_source, !policy.isUnrestricted() });
        var first = true;
        for (std.enums.values(mcpfilter.Group)) |g| {
            var any = false;
            for (mcpfilter.TOOL_META) |m| {
                if (m.group == g and policy.allowsMeta(m)) {
                    any = true;
                    break;
                }
            }
            if (!any) continue;
            if (!first) try w.writeAll(",");
            first = false;
            try std.json.Stringify.value(g.name(), .{}, w);
        }
        try w.writeAll("],\"groups_suppressed\":[");
        var sup_buf: [std.enums.values(mcpfilter.Group).len]mcpfilter.Group = undefined;
        const suppressed = mcpfilter.suppressedGroups(policy, &sup_buf);
        for (suppressed, 0..) |g, i| {
            if (i > 0) try w.writeAll(",");
            try std.json.Stringify.value(g.name(), .{}, w);
        }
        try w.writeAll("]}");
        try res.raw("tool_policy", aw.written());
        if (!policy.isUnrestricted()) {
            try res.textf("tool policy {s} (from {s}) restricts this connection; withheld tools are absent from tools/list AND refused by tools/call. A withheld tool is not a missing capability — ask the user to restart the server with --tools/--profile or $SKETERM_MCP_TOOLS", .{ policy.spec, policy_source });
            if (suppressed.len > 0) {
                var sw: std.Io.Writer.Allocating = .init(arena);
                for (suppressed, 0..) |g, i| {
                    if (i > 0) try sw.writer.writeAll(", ");
                    try sw.writer.writeAll(g.name());
                }
                try res.textf("suppressed groups: {s}", .{sw.written()});
            }
        }
    }

    // App/terminal sessions have no idle timeout; what ends them is
    // this server's own lifetime in isolated mode. Saying so removes a
    // whole class of "the app exited with status 0 for no reason".
    try res.fact("session_lifetime", srv_mode);
    if (std.mem.eql(u8, srv_mode, "shared"))
        try res.text("session lifetime: sessions live on the user's own daemon and outlive this server; nothing here times them out")
    else if (std.mem.eql(u8, srv_mode, "isolated"))
        try res.text("session lifetime: the private daemon and EVERY app/terminal on it are torn down when this MCP server exits. There is no idle timeout — an app that 'exited on its own' between sessions was killed by that teardown. Use --durable/--name for sessions that survive restarts")
    else
        try res.text("session lifetime: the daemon and its sessions survive this server's restarts and are reattached on reconnect; there is no idle timeout");

    try res.fact("open_terms", term_state.terms.count());
    try res.fact("open_apps", app_state.apps.count());
    try res.fact("open_forwards", forward_state.forwards.count());
    try res.textf("open: {d} terminal(s), {d} app(s), {d} forward(s)", .{
        term_state.terms.count(), app_state.apps.count(), forward_state.forwards.count(),
    });
    return res.finish();
}

fn yesNo(v: bool) []const u8 {
    return if (v) "yes" else "no";
}

// ── file_* tools (fsdrive against the app daemon) ─────────────────

/// An entry's mtime for a listing line: "?" when it has no local
/// representation, since a blank would misalign the columns.
fn fsFmtTime(buf: []u8, ms: i64) []const u8 {
    return clock.localStamp(buf, ms) orelse "?";
}

fn fsEntryLine(w: *std.Io.Writer, e: fsdrive.Entry) !void {
    var tb: [32]u8 = undefined;
    try w.print("{s: <5} {d: >12}  {s}  {o:0>4}  {s}", .{
        e.kind, e.size, fsFmtTime(&tb, e.mtime_ms), e.mode, e.name,
    });
    if (e.target) |t| try w.print(" -> {s}", .{t});
    try w.writeAll("\n");
}

/// An fsdrive error as one of the shared codes. The daemon's own
/// message is the only place a missing path is visible, so a refused
/// op is classified from it.
///
/// `NOENT` is the spelling that actually arrives: the daemon reports
/// failures as bare errno TAGS (`fsserve.errnoName` -> "NOENT",
/// "ACCES"), not as strerror prose. Matching only "ENOENT" therefore
/// typed every missing file as `io_failed`, which is RETRYABLE — so a
/// client retried a path that will never exist.
pub fn fsErrCode(err: fsdrive.Error, detail: []const u8) ErrCode {
    return switch (err) {
        fsdrive.Error.NotConnected => .unavailable,
        fsdrive.Error.Timeout => .timeout,
        fsdrive.Error.BadRequest => .invalid_args,
        fsdrive.Error.Conflict => .conflict,
        fsdrive.Error.OutOfMemory, fsdrive.Error.BadReply => .io_failed,
        // "NOENT" also matches the "ENOENT" spelling, which contains it.
        fsdrive.Error.FsOpFailed => if (std.mem.indexOf(u8, detail, "No such file") != null or
            std.mem.indexOf(u8, detail, "not found") != null or
            std.mem.indexOf(u8, detail, "NOENT") != null) .not_found else .io_failed,
    };
}

/// Describe an fsdrive failure. Captures the daemon's error string
/// BEFORE dropping a dead connection (the Fs would dangle after).
fn fsFail(arena: std.mem.Allocator, fs: *fsdrive.Fs, what: []const u8, err: fsdrive.Error) ![]const u8 {
    if (err == fsdrive.Error.NotConnected) {
        fs_state.drop();
        return errRes(arena, .unavailable, "daemon connection lost (reconnects on the next file_* call)");
    }
    const detail = fs.lastErr();
    const msg = std.fmt.allocPrint(arena, "{s} failed: {s} ({s})", .{
        what, detail, @errorName(err),
    }) catch return error.OutOfMemory;
    const code = fsErrCode(err, detail);
    // A send timeout may have left half a frame on the stream. Preserve the
    // timeout verdict, but retire that connection before the next request.
    if (!fs.usable()) fs_state.drop();
    return errRes(arena, code, msg);
}

/// Wait for a job's terminal event and render the outcome. A timeout
/// is HONEST: the job keeps running daemon-side, and that is a FACT
/// (`status: running`, `timed_out`), never a tool error.
fn fsAwaitJob(arena: std.mem.Allocator, fs: *fsdrive.Fs, job: u64, opname: []const u8, timeout_ms: i64) ![]const u8 {
    const end = fs.waitJobEnd(job, timeout_ms) catch |err| switch (err) {
        fsdrive.Error.Timeout => {
            var res = Res.init(arena);
            try res.fact("op", opname);
            try res.fact("job", job);
            try res.field("status", @as([]const u8, "running"));
            try res.fact("timed_out", true);
            try res.textf("{s} job {d} is still running after {d}ms — it continues in the background (file_jobs to check, file_job to cancel)", .{ opname, job, timeout_ms });
            return res.finish();
        },
        else => return fsFail(arena, fs, opname, err),
    };
    if (!end.ok) {
        const msg = std.fmt.allocPrint(arena, "{s} job {d} {s}: {s}", .{
            opname, job, if (end.canceled) "canceled" else "FAILED", end.messageText(),
        }) catch return error.OutOfMemory;
        return errRes(arena, if (end.canceled) .conflict else .io_failed, msg);
    }
    var res = Res.init(arena);
    try res.fact("op", opname);
    try res.fact("job", job);
    try res.field("status", @as([]const u8, "done"));
    try res.fact("timed_out", false);
    try res.fact("bytes", end.bytes_done);
    if (end.resumed_from > 0) try res.fact("resumed_from", end.resumed_from);
    if (end.has_hash) try res.fact("sha256", end.hash[0..]);
    try res.textf("{s} job {d} done: {d} bytes", .{ opname, job, end.bytes_done });
    if (end.resumed_from > 0) try res.textf("resumed from {d} (partial verified by hash)", .{end.resumed_from});
    if (end.has_hash) try res.textf("sha256 {s}", .{end.hash[0..]});
    return res.finish();
}

/// One directory entry as machine facts. Same vocabulary as the text
/// table `fsEntryLine` writes, so a listing cannot say two things.
fn fsEntryJson(w: *std.Io.Writer, e: fsdrive.Entry) !void {
    try w.writeAll("{\"name\":");
    try std.json.Stringify.value(e.name, .{}, w);
    try w.print(",\"kind\":\"{s}\",\"size\":{d},\"mode\":{d},\"mtime_ms\":{d},\"uid\":{d},\"gid\":{d}", .{
        e.kind, e.size, e.mode, e.mtime_ms, e.uid, e.gid,
    });
    if (e.target) |t| {
        try w.writeAll(",\"target\":");
        try std.json.Stringify.value(t, .{}, w);
        try w.print(",\"target_is_dir\":{}", .{e.tdir});
    }
    try w.writeAll("}");
}

fn fsTool(arena: std.mem.Allocator, name: []const u8, args: std.json.Value) ![]const u8 {
    const eql = std.mem.eql;
    const fs = fs_state.get() orelse
        return errRes(arena, .unavailable, "cannot reach the mux daemon for file tools");

    if (eql(u8, name, "file_list")) {
        const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
        var l = fs.list(path) catch |err| return fsFail(arena, fs, "list", err);
        defer l.deinit();
        var entries: std.Io.Writer.Allocating = .init(arena);
        var table: std.Io.Writer.Allocating = .init(arena);
        try entries.writer.writeAll("[");
        for (l.entries, 0..) |e, i| {
            if (i > 0) try entries.writer.writeAll(",");
            try fsEntryJson(&entries.writer, e);
            try fsEntryLine(&table.writer, e);
        }
        try entries.writer.writeAll("]");
        var res = Res.init(arena);
        try res.fact("path", l.path);
        try res.fact("count", l.entries.len);
        try res.fact("truncated", l.truncated);
        try res.raw("entries", entries.written());
        try res.textf("{s}: {d} entries{s}", .{
            l.path, l.entries.len, if (l.truncated) " (TRUNCATED at the listing cap)" else "",
        });
        if (l.entries.len > 0) try res.textf("--- entries ---\n{s}", .{table.written()});
        return res.finish();
    }
    if (eql(u8, name, "file_stat")) {
        const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
        const e = fs.statPath(arena, path) catch |err| return fsFail(arena, fs, "stat", err);
        var res = Res.init(arena);
        try res.fact("path", path);
        try res.fact("kind", e.kind);
        try res.fact("size", e.size);
        try res.fact("mode", e.mode);
        try res.fact("uid", e.uid);
        try res.fact("gid", e.gid);
        try res.fact("mtime_ms", e.mtime_ms);
        if (e.target) |t| {
            try res.fact("target", t);
            try res.fact("target_is_dir", e.tdir);
        }
        var tb: [32]u8 = undefined;
        try res.textf("{s}: {s}, {d} bytes, mode {o:0>4}, uid {d} gid {d}, mtime {s}", .{
            path, e.kind, e.size, e.mode, e.uid, e.gid, fsFmtTime(&tb, e.mtime_ms),
        });
        if (e.target) |t| try res.textf("-> {s}{s}", .{ t, if (e.tdir) " (dir)" else "" });
        return res.finish();
    }
    if (eql(u8, name, "file_read")) {
        const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
        const off: u64 = @intCast(@max(0, argInt(args, "offset") orelse 0));
        const want: u32 = @intCast(std.math.clamp(argInt(args, "length") orelse 262_144, 1, 2_097_152));
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(arena);
        const info = fs.read(path, off, want, &data) catch |err| return fsFail(arena, fs, "read", err);
        const textual = std.unicode.utf8ValidateSlice(data.items) and
            std.mem.indexOfScalar(u8, data.items, 0) == null;
        var res = Res.init(arena);
        try res.fact("path", path);
        try res.fact("size", info.size);
        try res.fact("offset", off);
        try res.fact("bytes", data.items.len);
        try res.fact("eof", info.eof);
        try res.fact("more", !info.eof);
        try res.fact("binary", !textual);
        try res.textf("{s}: read {d} of {d} bytes at offset {d}, {s}", .{
            path, data.items.len, info.size, off, if (info.eof) "eof" else "MORE remains",
        });
        if (textual) {
            // Text content is the payload the text lane exists for;
            // duplicating it into structuredContent would double a
            // multi-megabyte read for no reader.
            try res.textf("--- content ---\n{s}", .{data.items});
        } else {
            // Bytes are machine data, not prose: the base64 belongs in
            // the structured lane, and the text lane just says so.
            const enc = std.base64.standard.Encoder;
            const b64 = arena.alloc(u8, enc.calcSize(data.items.len)) catch return error.OutOfMemory;
            try res.fact("base64", enc.encode(b64, data.items));
            try res.text("binary content: the bytes are base64 in structuredContent.base64");
        }
        return res.finish();
    }
    if (eql(u8, name, "file_write")) {
        const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
        const content = argStr(args, "content") orelse return errRes(arena, .invalid_args, "missing content");
        const append = argBool(args, "append");
        const n = fs.write(path, 0, content, .{
            .create = true,
            .truncate = !append,
            .append = append,
        }) catch |err| return fsFail(arena, fs, "write", err);
        var res = Res.init(arena);
        try res.fact("path", path);
        try res.fact("bytes", n);
        try res.fact("append", append);
        try res.textf("{s}: {d} bytes {s}", .{ path, n, if (append) "appended" else "written" });
        return res.finish();
    }
    if (eql(u8, name, "file_mkdir")) {
        const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
        fs.mkdir(path) catch |err| return fsFail(arena, fs, "mkdir", err);
        var res = Res.init(arena);
        try res.fact("path", path);
        try res.fact("created", true);
        try res.textf("{s}: created", .{path});
        return res.finish();
    }
    if (eql(u8, name, "file_rename")) {
        const from = argStr(args, "from") orelse return errRes(arena, .invalid_args, "missing from");
        const to = argStr(args, "to") orelse return errRes(arena, .invalid_args, "missing to");
        fs.rename(from, to) catch |err| return fsFail(arena, fs, "rename", err);
        var res = Res.init(arena);
        try res.fact("from", from);
        try res.fact("to", to);
        try res.fact("renamed", true);
        try res.textf("renamed {s} to {s}", .{ from, to });
        return res.finish();
    }
    if (eql(u8, name, "file_delete")) {
        const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
        fs.deletePath(path) catch |err| return fsFail(arena, fs, "delete", err);
        var res = Res.init(arena);
        try res.fact("path", path);
        try res.fact("deleted", true);
        try res.textf("{s}: deleted", .{path});
        return res.finish();
    }
    if (eql(u8, name, "file_chmod")) {
        const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
        const mode: u32 = @intCast(std.math.clamp(argInt(args, "mode") orelse -1, 0, 0o7777));
        fs.chmod(path, mode) catch |err| return fsFail(arena, fs, "chmod", err);
        var res = Res.init(arena);
        try res.fact("path", path);
        try res.fact("mode", mode);
        try res.textf("{s}: mode {o:0>4}", .{ path, mode });
        return res.finish();
    }
    if (eql(u8, name, "file_truncate")) {
        const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
        const size: u64 = @intCast(@max(0, argInt(args, "size") orelse 0));
        fs.truncate(path, size) catch |err| return fsFail(arena, fs, "truncate", err);
        var res = Res.init(arena);
        try res.fact("path", path);
        try res.fact("size", size);
        try res.textf("{s}: size now {d}", .{ path, size });
        return res.finish();
    }
    if (eql(u8, name, "file_copy") or eql(u8, name, "file_delete_tree") or eql(u8, name, "file_hash") or
        eql(u8, name, "file_extract") or eql(u8, name, "file_archive_create") or eql(u8, name, "file_trash"))
    {
        const timeout: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 60_000, 1_000, 120_000);
        var job: u64 = 0;
        var opname: []const u8 = "";
        if (eql(u8, name, "file_copy")) {
            const src = argStr(args, "src") orelse return errRes(arena, .invalid_args, "missing src");
            const dst = argStr(args, "dst") orelse return errRes(arena, .invalid_args, "missing dst");
            job = fs.startCopy(src, dst, argBool(args, "resume")) catch |err| return fsFail(arena, fs, "copy", err);
            opname = "copy";
        } else if (eql(u8, name, "file_delete_tree")) {
            const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
            job = fs.startDeleteTree(path) catch |err| return fsFail(arena, fs, "delete_tree", err);
            opname = "delete_tree";
        } else if (eql(u8, name, "file_extract")) {
            const archive = argStr(args, "archive") orelse return errRes(arena, .invalid_args, "missing archive");
            const destination = argStr(args, "destination") orelse return errRes(arena, .invalid_args, "missing destination");
            job = fs.startExtract(archive, destination) catch |err| return fsFail(arena, fs, "extract", err);
            opname = "extract";
        } else if (eql(u8, name, "file_archive_create")) {
            const source = argStr(args, "source") orelse return errRes(arena, .invalid_args, "missing source");
            const archive = argStr(args, "archive") orelse return errRes(arena, .invalid_args, "missing archive");
            job = fs.startArchiveCreate(source, archive) catch |err| return fsFail(arena, fs, "archive_create", err);
            opname = "archive_create";
        } else if (eql(u8, name, "file_trash")) {
            const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
            job = fs.startTrash(path) catch |err| return fsFail(arena, fs, "trash", err);
            opname = "trash";
        } else {
            const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
            job = fs.startHash(path) catch |err| return fsFail(arena, fs, "hash", err);
            opname = "hash";
        }
        const wait = if (args == .object and args.object.get("wait") != null) argBool(args, "wait") else true;
        if (!wait) {
            var res = Res.init(arena);
            try res.fact("op", opname);
            try res.field("job", job);
            try res.field("status", @as([]const u8, "started"));
            try res.textf("{s} job {d} started (file_jobs to check)", .{ opname, job });
            return res.finish();
        }
        return fsAwaitJob(arena, fs, job, opname, timeout);
    }
    if (eql(u8, name, "file_media_info")) {
        const list_v = if (args == .object) args.object.get("paths") else null;
        if (list_v == null or list_v.? != .array) return errRes(arena, .invalid_args, "file_media_info needs a 'paths' array");
        const items = list_v.?.array.items;
        if (items.len == 0) return errRes(arena, .invalid_args, "file_media_info needs at least one path");
        if (items.len > fsdrive.MEDIA_BATCH_MAX) {
            const msg = std.fmt.allocPrint(arena, "file_media_info takes at most {d} paths per call", .{fsdrive.MEDIA_BATCH_MAX}) catch return error.OutOfMemory;
            return errRes(arena, .invalid_args, msg);
        }
        var paths: std.ArrayList([]const u8) = .empty;
        for (items) |item| {
            if (item != .string or item.string.len == 0 or item.string[0] != '/')
                return errRes(arena, .invalid_args, "every file_media_info path must be absolute");
            paths.append(arena, item.string) catch return error.OutOfMemory;
        }
        // "/" plus absolute names: the daemon resolves absolute entries
        // as-is, so one call can span directories.
        const rows = fs.mediaMeta(arena, "/", paths.items, 30_000) catch |err|
            return fsFail(arena, fs, "media_info", err);
        var files: std.Io.Writer.Allocating = .init(arena);
        var table: std.Io.Writer.Allocating = .init(arena);
        const jw = &files.writer;
        const tw = &table.writer;
        try jw.writeAll("[");
        for (rows, 0..) |r, i| {
            if (i > 0) try jw.writeAll(",");
            try jw.writeAll("{\"path\":");
            try std.json.Stringify.value(r.path, .{}, jw);
            try jw.print(",\"kind\":\"{s}\",\"cached\":{}", .{ r.kind, r.cached });
            if (r.note.len > 0) {
                try jw.writeAll(",\"note\":");
                try std.json.Stringify.value(r.note, .{}, jw);
            }
            try jw.writeAll(",\"fields\":{");
            for (r.fields, 0..) |f, fi| {
                if (fi > 0) try jw.writeAll(",");
                try std.json.Stringify.value(f.k, .{}, jw);
                try jw.writeAll(":");
                try std.json.Stringify.value(f.v, .{}, jw);
            }
            try jw.writeAll("}}");

            try tw.print("{s} [{s}]{s}\n", .{ r.path, r.kind, if (r.cached) " (cached)" else "" });
            if (r.note.len > 0) try tw.print("  skipped: {s}\n", .{r.note});
            for (r.fields) |f| try tw.print("  {s}={s}\n", .{ f.k, f.v });
        }
        try jw.writeAll("]");
        var res = Res.init(arena);
        try res.fact("count", rows.len);
        try res.raw("files", files.written());
        try res.textf("{d} file(s)", .{rows.len});
        if (rows.len > 0) try res.textf("--- media ---\n{s}", .{table.written()});
        return res.finish();
    }
    if (eql(u8, name, "file_jobs")) {
        const rows = fs.jobList(arena) catch |err| return fsFail(arena, fs, "job_list", err);
        var jobs: std.Io.Writer.Allocating = .init(arena);
        var table: std.Io.Writer.Allocating = .init(arena);
        const jw = &jobs.writer;
        const tw = &table.writer;
        try jw.writeAll("[");
        for (rows, 0..) |row, i| {
            if (i > 0) try jw.writeAll(",");
            try jw.print("{{\"job\":{d},\"op\":", .{row.job});
            try std.json.Stringify.value(row.op, .{}, jw);
            try jw.writeAll(",\"state\":");
            try std.json.Stringify.value(row.state, .{}, jw);
            try jw.print(",\"done\":{d},\"total\":{d},\"src\":", .{ row.done, row.total });
            try std.json.Stringify.value(row.src, .{}, jw);
            try jw.writeAll(",\"dst\":");
            try std.json.Stringify.value(row.dst, .{}, jw);
            try jw.writeAll(",\"message\":");
            try std.json.Stringify.value(row.message, .{}, jw);
            try jw.writeAll("}");
            if (i > 0) try tw.writeAll("\n");
            try tw.print("job {d}: {s} {s} {d}/{d} bytes", .{ row.job, row.op, row.state, row.done, row.total });
        }
        try jw.writeAll("]");
        var res = Res.init(arena);
        try res.fact("count", rows.len);
        try res.raw("jobs", jobs.written());
        if (rows.len == 0)
            try res.text("no file jobs")
        else
            try res.textf("{d} file job(s)\n--- jobs ---\n{s}", .{ rows.len, table.written() });
        return res.finish();
    }
    if (eql(u8, name, "file_job")) {
        const job: u64 = @intCast(@max(0, argInt(args, "job") orelse 0));
        const action = argStr(args, "action") orelse return errRes(arena, .invalid_args, "missing action");
        if (eql(u8, action, "cancel")) {
            fs.jobCancel(job) catch |err| return fsFail(arena, fs, "job_cancel", err);
        } else if (eql(u8, action, "pause")) {
            fs.jobPause(job) catch |err| return fsFail(arena, fs, "job_pause", err);
        } else if (eql(u8, action, "resume")) {
            fs.jobResume(job) catch |err| return fsFail(arena, fs, "job_resume", err);
        } else return errRes(arena, .invalid_args, "action must be cancel|pause|resume");
        var res = Res.init(arena);
        try res.fact("job", job);
        try res.fact("action", action);
        try res.fact("sent", true);
        try res.textf("job {d}: {s} sent", .{ job, action });
        return res.finish();
    }
    return errRes(arena, .unknown_tool, "unknown file tool");
}

// ── ui_*: agent-authored UI panels ────────────────────────────────
//
// Live panels are RENDERED BY THE GUI. The same `panel-*` JSON commands
// reach it through either the owning mux session's panel relay or the
// legacy direct control socket; panelstore.zig remains the saved half.
// Two invariants hold it together:
//
// - **Poll here, never block there.** `panel-events` answers
//   immediately by design: it is dispatched on the GLib main loop, and
//   blocking that would freeze every window the user has. So
//   `ui_wait_event`'s BLOCKING semantics live here, as a poll loop.
//   Do not "fix" it by teaching the GUI side to wait.
// - **One session key for both halves.** Several assistants drive one
//   sketerm, so a panel is (session, name). The session is resolved
//   ONCE per call (`panelstore.resolveSession`: explicit arg, else
//   $SKETERM_SESSION, else NONE — `?[]const u8`, never a magic name)
//   and passed explicitly to the GUI, so a live panel and its saved
//   document can never end up under different keys. "No session" is a
//   different SHAPE, not a reserved session name: on the wire it is an
//   empty `session` field (`panelhost.NO_SESSION_WIRE`, distinct from
//   an absent one, which means "scope me to the requesting pane"), and
//   on disk it is its own directory (`panelstore.NO_SESSION_DIR`).
// - **The GUI holds the document; this server holds none.** `ui_save`
//   with no `document` reads the panel back with `panel-get`, so it
//   works against a panel any process showed, at any time. There is
//   deliberately no server-side mirror to go stale.

/// Poll granularity for ui_wait_event. Human interaction latency is
/// orders of magnitude above this, and each tick is one tiny IPC
/// round-trip on the GUI's main loop.
const UI_POLL_MS: u32 = 100;

const UI_WAIT_DEFAULT_MS: i64 = 30_000;

const UI_NEEDS_TRANSPORT =
    "no live panel transport is available. From a sketerm pane, preserve SKETERM_SESSION and " ++
    "SKETERM_MUX_SOCKET so ui_* can relay through that exact mux session; sessionless/legacy callers " ++
    "can use an explicit --socket <GUI path>. The MCP app tools remain on their private daemon. " ++
    "ui_save with a document, ui_panels' saved half, and ui_delete still work without a live viewer.";

/// `ui_save` with no document reads the panel back from the GUI
/// (`panel-get`), which is why this server keeps no document state of
/// its own.
const UI_SAVE_NEEDS_TRANSPORT =
    "ui_save without 'document' reads the panel's CURRENT document back from the sketerm GUI, " ++
    "but no live panel transport is available. Either pass 'document' explicitly, run with the originating " ++
    "SKETERM_SESSION + SKETERM_MUX_SOCKET, or use an explicit --socket for a sessionless/legacy GUI. " ++
    "`capabilities` reports `panels`, `panel_transport`, and `gui_socket` separately.";

const UI_RELAY_CALL_MS: i64 = 40_000;

/// `capabilities` is a preflight: its liveness probe must cost a moment, not
/// a whole tool call's budget.
const UI_CAPABILITY_PROBE_MS: i64 = 2_000;

/// Cap on `ui_show_files`. Well under doc.MAX_CHILDREN (128, and the
/// heading takes one), and past a few dozen images a scrolling column
/// is the wrong presentation anyway.
const UI_FILES_MAX: usize = 64;

/// Default panel name for `ui_show_files`, so the common call is
/// genuinely one line. Re-showing it replaces the panel in place,
/// which is what "here is the next epoch" wants.
const UI_FILES_NAME = "files";

/// One entry of `ui_show_files`: an absolute image path plus the
/// caption drawn under it (or, in compare mode, its side label).
const UiFile = struct { path: []const u8, caption: []const u8 };

/// Build the panel document `ui_show_files` shows. Pure — no IPC, no
/// disk — so "the generator emits a document the parser accepts" is a
/// unit-testable property rather than a GUI-side refusal.
fn uiFilesDocument(
    arena: std.mem.Allocator,
    files: []const UiFile,
    title: []const u8,
    compare: bool,
) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    const heading = title.len > 0;

    try w.writeAll("{\"version\":1,\"title\":");
    try std.json.Stringify.value(if (heading) title else "Images", .{}, w);
    try w.writeAll(",\"root\":\"main\",\"components\":{\"main\":{\"type\":\"column\",\"children\":[");
    if (heading) try w.writeAll("\"h\"");
    if (compare) {
        if (heading) try w.writeByte(',');
        try w.writeAll("\"cmp\"");
    } else for (files, 0..) |_, i| {
        if (heading or i > 0) try w.writeByte(',');
        try w.print("\"img{d}\"", .{i + 1});
    }
    try w.writeAll("]}");

    if (heading) {
        try w.writeAll(",\"h\":{\"type\":\"heading\",\"level\":2,\"text\":");
        try std.json.Stringify.value(title, .{}, w);
        try w.writeByte('}');
    }
    if (compare) {
        try w.writeAll(",\"cmp\":{\"type\":\"image_compare\",\"left\":{\"src\":");
        try std.json.Stringify.value(files[0].path, .{}, w);
        try w.writeAll(",\"label\":");
        try std.json.Stringify.value(files[0].caption, .{}, w);
        try w.writeAll("},\"right\":{\"src\":");
        try std.json.Stringify.value(files[1].path, .{}, w);
        try w.writeAll(",\"label\":");
        try std.json.Stringify.value(files[1].caption, .{}, w);
        try w.writeAll("}}");
    } else for (files, 0..) |f, i| {
        try w.print(",\"img{d}\":{{\"type\":\"image\",\"src\":", .{i + 1});
        try std.json.Stringify.value(f.path, .{}, w);
        try w.writeAll(",\"caption\":");
        try std.json.Stringify.value(f.caption, .{}, w);
        try w.writeByte('}');
    }
    try w.writeAll("}}");
    return aw.written();
}

/// The session a ui_* call is scoped to — `null` when there is none.
/// Resolved ONCE per call and passed explicitly to both halves, so a
/// live panel and its saved document cannot land under different keys.
fn uiSession(args: std.json.Value) error{InvalidSessionType}!?[]const u8 {
    if (args == .object) {
        if (args.object.get("session")) |value| {
            if (value == .string) return panelstore.resolveSession(.{ .explicit = value.string });
            return error.InvalidSessionType;
        }
    }
    return panelstore.resolveSession(.absent);
}

/// The scope as the control socket spells it: an EMPTY `session`
/// states "this caller has no session", which the GUI must not confuse
/// with an absent field (= scope me to the requesting pane).
fn uiWireSession(session: ?[]const u8) []const u8 {
    return session orelse "";
}

const UiStoreScope = struct {
    scope: panelstore.Scope = .sessionless,
    err: []const u8 = "",
};

const UiTransport = struct {
    arena: std.mem.Allocator,
    backend: Backend,
    session: ?[]const u8,
    mode: enum { auto, mux_relay, gui_socket, none },
    origin: ?paneldrive.Origin = null,
    failure: ?paneldrive.Failure = null,
    validated_store_scope: ?panelstore.Scope = null,

    fn init(arena: std.mem.Allocator, backend: Backend, session: ?[]const u8) UiTransport {
        const exact_origin = session != null and paneldrive.hasEnvironmentSocket();
        return .{
            .arena = arena,
            .backend = backend,
            .session = session,
            .mode = if (exact_origin)
                if (panel_pool != null) .auto else .none
            else if (srv_gui_socket_source == .explicit)
                .gui_socket
            else if (session != null and panel_pool != null)
                .auto
            else if (srv_gui_socket)
                .gui_socket
            else
                .none,
        };
    }

    fn deinit(self: *UiTransport) void {
        if (self.origin) |*origin| origin.deinit(self.arena);
        self.origin = null;
    }

    fn selected(self: *const UiTransport) []const u8 {
        return switch (self.mode) {
            .auto, .mux_relay => "mux_relay",
            .gui_socket => "gui_socket",
            .none => "none",
        };
    }

    fn source(self: *const UiTransport) []const u8 {
        return switch (self.mode) {
            .gui_socket => switch (srv_gui_socket_source) {
                .explicit => "gui_socket_explicit",
                .discovered => "gui_socket_discovered",
                .none => "none",
            },
            .auto, .mux_relay => if (self.origin) |origin| switch (origin.source) {
                .environment => "SKETERM_MUX_SOCKET",
                .default_compat => "default_socket_connect_only",
            } else "none",
            .none => "none",
        };
    }

    fn talk(self: *UiTransport, req: protocol.Request) IpcReply {
        return self.talkFor(req, UI_RELAY_CALL_MS);
    }

    fn talkFor(self: *UiTransport, req: protocol.Request, timeout_ms: i64) IpcReply {
        const deadline_ms = clock.nowMs() + @max(timeout_ms, 0);
        switch (self.mode) {
            .gui_socket => return self.directUntil(req, deadline_ms),
            .none => return .{ .ok = false, .value = .null, .err = UI_NEEDS_TRANSPORT },
            .mux_relay, .auto => return self.relayUntil(req, deadline_ms),
        }
    }

    fn directUntil(self: *UiTransport, req: protocol.Request, deadline_ms: i64) IpcReply {
        const remain = deadline_ms - clock.nowMs();
        if (remain <= 0) return .{
            .ok = false,
            .value = .null,
            .err = "the shared panel deadline expired before direct fallback delivery; failure_class=pre_delivery, mutation_may_have_applied=false, resend_safe=true",
            .delivery = .pre_delivery,
        };
        const line = reqLine(self.arena, req) catch
            return .{ .ok = false, .value = .null, .err = "could not encode the panel request" };
        const response = switch (self.backend.talkFor(self.backend.ctx, self.arena, line, remain)) {
            .reply => |reply| reply,
            .failure => |failure| return .{
                .ok = false,
                .value = .null,
                .err = directFailureMessage(self.arena, req.cmd, failure),
                .delivery = switch (failure.delivery) {
                    .pre_delivery => .pre_delivery,
                    .uncertain_delivery => .uncertain_delivery,
                },
            },
        };
        const meta = panelrpc.validateReply(self.arena, panelrpc.opFromCommand(req.cmd), response) catch |err| return .{
            .ok = false,
            .value = .null,
            .err = std.fmt.allocPrint(
                self.arena,
                "the direct GUI presenter returned an invalid {s} reply after request delivery ({s}); delivery is uncertain, the mutation may have applied, and the request was NOT resent",
                .{ req.cmd, @errorName(err) },
            ) catch "the direct GUI presenter returned an invalid reply after uncertain delivery; the request was not resent",
            .delivery = .uncertain_delivery,
        };
        const parsed = parseIpcReply(self.arena, response);
        if (meta.uncertain_delivery) return .{
            .ok = false,
            .value = .null,
            .err = std.fmt.allocPrint(
                self.arena,
                "the direct GUI presenter reported failure_class=uncertain_delivery ({s}); delivery is uncertain, the mutation may have applied, and it was NOT resent automatically. Do not resend it automatically",
                .{parsed.err},
            ) catch "the direct GUI presenter reported uncertain delivery; the mutation may have applied and it was not resent",
            .delivery = .uncertain_delivery,
        };
        return parsed;
    }

    fn direct(self: *UiTransport, req: protocol.Request, timeout_ms: i64) IpcReply {
        return self.directUntil(req, clock.nowMs() + @max(timeout_ms, 0));
    }

    /// Validate and retain persistence identity before a live request can fail.
    fn prepareStoreScopeUntil(
        self: *UiTransport,
        origin: paneldrive.Origin,
        deadline_ms: i64,
    ) ?paneldrive.Failure {
        if (self.validated_store_scope != null) return null;
        if (origin.source == .environment) switch (paneldrive.environmentIdentity(origin.session)) {
            .exact => |origin_id| {
                self.validated_store_scope = .{ .origin = .{
                    .daemon_origin = origin.socket,
                    .origin_id = origin_id,
                    .label = origin.session,
                } };
                return null;
            },
            .malformed => return .{
                .kind = .malformed_attach,
                .detail = "MalformedInheritedOriginId",
            },
            .none => {},
        };
        const pool = panel_pool orelse return .{
            .kind = .unsupported,
            .detail = "PanelRelayUnavailable",
        };
        const outcome = pool.identifyUntil(self.arena, origin, deadline_ms) catch return .{
            .kind = .allocation_failed,
            .detail = "OutOfMemory",
        };
        switch (outcome) {
            .identity => |identity| {
                self.validated_store_scope = .{ .origin = .{
                    .daemon_origin = identity.daemon_origin,
                    .origin_id = identity.origin_id,
                    .label = origin.session,
                } };
                return null;
            },
            .failure => |failure| {
                // A daemon with no lifetime id cannot key an exact scope, so
                // the session name is the best identity available. Anything
                // else leaves the scope unresolved rather than guessing.
                if (failure.kind == .legacy_daemon or origin.source == .default_compat)
                    self.validated_store_scope = .{ .session = origin.session };
                return failure;
            },
        }
    }

    fn relayUntil(self: *UiTransport, req: protocol.Request, deadline_ms: i64) IpcReply {
        if (self.origin == null) {
            self.origin = paneldrive.Origin.resolve(self.arena, self.session) catch {
                self.mode = .none;
                return .{ .ok = false, .value = .null, .err = UI_NEEDS_TRANSPORT };
            };
        }
        const origin = self.origin.?;
        const line = reqLine(self.arena, req) catch
            return .{ .ok = false, .value = .null, .err = "could not encode the panel request" };
        const pool = panel_pool orelse {
            self.mode = .none;
            return .{ .ok = false, .value = .null, .err = UI_NEEDS_TRANSPORT };
        };
        if (self.prepareStoreScopeUntil(origin, deadline_ms)) |failure| {
            if (self.canFallbackDirect(origin, failure)) {
                self.failure = failure;
                self.mode = .gui_socket;
                return self.directUntil(req, deadline_ms);
            }
            self.failure = failure;
            self.mode = .mux_relay;
            return .{
                .ok = false,
                .value = .null,
                .err = relayFailure(self.arena, origin, failure),
                .delivery = .pre_delivery,
            };
        }
        // The relay validated this reply against the same op on the way in:
        // `panelrpc.validateReply` runs once, in paneldrive, and a bad shape
        // arrives here as a failure rather than as a reply to re-check.
        const outcome = pool.callUntil(self.arena, origin, panelrpc.opFromCommand(req.cmd), line, deadline_ms) catch
            return .{ .ok = false, .value = .null, .err = "panel relay ran out of memory" };
        switch (outcome) {
            .reply => |reply| {
                self.mode = .mux_relay;
                const parsed = parseIpcReply(self.arena, reply.json);
                if (reply.pre_delivery and !parsed.ok) return .{
                    .ok = false,
                    .value = parsed.value,
                    .err = std.fmt.allocPrint(
                        self.arena,
                        "{s}; failure_class=pre_delivery, mutation_may_have_applied=false, resend_safe=true",
                        .{parsed.err},
                    ) catch parsed.err,
                    .delivery = .pre_delivery,
                };
                return parsed;
            },
            .failure => |failure| {
                if (self.canFallbackDirect(origin, failure)) {
                    self.failure = failure;
                    self.mode = .gui_socket;
                    return self.directUntil(req, deadline_ms);
                }
                self.failure = failure;
                self.mode = .mux_relay;
                return .{
                    .ok = false,
                    .value = .null,
                    .err = relayFailure(self.arena, origin, failure),
                    .delivery = if (failure.uncertain()) .uncertain_delivery else .pre_delivery,
                };
            },
        }
    }

    fn canFallbackDirect(_: *const UiTransport, origin: paneldrive.Origin, failure: paneldrive.Failure) bool {
        if (origin.source != .environment or srv_gui_socket_source != .explicit) return false;
        return switch (failure.kind) {
            .legacy_daemon, .unsupported, .no_compatible_gui, .attach_failed, .malformed_attach => true,
            .no_such_session => false,
            else => false,
        };
    }
};

/// Resolve the saved-panel scope, spending at most `budget_ms` on the
/// identity probe it may have to make.
fn uiStoreScope(transport: *UiTransport, budget_ms: i64) UiStoreScope {
    const session = transport.session orelse return .{ .scope = .sessionless };
    // With no exact daemon to key on, the session name is the whole identity.
    const by_session = UiStoreScope{ .scope = .{ .session = session } };

    if (transport.mode == .gui_socket and transport.origin == null and !paneldrive.hasEnvironmentSocket())
        return by_session;
    if (transport.origin == null) {
        transport.origin = paneldrive.Origin.resolve(transport.arena, session) catch |err| {
            if (!paneldrive.hasEnvironmentSocket()) return by_session;
            return .{ .err = std.fmt.allocPrint(
                transport.arena,
                "could not canonicalize the exact SKETERM_MUX_SOCKET persistence origin ({s}); refusing reusable (socket,session) storage",
                .{@errorName(err)},
            ) catch "could not canonicalize the exact persistence origin; refusing reusable storage" };
        };
    }
    const origin = transport.origin.?;
    if (transport.validated_store_scope) |scope| return .{ .scope = scope };
    if (origin.source == .default_compat and (panel_pool == null or transport.mode == .none))
        return by_session;

    // An inherited $SKETERM_MUX_SOCKET names one exact daemon. If its lifetime
    // identity cannot be established, say so instead of silently writing into
    // the (socket, session) namespace a later same-name session would share.
    const failure = transport.failure orelse
        transport.prepareStoreScopeUntil(origin, clock.nowMs() + @max(budget_ms, 0));
    if (transport.validated_store_scope) |scope| return .{ .scope = scope };
    if (origin.source != .environment) return by_session;
    if (failure) |f| return .{ .err = uiStoreFailure(transport.arena, origin, f) };
    return .{
        .err = "exact saved-panel identity validation completed without a scope; refusing to downgrade to reusable (socket,session) storage",
    };
}

fn uiStoreFailure(arena: std.mem.Allocator, origin: paneldrive.Origin, failure: paneldrive.Failure) []const u8 {
    const reason: []const u8 = switch (failure.kind) {
        // A legacy daemon always retains a by-session scope in
        // `prepareStoreScopeUntil`, so it can only reach this switch as the
        // same "no compatible exact identity" story `unsupported` tells.
        .legacy_daemon, .unsupported => "the daemon cannot expose a compatible exact lifetime identity",
        .no_compatible_gui => "no compatible GUI was available before exact identity validation",
        .no_such_session => "the exact session is no longer present",
        .origin_unreachable => "the exact daemon is unreachable",
        .origin_timeout => "exact daemon identity validation timed out",
        .attach_failed => "the exact session attach failed",
        .identity_mismatch => "the session lifetime identity does not match",
        .malformed_attach => "the inherited or attached session lifetime identity is malformed",
        .malformed_welcome => "the daemon capability welcome is malformed",
        .request_too_large => "identity validation reported an impossible oversized request",
        .allocation_failed => "identity validation ran out of memory",
        .send_pre_delivery => "identity validation transport failed before delivery",
        .delivery_uncertain => "identity validation delivery is uncertain",
        .reply_timeout => "identity validation reply timed out after delivery",
        .disconnected => "identity validation disconnected after delivery",
        .malformed_reply => "identity validation received a malformed reply after delivery",
    };
    return std.fmt.allocPrint(
        arena,
        "saved-panel persistence scope for exact origin {s} session {s} is unavailable: {s} ({s}: {s}); refusing to downgrade to reusable (socket,session) storage",
        .{ origin.socket, origin.session, reason, @tagName(failure.kind), failure.detail },
    ) catch "saved-panel exact persistence identity is unavailable; refusing reusable (socket,session) storage";
}

fn relayFailure(arena: std.mem.Allocator, origin: paneldrive.Origin, failure: paneldrive.Failure) []const u8 {
    return switch (failure.kind) {
        .legacy_daemon, .unsupported => std.fmt.allocPrint(
            arena,
            "the origin mux daemon does not support panel relay ({s}); update it, or use an explicit direct GUI --socket for legacy operation",
            .{failure.detail},
        ) catch "the origin mux daemon does not support panel relay",
        .no_compatible_gui => std.fmt.allocPrint(
            arena,
            "no compatible GUI is attached to origin session {s}; the request failed before presenter delivery",
            .{origin.session},
        ) catch "no compatible GUI is attached to the origin session",
        .no_such_session => std.fmt.allocPrint(
            arena,
            "origin session {s} is no longer present on its exact daemon ({s})",
            .{ origin.session, failure.detail },
        ) catch "the exact origin session is no longer present",
        .origin_unreachable => std.fmt.allocPrint(
            arena,
            "the origin mux daemon at {s} is unavailable ({s}). It was selected exactly and was not autostarted or replaced, so the MCP private app daemon remains isolated",
            .{ origin.socket, failure.detail },
        ) catch "the origin mux daemon is unavailable",
        .origin_timeout => std.fmt.allocPrint(
            arena,
            "the origin mux daemon at {s} did not complete identity negotiation before the deadline ({s}); it was selected exactly and no replacement was used",
            .{ origin.socket, failure.detail },
        ) catch "the exact origin mux daemon identity negotiation timed out",
        .attach_failed => std.fmt.allocPrint(
            arena,
            "the origin daemon refused a panel-only attachment to session {s} ({s}); the session may have ended",
            .{ origin.session, failure.detail },
        ) catch "the origin daemon refused the panel attachment",
        .identity_mismatch => std.fmt.allocPrint(
            arena,
            "the origin daemon refused session {s} because its lifetime identity changed ({s}); this is a same-name replacement and direct GUI fallback is forbidden",
            .{ origin.session, failure.detail },
        ) catch "the origin session lifetime identity changed; direct fallback is forbidden",
        .malformed_attach => std.fmt.allocPrint(
            arena,
            "the exact origin has malformed inherited or panel-only attachment identity ({s}); immutable origin_name plus lifetime-unique origin_id are required and no requested-alias substitute was used",
            .{failure.detail},
        ) catch "the exact origin has malformed lifetime identity metadata",
        .malformed_welcome => std.fmt.allocPrint(
            arena,
            "the origin daemon returned malformed capability negotiation ({s}); it was not classified as a legacy daemon and no fallback identity was assumed",
            .{failure.detail},
        ) catch "the origin daemon returned malformed capability negotiation",
        .request_too_large, .allocation_failed, .send_pre_delivery => std.fmt.allocPrint(
            arena,
            "the mux panel request failed before any request bytes were delivered ({s}: {s}); failure_class=pre_delivery, mutation_may_have_applied=false, resend_safe=true",
            .{ @tagName(failure.kind), failure.detail },
        ) catch "the mux panel request failed before delivery; resend_safe=true",
        .delivery_uncertain, .reply_timeout, .disconnected, .malformed_reply => std.fmt.allocPrint(
            arena,
            "the mux panel request failed after delivery became uncertain ({s}: {s}); the mutation may have applied and it was NOT resent automatically. Do not resend it automatically",
            .{ @tagName(failure.kind), failure.detail },
        ) catch "the mux panel request failed after uncertain delivery; the mutation may have applied and it was not resent",
    };
}

fn directFailureMessage(arena: std.mem.Allocator, command: []const u8, failure: DirectTalkFailure) []const u8 {
    if (failure.delivery == .pre_delivery) return std.fmt.allocPrint(
        arena,
        "the direct GUI request failed before any request bytes were written ({s}); failure_class=pre_delivery, mutation_may_have_applied=false, resend_safe=true",
        .{@errorName(failure.err)},
    ) catch "the direct GUI request failed before delivery; resend_safe=true";
    if (std.mem.eql(u8, command, "panel-events")) return std.fmt.allocPrint(
        arena,
        "the direct GUI panel-events request was partially or fully written but its reply was lost ({s}); failure_class=uncertain_delivery, events_may_have_been_drained=true, resend_safe=false. Events may have been drained by the lost reply; the request was NOT retried automatically",
        .{@errorName(failure.err)},
    ) catch "the direct GUI event reply was lost; events may have been drained and the request was not retried";
    const mutation = std.mem.eql(u8, command, "panel-show") or
        std.mem.eql(u8, command, "panel-patch") or
        std.mem.eql(u8, command, "panel-close");
    if (mutation) return std.fmt.allocPrint(
        arena,
        "the direct GUI mutation was partially or fully written but its reply was lost ({s}); failure_class=uncertain_delivery, mutation_may_have_applied=true, resend_safe=false. The request was NOT retried automatically",
        .{@errorName(failure.err)},
    ) catch "the direct GUI mutation reply was lost after delivery became uncertain; the request was not retried";
    return std.fmt.allocPrint(
        arena,
        "the direct GUI request was partially or fully written but its reply was lost ({s}); failure_class=uncertain_delivery, resend_safe=false. The request was NOT retried automatically",
        .{@errorName(failure.err)},
    ) catch "the direct GUI reply was lost after delivery became uncertain; the request was not retried";
}

/// A failed panel round trip as a typed error. The message is the
/// transport's own (it names the exact origin, session and phase);
/// only the CODE is derived here, from the delivery phase and the
/// vocabulary `relayFailure`/`UI_NEEDS_TRANSPORT` speak.
fn uiFailCode(reply: IpcReply) ErrCode {
    return switch (reply.delivery) {
        .pre_delivery => .unavailable,
        .uncertain_delivery => .io_failed,
        .ordinary => if (std.mem.indexOf(u8, reply.err, "no longer present") != null or
            std.mem.indexOf(u8, reply.err, "no such") != null or
            std.mem.indexOf(u8, reply.err, "not live") != null)
            .not_found
        else if (std.mem.indexOf(u8, reply.err, "no live panel transport") != null or
            std.mem.indexOf(u8, reply.err, "unavailable") != null or
            std.mem.indexOf(u8, reply.err, "no compatible GUI") != null or
            std.mem.indexOf(u8, reply.err, "does not support panel relay") != null)
            .unavailable
        else
            .failed,
    };
}

fn uiTransportErr(arena: std.mem.Allocator, reply: IpcReply) ![]const u8 {
    return errRes(arena, uiFailCode(reply), reply.err);
}

/// The one shape `ui_wait_event` answers with, whether it timed out or
/// carried interactions: the events are machine facts, and the text
/// lane is one line per interaction. A timeout is a FACT, never a tool
/// error — the panel is still showing.
fn uiEventsResult(
    arena: std.mem.Allocator,
    panel_id: u32,
    waited_ms: i64,
    events: ?std.json.Value,
    dropped: i64,
    timeout_ms: i64,
) ![]const u8 {
    var res = Res.init(arena);
    try res.fact("panel_id", panel_id);
    try res.fact("waited_ms", waited_ms);
    try res.fact("dropped", dropped);

    const items: []const std.json.Value = if (events) |e|
        (if (e == .array) e.array.items else &.{})
    else
        &.{};
    if (events) |e| {
        var aw: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(e, .{}, &aw.writer);
        try res.raw("events", aw.written());
    } else try res.raw("events", "[]");
    try res.fact("count", items.len);
    try res.fact("timed_out", items.len == 0);

    if (items.len == 0)
        try res.textf("no interaction within {d}ms — the panel is still showing; wait again or ui_patch it", .{timeout_ms})
    else
        try res.textf("{d} interaction(s) after {d}ms", .{ items.len, waited_ms });
    if (dropped > 0)
        try res.textf("the panel's event queue overflowed and {d} OLDER interaction(s) were discarded; this reply is not the complete history", .{dropped});
    if (items.len > 0) {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        for (items, 0..) |ev, i| {
            if (i > 0) try w.writeAll("\n");
            try w.print("{d} {s} {s}", .{ objInt(ev, "seq"), objStr(ev, "kind"), objStr(ev, "component") });
            const v = if (ev == .object) ev.object.get("value") else null;
            if (v) |value| switch (value) {
                .null => {},
                .string => |sv| try w.print(" = {s}", .{sv}),
                .bool => |bv| try w.print(" = {}", .{bv}),
                .integer => |iv| try w.print(" = {d}", .{iv}),
                .float => |fv| try w.print(" = {d}", .{fv}),
                else => {},
            };
        }
        try res.textf("--- events ---\n{s}", .{aw.written()});
    }
    return res.finish();
}

/// A panel that could not be ADDRESSED: a bad handle is the caller's
/// argument, an unknown name is a missing panel, and anything else
/// came from the transport that answered the lookup.
fn uiResolveErr(arena: std.mem.Allocator, target: UiResolved) ![]const u8 {
    const code: ErrCode = if (std.mem.indexOf(u8, target.err, "panel_id must be") != null or
        std.mem.indexOf(u8, target.err, "address the panel by") != null)
        .invalid_args
    else if (std.mem.indexOf(u8, target.err, "no LIVE panel named") != null)
        .not_found
    else if (std.mem.indexOf(u8, target.err, "deadline expired") != null)
        .timeout
    else
        uiFailCode(.{ .ok = false, .value = .null, .err = target.err });
    return errRes(arena, code, target.err);
}

/// An argument that may be given either as a JSON value (the natural
/// way for an assistant to write a document) or as a JSON string (the
/// way the control socket carries it). Returns the raw JSON text.
fn uiJsonArg(arena: std.mem.Allocator, args: std.json.Value, key: []const u8) !?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .null => null,
        .string => |s| s,
        else => blk: {
            var aw: std.Io.Writer.Allocating = .init(arena);
            std.json.Stringify.value(v, .{}, &aw.writer) catch return error.OutOfMemory;
            break :blk aw.written();
        },
    };
}

/// One IPC round-trip whose transport failure is a described error
/// rather than a JSON-RPC fault — a GUI that went away mid-flow is a
/// normal thing for an assistant to be told about.
fn uiTalk(transport: *UiTransport, req: protocol.Request) IpcReply {
    return transport.talk(req);
}

const UiResolved = struct {
    id: u32 = 0,
    /// Non-empty when the panel could not be addressed.
    err: []const u8 = "",
};

/// Resolve `panel_id`, or look a `name` up in the session's live
/// panels. Name is the stable address; panel_id is what ui_show hands
/// back and what the control socket speaks.
fn uiResolve(
    arena: std.mem.Allocator,
    transport: *UiTransport,
    args: std.json.Value,
    session: ?[]const u8,
) UiResolved {
    return uiResolveFor(arena, transport, args, session, UI_RELAY_CALL_MS);
}

fn uiResolveFor(
    arena: std.mem.Allocator,
    transport: *UiTransport,
    args: std.json.Value,
    session: ?[]const u8,
    timeout_ms: i64,
) UiResolved {
    if (argInt(args, "panel_id")) |pid| {
        if (pid <= 0 or pid > std.math.maxInt(u32))
            return .{ .err = "panel_id must be a positive integer (the handle ui_show returned)" };
        return .{ .id = @intCast(pid) };
    }
    const name = argStr(args, "name") orelse
        return .{ .err = "address the panel by 'name' (stable, preferred) or by 'panel_id'" };

    if (timeout_ms <= 0) return .{ .err = "ui_wait_event's deadline expired while resolving the panel" };
    const reply = transport.talkFor(.{ .cmd = "panel-list", .session = uiWireSession(session) }, timeout_ms);
    if (!reply.ok) return .{ .err = reply.err };
    const panels = reply.value.object.get("panels") orelse
        return .{ .err = "malformed panel-list reply" };
    if (panels == .array) {
        for (panels.array.items) |p| {
            if (p != .object) continue;
            const n = p.object.get("name") orelse continue;
            if (n != .string or !std.mem.eql(u8, n.string, name)) continue;
            const idv = p.object.get("panel_id") orelse continue;
            if (idv == .integer and idv.integer > 0) return .{ .id = @intCast(idv.integer) };
        }
    }
    return .{ .err = std.fmt.allocPrint(
        arena,
        "no LIVE panel named \"{s}\" in session {s}. `ui_panels` lists what is on screen and what is saved; `ui_show` opens one (with load=\"{s}\" if it is saved).",
        .{ name, panelstore.sessionLabel(session), name },
    ) catch "no live panel with that name" };
}

/// The live document behind a panel, canonically serialized, straight
/// from the GUI's own `doc.Document`. Any panel is readable this way —
/// including one another process showed, or one shown before this
/// server started.
fn uiLiveDocument(
    transport: *UiTransport,
    id: u32,
    session: ?[]const u8,
) struct { json: []const u8 = "", err: []const u8 = "" } {
    const reply = uiTalk(transport, .{
        .cmd = "panel-get",
        .panel_id = id,
        .session = uiWireSession(session),
    });
    if (!reply.ok) return .{ .err = reply.err };
    const dv = reply.value.object.get("document") orelse
        return .{ .err = "panel-get answered without a document" };
    if (dv != .string) return .{ .err = "panel-get answered with a malformed document" };
    return .{ .json = dv.string };
}

/// The remote-image hydration report the GUI attaches to a panel
/// mutation: facts in structuredContent, and ONE situational text line
/// when something failed (a placeholder the user will see).
fn addUiAssetFacts(res: *Res, arena: std.mem.Allocator, reply: IpcReply) !void {
    if (reply.value != .object) return;
    const report = reply.value.object.get("assets") orelse return;
    if (report != .array) return;
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(report, .{}, &aw.writer);
    try res.raw("assets", aw.written());
    const failures = reply.value.object.get("asset_failures");
    if (failures == null or failures.? != .integer) return;
    try res.fact("asset_failures", failures.?.integer);
    if (failures.?.integer > 0)
        try res.textf(
            "{d} remote image(s) could not be hydrated; the panel shows explicit placeholders and each failed logical path is listed in assets",
            .{failures.?.integer},
        );
}

/// panelstore failure → the store's own diagnostic (which names the
/// offending panel or component) with the tool-level next step added.
fn uiStoreErr(
    arena: std.mem.Allocator,
    err: panelstore.Error,
    diag: *const paneldoc.Diag,
    what: []const u8,
) ![]const u8 {
    const detail = if (diag.len > 0) diag.msg() else @errorName(err);
    const hint: []const u8 = switch (err) {
        error.NotFound => " — `ui_panels` lists the saved documents in this session",
        error.Corrupt => " — the stored file no longer parses; re-save it with ui_save",
        error.Invalid => " — fix the document and re-send; nothing was written",
        error.TooMany => " — delete one with ui_delete",
        else => "",
    };
    const msg = std.fmt.allocPrint(arena, "{s}: {s}{s}", .{ what, detail, hint }) catch
        return error.OutOfMemory;
    return errRes(arena, uiStoreErrCode(err), msg);
}

/// A panelstore refusal as one of the shared codes.
fn uiStoreErrCode(err: panelstore.Error) ErrCode {
    return switch (err) {
        error.NotFound => .not_found,
        error.Invalid => .invalid_args,
        error.TooMany => .conflict,
        else => .io_failed,
    };
}

fn uiStoreMutationErr(
    arena: std.mem.Allocator,
    err: panelstore.Error,
    diag: *const paneldoc.Diag,
    what: []const u8,
    mutation: []const u8,
) ![]const u8 {
    const detail = if (diag.len > 0) diag.msg() else @errorName(err);
    const hint: []const u8 = switch (err) {
        error.NotFound => " — `ui_panels` lists the saved documents in this session",
        error.Invalid => " — fix the document and re-send; nothing was written",
        error.TooMany => " — delete one with ui_delete",
        else => "",
    };
    // Store mutations are staged then renamed, so a failure never leaves a
    // partial document: it either happened or it did not. That verdict is
    // stated the way every other panel failure states it — as prose the
    // assistant reads, in the same key=value spelling.
    const message = std.fmt.allocPrint(
        arena,
        "{s}: {s}{s} ({s}); mutation={s}, failure_class=pre_commit, mutation_state=not_applied, mutation_may_have_applied=false, committed=false, resend_safe=true",
        .{ what, detail, hint, @errorName(err), mutation },
    ) catch return error.OutOfMemory;
    return errRes(arena, uiStoreErrCode(err), message);
}

fn uiTool(arena: std.mem.Allocator, backend: Backend, name: []const u8, args: std.json.Value) ![]const u8 {
    const eql = std.mem.eql;
    const session = uiSession(args) catch
        return errRes(arena, .invalid_args, "'session' must be a string when present; omit it to use SKETERM_SESSION, or pass an explicit empty string for sessionless scope");
    var transport = UiTransport.init(arena, backend, session);
    defer transport.deinit();

    if (eql(u8, name, "ui_show")) {
        const panel_name = argStr(args, "name") orelse
            return errRes(arena, .invalid_args, "ui_show requires 'name' (the panel's identity in this session)");
        const inline_doc = try uiJsonArg(arena, args, "document");
        const load_name = argStr(args, "load");
        if (inline_doc != null and load_name != null)
            return errRes(arena, .invalid_args, "pass either 'document' (an inline document) or 'load' (a saved one), not both");

        var diag = paneldoc.Diag{};
        const document = inline_doc orelse blk: {
            const saved = load_name orelse
                return errRes(arena, .invalid_args, "ui_show requires 'document' (the panel to render) or 'load' (the name of a document saved with ui_save)");
            const store = uiStoreScope(&transport, UI_RELAY_CALL_MS);
            if (store.err.len > 0) return errRes(arena, .unavailable, store.err);
            break :blk panelstore.loadJsonScoped(arena, store.scope, saved, &diag) catch |err|
                return uiStoreErr(arena, err, &diag, "ui_show could not load the saved panel");
        };

        const target = argStr(args, "target") orelse "tab";
        const reply = uiTalk(&transport, .{
            .cmd = "panel-show",
            .name = panel_name,
            .session = uiWireSession(session),
            .target = target,
            .document = document,
        });
        // A rejected document answers with doc.Diag's own message,
        // VERBATIM: it names the offending component id, and that text
        // is how the assistant fixes what it wrote.
        if (!reply.ok) return uiTransportErr(arena, reply);

        const pid = reply.value.object.get("panel_id");
        const id: i64 = if (pid) |p| (if (p == .integer) p.integer else 0) else 0;

        var res = Res.init(arena);
        try res.fact("panel_id", id);
        try res.fact("name", panel_name);
        try res.fact("session", session);
        try res.fact("target", target);
        try res.fact("showing", true);
        try res.textf("showing panel {s} (id {d}) in session {s} as {s}", .{
            panel_name, id, panelstore.sessionLabel(session), target,
        });
        try addUiAssetFacts(&res, arena, reply);
        return res.finish();
    }

    // A document GENERATOR over the exact path ui_show uses: it builds
    // the document server-side and hands it to the same panel-show.
    // There is no second rendering path, no new component and no new
    // control command here, deliberately.
    if (eql(u8, name, "ui_show_files")) {
        const files_v = if (args == .object) args.object.get("files") else null;
        const items = blk: {
            const v = files_v orelse
                return errRes(arena, .invalid_args, "ui_show_files requires 'files': a list of absolute image paths, or {path, caption} objects");
            if (v != .array or v.array.items.len == 0)
                return errRes(arena, .invalid_args, "'files' must be a NON-EMPTY array of absolute image paths (or {path, caption} objects)");
            break :blk v.array.items;
        };
        if (items.len > UI_FILES_MAX) {
            const msg = std.fmt.allocPrint(
                arena,
                "ui_show_files shows at most {d} files at once and got {d} — show a subset (the user can be sent the next batch by re-calling with the same 'name'), or author a paged panel with ui_show.",
                .{ UI_FILES_MAX, items.len },
            ) catch return error.OutOfMemory;
            return errRes(arena, .invalid_args, msg);
        }
        const compare = argBool(args, "compare");
        if (compare and items.len != 2) {
            const msg = std.fmt.allocPrint(
                arena,
                "compare:true draws ONE A/B slider between exactly two images, and 'files' has {d}. Pass exactly two files, or drop 'compare' to stack them as separate images.",
                .{items.len},
            ) catch return error.OutOfMemory;
            return errRes(arena, .invalid_args, msg);
        }

        const files = arena.alloc(UiFile, items.len) catch return error.OutOfMemory;
        var unreadable: std.ArrayList([]const u8) = .empty;
        for (items, 0..) |item, i| {
            const path: []const u8 = switch (item) {
                .string => |s| s,
                .object => |o| pblk: {
                    const pv = o.get("path") orelse {
                        const msg = std.fmt.allocPrint(arena, "files[{d}] has no \"path\"", .{i}) catch
                            return error.OutOfMemory;
                        return errRes(arena, .invalid_args, msg);
                    };
                    if (pv != .string) {
                        const msg = std.fmt.allocPrint(arena, "files[{d}].path must be a string", .{i}) catch
                            return error.OutOfMemory;
                        return errRes(arena, .invalid_args, msg);
                    }
                    break :pblk pv.string;
                },
                else => {
                    const msg = std.fmt.allocPrint(
                        arena,
                        "files[{d}] must be an absolute path string or a {{path, caption}} object",
                        .{i},
                    ) catch return error.OutOfMemory;
                    return errRes(arena, .invalid_args, msg);
                },
            };
            if (!paneldoc.validImagePath(path)) {
                const msg = std.fmt.allocPrint(
                    arena,
                    "files[{d}]: \"{s}\" must be an ABSOLUTE path with no \"..\" segment and no control characters (panels are persisted and re-opened later, so paths are constrained structurally)",
                    .{ i, path },
                ) catch return error.OutOfMemory;
                return errRes(arena, .invalid_args, msg);
            }
            var caption: []const u8 = std.fs.path.basename(path);
            if (item == .object) {
                if (item.object.get("caption")) |cv| {
                    if (cv != .string) {
                        const msg = std.fmt.allocPrint(arena, "files[{d}].caption must be a string", .{i}) catch
                            return error.OutOfMemory;
                        return errRes(arena, .invalid_args, msg);
                    }
                    caption = cv.string;
                }
            }
            if (caption.len > paneldoc.MAX_TEXT) {
                const msg = std.fmt.allocPrint(
                    arena,
                    "files[{d}].caption is longer than {d} characters",
                    .{ i, paneldoc.MAX_TEXT },
                ) catch return error.OutOfMemory;
                return errRes(arena, .invalid_args, msg);
            }
            files[i] = .{ .path = path, .caption = caption };

            // Readability is checked HERE rather than left to the
            // renderer's placeholder: a placeholder is right for the
            // one image that vanished mid-training, but a panel made
            // entirely of them is a typo the assistant must be told
            // about, not shown to the user.
            const z = std.fmt.allocPrintSentinel(arena, "{s}", .{path}, 0) catch
                return error.OutOfMemory;
            if (c.access(z.ptr, c.R_OK) != 0)
                unreadable.append(arena, path) catch return error.OutOfMemory;
        }

        if (unreadable.items.len == items.len) {
            var aw: std.Io.Writer.Allocating = .init(arena);
            const w = &aw.writer;
            try w.print(
                "none of the {d} file(s) can be read, so nothing was shown (a panel of nothing but placeholders would only look broken). Check the paths:",
                .{items.len},
            );
            for (unreadable.items, 0..) |p, i| {
                if (i >= 5) {
                    try w.print(" … and {d} more", .{unreadable.items.len - i});
                    break;
                }
                try w.print(" {s}", .{p});
            }
            return errRes(arena, .invalid_args, aw.written());
        }

        const title = argStr(args, "title") orelse "";
        const document = uiFilesDocument(arena, files, title, compare) catch
            return error.OutOfMemory;
        // The generator's own output is validated before it leaves:
        // an invalid document must never reach the GUI as an opaque
        // rejection of something the assistant did not write.
        var gen_diag = paneldoc.Diag{};
        var checked = paneldoc.Document.parse(arena, document, &gen_diag) catch |err| {
            const msg = std.fmt.allocPrint(
                arena,
                "ui_show_files built a document its own parser rejected ({s}: {s}) — that is a sketerm bug; ui_show with a hand-written document still works",
                .{ @errorName(err), gen_diag.msg() },
            ) catch return error.OutOfMemory;
            return errRes(arena, .invalid_args, msg);
        };
        checked.deinit();

        const panel_name = argStr(args, "name") orelse UI_FILES_NAME;
        const target = argStr(args, "target") orelse "tab";
        const reply = uiTalk(&transport, .{
            .cmd = "panel-show",
            .name = panel_name,
            .session = uiWireSession(session),
            .target = target,
            .document = document,
        });
        if (!reply.ok) return uiTransportErr(arena, reply);
        const pid = reply.value.object.get("panel_id");
        const id: i64 = if (pid) |p| (if (p == .integer) p.integer else 0) else 0;

        const layout: []const u8 = if (compare) "image_compare" else "stacked_images";
        var res = Res.init(arena);
        try res.fact("panel_id", id);
        try res.fact("name", panel_name);
        try res.fact("session", session);
        try res.fact("target", target);
        try res.fact("files", files.len);
        try res.fact("layout", layout);
        try res.fact("showing", true);
        try res.textf("showing {d} image(s) as {s} in panel {s} (id {d})", .{
            files.len, layout, panel_name, id,
        });
        if (unreadable.items.len > 0) {
            try res.fact("unreadable", unreadable.items);
            try res.textf(
                "{d} of {d} file(s) could not be read; they are drawn as an explicit placeholder in the panel, the rest render normally",
                .{ unreadable.items.len, files.len },
            );
        }
        try addUiAssetFacts(&res, arena, reply);
        return res.finish();
    }

    if (eql(u8, name, "ui_patch")) {
        const patch = (try uiJsonArg(arena, args, "patch")) orelse
            return errRes(arena, .invalid_args, "ui_patch requires 'patch' (a JSON array of ops)");
        const target = uiResolve(arena, &transport, args, session);
        if (target.err.len > 0) return uiResolveErr(arena, target);
        const reply = uiTalk(&transport, .{
            .cmd = "panel-patch",
            .panel_id = target.id,
            .patch = patch,
            .session = uiWireSession(session),
        });
        if (!reply.ok) return uiTransportErr(arena, reply);
        var res = Res.init(arena);
        try res.fact("panel_id", target.id);
        try res.fact("patched", true);
        try res.textf("patched panel {d}", .{target.id});
        try addUiAssetFacts(&res, arena, reply);
        return res.finish();
    }

    if (eql(u8, name, "ui_wait_event")) {
        const asked: i64 = argInt(args, "timeout_ms") orelse UI_WAIT_DEFAULT_MS;
        const timeout_ms = @min(@max(asked, 0), WAIT_CAP_MS);
        // One budget includes name resolution, every poll round trip, and
        // sleeps. A slow presenter cannot multiply timeout_ms by poll count.
        const start = backend.nowMs(backend.ctx);
        const deadline = start + timeout_ms;
        const target = uiResolveFor(arena, &transport, args, session, deadline - backend.nowMs(backend.ctx));
        if (target.err.len > 0) return uiResolveErr(arena, target);

        // The GUI answers panel-events immediately (it runs on the main
        // loop and must never block), so the WAIT is ours: poll until
        // something is queued or the budget runs out.
        var dropped_total: i64 = 0;
        while (true) {
            const before_poll = backend.nowMs(backend.ctx);
            const remain = deadline - before_poll;
            if (remain <= 0)
                return uiEventsResult(arena, target.id, before_poll - start, null, dropped_total, timeout_ms);
            const reply = transport.talkFor(.{
                .cmd = "panel-events",
                .panel_id = target.id,
                .session = uiWireSession(session),
            }, remain);
            if (!reply.ok) {
                if (reply.delivery == .uncertain_delivery) {
                    const msg = std.fmt.allocPrint(
                        arena,
                        "the panel-events request may have drained queued interactions before its reply was lost ({s}). Events may have been drained; failure_class=uncertain_delivery, events_may_have_been_drained=true, resend_safe=false. The poll was NOT retried automatically",
                        .{reply.err},
                    ) catch return error.OutOfMemory;
                    return errRes(arena, .io_failed, msg);
                }
                if (reply.delivery == .pre_delivery) {
                    const msg = std.fmt.allocPrint(
                        arena,
                        "the panel-events poll was unavailable before presenter delivery ({s}); failure_class=pre_delivery, events_may_have_been_drained=false, resend_safe=true. The panel's open/closed state and queued events are UNKNOWN; retry when a compatible GUI is attached",
                        .{reply.err},
                    ) catch return error.OutOfMemory;
                    return errRes(arena, .unavailable, msg);
                }
                const msg = std.fmt.allocPrint(
                    arena,
                    "the GUI presenter confirmed that this panel is not live ({s}); it may have been closed by the user or the id may never have existed",
                    .{reply.err},
                ) catch return error.OutOfMemory;
                return errRes(arena, .not_found, msg);
            }
            if (reply.value.object.get("dropped")) |d| {
                if (d == .integer) dropped_total += d.integer;
            }
            const evs = reply.value.object.get("events");
            const count: usize = if (evs) |e| (if (e == .array) e.array.items.len else 0) else 0;
            const elapsed = backend.nowMs(backend.ctx) - start;
            if (count > 0 or elapsed >= timeout_ms)
                return uiEventsResult(arena, target.id, elapsed, if (count > 0) evs.? else null, dropped_total, timeout_ms);
            const sleep_remain = deadline - backend.nowMs(backend.ctx);
            if (sleep_remain > 0)
                backend.sleepMs(backend.ctx, @intCast(@min(@as(i64, UI_POLL_MS), sleep_remain)));
        }
    }

    if (eql(u8, name, "ui_panels")) {
        var res = Res.init(arena);
        try res.fact("session", session);
        var text: std.Io.Writer.Allocating = .init(arena);
        const tw = &text.writer;

        const reply = uiTalk(&transport, .{ .cmd = "panel-list", .session = uiWireSession(session) });
        if (!reply.ok) {
            try res.raw("live", "null");
            try res.fact("live_error", reply.err);
            try res.textf("live: unavailable ({s})", .{reply.err});
        } else {
            const panels = reply.value.object.get("panels");
            const items: []const std.json.Value =
                if (panels != null and panels.? == .array) panels.?.array.items else &.{};
            var aw: std.Io.Writer.Allocating = .init(arena);
            if (panels != null and panels.? == .array)
                try std.json.Stringify.value(panels.?, .{}, &aw.writer)
            else
                try aw.writer.writeAll("[]");
            try res.raw("live", aw.written());
            try res.fact("live_count", items.len);
            try res.textf("live: {d} panel(s)", .{items.len});
            for (items) |p| {
                try tw.print("\nlive {d} {s}", .{ objInt(p, "panel_id"), objStr(p, "name") });
                const title = objStr(p, "title");
                if (title.len > 0) try tw.print("  {s}", .{title});
            }
        }

        const store = uiStoreScope(&transport, UI_RELAY_CALL_MS);
        if (store.err.len > 0) {
            try res.raw("saved", "null");
            try res.fact("saved_error", store.err);
            try res.textf("saved: unavailable ({s})", .{store.err});
        } else if (panelstore.listScoped(arena, store.scope)) |entries| {
            var aw: std.Io.Writer.Allocating = .init(arena);
            const w = &aw.writer;
            try w.writeAll("[");
            for (entries, 0..) |e, i| {
                if (i > 0) try w.writeAll(",");
                try w.writeAll("{\"name\":");
                try std.json.Stringify.value(e.name, .{}, w);
                try w.writeAll(",\"title\":");
                try std.json.Stringify.value(e.title, .{}, w);
                try w.print(",\"bytes\":{d},\"mtime\":{d},\"parses\":{}}}", .{ e.bytes, e.mtime, e.ok });
                try tw.print("\nsaved {s}  {d} bytes", .{ e.name, e.bytes });
                if (e.title.len > 0) try tw.print("  {s}", .{e.title});
                if (!e.ok) try tw.writeAll("  (does NOT parse)");
            }
            try w.writeAll("]");
            try res.raw("saved", aw.written());
            try res.fact("saved_count", entries.len);
            try res.textf("saved: {d} document(s)", .{entries.len});
        } else |err| {
            try res.raw("saved", "null");
            try res.fact("saved_error", @errorName(err));
            try res.textf("saved: unavailable ({s})", .{@errorName(err)});
        }
        if (text.written().len > 0) try res.textf("--- panels ---{s}", .{text.written()});
        return res.finish();
    }

    if (eql(u8, name, "ui_save")) {
        const panel_name = argStr(args, "name") orelse
            return errRes(arena, .invalid_args, "ui_save requires 'name' (what to save it as)");
        var diag = paneldoc.Diag{};
        // No document: read the LIVE one back from the GUI. That works
        // for ANY panel on screen — including one another process
        // showed — because the GUI's registry is the only copy.
        const document = (try uiJsonArg(arena, args, "document")) orelse blk: {
            if (transport.mode == .none) return errRes(arena, .unavailable, UI_SAVE_NEEDS_TRANSPORT);
            const target = uiResolve(arena, &transport, args, session);
            if (target.err.len > 0) return uiResolveErr(arena, target);
            const live = uiLiveDocument(&transport, target.id, session);
            if (live.err.len > 0) return errRes(arena, .unavailable, live.err);
            break :blk live.json;
        };
        const store = uiStoreScope(&transport, UI_RELAY_CALL_MS);
        if (store.err.len > 0) return errRes(arena, .unavailable, store.err);
        const canonical_bytes = panelstore.saveJsonScoped(arena, store.scope, panel_name, document, &diag) catch |err|
            return uiStoreMutationErr(arena, err, &diag, "ui_save refused to store the panel", "save");
        var res = Res.init(arena);
        try res.fact("saved", panel_name);
        try res.fact("session", session);
        try res.fact("bytes", canonical_bytes);
        try res.textf("saved {s} in session {s}: {d} canonical bytes on disk", .{
            panel_name, panelstore.sessionLabel(session), canonical_bytes,
        });
        return res.finish();
    }

    if (eql(u8, name, "ui_close")) {
        const target = uiResolve(arena, &transport, args, session);
        if (target.err.len > 0) return uiResolveErr(arena, target);
        const reply = uiTalk(&transport, .{
            .cmd = "panel-close",
            .panel_id = target.id,
            .session = uiWireSession(session),
        });
        if (!reply.ok) return uiTransportErr(arena, reply);
        var res = Res.init(arena);
        try res.fact("panel_id", target.id);
        try res.fact("closed", true);
        try res.textf("closed panel {d}", .{target.id});
        return res.finish();
    }

    if (eql(u8, name, "ui_delete")) {
        const panel_name = argStr(args, "name") orelse
            return errRes(arena, .invalid_args, "ui_delete requires 'name' (the SAVED panel to delete)");
        var diag = paneldoc.Diag{};
        const store = uiStoreScope(&transport, UI_RELAY_CALL_MS);
        if (store.err.len > 0) return errRes(arena, .unavailable, store.err);
        panelstore.deleteScoped(arena, store.scope, panel_name, &diag) catch |err|
            return uiStoreMutationErr(arena, err, &diag, "ui_delete could not delete the saved panel", "delete");
        var res = Res.init(arena);
        try res.fact("deleted", panel_name);
        try res.fact("session", session);
        try res.textf("deleted the saved document {s} in session {s}", .{
            panel_name, panelstore.sessionLabel(session),
        });
        return res.finish();
    }

    return errRes(arena, .unknown_tool, "unknown ui tool");
}

/// Screenshot one GUI pane. The GUI renders the PNG to a temp file (its
/// control protocol is line-JSON), which is read back and returned as an
/// inline image. Shared by `screenshot_pane` and `web_screenshot`.
pub fn paneScreenshot(arena: std.mem.Allocator, backend: Backend, pane: ?u32) ![]const u8 {
    const png = switch (try paneScreenshotPng(arena, backend, pane)) {
        .err => |e| return errRes(arena, .io_failed, e),
        .png => |bytes| bytes,
    };
    var res = Res.init(arena);
    try addPane(&res, pane);
    try res.fact("bytes", png.len);
    if (pngSize(png)) |s| {
        try res.fact("width", s.w);
        try res.fact("height", s.h);
        try res.textf("terminal pane screenshot, {d}x{d}", .{ s.w, s.h });
    } else try res.text("terminal pane screenshot");
    return res.finishWithImages(&.{png}, &.{"pane"});
}

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

fn callTool(arena: std.mem.Allocator, backend: Backend, name: []const u8, args: std.json.Value) ![]const u8 {
    const eql = std.mem.eql;

    if (eql(u8, name, "launch_app") or eql(u8, name, "list_apps") or eql(u8, name, "close_app") or
        eql(u8, name, "close_app_window") or eql(u8, name, "screenshot_app") or
        eql(u8, name, "get_app_state") or
        eql(u8, name, "list_installed_apps") or std.mem.startsWith(u8, name, "app_"))
    {
        return @import("mcp_app.zig").appTool(arena, name, args);
    }
    if (std.mem.startsWith(u8, name, "term_")) {
        return @import("mcp_term.zig").termTool(arena, name, args);
    }
    if (eql(u8, name, "upload_file") or eql(u8, name, "download_file") or
        std.mem.startsWith(u8, name, "port_forward_"))
    {
        return @import("mcp_term.zig").xferTool(arena, name, args);
    }
    if (std.mem.startsWith(u8, name, "web_")) {
        return @import("mcp_web.zig").webTool(arena, backend, name, args);
    }
    if (std.mem.startsWith(u8, name, "file_")) {
        return fsTool(arena, name, args);
    }
    if (std.mem.startsWith(u8, name, "ui_")) {
        return uiTool(arena, backend, name, args);
    }
    if (eql(u8, name, "capabilities")) {
        return capabilitiesTool(arena, backend);
    }

    const pane = paneFromArgs(args);

    if (eql(u8, name, "list_terminals")) {
        const reply = try ipcParsed(arena, backend, .{ .cmd = "list" });
        if (!reply.ok) return paneIpcErr(arena, reply.err);
        return listTerminalsResult(arena, reply.value);
    }
    if (eql(u8, name, "screenshot_pane")) {
        return paneScreenshot(arena, backend, pane);
    }
    if (eql(u8, name, "record_pane_start")) {
        const path = argStr(args, "path") orelse
            return errRes(arena, .invalid_args, "record_pane_start requires 'path' (absolute .cast output)");
        const reply = try ipcParsed(arena, backend, .{ .cmd = "record-start", .pane = pane, .data = path });
        if (!reply.ok) return paneIpcErr(arena, reply.err);
        var res = Res.init(arena);
        try addPane(&res, pane);
        try res.field("path", path);
        try res.fact("recording", true);
        try res.text("recording started (asciicast v2; stop with record_pane_stop)");
        return res.finish();
    }
    if (eql(u8, name, "record_pane_stop")) {
        const reply = try ipcParsed(arena, backend, .{ .cmd = "record-stop", .pane = pane });
        if (!reply.ok) return paneIpcErr(arena, reply.err);
        var res = Res.init(arena);
        try addPane(&res, pane);
        try res.fact("recording", false);
        try res.text("recording stopped");
        return res.finish();
    }
    if (eql(u8, name, "read_screen")) {
        if (argBool(args, "last_command")) {
            const reply = try ipcParsed(arena, backend, .{ .cmd = "get-text", .pane = pane, .last_command = true });
            if (!reply.ok) return paneIpcErr(arena, reply.err);
            const last = reply.value.object.get("last") orelse
                return errRes(arena, .io_failed, "malformed reply");
            const text = (if (last == .object) last.object.get("text") else null) orelse std.json.Value{ .string = "" };
            const exit = (if (last == .object) last.object.get("exit") else null) orelse std.json.Value{ .integer = 0 };
            const out: []const u8 = if (text == .string) text.string else "";
            var res = Res.init(arena);
            try addPane(&res, pane);
            try res.fact("last_command", true);
            try res.field("exit_status", if (exit == .integer) exit.integer else 0);
            try res.fact("output", out);
            try res.textf("--- command ---\n{s}", .{out});
            return res.finish();
        }
        const sb: u32 = if (argInt(args, "scrollback")) |s|
            (if (s > 0) @intCast(@min(s, 100_000)) else 0)
        else
            0;
        const screen = readScreen(arena, backend, pane, sb) catch |err| switch (err) {
            error.NoSuchPane => return errRes(arena, .not_found, "no such pane"),
            else => return err,
        };
        var res = Res.init(arena);
        try addPane(&res, pane);
        try addScreenFacts(&res, screen);
        try res.fact("text", screen.text);
        try res.textf("--- screen ---\n{s}", .{screen.text});
        return res.finish();
    }
    if (eql(u8, name, "send_text")) {
        const text = argStr(args, "text") orelse
            return errRes(arena, .invalid_args, "send_text requires 'text'");
        const enter = argBool(args, "enter");
        const data = if (enter)
            try std.fmt.allocPrint(arena, "{s}\r", .{text})
        else
            text;
        const reply = try ipcParsed(arena, backend, .{ .cmd = "send-text", .pane = pane, .data = data });
        if (!reply.ok) return paneIpcErr(arena, reply.err);
        var res = Res.init(arena);
        try addPane(&res, pane);
        try res.fact("bytes", text.len);
        try res.fact("enter", enter);
        try res.textf("typed {d} byte(s){s}", .{ text.len, if (enter) " and pressed Enter" else "" });
        return res.finish();
    }
    if (eql(u8, name, "send_keys")) {
        const keys = argStr(args, "keys") orelse
            return errRes(arena, .invalid_args, "send_keys requires 'keys'");
        const reply = try ipcParsed(arena, backend, .{ .cmd = "send-keys", .pane = pane, .data = keys });
        if (!reply.ok) return paneIpcErr(arena, reply.err);
        var res = Res.init(arena);
        try addPane(&res, pane);
        try res.field("keys", keys);
        try res.fact("sent", true);
        return res.finish();
    }
    if (eql(u8, name, "run_command")) {
        const command = argStr(args, "command") orelse
            return errRes(arena, .invalid_args, "run_command requires 'command'");
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 15_000;
        const quiet_ms: i64 = argInt(args, "quiet_ms") orelse 400;
        const data = try std.fmt.allocPrint(arena, "{s}\r", .{command});
        const send = try ipcParsed(arena, backend, .{ .cmd = "send-text", .pane = pane, .data = data });
        if (!send.ok) return paneIpcErr(arena, send.err);
        const settled = waitIdle(arena, backend, pane, timeout_ms, quiet_ms) catch |err| switch (err) {
            error.NoSuchPane => return errRes(arena, .not_found, "no such pane"),
            else => return err,
        };
        const want_output_only = argBool(args, "output_only");
        if (want_output_only) {
            // OSC 133 command zone: just the command's output + exit
            // code, no prompt/echo noise. Falls through to the screen
            // scrape when no zone exists (shell integration inactive)
            // — announced below, never a silent shape change.
            const reply = try ipcParsed(arena, backend, .{ .cmd = "get-text", .pane = pane, .last_command = true });
            if (reply.ok) {
                if (reply.value.object.get("last")) |last| {
                    if (last == .object) {
                        const text = (last.object.get("text") orelse std.json.Value{ .string = "" });
                        const exit = (last.object.get("exit") orelse std.json.Value{ .integer = 0 });
                        const out: []const u8 = if (text == .string) text.string else "";
                        var res = Res.init(arena);
                        try addPane(&res, pane);
                        try res.fact("command", command);
                        try res.fact("source", @as([]const u8, "command_zone"));
                        try res.fact("settled", settled);
                        try res.fact("timed_out", !settled);
                        try res.field("exit_status", if (exit == .integer) exit.integer else 0);
                        try res.fact("output", out);
                        if (!settled) try res.text("still producing output after the timeout");
                        try res.textf("--- output ---\n{s}", .{out});
                        return res.finish();
                    }
                }
            }
        }
        const screen = try readScreen(arena, backend, pane, 0);
        var res = Res.init(arena);
        try addPane(&res, pane);
        try res.fact("command", command);
        try res.fact("source", @as([]const u8, "screen"));
        try res.fact("settled", settled);
        try res.fact("timed_out", !settled);
        try addScreenFacts(&res, screen);
        try res.fact("output", screen.text);
        if (want_output_only)
            try res.text("output_only was unavailable: no completed OSC 133 command zone — shell integration is inactive in this pane (unsupported shell, or the command emitted no marks), so this is the rendered screen");
        if (!settled) try res.text("still producing output after the timeout");
        try res.textf("--- screen ---\n{s}", .{screen.text});
        return res.finish();
    }
    if (eql(u8, name, "wait_idle")) {
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 15_000;
        const quiet_ms: i64 = argInt(args, "quiet_ms") orelse 400;
        const settled = waitIdle(arena, backend, pane, timeout_ms, quiet_ms) catch |err| switch (err) {
            error.NoSuchPane => return errRes(arena, .not_found, "no such pane"),
            else => return err,
        };
        var res = Res.init(arena);
        try addPane(&res, pane);
        try res.fact("settled", settled);
        try res.fact("timed_out", !settled);
        try res.fact("timeout_ms", timeout_ms);
        try res.fact("quiet_ms", quiet_ms);
        try res.text(if (settled) "settled" else "timeout: still producing output");
        return res.finish();
    }
    if (eql(u8, name, "new_tab")) {
        const reply = ipcParsed(arena, backend, .{ .cmd = "new-tab", .cwd = argStr(args, "cwd"), .title = argStr(args, "title") }) catch |err| {
            // No GUI reachable: fall back to a headless terminal so the
            // caller can keep working instead of dead-ending.
            if (term_state.mux_sock != null) {
                const id = @import("mcp_term.zig").spawnRegisteredTerm(null, 120, 40) catch
                    return errRes(arena, .unavailable, "no GUI socket, and the headless fallback failed too (mux daemon unreachable?)");
                const t = term_state.terms.get(id).?;
                _ = t.waitIdle(250, 3_000);
                var res = Res.init(arena);
                try res.fact("headless", true);
                try res.field("term", id);
                try res.textf("no GUI is running — opened headless terminal {d} instead; drive it with term_run/term_exec/term_read (term ids, not pane ids)", .{id});
                return res.finish();
            }
            return err;
        };
        if (!reply.ok) return paneIpcErr(arena, reply.err);
        const created = reply.value.object.get("created");
        var res = Res.init(arena);
        try res.fact("headless", false);
        try res.field("tab", objInt(created, "tab"));
        try res.field("pane", objInt(created, "pane"));
        return res.finish();
    }
    if (eql(u8, name, "split_pane")) {
        const direction = argStr(args, "direction") orelse "h";
        const reply = try ipcParsed(arena, backend, .{ .cmd = "split", .pane = pane, .direction = direction });
        if (!reply.ok) return paneIpcErr(arena, reply.err);
        var res = Res.init(arena);
        try res.field("pane", objInt(reply.value.object.get("created"), "pane"));
        try res.fact("direction", direction);
        if (pane) |p| try res.fact("split_from", p);
        try res.text(if (std.mem.eql(u8, direction, "v")) "stacked below the source pane" else "placed beside the source pane");
        return res.finish();
    }
    if (eql(u8, name, "focus_pane")) {
        if (pane == null) return errRes(arena, .invalid_args, "focus_pane requires 'pane'");
        const reply = try ipcParsed(arena, backend, .{ .cmd = "focus", .pane = pane });
        if (!reply.ok) return paneIpcErr(arena, reply.err);
        var res = Res.init(arena);
        try res.field("pane", pane.?);
        try res.fact("focused", true);
        return res.finish();
    }
    if (eql(u8, name, "close_pane")) {
        if (pane == null) return errRes(arena, .invalid_args, "close_pane requires 'pane'");
        const reply = try ipcParsed(arena, backend, .{ .cmd = "close-pane", .pane = pane });
        if (!reply.ok) return paneIpcErr(arena, reply.err);
        var res = Res.init(arena);
        try res.field("pane", pane.?);
        try res.fact("closed", true);
        return res.finish();
    }
    return errRes(arena, .unknown_tool, "unknown tool");
}

/// A GUI IPC refusal as a typed error: an unknown address is
/// `not_found`, anything else is the transport/GUI failing.
fn paneIpcErr(arena: std.mem.Allocator, msg: []const u8) ![]const u8 {
    const missing = std.mem.indexOf(u8, msg, "no such") != null;
    return errRes(arena, if (missing) .not_found else .io_failed, msg);
}

/// `pane` is a fact only when the caller addressed one: an omitted
/// pane means "the focused one", and inventing an id would be a lie.
fn addPane(res: *Res, pane: ?u32) !void {
    if (pane) |p| try res.fact("pane", p);
}

fn objInt(v: ?std.json.Value, key: []const u8) i64 {
    const o = v orelse return 0;
    if (o != .object) return 0;
    const x = o.object.get(key) orelse return 0;
    return if (x == .integer) x.integer else 0;
}

fn objStr(v: std.json.Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const x = v.object.get(key) orelse return "";
    return if (x == .string) x.string else "";
}

fn objBool(v: std.json.Value, key: []const u8) bool {
    if (v != .object) return false;
    const x = v.object.get(key) orelse return false;
    return x == .bool and x.bool;
}

/// The GUI's `list` reply (tabs, each with its panes) restructured into
/// the flat, addressable `terminals` array plus a one-line-per-pane
/// listing. Pure so the shape is testable without a GUI.
pub fn listTerminalsResult(arena: std.mem.Allocator, reply: std.json.Value) ![]const u8 {
    var res = Res.init(arena);
    var sc: std.Io.Writer.Allocating = .init(arena);
    var text: std.Io.Writer.Allocating = .init(arena);
    const jw = &sc.writer;
    const tw = &text.writer;
    try jw.writeAll("[");

    var panes: usize = 0;
    var tabs: usize = 0;
    const tabs_v = if (reply == .object) reply.object.get("tabs") else null;
    if (tabs_v != null and tabs_v.? == .array) {
        for (tabs_v.?.array.items) |tab| {
            if (tab != .object) continue;
            tabs += 1;
            const tab_id = objInt(tab, "id");
            const tab_title = objStr(tab, "title");
            const window = objInt(tab, "window");
            const selected = objBool(tab, "selected");
            const pane_list = tab.object.get("panes") orelse continue;
            if (pane_list != .array) continue;
            for (pane_list.array.items) |p| {
                if (p != .object) continue;
                if (panes > 0) try jw.writeAll(",");
                panes += 1;
                const id = objInt(p, "id");
                const title = objStr(p, "title");
                const cwd = objStr(p, "cwd");
                const rows = objInt(p, "rows");
                const cols = objInt(p, "cols");
                const focused = objBool(p, "focused");
                const zoomed = objBool(p, "zoomed");
                try jw.print("{{\"pane\":{d},\"tab\":{d},\"window\":{d},\"rows\":{d},\"cols\":{d},\"focused\":{},\"zoomed\":{},\"tab_selected\":{},\"title\":", .{
                    id, tab_id, window, rows, cols, focused, zoomed, selected,
                });
                try std.json.Stringify.value(title, .{}, jw);
                try jw.writeAll(",\"tab_title\":");
                try std.json.Stringify.value(tab_title, .{}, jw);
                try jw.writeAll(",\"cwd\":");
                try std.json.Stringify.value(cwd, .{}, jw);
                try jw.writeAll("}");

                if (text.written().len != 0) try tw.writeAll("\n");
                try tw.print("pane {d}  tab {d}  {d}x{d}", .{ id, tab_id, cols, rows });
                if (focused) try tw.writeAll("  focused");
                if (zoomed) try tw.writeAll("  zoomed");
                if (title.len > 0) try tw.print("  {s}", .{title});
                if (cwd.len > 0) try tw.print("  [{s}]", .{cwd});
            }
        }
    }
    try jw.writeAll("]");

    try res.raw("terminals", sc.written());
    try res.fact("count", panes);
    try res.fact("tabs", tabs);
    try res.textf("{d} pane(s) in {d} tab(s)", .{ panes, tabs });
    if (panes > 0) try res.textf("--- panes ---\n{s}", .{text.written()});
    return res.finish();
}

// ── Tests ─────────────────────────────────────────────────────────

const FakeBackend = struct {
    /// Scripted responses, consumed in order; the request lines are
    /// recorded for assertions.
    responses: []const []const u8,
    requests: std.ArrayList([]u8) = .empty,
    timeouts: std.ArrayList(i64) = .empty,
    /// Optional fake time consumed by each deadline-aware exchange.
    talk_delays_ms: []const i64 = &.{},
    /// Optional direct-transport failures aligned with `responses`.
    talk_failures: []const ?DirectTalkFailure = &.{},
    idx: usize = 0,
    clock_ms: i64 = 0,
    allocator: std.mem.Allocator,

    fn talk(ctx: *anyopaque, allocator: std.mem.Allocator, line: []const u8) anyerror![]u8 {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        try self.requests.append(self.allocator, try self.allocator.dupe(u8, line));
        if (self.idx >= self.responses.len) return error.NoResponse;
        const r = self.responses[self.idx];
        self.idx += 1;
        return allocator.dupe(u8, r);
    }

    fn talkFor(ctx: *anyopaque, allocator: std.mem.Allocator, line: []const u8, timeout_ms: i64) DirectTalkResult {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        const call_index = self.timeouts.items.len;
        self.timeouts.append(self.allocator, timeout_ms) catch
            return .{ .failure = .{ .err = error.OutOfMemory, .delivery = .pre_delivery } };
        if (call_index < self.talk_delays_ms.len)
            self.clock_ms += self.talk_delays_ms[call_index];
        const recorded = self.allocator.dupe(u8, line) catch
            return .{ .failure = .{ .err = error.OutOfMemory, .delivery = .pre_delivery } };
        self.requests.append(self.allocator, recorded) catch {
            self.allocator.free(recorded);
            return .{ .failure = .{ .err = error.OutOfMemory, .delivery = .pre_delivery } };
        };
        if (self.idx < self.talk_failures.len) {
            if (self.talk_failures[self.idx]) |failure| {
                self.idx += 1;
                return .{ .failure = failure };
            }
        }
        if (self.idx >= self.responses.len)
            return .{ .failure = .{ .err = error.NoResponse, .delivery = .pre_delivery } };
        const response = self.responses[self.idx];
        self.idx += 1;
        const owned = allocator.dupe(u8, response) catch
            return .{ .failure = .{ .err = error.OutOfMemory, .delivery = .uncertain_delivery } };
        return .{ .reply = owned };
    }

    fn sleepMs(ctx: *anyopaque, ms: u32) void {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        self.clock_ms += ms;
    }

    fn nowMs(ctx: *anyopaque) i64 {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        return self.clock_ms;
    }

    fn backend(self: *FakeBackend) Backend {
        return .{ .ctx = @ptrCast(self), .talk = talk, .talkFor = talkFor, .sleepMs = sleepMs, .nowMs = nowMs };
    }

    fn deinit(self: *FakeBackend) void {
        for (self.requests.items) |r| self.allocator.free(r);
        self.requests.deinit(self.allocator);
        self.timeouts.deinit(self.allocator);
    }
};

const DelayedExit = struct {
    fd: c_int,
    status: i32,
    delay_us: u32 = 50_000,

    fn send(self: DelayedExit) void {
        _ = c.usleep(self.delay_us);
        var frame: [9]u8 = undefined;
        std.mem.writeInt(u32, frame[0..4], 5, .little);
        frame[4] = @intFromEnum(wire.FrameType.exit);
        std.mem.writeInt(i32, frame[5..9], self.status, .little);
        _ = c.write(self.fd, &frame, frame.len);
    }
};

const DirectDropScript = struct {
    const Mode = enum { after_prefix, after_line };

    listener: c_int,
    mode: Mode,

    fn run(self: DirectDropScript) void {
        const accepted = c.accept(self.listener, null, null);
        if (accepted < 0) return;
        defer _ = c.close(accepted);
        var buf: [16 << 10]u8 = undefined;
        switch (self.mode) {
            .after_prefix => {
                _ = c.read(accepted, &buf, buf.len);
            },
            .after_line => while (true) {
                const n = c.read(accepted, &buf, buf.len);
                if (n <= 0) return;
                if (std.mem.indexOfScalar(u8, buf[0..@intCast(n)], '\n') != null) return;
            },
        }
    }
};

const LegacyPanelDaemonScript = struct {
    listener: c_int,
    delay_us: u32,

    fn run(self: LegacyPanelDaemonScript) void {
        const accepted = c.accept(self.listener, null, null);
        if (accepted < 0) return;
        var conn = muxclient.Conn{ .allocator = std.heap.c_allocator, .fd = accepted };
        defer conn.deinit();
        const hello = conn.recvExpect(&.{.hello}) catch return;
        hello.deinit(conn.allocator);
        _ = c.usleep(self.delay_us);
        // Exact pre-panel daemon: normal mux negotiation, no panel_rpc.
        conn.sendFrame(.welcome, "{\"proto\":6,\"server_proto\":6,\"negotiation\":1}") catch return;
    }
};

fn directDropListener(path: [:0]const u8) !c_int {
    const listener = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (listener < 0) return error.SocketFailed;
    errdefer _ = c.close(listener);
    var addr: c.struct_sockaddr_un = undefined;
    try @import("../mux/daemon.zig").fillSockaddrUn(&addr, path);
    if (c.bind(listener, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0)
        return error.BindFailed;
    if (c.listen(listener, 1) != 0) return error.ListenFailed;
    return listener;
}

fn testActionApp(a: std.mem.Allocator, with_window: bool) !struct { app: *appdrive.App, peer: c_int } {
    var fds: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds) != 0) return error.SocketFailed;
    errdefer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }
    const app = try a.create(appdrive.App);
    errdefer a.destroy(app);
    app.* = .{
        .allocator = a,
        .conn = .{ .allocator = a, .fd = fds[0] },
        .name = try a.dupe(u8, "mcp-action-test"),
    };
    app.conn.setNonBlocking();
    if (with_window) {
        const win = try a.create(appdrive.Window);
        errdefer a.destroy(win);
        win.* = .{ .id = 1, .chan = 7, .sid = 11, .w = 1, .h = 1, .frames = 1 };
        try win.pixels.appendSlice(a, &.{ 1, 2, 3, 255 });
        try app.windows.append(a, win);
        app.had_toplevel = true;
    }
    app_state.allocator = a;
    return .{ .app = app, .peer = fds[1] };
}

fn parseTestValue(a: std.mem.Allocator, json: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
}

test "appSelect separates unknown, ambiguous and single-live apps" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const f1 = try testActionApp(t.allocator, true);
    defer _ = c.close(f1.peer);
    defer f1.app.deinit();
    const f2 = try testActionApp(t.allocator, true);
    defer _ = c.close(f2.peer);
    defer f2.app.deinit();
    defer {
        app_state.apps.deinit(t.allocator);
        app_state.apps = .empty;
    }
    const empty = try parseTestValue(arena, "{}");

    // Nothing launched: must not read as a dead app.
    switch (appSelect(arena, empty)) {
        .app => return error.UnexpectedApp,
        .err => |e| try t.expect(std.mem.indexOf(u8, e, "no app sessions exist") != null),
    }

    try app_state.apps.put(t.allocator, 7, f1.app);
    // Single app: `app` stays optional.
    switch (appSelect(arena, empty)) {
        .app => |a| try t.expect(a == f1.app),
        .err => return error.UnexpectedError,
    }

    try app_state.apps.put(t.allocator, 8, f2.app);
    // Two live apps, no id: AMBIGUOUS, and the message must name them
    // — the old wording claimed the app was unknown, which reads
    // exactly like a crash and gets misdiagnosed as one.
    switch (appSelect(arena, empty)) {
        .app => return error.UnexpectedApp,
        .err => |e| {
            try t.expect(std.mem.indexOf(u8, e, "AMBIGUOUS") != null);
            try t.expect(std.mem.indexOf(u8, e, "app 7 (alive") != null);
            try t.expect(std.mem.indexOf(u8, e, "app 8 (alive") != null);
        },
    }

    // A wrong id names the roster instead of a bare failure.
    const bad = try parseTestValue(arena, "{\"app\":99}");
    switch (appSelect(arena, bad)) {
        .app => return error.UnexpectedApp,
        .err => |e| {
            try t.expect(std.mem.indexOf(u8, e, "no app has id 99") != null);
            try t.expect(std.mem.indexOf(u8, e, "app 7") != null);
        },
    }

    // An exited session lingers until close_app; it must not make the
    // one remaining live app ambiguous.
    f2.app.exited = true;
    switch (appSelect(arena, empty)) {
        .app => |a| try t.expect(a == f1.app),
        .err => return error.UnexpectedError,
    }
}

test "frame counters make a capture provably newer than an input" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const f = try testActionApp(t.allocator, true);
    defer _ = c.close(f.peer);
    defer f.app.deinit();

    try t.expectEqual(@as(u64, 1), f.app.frameCount(1));
    try t.expectEqual(@as(u64, 0), f.app.frameCount(999));
    // Already past the bar: returns at once.
    try t.expect(f.app.waitFrameAfter(1, 0, 50));
    // Never reached within the bound (nothing commits on this fixture).
    try t.expect(!f.app.waitFrameAfter(1, 5, 50));

    var piw = PostInputWait.begin(try parseTestValue(arena, "{}"), f.app, 1, false);
    try t.expectEqual(@as(u64, 1), piw.frame_at_input);
    const note = piw.frameNote(arena, f.app, 1);
    try t.expect(std.mem.indexOf(u8, note, "frame 1 at input") != null);
    try t.expect(std.mem.indexOf(u8, note, "min_frame:1") != null);
}

test "a11yTreeIsBare only flags a registry with no widgets under it" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The real reply from an SDL game: registry + a desktop service,
    // nothing below either.
    try t.expect(a11yTreeIsBare(arena,
        \\{"tree":{"id":"org.a11y.atspi.Registry#root","role":14,"name":"main","children":[{"id":":1.2#root","role":75,"name":"xdg-desktop-portal-gtk"}]}}
    ));
    // A toolkit app nests widgets — never call that "no tree".
    try t.expect(!a11yTreeIsBare(arena,
        \\{"tree":{"id":"reg","role":14,"children":[{"id":"app","role":75,"children":[{"id":"win","role":14}]}]}}
    ));
    try t.expect(!a11yTreeIsBare(arena, "not json"));
}

test "regionOf accepts the object shape and the array shorthand" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const obj = (regionOf(try parseTestValue(arena, "{\"x\":0,\"y\":330,\"w\":145,\"h\":150}"))).?;
    try t.expectEqual(@as(u32, 330), obj.y);
    try t.expectEqual(@as(u32, 145), obj.w);
    const arr = (regionOf(try parseTestValue(arena, "[0,330,145,150]"))).?;
    try t.expectEqual(obj.y, arr.y);
    try t.expectEqual(obj.h, arr.h);
    // Degenerate rects are rejected, not silently clamped.
    try t.expect(regionOf(try parseTestValue(arena, "{\"x\":1,\"y\":1,\"w\":0,\"h\":5}")) == null);
    try t.expect(regionOf(try parseTestValue(arena, "\"0,330,145,150\"")) == null);
}

test "debuggerSignal parses gdb and valgrind crash headlines" {
    const t = std.testing;
    try t.expectEqual(@as(?i32, 11), debuggerSignal("Program received signal SIGSEGV, Segmentation fault."));
    try t.expectEqual(@as(?i32, 6), debuggerSignal("Process terminating with default action of signal 6 (SIGABRT)"));
    try t.expectEqual(@as(?i32, null), debuggerSignal("ordinary app output"));
}

test "app_actions stops structurally when a click crashes the app" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, true);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();

    const sender = try std.Thread.spawn(.{}, DelayedExit.send, .{DelayedExit{ .fd = fixture.peer, .status = -11 }});
    defer sender.join();
    const root = try parseTestValue(arena,
        \\{"actions":[{"click":[0,0],"screenshot":true},{"screenshot":true}]}
    );
    const result = try @import("mcp_app.zig").runActionSteps(arena, fixture.app, root.object.get("actions").?.array.items, 1, false, null);
    const parsed = try expectToolResultShape(arena, "app_actions", result);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expectEqualStrings("app_exited", sc.get("status").?.string);
    try t.expectEqual(@as(i64, 1), sc.get("step").?.integer);
    try t.expectEqual(@as(i64, 11), sc.get("signal").?.integer);
    try t.expectEqualStrings("SIGSEGV", sc.get("signal_name").?.string);
    try t.expect(sc.get("remaining_steps_skipped").?.bool);
    // A step failure is never a tool error, and the transcript still
    // tells the story in prose.
    try t.expect(parsed.object.get("isError") == null);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, text, "app EXITED") != null);
    try t.expect(std.mem.indexOf(u8, text, "SIGSEGV") != null);
    try t.expect(std.mem.indexOf(u8, text, "no pixels yet") == null);
    try t.expect(std.mem.indexOf(u8, text, "all 2 steps completed") == null);
}

test "app_actions reports clean exit status and skips later steps" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, true);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();

    const sender = try std.Thread.spawn(.{}, DelayedExit.send, .{DelayedExit{ .fd = fixture.peer, .status = 0 }});
    defer sender.join();
    const root = try parseTestValue(arena,
        \\{"actions":[{"wait_idle":{"quiet_ms":500,"timeout_ms":1000}},{"key":"enter"}]}
    );
    const result = try @import("mcp_app.zig").runActionSteps(arena, fixture.app, root.object.get("actions").?.array.items, 1, false, null);
    const parsed = try expectToolResultShape(arena, "app_actions", result);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expectEqualStrings("app_exited", sc.get("status").?.string);
    try t.expectEqual(@as(i64, 0), sc.get("exit_status").?.integer);
    try t.expectEqual(@as(i64, 2), sc.get("steps_total").?.integer);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, text, "app exited during wait_idle (status 0)") != null);
    // The second step never ran.
    try t.expect(std.mem.indexOf(u8, text, "pressed") == null);
}

test "app_actions keeps a live frozen app distinct from exit" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, true);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();

    const root = try parseTestValue(arena,
        \\{"actions":[{"wait_idle":{"quiet_ms":500,"timeout_ms":100,"required":true}}]}
    );
    const result = try @import("mcp_app.zig").runActionSteps(arena, fixture.app, root.object.get("actions").?.array.items, 1, false, null);
    const parsed = try expectToolResultShape(arena, "app_actions", result);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expectEqualStrings("failed", sc.get("status").?.string);
    try t.expectEqual(@as(i64, 1), sc.get("step").?.integer);
    // The failing step's own words are the reason — no exit is claimed.
    try t.expect(std.mem.indexOf(u8, sc.get("reason").?.string, "wait_idle did not settle") != null);
    try t.expect(sc.get("exit_status") == null);
    try t.expect(sc.get("signal") == null);
    // One outcome, marked not-ok.
    const steps_out = sc.get("steps").?.array.items;
    try t.expectEqual(@as(usize, 1), steps_out.len);
    try t.expect(!steps_out[0].object.get("ok").?.bool);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, text, "wait_idle did not settle before timeout") != null);
}

test "app_actions treats debugger client loss as inferior exit" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, false);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();
    fixture.app.had_toplevel = true;
    fixture.app.presentation_gone = .client_disconnected;
    try fixture.app.log_buf.appendSlice(t.allocator, "{\"lines\":[{\"text\":\"Program received signal SIGSEGV, Segmentation fault.\"}]}");

    const root = try parseTestValue(arena, "{\"actions\":[{\"wait_idle\":{\"timeout_ms\":100}},{\"screenshot\":true}]}");
    const result = try @import("mcp_app.zig").runActionSteps(arena, fixture.app, root.object.get("actions").?.array.items, null, false, null);
    const parsed = try expectToolResultShape(arena, "app_actions", result);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expectEqualStrings("app_exited", sc.get("status").?.string);
    try t.expectEqualStrings("client_disconnected", sc.get("reason").?.string);
    try t.expectEqual(@as(i64, 11), sc.get("signal").?.integer);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, text, "SIGSEGV") != null);
    // The batch stopped at step 1, so the screenshot step never ran and
    // never complained about the missing window.
    try t.expect(std.mem.indexOf(u8, text, "no rendered window to screenshot") == null);
}

test "PostInputWait reports a click-triggered process crash" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, true);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();
    const args = try parseTestValue(arena, "{\"wait_change\":true,\"timeout_ms\":500,\"settle_ms\":0}");
    var wait = PostInputWait.begin(args, fixture.app, 1, true);
    const sender = try std.Thread.spawn(.{}, DelayedExit.send, .{DelayedExit{ .fd = fixture.peer, .status = -11 }});
    defer sender.join();
    const note = try wait.finish(arena, fixture.app, 1);
    try t.expect(wait.stop != null);
    try t.expectEqual(@as(?i32, 11), wait.stop.?.signal);
    try t.expect(std.mem.indexOf(u8, note, "app EXITED") != null);
    try t.expect(std.mem.indexOf(u8, note, "SIGSEGV") != null);
}

test "a no-repaint verdict names the app when it had already stopped painting" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, true);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();
    const args = try parseTestValue(arena, "{\"wait_change\":true,\"timeout_ms\":150,\"settle_ms\":0}");

    // The window was painting a moment before the input: a dry wait is
    // genuinely ambiguous (dead area vs an app that reacts silently),
    // and must still say so.
    fixture.app.windows.items[0].last_commit_ms = clock.nowMs() - 100;
    var live = PostInputWait.begin(args, fixture.app, 1, false);
    const live_note = try live.finish(arena, fixture.app, 1);
    try t.expect(std.mem.indexOf(u8, live_note, "dead area") != null);
    try t.expect(std.mem.indexOf(u8, live_note, "WAS painting") != null);
    try t.expect(std.mem.indexOf(u8, live_note, "LIVENESS") == null);

    // The window had been silent for 10s BEFORE the input. This input
    // cannot have caused that, and the first evidence of a hang must
    // not read as a click that missed.
    fixture.app.windows.items[0].last_commit_ms = clock.nowMs() - 10_000;
    var hung = PostInputWait.begin(args, fixture.app, 1, false);
    try t.expect(hung.quietBeforeMs() >= APP_QUIET_HANG_MS);
    const hung_note = try hung.finish(arena, fixture.app, 1);
    try t.expect(std.mem.indexOf(u8, hung_note, "APP LIVENESS WARNING") != null);
    try t.expect(std.mem.indexOf(u8, hung_note, "app_backtrace") != null);
    try t.expect(std.mem.indexOf(u8, hung_note, "dead area") == null);
}

test "watchChanges reports a still window as measured, not as an empty sample" {
    const t = std.testing;
    const fixture = try testActionApp(t.allocator, true);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();

    var res = try fixture.app.watchChanges(1, 250, 2.0, null, 8, 2);
    defer res.deinit(t.allocator);
    // Nothing commits on this fixture: no events, and — the load-bearing
    // part — a frame total of zero, which is what separates "the app is
    // painting and the content did not change" from "the app is dead".
    try t.expectEqual(@as(usize, 0), res.events.len);
    try t.expectEqual(@as(u64, 0), res.frames);
    try t.expectEqual(@as(u64, 1), res.frame_first);
    try t.expect(!res.truncated);
    try t.expect(res.elapsed_ms >= 200);

    // No such window is an error, never a silent empty timeline.
    try t.expectError(appdrive.Error.NoSuchWindow, fixture.app.watchChanges(99, 50, 2.0, null, 4, 0));
}

test "app_click reports a crash during its held click" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, true);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();
    try t.expectEqual(@as(usize, 0), app_state.apps.count());
    app_state.ready = true;
    try app_state.apps.put(t.allocator, 1, fixture.app);
    defer {
        // Driving a real app tool records into the PROCESS-GLOBAL
        // journal (and its nudge/log-delta siblings), which only the
        // server's own shutdown normally clears — so without this the
        // entries outlive the test and are reported against
        // t.allocator. It leaked only on some orderings, because a
        // later test reusing these globals could happen to free them.
        Journal.deinitAll();
        LogDelta.deinitAll();
        MacroNudge.deinitAll();
        _ = app_state.apps.fetchSwapRemove(1);
        app_state.apps.deinit(t.allocator);
        app_state.apps = .empty;
        app_state.ready = false;
    }

    const args = try parseTestValue(arena, "{\"app\":1,\"window\":1,\"x\":0,\"y\":0,\"mark\":false,\"wait_change\":true,\"timeout_ms\":500}");
    const sender = try std.Thread.spawn(.{}, DelayedExit.send, .{DelayedExit{ .fd = fixture.peer, .status = -11 }});
    defer sender.join();
    const result = try @import("mcp_app.zig").appTool(arena, "app_click", args);
    const parsed = try expectToolResultShape(arena, "app_click", result);
    const sc = parsed.object.get("structuredContent").?.object;
    // The click's own facts survive the crash it triggered, and the
    // app's death is reported as app state, not as a click failure.
    try t.expectEqual(@as(i64, 1), sc.get("window").?.integer);
    try t.expect(sc.get("exited").?.bool);
    try t.expectEqual(@as(i64, 11), sc.get("signal").?.integer);
    try t.expect(sc.get("crashed").?.bool);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, text, "app EXITED") != null);
    try t.expect(std.mem.indexOf(u8, text, "SIGSEGV") != null);
    try t.expect(std.mem.indexOf(u8, text, "click failed") == null);
    try t.expect(std.mem.indexOf(u8, text, "no pixels yet") == null);
}

test "app tools speak both lanes: windows, wait, pointer and the roster" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, true);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();
    app_state.ready = true;
    try app_state.apps.put(t.allocator, 1, fixture.app);
    defer {
        Journal.deinitAll();
        LogDelta.deinitAll();
        MacroNudge.deinitAll();
        _ = app_state.apps.fetchSwapRemove(1);
        app_state.apps.deinit(t.allocator);
        app_state.apps = .empty;
        app_state.ready = false;
    }
    const app_tools = @import("mcp_app.zig");

    // 1. app_windows: the window list is a fact, the prose names it.
    const windows = try app_tools.appTool(arena, "app_windows", try parseTestValue(arena, "{\"app\":1}"));
    const wparsed = try expectToolResultShape(arena, "app_windows", windows);
    const wsc = wparsed.object.get("structuredContent").?.object;
    try t.expectEqual(@as(i64, 1), wsc.get("app").?.integer);
    try t.expect(!wsc.get("exited").?.bool);
    try t.expectEqual(@as(usize, 1), wsc.get("windows").?.array.items.len);
    try t.expectEqual(@as(i64, 1), wsc.get("windows").?.array.items[0].object.get("window").?.integer);
    try t.expectEqual(@as(i64, 1), wsc.get("primary_window").?.integer);
    const wtext = wparsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, wtext, "window 1: 1x1") != null);

    // 2. app_wait: the verdict is a fact (mode + settled), and the
    //    frame arithmetic that used to hide in prose is machine data.
    const waited = try app_tools.appTool(arena, "app_wait", try parseTestValue(arena, "{\"app\":1,\"quiet_ms\":10,\"timeout_ms\":200}"));
    const waparsed = try expectToolResultShape(arena, "app_wait", waited);
    const wasc = waparsed.object.get("structuredContent").?.object;
    try t.expectEqualStrings("idle", wasc.get("mode").?.string);
    try t.expect(wasc.get("settled").?.bool);
    try t.expectEqual(@as(i64, 0), wasc.get("frames_committed").?.integer);
    try t.expectEqual(@as(i64, 1), wasc.get("window").?.integer);

    // 3. app_mouse_move with no coordinates is a QUERY, and says so
    //    rather than pretending it moved anything.
    const ptr = try app_tools.appTool(arena, "app_mouse_move", try parseTestValue(arena, "{\"app\":1}"));
    const pparsed = try expectToolResultShape(arena, "app_mouse_move", ptr);
    const psc = pparsed.object.get("structuredContent").?.object;
    try t.expectEqualStrings("query", psc.get("mode").?.string);
    try t.expect(!psc.get("tracked").?.bool);

    // 4. list_apps: one entry per session, plus a count.
    const listed = try app_tools.appTool(arena, "list_apps", try parseTestValue(arena, "{}"));
    const lparsed = try expectToolResultShape(arena, "list_apps", listed);
    const lsc = lparsed.object.get("structuredContent").?.object;
    try t.expectEqual(@as(i64, 1), lsc.get("count").?.integer);
    try t.expectEqual(@as(i64, 1), lsc.get("apps").?.array.items[0].object.get("app").?.integer);

    // 5. An unknown app id is a typed not_found, never a bare failure.
    const missing = try app_tools.appTool(arena, "app_windows", try parseTestValue(arena, "{\"app\":99}"));
    const mparsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, missing, .{});
    try t.expect(mparsed.object.get("isError").?.bool);
    try t.expectEqualStrings("not_found", mparsed.object.get("structuredContent").?.object.get("error").?.object.get("code").?.string);
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

test "app_actions wait_image reports exit instead of template timeout" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try testActionApp(t.allocator, false);
    defer _ = c.close(fixture.peer);
    defer fixture.app.deinit();

    const png_bytes = try png_util.encodeRgba(arena, &.{ 255, 0, 0, 255 }, 1, 1);
    const enc = std.base64.standard.Encoder;
    const b64 = try arena.alloc(u8, enc.calcSize(png_bytes.len));
    _ = enc.encode(b64, png_bytes);
    const json = try std.fmt.allocPrint(
        arena,
        "{{\"actions\":[{{\"wait_image\":{{\"image_b64\":\"{s}\",\"timeout_ms\":1000}}}},{{\"wait\":1}}]}}",
        .{b64},
    );
    const root = try parseTestValue(arena, json);
    const sender = try std.Thread.spawn(.{}, DelayedExit.send, .{DelayedExit{ .fd = fixture.peer, .status = -11 }});
    defer sender.join();
    const result = try @import("mcp_app.zig").runActionSteps(arena, fixture.app, root.object.get("actions").?.array.items, null, false, null);
    const parsed = try expectToolResultShape(arena, "app_actions", result);
    try t.expectEqualStrings("app_exited", parsed.object.get("structuredContent").?.object.get("status").?.string);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, text, "app EXITED during wait_image") != null);
    try t.expect(std.mem.indexOf(u8, text, "template") == null or std.mem.indexOf(u8, text, "not found") == null);
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

test "tools/call send_keys routes to IPC send-keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeBackend{
        .responses = &.{"{\"ok\":true}"},
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();

    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"send_keys","arguments":{"pane":4,"keys":"ctrl+c enter"}}}
    ).?;
    const parsed = try expectToolResultShape(arena, "send_keys", try rpcToolResult(arena, resp));
    const sc = parsed.object.get("structuredContent").?.object;
    try std.testing.expectEqualStrings("ctrl+c enter", sc.get("keys").?.string);
    try std.testing.expect(sc.get("sent").?.bool);
    try std.testing.expectEqual(@as(i64, 4), sc.get("pane").?.integer);
    try std.testing.expectEqual(@as(usize, 1), fake.requests.items.len);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "\"cmd\":\"send-keys\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "\"pane\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "ctrl+c enter") != null);
}

/// One environment variable saved, cleared and put back, without an
/// allocator (a test helper must not perturb `std.testing.allocator`'s
/// leak accounting). A value longer than the buffer is refused rather
/// than truncated: silently restoring a different value is worse than
/// failing the test that clobbered it.
const EnvSave = struct {
    name: [*:0]const u8 = "",
    buf: [512]u8 = undefined,
    had: bool = false,

    fn take(self: *EnvSave, name: [*:0]const u8) !void {
        self.* = .{ .name = name };
        if (c.getenv(name)) |raw| {
            const value = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
            if (value.len >= self.buf.len) return error.EnvValueTooLong;
            @memcpy(self.buf[0..value.len], value);
            self.buf[value.len] = 0;
            self.had = true;
        }
        _ = c.unsetenv(name);
    }

    fn restore(self: *EnvSave) void {
        if (self.name[0] == 0) return;
        if (self.had) {
            _ = c.setenv(self.name, @ptrCast(&self.buf), 1);
        } else {
            _ = c.unsetenv(self.name);
        }
    }
};

/// Every environment variable that can steer a ui_* call away from the
/// injected `FakeBackend`. `SKETERM_MUX_SOCKET` is the load-bearing one:
/// `UiTransport.init` treats a session plus an environment socket as an
/// EXACT origin and takes the mux relay, so a suite run from inside a
/// live sketerm pane would talk to the developer's real daemon instead
/// of the fake, and the ui_* tests would fail on that machine only.
const UI_ISOLATED_ENV = [_][*:0]const u8{
    "SKETERM_SESSION",
    "SKETERM_MUX_SOCKET",
    "SKETERM_SESSION_ORIGIN_ID",
};

/// XDG_STATE_HOME pointed at a scratch dir, plus a GUI socket the
/// ui_* tools will believe in. Every panelstore path derives from the
/// state dir, so without this the tests would write into the
/// developer's real panel store.
const UiScratch = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,
    saved_gui: bool = false,
    saved_source: GuiSocketSource = .none,
    saved_state_home: EnvSave = .{},
    saved_env: [UI_ISOLATED_ENV.len]EnvSave = @splat(.{}),

    fn init(self: *UiScratch, tag: []const u8, gui: bool) !void {
        self.* = .{};
        try self.saved_state_home.take("XDG_STATE_HOME");
        for (&self.saved_env, UI_ISOLATED_ENV) |*slot, name| try slot.take(name);
        const p = try std.fmt.bufPrintZ(&self.buf, "/tmp/sketerm-mcp-ui-{s}-{d}", .{ tag, c.getpid() });
        self.len = p.len;
        _ = c.mkdir(@ptrCast(&self.buf), 0o755);
        _ = c.setenv("XDG_STATE_HOME", @ptrCast(&self.buf), 1);
        self.saved_gui = srv_gui_socket;
        self.saved_source = srv_gui_socket_source;
        srv_gui_socket = gui;
        srv_gui_socket_source = if (gui) .explicit else .none;
    }

    fn deinit(self: *UiScratch) void {
        srv_gui_socket = self.saved_gui;
        srv_gui_socket_source = self.saved_source;
        var i = self.saved_env.len;
        while (i > 0) {
            i -= 1;
            self.saved_env[i].restore();
        }
        self.saved_state_home.restore();
        var cmd: [256]u8 = undefined;
        const z = std.fmt.bufPrintZ(&cmd, "rm -rf {s}", .{self.buf[0..self.len]}) catch return;
        _ = c.system(z.ptr);
        self.* = undefined;
    }
};

const UI_DOC =
    \\{"title":"Epoch 41","root":"ok","components":{"ok":{"type":"button","text":"Approve","action":"approve"}}}
;

test "ui_show sends the document to the GUI, and ui_save reads the live one back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("show", true);
    defer scratch.deinit();

    const LIVE_DOC =
        \\{"title":"Epoch 42","root":"ok","components":{"ok":{"type":"button","text":"Approve","action":"approve"}}}
    ;
    var fake = FakeBackend{
        .responses = &.{
            "{\"ok\":true,\"panel_id\":7,\"session\":\"s1\"}", // panel-show
            "{\"ok\":true,\"panels\":[{\"panel_id\":7,\"name\":\"train\",\"session\":\"s1\",\"title\":\"Epoch 41\",\"target\":\"tab\"}]}", // panel-list (name -> id)
            "{\"ok\":true}", // panel-patch
            "{\"ok\":true,\"panels\":[{\"panel_id\":7,\"name\":\"train\",\"session\":\"s1\",\"title\":\"Epoch 42\",\"target\":\"tab\"}]}", // panel-list (name -> id)
            "{\"ok\":true,\"document\":\"{\\\"title\\\":\\\"Epoch 42\\\",\\\"root\\\":\\\"ok\\\",\\\"components\\\":{\\\"ok\\\":{\\\"type\\\":\\\"button\\\",\\\"text\\\":\\\"Approve\\\",\\\"action\\\":\\\"approve\\\"}}}\",\"name\":\"train\",\"session\":\"s1\",\"title\":\"Epoch 42\"}", // panel-get
        },
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();

    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_show","arguments":{"name":"train","session":"s1","document":{"title":"Epoch 41","root":"ok","components":{"ok":{"type":"button","text":"Approve","action":"approve"}}}}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "isError") == null);
    {
        const shape = try expectToolResultShape(arena, "ui_show", try rpcToolResult(arena, resp));
        const sc = shape.object.get("structuredContent").?.object;
        try std.testing.expectEqual(@as(i64, 7), sc.get("panel_id").?.integer);
        try std.testing.expectEqualStrings("train", sc.get("name").?.string);
        try std.testing.expect(sc.get("showing").?.bool);
    }
    // The document travelled as the control socket's JSON string, and
    // the target defaulted to a tab.
    const req = fake.requests.items[0];
    try std.testing.expect(std.mem.indexOf(u8, req, "\"cmd\":\"panel-show\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"target\":\"tab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"session\":\"s1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "image_compare") == null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Approve") != null);

    // A patch by name resolves the id and forwards the ops — and does
    // NOT keep any document state on this side.
    const patched = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_patch","arguments":{"name":"train","session":"s1","patch":[{"op":"title","value":"Epoch 42"}]}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, patched, "isError") == null);
    {
        const shape = try expectToolResultShape(arena, "ui_patch", try rpcToolResult(arena, patched));
        try std.testing.expect(shape.object.get("structuredContent").?.object.get("patched").?.bool);
    }
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[2], "\"cmd\":\"panel-patch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[2], "\"panel_id\":7") != null);
    // Exactly one list + one patch: no extra round-trip to learn a name.
    try std.testing.expectEqual(@as(usize, 3), fake.requests.items.len);

    // ui_save with no document reads the panel back over panel-get and
    // stores THAT — the patched title included, because the GUI is the
    // one holding the document.
    const saved = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"train","session":"s1"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, saved, "isError") == null);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[4], "\"cmd\":\"panel-get\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[4], "\"panel_id\":7") != null);
    try std.testing.expect(panelstore.existsScoped(arena, .{ .session = "s1" }, "train"));
    var loaded = try panelstore.loadScoped(arena, .{ .session = "s1" }, "train", null);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("Epoch 42", loaded.title);

    // The stored bytes are exactly what the GUI reported, canonically
    // serialized — not a re-derivation of anything held here.
    var live = try paneldoc.Document.parse(arena, LIVE_DOC, null);
    defer live.deinit();
    const want = try live.toJson(arena);
    const on_disk = try panelstore.loadJsonScoped(arena, .{ .session = "s1" }, "train", null);
    try std.testing.expectEqualStrings(want, on_disk);
}

test "ui_save persists a panel this server never showed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("foreign", true);
    defer scratch.deinit();

    // Nothing was ever shown through THIS server: the panel belongs to
    // another process (or to a run before this one). The mirror this
    // path replaced could not save it at all.
    var fake = FakeBackend{
        .responses = &.{
            "{\"ok\":true,\"panels\":[{\"panel_id\":3,\"name\":\"theirs\",\"session\":\"s9\",\"title\":\"Theirs\",\"target\":\"window\"}]}", // panel-list
            "{\"ok\":true,\"document\":\"{\\\"title\\\":\\\"Theirs\\\",\\\"root\\\":\\\"t\\\",\\\"components\\\":{\\\"t\\\":{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"hi\\\"}}}\",\"name\":\"theirs\",\"session\":\"s9\",\"title\":\"Theirs\"}", // panel-get
        },
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();

    const saved = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"theirs","session":"s9"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, saved, "isError") == null);
    var loaded = try panelstore.loadScoped(arena, .{ .session = "s9" }, "theirs", null);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("Theirs", loaded.title);

    // A panel that is not on screen is a described refusal naming the
    // session, not a save of something stale.
    var fake2 = FakeBackend{
        .responses = &.{"{\"ok\":true,\"panels\":[]}"},
        .allocator = std.testing.allocator,
    };
    defer fake2.deinit();
    const missing = handleMessage(arena, fake2.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"ghost","session":"s9"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, missing, "isError") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "ghost") != null);
}

test "ui_save reports the canonical byte count actually stored" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("canonical-bytes", false);
    defer scratch.deinit();
    var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
    defer fake.deinit();

    const authored =
        \\  {
        \\    "components": { "t": { "text": "saved", "type": "text" } },
        \\    "root": "t",
        \\    "title": "Canonical"
        \\  }
    ;
    var request: std.Io.Writer.Allocating = .init(arena);
    try request.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"ui_save\",\"arguments\":{\"name\":\"canonical\",\"session\":\"\",\"document\":");
    try std.json.Stringify.value(authored, .{}, &request.writer);
    try request.writer.writeAll("}}}");
    const response = handleMessage(arena, fake.backend(), request.written()).?;
    try t.expect(std.mem.indexOf(u8, response, "isError") == null);

    const stored = try panelstore.loadJsonScoped(arena, .sessionless, "canonical", null);
    try t.expect(stored.len < authored.len);
    const shape = try expectToolResultShape(arena, "ui_save", try rpcToolResult(arena, response));
    try t.expectEqual(@as(i64, @intCast(stored.len)), shape.object.get("structuredContent").?.object.get("bytes").?.integer);
}

test "ui_save without a document needs a live panel transport" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("savenogui", false);
    defer scratch.deinit();

    var fake = FakeBackend{ .responses = &.{}, .allocator = std.testing.allocator };
    defer fake.deinit();

    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"p","session":"s1"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "isError") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "live panel transport") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "'document'") != null);
    // Nothing was attempted on the socket, and nothing was written.
    try std.testing.expectEqual(@as(usize, 0), fake.requests.items.len);
    try std.testing.expect(!panelstore.existsScoped(arena, .{ .session = "s1" }, "p"));
}

test "an explicit empty ui session overrides SKETERM_SESSION for live and saved panels" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("explicit-empty", true);
    defer scratch.deinit();
    _ = c.setenv("SKETERM_SESSION", "environment-session", 1);
    defer _ = c.unsetenv("SKETERM_SESSION");

    var fake = FakeBackend{
        .responses = &.{"{\"ok\":true,\"panel_id\":17}"},
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();
    const shown = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_show","arguments":{"name":"sessionless","session":"","document":{"root":"t","components":{"t":{"type":"text","text":"x"}}}}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, shown, "isError") == null);
    {
        const shape = try expectToolResultShape(arena, "ui_show", try rpcToolResult(arena, shown));
        try std.testing.expectEqual(std.json.Value{ .null = {} }, shape.object.get("structuredContent").?.object.get("session").?);
    }
    try std.testing.expectEqual(@as(usize, 1), fake.requests.items.len);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "\"session\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "environment-session") == null);

    const saved = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"sessionless","session":"","document":{"root":"t","components":{"t":{"type":"text","text":"saved"}}}}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, saved, "isError") == null);
    try std.testing.expect(panelstore.existsScoped(arena, .sessionless, "sessionless"));
    try std.testing.expect(!panelstore.existsScoped(arena, .{ .session = "environment-session" }, "sessionless"));
}

test "every ui tool rejects a present non-string session without fallback or side effects" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("session-types", false);
    defer scratch.deinit();
    _ = c.setenv("SKETERM_SESSION", "environment-session", 1);
    defer _ = c.unsetenv("SKETERM_SESSION");

    var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
    defer fake.deinit();
    const tools = [_][]const u8{
        "ui_show",   "ui_show_files", "ui_patch", "ui_wait_event",
        "ui_panels", "ui_save",       "ui_close", "ui_delete",
    };
    const invalid = [_][]const u8{ "null", "0", "1.5", "{}", "[]", "true", "false" };
    var id: usize = 1;
    for (tools) |tool| {
        for (invalid) |value| {
            const request = try std.fmt.allocPrint(
                arena,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{{\"session\":{s}}}}}}}",
                .{ id, tool, value },
            );
            id += 1;
            const response = handleMessage(arena, fake.backend(), request).?;
            try t.expect(std.mem.indexOf(u8, response, "isError") != null);
            try t.expect(std.mem.indexOf(u8, response, "must be a string when present") != null);
            try t.expect(std.mem.indexOf(u8, response, "environment-session") == null);
        }
    }
    try t.expectEqual(@as(usize, 0), fake.requests.items.len);
    try t.expect(!panelstore.existsScoped(arena, .{ .session = "environment-session" }, "ui-invalid"));

    const absent = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":100,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"inherited","document":{"root":"t","components":{"t":{"type":"text","text":"saved"}}}}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, absent, "isError") == null);
    try t.expect(panelstore.existsScoped(arena, .{ .session = "environment-session" }, "inherited"));
}

test "ui_show refuses a bad document with the parser's own message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("bad", true);
    defer scratch.deinit();

    // The GUI is the one that parses; its Diag message must reach the
    // assistant verbatim, component id and all.
    var fake = FakeBackend{
        .responses = &.{"{\"ok\":false,\"error\":\"component \\\"r\\\": unknown type \\\"webview\\\"\"}"},
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();
    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_show","arguments":{"name":"x","session":"s1","document":"{\"root\":\"r\",\"components\":{\"r\":{\"type\":\"webview\"}}}"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "isError") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "webview") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "unknown type") != null);

    // document + load together is a caller error caught before any IPC.
    const both = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_show","arguments":{"name":"x","document":{},"load":"y"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, both, "not both") != null);
    try std.testing.expectEqual(@as(usize, 1), fake.requests.items.len);
}

test "ui presenter protocol shapes cannot fabricate panel success" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("bad-presenter-shape", true);
    defer scratch.deinit();

    var fake = FakeBackend{
        .responses = &.{
            "[]",
            "{}",
            "{\"ok\":\"yes\"}",
            "{\"ok\":true}",
            "{\"ok\":true,\"panel_id\":0}",
            "{\"ok\":false}",
            "{\"ok\":false,\"error\":\"presenter disconnected\",\"failure_class\":\"uncertain_delivery\",\"mutation_may_have_applied\":true,\"resend_safe\":false}",
        },
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();
    for (0..7) |i| {
        const request = try std.fmt.allocPrint(
            arena,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"ui_show\",\"arguments\":{{\"name\":\"shape\",\"session\":\"s1\",\"document\":{{\"root\":\"t\",\"components\":{{\"t\":{{\"type\":\"text\",\"text\":\"x\"}}}}}}}}}}}}",
            .{i + 1},
        );
        const response = handleMessage(arena, fake.backend(), request).?;
        try std.testing.expect(std.mem.indexOf(u8, response, "isError") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "delivery is uncertain") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "NOT resent") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "showing") == null);
    }
}

/// Create an empty file so ui_show_files' readability check passes.
fn touchFile(dir: []const u8, name: []const u8) void {
    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch return;
    const f = c.fopen(p.ptr, "wb") orelse return;
    _ = c.fwrite("x", 1, 1, f);
    _ = c.fclose(f);
}

test "ui_show_files generates a document the panel parser accepts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Stacked: a heading (because a title was given) plus one image per
    // file, in order, captions attached.
    const stacked = try uiFilesDocument(arena, &.{
        .{ .path = "/tmp/e40.png", .caption = "epoch 40" },
        .{ .path = "/tmp/e41.png", .caption = "e41.png" },
    }, "Epoch 41", false);
    var doc = try paneldoc.Document.parse(arena, stacked, null);
    defer doc.deinit();
    try std.testing.expectEqualStrings("Epoch 41", doc.title);
    try std.testing.expectEqualStrings("main", doc.root);
    const main = doc.get("main").?;
    try std.testing.expectEqual(@as(usize, 3), main.props.column.children.len);
    try std.testing.expectEqualStrings("h", main.props.column.children[0]);
    try std.testing.expectEqual(paneldoc.Kind.heading, doc.kindOf("h").?);
    try std.testing.expectEqualStrings("/tmp/e40.png", doc.get("img1").?.props.image.src);
    try std.testing.expectEqualStrings("epoch 40", doc.get("img1").?.props.image.caption);
    try std.testing.expectEqualStrings("/tmp/e41.png", doc.get("img2").?.props.image.src);

    // No title: no heading, and the column is images only.
    const untitled = try uiFilesDocument(arena, &.{
        .{ .path = "/tmp/a.png", .caption = "a.png" },
    }, "", false);
    var doc2 = try paneldoc.Document.parse(arena, untitled, null);
    defer doc2.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc2.get("main").?.props.column.children.len);
    try std.testing.expect(doc2.get("h") == null);

    // Compare: ONE image_compare, each caption becoming a side label.
    const cmp = try uiFilesDocument(arena, &.{
        .{ .path = "/tmp/e40.png", .caption = "epoch 40" },
        .{ .path = "/tmp/e41.png", .caption = "epoch 41" },
    }, "E41 vs E40", true);
    var doc3 = try paneldoc.Document.parse(arena, cmp, null);
    defer doc3.deinit();
    try std.testing.expectEqual(paneldoc.Kind.image_compare, doc3.kindOf("cmp").?);
    const ic = doc3.get("cmp").?.props.image_compare;
    try std.testing.expectEqualStrings("/tmp/e40.png", ic.left.src);
    try std.testing.expectEqualStrings("epoch 40", ic.left.label);
    try std.testing.expectEqualStrings("/tmp/e41.png", ic.right.src);
    try std.testing.expectEqualStrings("epoch 41", ic.right.label);
    try std.testing.expect(doc3.get("img1") == null);

    // A caption with quotes/newlines cannot break the generated JSON.
    const nasty = try uiFilesDocument(arena, &.{
        .{ .path = "/tmp/x.png", .caption = "he said \"hi\"\nthen \\left" },
    }, "a \"quoted\" title", false);
    var doc4 = try paneldoc.Document.parse(arena, nasty, null);
    defer doc4.deinit();
    try std.testing.expectEqualStrings("he said \"hi\"\nthen \\left", doc4.get("img1").?.props.image.caption);

    // Full cap: still one valid document (heading + 64 images < MAX_CHILDREN).
    var many: [UI_FILES_MAX]UiFile = undefined;
    for (&many) |*f| f.* = .{ .path = "/tmp/e.png", .caption = "e" };
    const big = try uiFilesDocument(arena, &many, "All", false);
    var doc5 = try paneldoc.Document.parse(arena, big, null);
    defer doc5.deinit();
    try std.testing.expectEqual(@as(usize, UI_FILES_MAX + 1), doc5.get("main").?.props.column.children.len);
}

test "ui_show_files shows an image set in one call, through the ui_show path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("files", true);
    defer scratch.deinit();
    const dir = scratch.buf[0..scratch.len];
    touchFile(dir, "e40.png");
    touchFile(dir, "e41.png");

    var fake = FakeBackend{
        .responses = &.{
            "{\"ok\":true,\"panel_id\":9}", // compare
            "{\"ok\":true,\"panel_id\":9}", // stacked, one file missing
        },
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();

    // compare:true with exactly two files -> the A/B slider, captions
    // as side labels.
    const req_cmp = try std.fmt.allocPrint(arena,
        \\{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":"ui_show_files","arguments":{{"session":"s1","title":"E41 vs E40","compare":true,"files":[{{"path":"{s}/e40.png","caption":"epoch 40"}},{{"path":"{s}/e41.png","caption":"epoch 41"}}]}}}}}}
    , .{ dir, dir });
    const resp = handleMessage(arena, fake.backend(), req_cmp).?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "isError") == null);
    {
        const shape = try expectToolResultShape(arena, "ui_show_files", try rpcToolResult(arena, resp));
        const sc = shape.object.get("structuredContent").?.object;
        try std.testing.expectEqual(@as(i64, 9), sc.get("panel_id").?.integer);
        try std.testing.expectEqualStrings("image_compare", sc.get("layout").?.string);
        try std.testing.expectEqual(@as(i64, 2), sc.get("files").?.integer);
    }
    // It went out over the SAME panel-show the hand-authored path uses,
    // under the default name, as an image_compare document.
    const sent = fake.requests.items[0];
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"cmd\":\"panel-show\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"name\":\"files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"target\":\"tab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "image_compare") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "epoch 40") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "epoch 41") != null);

    // Stacked, with one path that does not exist: the panel is still
    // shown (the renderer draws a placeholder) and the reply NAMES the
    // file, so the assistant can tell.
    const req_stack = try std.fmt.allocPrint(arena,
        \\{{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{{"name":"ui_show_files","arguments":{{"session":"s1","name":"preview","files":["{s}/e40.png","{s}/ghost.png"]}}}}}}
    , .{ dir, dir });
    const resp2 = handleMessage(arena, fake.backend(), req_stack).?;
    try std.testing.expect(std.mem.indexOf(u8, resp2, "isError") == null);
    {
        const shape = try expectToolResultShape(arena, "ui_show_files", try rpcToolResult(arena, resp2));
        const sc = shape.object.get("structuredContent").?.object;
        try std.testing.expectEqualStrings("stacked_images", sc.get("layout").?.string);
        const unreadable = sc.get("unreadable").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), unreadable.len);
        try std.testing.expect(std.mem.endsWith(u8, unreadable[0].string, "ghost.png"));
    }
    const sent2 = fake.requests.items[1];
    try std.testing.expect(std.mem.indexOf(u8, sent2, "\"name\":\"preview\"") != null);
    // Bare strings caption themselves with the basename, and no title
    // means no heading.
    try std.testing.expect(std.mem.indexOf(u8, sent2, "\\\"caption\\\":\\\"e40.png\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent2, "heading") == null);
    try std.testing.expectEqual(@as(usize, 2), fake.requests.items.len);
}

test "ui_show_files refuses bad arity, bad paths and an all-missing set" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("files-bad", true);
    defer scratch.deinit();
    const dir = scratch.buf[0..scratch.len];
    touchFile(dir, "a.png");

    var fake = FakeBackend{ .responses = &.{"{\"ok\":true,\"panel_id\":1}"}, .allocator = std.testing.allocator };
    defer fake.deinit();

    // compare with three files: refused, clearly, before any IPC.
    const arity = handleMessage(arena, fake.backend(), try std.fmt.allocPrint(arena,
        \\{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":"ui_show_files","arguments":{{"compare":true,"files":["{s}/a.png","{s}/a.png","{s}/a.png"]}}}}}}
    , .{ dir, dir, dir })).?;
    try std.testing.expect(std.mem.indexOf(u8, arity, "isError") != null);
    try std.testing.expect(std.mem.indexOf(u8, arity, "exactly two") != null);

    // compare with one file: same refusal.
    const one = handleMessage(arena, fake.backend(), try std.fmt.allocPrint(arena,
        \\{{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{{"name":"ui_show_files","arguments":{{"compare":true,"files":["{s}/a.png"]}}}}}}
    , .{dir})).?;
    try std.testing.expect(std.mem.indexOf(u8, one, "exactly two") != null);

    // Empty list, a relative path and a traversing path.
    const empty = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ui_show_files","arguments":{"files":[]}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, empty, "NON-EMPTY") != null);
    const relative = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ui_show_files","arguments":{"files":["rel.png"]}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, relative, "ABSOLUTE") != null);
    const traverse = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"ui_show_files","arguments":{"files":["/a/../etc/shadow"]}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, traverse, "isError") != null);

    // Nothing readable at all: refused rather than shown as a wall of
    // placeholders, and the message names the paths.
    const gone = handleMessage(arena, fake.backend(), try std.fmt.allocPrint(arena,
        \\{{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{{"name":"ui_show_files","arguments":{{"files":["{s}/gone1.png","{s}/gone2.png"]}}}}}}
    , .{ dir, dir })).?;
    try std.testing.expect(std.mem.indexOf(u8, gone, "isError") != null);
    try std.testing.expect(std.mem.indexOf(u8, gone, "none of the 2 file(s) can be read") != null);
    try std.testing.expect(std.mem.indexOf(u8, gone, "gone2.png") != null);

    // Over the cap.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(std.testing.allocator);
    try big.appendSlice(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"ui_show_files","arguments":{"files":[
    );
    for (0..UI_FILES_MAX + 1) |i| {
        if (i > 0) try big.append(std.testing.allocator, ',');
        try big.appendSlice(std.testing.allocator, "\"/tmp/x.png\"");
    }
    try big.appendSlice(std.testing.allocator, "]}}}");
    const capped = handleMessage(arena, fake.backend(), big.items).?;
    try std.testing.expect(std.mem.indexOf(u8, capped, "at most 64 files") != null);

    // Not one of those reached the GUI.
    try std.testing.expectEqual(@as(usize, 0), fake.requests.items.len);
}

test "panel transport precedence is exact origin, explicit GUI, then default compatibility" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
    defer fake.deinit();
    var pool = paneldrive.Pool.init(t.allocator);
    defer pool.deinit();

    const old_pool = panel_pool;
    const old_gui = srv_gui_socket;
    const old_source = srv_gui_socket_source;
    const old_socket = if (c.getenv("SKETERM_MUX_SOCKET")) |value|
        try t.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(value))))
    else
        null;
    defer {
        panel_pool = old_pool;
        srv_gui_socket = old_gui;
        srv_gui_socket_source = old_source;
        if (old_socket) |value| {
            const z = std.fmt.allocPrintSentinel(t.allocator, "{s}", .{value}, 0) catch @panic("restore env oom");
            defer t.allocator.free(z);
            _ = c.setenv("SKETERM_MUX_SOCKET", z.ptr, 1);
            t.allocator.free(value);
        } else _ = c.unsetenv("SKETERM_MUX_SOCKET");
    }
    panel_pool = &pool;
    srv_gui_socket = true;
    srv_gui_socket_source = .explicit;

    _ = c.setenv("SKETERM_MUX_SOCKET", "/tmp/exact.sock", 1);
    var exact = UiTransport.init(arena, fake.backend(), "same");
    defer exact.deinit();
    try t.expect(exact.mode == .auto);
    exact.origin = try paneldrive.Origin.resolve(arena, "same");
    try t.expectEqualStrings("SKETERM_MUX_SOCKET", exact.source());

    _ = c.unsetenv("SKETERM_MUX_SOCKET");
    var explicit = UiTransport.init(arena, fake.backend(), "same");
    defer explicit.deinit();
    try t.expect(explicit.mode == .gui_socket);
    try t.expectEqualStrings("gui_socket_explicit", explicit.source());
    switch (uiStoreScope(&explicit, UI_RELAY_CALL_MS).scope) {
        .session => |session| try t.expectEqualStrings("same", session),
        else => return error.TestUnexpectedResult,
    }

    srv_gui_socket_source = .discovered;
    var compat = UiTransport.init(arena, fake.backend(), "same");
    defer compat.deinit();
    try t.expect(compat.mode == .auto);
    compat.origin = try paneldrive.Origin.resolve(arena, "same");
    try t.expectEqualStrings("default_socket_connect_only", compat.source());

    var sessionless = UiTransport.init(arena, fake.backend(), null);
    defer sessionless.deinit();
    try t.expect(sessionless.mode == .gui_socket);
    try t.expectEqualStrings("gui_socket_discovered", sessionless.source());
    try t.expect(uiStoreScope(&sessionless, UI_RELAY_CALL_MS).scope == .sessionless);

    // Without an exact inherited daemon or a live default-daemon probe, a
    // legacy caller retains the historical by-session namespace.
    var unavailable = UiTransport.init(arena, fake.backend(), "legacy");
    defer unavailable.deinit();
    unavailable.mode = .none;
    switch (uiStoreScope(&unavailable, UI_RELAY_CALL_MS).scope) {
        .session => |session| try t.expectEqualStrings("legacy", session),
        else => return error.TestUnexpectedResult,
    }
}

test "a daemon with no lifetime id falls back to by-session storage" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-store-legacy-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    const listener = try directDropListener(path);
    defer _ = c.close(listener);
    const server = try std.Thread.spawn(.{}, LegacyPanelDaemonScript.run, .{LegacyPanelDaemonScript{
        .listener = listener,
        .delay_us = 0,
    }});
    defer server.join();

    const old_pool = panel_pool;
    var pool = paneldrive.Pool.init(t.allocator);
    defer pool.deinit();
    panel_pool = &pool;
    defer panel_pool = old_pool;
    _ = c.setenv("SKETERM_MUX_SOCKET", path.ptr, 1);
    _ = c.setenv("SKETERM_SESSION", "old-session", 1);
    _ = c.unsetenv("SKETERM_SESSION_ORIGIN_ID");
    defer _ = c.unsetenv("SKETERM_MUX_SOCKET");
    defer _ = c.unsetenv("SKETERM_SESSION");

    var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
    defer fake.deinit();
    var transport = UiTransport.init(arena_state.allocator(), fake.backend(), "old-session");
    defer transport.deinit();
    const store = uiStoreScope(&transport, UI_RELAY_CALL_MS);
    try t.expectEqualStrings("", store.err);
    switch (store.scope) {
        .session => |session| try t.expectEqualStrings("old-session", session),
        else => return error.TestUnexpectedResult,
    }
    try t.expect(transport.failure == null);
}

test "exact persistence failures never select reusable legacy storage" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = c.setenv("SKETERM_MUX_SOCKET", "/tmp/exact-store-failure.sock", 1);
    defer _ = c.unsetenv("SKETERM_MUX_SOCKET");
    _ = c.unsetenv("SKETERM_SESSION_ORIGIN_ID");

    const cases = [_]struct {
        kind: paneldrive.FailureKind,
        needle: []const u8,
    }{
        .{ .kind = .attach_failed, .needle = "attach failed" },
        .{ .kind = .origin_unreachable, .needle = "unreachable" },
        .{ .kind = .malformed_attach, .needle = "identity is malformed" },
        .{ .kind = .malformed_welcome, .needle = "welcome is malformed" },
        .{ .kind = .identity_mismatch, .needle = "does not match" },
        .{ .kind = .origin_timeout, .needle = "timed out" },
        .{ .kind = .no_compatible_gui, .needle = "no compatible GUI" },
        .{ .kind = .delivery_uncertain, .needle = "delivery is uncertain" },
        .{ .kind = .reply_timeout, .needle = "reply timed out" },
        .{ .kind = .disconnected, .needle = "disconnected" },
        .{ .kind = .malformed_reply, .needle = "malformed reply" },
    };
    for (cases) |case| {
        var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
        defer fake.deinit();
        var transport = UiTransport{
            .arena = arena,
            .backend = fake.backend(),
            .session = "exact-session",
            .mode = .mux_relay,
            .origin = .{
                .socket = try arena.dupe(u8, "/tmp/exact-store-failure.sock"),
                .session = "exact-session",
                .source = .environment,
            },
            .failure = .{ .kind = case.kind, .detail = "fixture" },
        };
        defer transport.deinit();
        const store = uiStoreScope(&transport, UI_RELAY_CALL_MS);
        try t.expect(store.err.len > 0);
        try t.expect(std.mem.indexOf(u8, store.err, case.needle) != null);
        try t.expect(std.mem.indexOf(u8, store.err, "refusing to downgrade") != null);
    }
}

test "exact persistence retains a previously validated lifetime scope after every failure class" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = c.setenv("SKETERM_MUX_SOCKET", "/tmp/exact-store-retained.sock", 1);
    defer _ = c.unsetenv("SKETERM_MUX_SOCKET");

    const failures = [_]paneldrive.FailureKind{
        .attach_failed,
        .origin_unreachable,
        .malformed_attach,
        .malformed_welcome,
        .identity_mismatch,
        .origin_timeout,
        .no_compatible_gui,
        .delivery_uncertain,
        .reply_timeout,
        .disconnected,
        .malformed_reply,
    };
    for (failures) |kind| {
        var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
        defer fake.deinit();
        var transport = UiTransport{
            .arena = arena,
            .backend = fake.backend(),
            .session = "exact-session",
            .mode = .mux_relay,
            .origin = .{
                .socket = try arena.dupe(u8, "/tmp/exact-store-retained.sock"),
                .session = "exact-session",
                .source = .environment,
            },
            .failure = .{ .kind = kind, .detail = "fixture" },
            .validated_store_scope = .{ .origin = .{
                .daemon_origin = "/tmp/exact-store-retained.sock",
                .origin_id = "10000000000000000000000000000001",
                .label = "exact-session",
            } },
        };
        defer transport.deinit();
        const store = uiStoreScope(&transport, UI_RELAY_CALL_MS);
        try t.expectEqualStrings("", store.err);
        switch (store.scope) {
            .origin => |exact| {
                try t.expectEqualStrings("10000000000000000000000000000001", exact.origin_id);
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "malformed inherited exact identity is an error rather than old-daemon evidence" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = c.setenv("SKETERM_MUX_SOCKET", "/tmp/exact-store-malformed.sock", 1);
    _ = c.setenv("SKETERM_SESSION", "exact-session", 1);
    _ = c.setenv("SKETERM_SESSION_ORIGIN_ID", "not-an-origin-id", 1);
    defer _ = c.unsetenv("SKETERM_MUX_SOCKET");
    defer _ = c.unsetenv("SKETERM_SESSION");
    defer _ = c.unsetenv("SKETERM_SESSION_ORIGIN_ID");

    var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
    defer fake.deinit();
    var transport = UiTransport{
        .arena = arena,
        .backend = fake.backend(),
        .session = "exact-session",
        .mode = .mux_relay,
        .origin = .{
            .socket = try arena.dupe(u8, "/tmp/exact-store-malformed.sock"),
            .session = "exact-session",
            .source = .environment,
        },
    };
    defer transport.deinit();
    const store = uiStoreScope(&transport, UI_RELAY_CALL_MS);
    try t.expect(std.mem.indexOf(u8, store.err, "identity is malformed") != null);
    try t.expect(std.mem.indexOf(u8, store.err, "refusing to downgrade") != null);
}

test "exact origin falls back only to an explicit GUI after proven pre-delivery attach failure" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const old_source = srv_gui_socket_source;
    defer srv_gui_socket_source = old_source;
    var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
    defer fake.deinit();
    var transport = UiTransport{
        .arena = arena_state.allocator(),
        .backend = fake.backend(),
        .session = "session",
        .mode = .mux_relay,
    };
    const exact = paneldrive.Origin{
        .socket = @constCast("/tmp/exact-origin.sock"),
        .session = "session",
        .source = .environment,
    };
    srv_gui_socket_source = .explicit;
    for ([_]paneldrive.FailureKind{ .legacy_daemon, .unsupported, .no_compatible_gui, .attach_failed, .malformed_attach }) |kind|
        try t.expect(transport.canFallbackDirect(exact, .{ .kind = kind, .detail = "pre" }));
    for ([_]paneldrive.FailureKind{ .identity_mismatch, .origin_unreachable, .origin_timeout, .malformed_welcome, .delivery_uncertain, .reply_timeout, .disconnected, .malformed_reply }) |kind|
        try t.expect(!transport.canFallbackDirect(exact, .{ .kind = kind, .detail = "unsafe" }));
    srv_gui_socket_source = .discovered;
    try t.expect(!transport.canFallbackDirect(exact, .{ .kind = .unsupported, .detail = "legacy" }));
}

test "a relayed uncertain-delivery verdict still reaches the tool result as uncertain" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const origin = paneldrive.Origin{
        .socket = @constCast("/tmp/origin.sock"),
        .session = "session",
        .source = .environment,
    };
    // paneldrive is the single validator now: a presenter reply carrying
    // failure_class=uncertain_delivery arrives here already classified, and
    // the tool-visible message must still say so and forbid a resend.
    const message = relayFailure(arena_state.allocator(), origin, .{
        .kind = .delivery_uncertain,
        .detail = "daemon reported failure_class=uncertain_delivery",
        .connection_usable = true,
    });
    try t.expect(std.mem.indexOf(u8, message, "delivery became uncertain") != null);
    try t.expect(std.mem.indexOf(u8, message, "mutation may have applied") != null);
    try t.expect(std.mem.indexOf(u8, message, "NOT resent automatically") != null);
    try t.expect(paneldrive.Failure.uncertain(.{ .kind = .malformed_reply, .detail = "InvalidPanelId" }));
}

test "relay to explicit direct fallback shares one deadline for ui_wait_event" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var scratch: UiScratch = undefined;
    try scratch.init("fallback-deadline", true);
    defer scratch.deinit();

    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-panel-legacy-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    const listener = try directDropListener(path);
    defer _ = c.close(listener);
    const server = try std.Thread.spawn(.{}, LegacyPanelDaemonScript.run, .{LegacyPanelDaemonScript{
        .listener = listener,
        .delay_us = 90_000,
    }});
    defer server.join();

    const old_pool = panel_pool;
    var pool = paneldrive.Pool.init(t.allocator);
    defer pool.deinit();
    panel_pool = &pool;
    defer panel_pool = old_pool;
    _ = c.setenv("SKETERM_MUX_SOCKET", path.ptr, 1);
    _ = c.setenv("SKETERM_SESSION", "legacy-session", 1);
    defer _ = c.unsetenv("SKETERM_MUX_SOCKET");
    defer _ = c.unsetenv("SKETERM_SESSION");
    _ = c.unsetenv("SKETERM_SESSION_ORIGIN_ID");

    var fake = FakeBackend{
        .responses = &.{"{\"ok\":true,\"events\":[{\"component\":\"ok\",\"kind\":\"click\",\"value\":\"yes\",\"ts\":1}],\"dropped\":0}"},
        .allocator = t.allocator,
    };
    defer fake.deinit();
    const response = handleMessage(arena_state.allocator(), fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"timeout_ms":250}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, response, "yes") != null);
    try t.expectEqual(@as(usize, 1), fake.timeouts.items.len);
    try t.expect(fake.timeouts.items[0] > 0);
    try t.expect(fake.timeouts.items[0] < 210);
}

test "direct GUI write and reply loss preserve delivery phase" {
    const t = std.testing;
    var missing_buf: [256:0]u8 = undefined;
    const missing = try std.fmt.bufPrintZ(&missing_buf, "/tmp/sketerm-direct-missing-{d}.sock", .{c.getpid()});
    _ = c.unlink(missing.ptr);
    var unavailable = RealBackend{ .sock_path = missing };
    switch (RealBackend.talkFor(@ptrCast(&unavailable), t.allocator, "{}", 250)) {
        .failure => |failure| try t.expectEqual(.pre_delivery, failure.delivery),
        .reply => |reply| {
            t.allocator.free(reply);
            return error.UnexpectedReply;
        },
    }

    const cases = [_]struct {
        suffix: []const u8,
        mode: DirectDropScript.Mode,
        bytes: usize,
    }{
        .{ .suffix = "partial", .mode = .after_prefix, .bytes = 2 << 20 },
        .{ .suffix = "full", .mode = .after_line, .bytes = 16 },
    };
    for (cases) |case| {
        var path_buf: [256:0]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-direct-{s}-{d}.sock", .{ case.suffix, c.getpid() });
        _ = c.unlink(path.ptr);
        defer _ = c.unlink(path.ptr);
        const listener = try directDropListener(path);
        defer _ = c.close(listener);
        const thread = try std.Thread.spawn(.{}, DirectDropScript.run, .{DirectDropScript{
            .listener = listener,
            .mode = case.mode,
        }});
        const line = try t.allocator.alloc(u8, case.bytes);
        defer t.allocator.free(line);
        @memset(line, 'x');
        var backend = RealBackend{ .sock_path = path };
        const result = RealBackend.talkFor(@ptrCast(&backend), t.allocator, line, 2_000);
        switch (result) {
            .failure => |failure| try t.expectEqual(.uncertain_delivery, failure.delivery),
            .reply => |reply| {
                t.allocator.free(reply);
                return error.UnexpectedReply;
            },
        }
        thread.join();
    }
}

test "expired direct deadlines dispatch neither mutations nor event drains" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
    defer fake.deinit();
    var transport = UiTransport{
        .arena = arena_state.allocator(),
        .backend = fake.backend(),
        .session = "s",
        .mode = .gui_socket,
    };
    const expired = clock.nowMs() - 1;
    for ([_]protocol.Request{
        .{ .cmd = "panel-patch", .panel_id = 1, .patch = "[]" },
        .{ .cmd = "panel-events", .panel_id = 1 },
    }) |request_value| {
        const reply = transport.directUntil(request_value, expired);
        try t.expect(!reply.ok);
        try t.expectEqual(IpcDelivery.pre_delivery, reply.delivery);
        try t.expect(std.mem.indexOf(u8, reply.err, "resend_safe=true") != null);
    }
    try t.expectEqual(@as(usize, 0), fake.requests.items.len);

    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-direct-expired-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    const listener = try directDropListener(path);
    defer _ = c.close(listener);
    var backend = RealBackend{ .sock_path = path };
    switch (RealBackend.talkFor(@ptrCast(&backend), t.allocator, "mutation", 0)) {
        .failure => |failure| try t.expectEqual(.pre_delivery, failure.delivery),
        .reply => |response| {
            t.allocator.free(response);
            return error.UnexpectedReply;
        },
    }
    var pfd = c.struct_pollfd{ .fd = listener, .events = c.POLLIN, .revents = 0 };
    try t.expectEqual(@as(c_int, 0), c.poll(&pfd, 1, 0));
}

test "direct mutation and event-drain reply loss are never described as missed-nothing" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const failures = [_]?DirectTalkFailure{
        .{ .err = error.NoResponse, .delivery = .uncertain_delivery },
        .{ .err = error.NoResponse, .delivery = .uncertain_delivery },
        .{ .err = error.ConnectFailed, .delivery = .pre_delivery },
    };
    var fake = FakeBackend{
        .responses = &.{},
        .talk_failures = &failures,
        .allocator = t.allocator,
    };
    defer fake.deinit();
    var transport = UiTransport{
        .arena = arena_state.allocator(),
        .backend = fake.backend(),
        .session = "s",
        .mode = .gui_socket,
    };
    const mutation = transport.direct(.{ .cmd = "panel-patch", .panel_id = 1, .patch = "[]" }, 1_000);
    try t.expect(!mutation.ok);
    try t.expect(std.mem.indexOf(u8, mutation.err, "mutation_may_have_applied=true") != null);
    try t.expect(std.mem.indexOf(u8, mutation.err, "resend_safe=false") != null);
    const events = transport.direct(.{ .cmd = "panel-events", .panel_id = 1 }, 1_000);
    try t.expect(!events.ok);
    try t.expect(std.mem.indexOf(u8, events.err, "events_may_have_been_drained=true") != null);
    try t.expect(std.mem.indexOf(u8, events.err, "Nothing was missed") == null);
    const safe = transport.direct(.{ .cmd = "panel-show", .document = "{}" }, 1_000);
    try t.expect(!safe.ok);
    try t.expect(std.mem.indexOf(u8, safe.err, "failure_class=pre_delivery") != null);
    try t.expect(std.mem.indexOf(u8, safe.err, "mutation_may_have_applied=false") != null);
}

test "ui_wait_event reports that a lost direct reply may already have drained events" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var scratch: UiScratch = undefined;
    try scratch.init("event-loss", true);
    defer scratch.deinit();
    const failures = [_]?DirectTalkFailure{
        .{ .err = error.NoResponse, .delivery = .uncertain_delivery },
    };
    var fake = FakeBackend{
        .responses = &.{},
        .talk_failures = &failures,
        .allocator = t.allocator,
    };
    defer fake.deinit();
    const response = handleMessage(arena_state.allocator(), fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"session":"","timeout_ms":5000}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, response, "isError") != null);
    try t.expect(std.mem.indexOf(u8, response, "events_may_have_been_drained=true") != null);
    try t.expect(std.mem.indexOf(u8, response, "Events may have been drained") != null);
    try t.expect(std.mem.indexOf(u8, response, "Nothing was missed") == null);
    try t.expectEqual(@as(usize, 1), fake.requests.items.len);
}

test "ui_wait_event distinguishes pre-delivery unavailability from confirmed closure" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var scratch: UiScratch = undefined;
    try scratch.init("event-delivery-state", true);
    defer scratch.deinit();

    const failures = [_]?DirectTalkFailure{
        .{ .err = error.ConnectFailed, .delivery = .pre_delivery },
    };
    var unavailable = FakeBackend{
        .responses = &.{},
        .talk_failures = &failures,
        .allocator = t.allocator,
    };
    defer unavailable.deinit();
    const unknown = handleMessage(arena_state.allocator(), unavailable.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"session":"","timeout_ms":5000}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, unknown, "isError") != null);
    try t.expect(std.mem.indexOf(u8, unknown, "failure_class=pre_delivery") != null);
    try t.expect(std.mem.indexOf(u8, unknown, "events_may_have_been_drained=false") != null);
    try t.expect(std.mem.indexOf(u8, unknown, "resend_safe=true") != null);
    try t.expect(std.mem.indexOf(u8, unknown, "UNKNOWN") != null);
    try t.expect(std.mem.indexOf(u8, unknown, "confirmed") == null);
    try t.expect(std.mem.indexOf(u8, unknown, "Nothing was missed") == null);

    var closed = FakeBackend{
        .responses = &.{"{\"ok\":false,\"error\":\"no such panel\"}"},
        .allocator = t.allocator,
    };
    defer closed.deinit();
    const confirmed = handleMessage(arena_state.allocator(), closed.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"session":"","timeout_ms":5000}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, confirmed, "isError") != null);
    try t.expect(std.mem.indexOf(u8, confirmed, "confirmed") != null);
    try t.expect(std.mem.indexOf(u8, confirmed, "not live") != null);
    try t.expect(std.mem.indexOf(u8, confirmed, "UNKNOWN") == null);
}

test "maximum panel document crosses the direct GUI request boundary intact" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prefix = "{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"ok\"}},\"padding\":\"";
    const suffix = "\"}";
    const document = try arena.alloc(u8, paneldoc.MAX_JSON_BYTES);
    @memcpy(document[0..prefix.len], prefix);
    const body = document[prefix.len .. document.len - suffix.len];
    var i: usize = 0;
    while (i + 1 < body.len) : (i += 2) {
        body[i] = '\\';
        body[i + 1] = '"';
    }
    if (i < body.len) body[i] = 'x';
    @memcpy(document[document.len - suffix.len ..], suffix);
    var parsed_doc = try paneldoc.Document.parse(arena, document, null);
    defer parsed_doc.deinit();

    var fake = FakeBackend{
        .responses = &.{"{\"ok\":true,\"panel_id\":17}"},
        .allocator = t.allocator,
    };
    defer fake.deinit();
    var transport = UiTransport{
        .arena = arena,
        .backend = fake.backend(),
        .session = "boundary-session",
        .mode = .gui_socket,
    };
    const reply = transport.direct(.{
        .cmd = "panel-show",
        .session = "boundary-session",
        .name = "boundary",
        .target = "tab",
        .document = document,
    }, 5_000);
    try t.expect(reply.ok);
    try t.expectEqual(@as(usize, 1), fake.requests.items.len);
    const sent = fake.requests.items[0];
    try t.expect(sent.len > (1 << 20));
    try t.expect(sent.len <= protocol.MAX_LINE);
    var parsed = try protocol.parseRequest(arena, sent);
    defer parsed.deinit();
    try t.expectEqual(document.len, parsed.value.document.?.len);
    try t.expectEqualStrings(document, parsed.value.document.?);
}

test "ui_wait_event polls instead of blocking the GUI, and reports drops" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("wait", true);
    defer scratch.deinit();

    // panel-events answers immediately every time (it runs on the GLib
    // main loop); the WAIT is this tool's poll loop.
    var fake = FakeBackend{
        .responses = &.{
            "{\"ok\":true,\"events\":[],\"dropped\":0}",
            "{\"ok\":true,\"events\":[],\"dropped\":2}",
            "{\"ok\":true,\"events\":[{\"component\":\"ok\",\"kind\":\"click\",\"value\":\"approve\",\"ts\":42}],\"dropped\":0}",
        },
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();

    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"timeout_ms":5000}}}
    ).?;
    try std.testing.expectEqual(@as(usize, 3), fake.requests.items.len);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "\"cmd\":\"panel-events\"") != null);
    {
        const shape = try expectToolResultShape(arena, "ui_wait_event", try rpcToolResult(arena, resp));
        const sc = shape.object.get("structuredContent").?.object;
        const evs = sc.get("events").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), evs.len);
        try std.testing.expectEqualStrings("approve", evs[0].object.get("value").?.string);
        // The drop counter seen on an earlier poll is not lost.
        try std.testing.expectEqual(@as(i64, 2), sc.get("dropped").?.integer);
        try std.testing.expect(!sc.get("timed_out").?.bool);
        const text = shape.object.get("content").?.array.items[0].object.get("text").?.string;
        try std.testing.expect(std.mem.indexOf(u8, text, "OLDER interaction(s) were discarded") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "click ok = approve") != null);
    }
    // Two poll ticks were slept, not spun.
    try std.testing.expectEqual(@as(i64, 2 * UI_POLL_MS), fake.clock_ms);
    try std.testing.expectEqualSlices(i64, &.{ 5000, 4900, 4800 }, fake.timeouts.items);
}

test "ui_wait_event times out honestly and clamps the budget" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("timeout", true);
    defer scratch.deinit();

    var bufs: [4][]const u8 = @splat("{\"ok\":true,\"events\":[],\"dropped\":0}");
    var fake = FakeBackend{ .responses = &bufs, .allocator = std.testing.allocator };
    defer fake.deinit();

    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"timeout_ms":250}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "isError") == null);
    {
        const shape = try expectToolResultShape(arena, "ui_wait_event", try rpcToolResult(arena, resp));
        const sc = shape.object.get("structuredContent").?.object;
        try std.testing.expect(sc.get("timed_out").?.bool);
        try std.testing.expectEqual(@as(usize, 0), sc.get("events").?.array.items.len);
        const text = shape.object.get("content").?.array.items[0].object.get("text").?.string;
        try std.testing.expect(std.mem.indexOf(u8, text, "still showing") != null);
    }
    try std.testing.expectEqualSlices(i64, &.{ 250, 150, 50 }, fake.timeouts.items);

    // A wait longer than the watchdog allows is clamped, not promised.
    var bufs2: [1][]const u8 = @splat("{\"ok\":true,\"events\":[{\"component\":\"s\",\"kind\":\"change\",\"value\":3,\"ts\":1}],\"dropped\":0}");
    var fake2 = FakeBackend{ .responses = &bufs2, .allocator = std.testing.allocator };
    defer fake2.deinit();
    const clamped = handleMessage(arena, fake2.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"timeout_ms":999999}}}
    ).?;
    {
        const shape = try expectToolResultShape(arena, "ui_wait_event", try rpcToolResult(arena, clamped));
        const evs = shape.object.get("structuredContent").?.object.get("events").?.array.items;
        try std.testing.expectEqualStrings("change", evs[0].object.get("kind").?.string);
    }

    // A panel that went away ends the wait at once, and says so.
    var bufs3: [1][]const u8 = @splat("{\"ok\":false,\"error\":\"no such panel\"}");
    var fake3 = FakeBackend{ .responses = &bufs3, .allocator = std.testing.allocator };
    defer fake3.deinit();
    const gone = handleMessage(arena, fake3.backend(),
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"timeout_ms":60000}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, gone, "isError") != null);
    try std.testing.expect(std.mem.indexOf(u8, gone, "confirmed") != null);
    try std.testing.expect(std.mem.indexOf(u8, gone, "not live") != null);
    try std.testing.expect(std.mem.indexOf(u8, gone, "UNKNOWN") == null);
}

test "ui_wait_event includes name resolution and every exchange in one deadline" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("whole-deadline", true);
    defer scratch.deinit();

    var fake = FakeBackend{
        .responses = &.{
            "{\"ok\":true,\"panels\":[{\"panel_id\":9,\"name\":\"slow\"}]}",
            "{\"ok\":true,\"events\":[],\"dropped\":0}",
        },
        .talk_delays_ms = &.{ 120, 80 },
        .allocator = t.allocator,
    };
    defer fake.deinit();
    const response = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"name":"slow","timeout_ms":250}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, response, "timed_out") != null);
    try t.expect(std.mem.indexOf(u8, response, "isError") == null);
    try t.expectEqual(@as(i64, 250), fake.clock_ms);
    try t.expectEqualSlices(i64, &.{ 250, 130 }, fake.timeouts.items);
    try t.expectEqual(@as(usize, 2), fake.requests.items.len);
}

test "ui_* tools need live transport while store-only behavior remains" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("nogui", false);
    defer scratch.deinit();

    var fake = FakeBackend{ .responses = &.{}, .allocator = std.testing.allocator };
    defer fake.deinit();

    for ([_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_show","arguments":{"name":"x","document":{}}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_close","arguments":{"panel_id":1}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":1}}}
        ,
    }) |msg| {
        const resp = handleMessage(arena, fake.backend(), msg).?;
        try std.testing.expect(std.mem.indexOf(u8, resp, "isError") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "panel transport") != null);
    }
    // Nothing was even attempted on the socket.
    try std.testing.expectEqual(@as(usize, 0), fake.requests.items.len);

    // The saved half is independent of the GUI: save, list, delete.
    const saved = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"kept","session":"s2","document":{"title":"Kept","root":"t","components":{"t":{"type":"text","text":"hi"}}}}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, saved, "isError") == null);

    const listed = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"ui_panels","arguments":{"session":"s2"}}}
    ).?;
    {
        const shape = try expectToolResultShape(arena, "ui_panels", try rpcToolResult(arena, listed));
        const sc = shape.object.get("structuredContent").?.object;
        try std.testing.expectEqual(std.json.Value{ .null = {} }, sc.get("live").?);
        try std.testing.expect(std.mem.indexOf(u8, sc.get("live_error").?.string, "panel transport") != null);
        try std.testing.expectEqual(@as(usize, 1), sc.get("saved").?.array.items.len);
    }
    try std.testing.expect(std.mem.indexOf(u8, listed, "kept") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "Kept") != null);

    const deleted = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"ui_delete","arguments":{"name":"kept","session":"s2"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, deleted, "isError") == null);
    try std.testing.expect(!panelstore.existsScoped(arena, .{ .session = "s2" }, "kept"));

    // Deleting what is not there names the panel and the session.
    const again = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"ui_delete","arguments":{"name":"kept","session":"s2"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, again, "isError") != null);
    try std.testing.expect(std.mem.indexOf(u8, again, "kept") != null);
}

test "store-only panel tools refuse an unidentified exact daemon environment" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var scratch: UiScratch = undefined;
    try scratch.init("pre-panel-store", false);
    defer scratch.deinit();
    const old_pool = panel_pool;
    panel_pool = null;
    defer panel_pool = old_pool;
    _ = c.setenv("SKETERM_MUX_SOCKET", "/tmp/exact-pre-panel/mux.sock", 1);
    _ = c.setenv("SKETERM_SESSION", "old-session", 1);
    _ = c.unsetenv("SKETERM_SESSION_ORIGIN_ID");
    defer _ = c.unsetenv("SKETERM_MUX_SOCKET");
    defer _ = c.unsetenv("SKETERM_SESSION");

    var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
    defer fake.deinit();
    const saved = handleMessage(arena_state.allocator(), fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"offline","document":{"title":"Offline","root":"r","components":{"r":{"type":"text","text":"saved"}}}}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, saved, "isError") != null);
    try t.expect(std.mem.indexOf(u8, saved, "refusing to downgrade") != null);
    const listed = handleMessage(arena_state.allocator(), fake.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_panels","arguments":{}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, listed, "saved_error") != null);
    try t.expect(std.mem.indexOf(u8, listed, "refusing to downgrade") != null);
    const deleted = handleMessage(arena_state.allocator(), fake.backend(),
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ui_delete","arguments":{"name":"offline"}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, deleted, "isError") != null);
    try t.expect(std.mem.indexOf(u8, deleted, "refusing to downgrade") != null);
    try t.expectEqual(@as(usize, 0), fake.requests.items.len);

    try t.expect(!panelstore.existsScoped(t.allocator, .{ .session = "old-session" }, "offline"));
}

test "ui panels are session-scoped, including a session with a space" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("scope", false);
    defer scratch.deinit();

    var fake = FakeBackend{ .responses = &.{}, .allocator = std.testing.allocator };
    defer fake.deinit();

    // A legal daemon session name the old charset rule would have
    // rejected outright.
    const save_a =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"p","session":"my work","document":{"title":"Mine","root":"t","components":{"t":{"type":"text","text":"a"}}}}}}
    ;
    try std.testing.expect(std.mem.indexOf(u8, handleMessage(arena, fake.backend(), save_a).?, "isError") == null);
    const save_b =
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"p","session":"other","document":{"title":"Theirs","root":"t","components":{"t":{"type":"text","text":"b"}}}}}}
    ;
    try std.testing.expect(std.mem.indexOf(u8, handleMessage(arena, fake.backend(), save_b).?, "isError") == null);

    const mine = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ui_panels","arguments":{"session":"my work"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, mine, "Mine") != null);
    try std.testing.expect(std.mem.indexOf(u8, mine, "Theirs") == null);
}

test "explicit empty ui session selects sessionless despite inherited session" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("explicit-empty", false);
    defer scratch.deinit();
    _ = c.setenv("SKETERM_SESSION", "inherited-session", 1);
    defer _ = c.unsetenv("SKETERM_SESSION");

    var fake = FakeBackend{ .responses = &.{}, .allocator = std.testing.allocator };
    defer fake.deinit();
    const explicit_empty = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"empty","session":"","document":{"root":"t","components":{"t":{"type":"text","text":"none"}}}}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, explicit_empty, "isError") == null);
    try std.testing.expect(panelstore.existsScoped(arena, .sessionless, "empty"));
    try std.testing.expect(!panelstore.existsScoped(arena, .{ .session = "inherited-session" }, "empty"));

    const absent = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"inherited","document":{"root":"t","components":{"t":{"type":"text","text":"env"}}}}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, absent, "isError") == null);
    try std.testing.expect(panelstore.existsScoped(arena, .{ .session = "inherited-session" }, "inherited"));
    try std.testing.expect(!panelstore.existsScoped(arena, .sessionless, "inherited"));
}

test "read_screen last_command extracts the OSC 133 zone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeBackend{
        .responses = &.{"{\"ok\":true,\"last\":{\"text\":\"hi\\n\",\"exit\":3}}"},
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();

    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"read_screen","arguments":{"pane":2,"last_command":true}}}
    ).?;
    const parsed = try expectToolResultShape(arena, "read_screen", try rpcToolResult(arena, resp));
    const sc = parsed.object.get("structuredContent").?.object;
    try std.testing.expectEqual(@as(i64, 3), sc.get("exit_status").?.integer);
    try std.testing.expect(sc.get("last_command").?.bool);
    try std.testing.expectEqualStrings("hi\n", sc.get("output").?.string);
    // The output rides the text lane behind its payload divider.
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expectEqualStrings("exit_status: 3\n--- command ---\nhi\n", text);
    try std.testing.expectEqual(@as(usize, 1), fake.requests.items.len);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "\"last_command\":true") != null);
}

test "run_command settles via seq polling" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // send-text ok → seq 5 (start) → seq 7 (changed) → seq 7 (quiet
    // window elapses via fake clock) → screen-info + get-text for the
    // final read.
    const screen5 = "{\"ok\":true,\"screen\":{\"rows\":24,\"cols\":80,\"cursor_row\":0,\"cursor_col\":0,\"alt_screen\":false,\"seq\":5}}";
    const screen7 = "{\"ok\":true,\"screen\":{\"rows\":24,\"cols\":80,\"cursor_row\":1,\"cursor_col\":0,\"alt_screen\":false,\"seq\":7}}";
    var fake = FakeBackend{
        .responses = &.{
            "{\"ok\":true}", // send-text
            screen5, // poll 1: baseline
            screen7, // poll 2: changed → reset quiet timer
            screen7, // poll 3: unchanged
            screen7, // poll 4: unchanged, quiet window passed → settled
            screen7, // final readScreenText: screen-info
            "{\"ok\":true,\"text\":\"$ echo hi\\nhi\\n\"}", // final get-text
        },
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();

    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"run_command","arguments":{"pane":1,"command":"echo hi","quiet_ms":100,"timeout_ms":5000}}}
    ).?;
    const parsed = try expectToolResultShape(arena, "run_command", try rpcToolResult(arena, resp));
    const sc = parsed.object.get("structuredContent").?.object;
    try std.testing.expectEqualStrings("echo hi", sc.get("command").?.string);
    try std.testing.expectEqualStrings("screen", sc.get("source").?.string);
    try std.testing.expect(sc.get("settled").?.bool);
    try std.testing.expect(!sc.get("timed_out").?.bool);
    // The screen metadata is a FACT now, not text inside a text value.
    try std.testing.expectEqual(@as(i64, 7), sc.get("seq").?.integer);
    try std.testing.expectEqual(@as(i64, 80), sc.get("cols").?.integer);
    try std.testing.expectEqualStrings("$ echo hi\nhi\n", sc.get("output").?.string);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, text, "--- screen ---\n$ echo hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, textProse(text), "timeout") == null);
    // First request was the send-text with a trailing CR.
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "\"cmd\":\"send-text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "echo hi\\r") != null);
}

test "wait_idle times out when output keeps flowing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // seq keeps incrementing forever; fake clock advances 50ms per
    // poll, timeout at 200ms.
    var bufs: [8][]const u8 = undefined;
    var storage: [8][96]u8 = undefined;
    for (0..8) |n| {
        bufs[n] = std.fmt.bufPrint(&storage[n], "{{\"ok\":true,\"screen\":{{\"seq\":{d}}}}}", .{n}) catch unreachable;
    }
    var fake = FakeBackend{ .responses = &bufs, .allocator = std.testing.allocator };
    defer fake.deinit();

    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"wait_idle","arguments":{"quiet_ms":100,"timeout_ms":200}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "timeout") != null);
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

test "stagedPartPath preserves the extension" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.expectEqualStrings("/etc/systemd/system/hohenheim.sketerm-part.service", try @import("mcp_term.zig").stagedPartPath(arena, "/etc/systemd/system/hohenheim.service"));
    // Last-suffix preservation (what suffix-sensitive validators need).
    try t.expectEqualStrings("/srv/app.tar.sketerm-part.gz", try @import("mcp_term.zig").stagedPartPath(arena, "/srv/app.tar.gz"));
    try t.expectEqualStrings("/usr/local/bin/hohenheim.sketerm-part", try @import("mcp_term.zig").stagedPartPath(arena, "/usr/local/bin/hohenheim"));
    // Dotfiles and trailing dots don't split.
    try t.expectEqualStrings("/home/x/.bashrc.sketerm-part", try @import("mcp_term.zig").stagedPartPath(arena, "/home/x/.bashrc"));
    try t.expectEqualStrings("/tmp/weird..sketerm-part", try @import("mcp_term.zig").stagedPartPath(arena, "/tmp/weird."));
}

test "chromiumFamily basename matching" {
    const t = std.testing;
    try t.expect(chromiumFamily("chromium"));
    try t.expect(chromiumFamily("/usr/bin/chromium"));
    try t.expect(chromiumFamily("/opt/google/chrome/google-chrome-stable"));
    try t.expect(chromiumFamily("brave-browser"));
    try t.expect(chromiumFamily("electron22"));
    try t.expect(!chromiumFamily("firefox"));
    try t.expect(!chromiumFamily("/usr/bin/gedit"));
}

test "findHex64 finds standalone sha tokens" {
    const t = std.testing;
    const sha = "a" ** 64;
    try t.expectEqualStrings(sha, @import("mcp_term.zig").findHex64("prefix " ++ sha ++ "  /path/file").?);
    try t.expect(@import("mcp_term.zig").findHex64("short deadbeef only") == null);
    // 65 hex chars: not a standalone 64-run.
    try t.expect(@import("mcp_term.zig").findHex64("f" ** 65) == null);
}

test "pickFreePort and tcpListening agree" {
    const t = std.testing;
    const port = @import("mcp_term.zig").pickFreePort() orelse return error.SkipZigTest;
    try t.expect(port > 0);
    // Nothing listens there after the probe socket closed.
    try t.expect(!@import("mcp_term.zig").tcpListening(port, 200));
}

test "localCopyAtomic copies, verifies and renames" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sbuf: [128]u8 = undefined;
    var dbuf: [128]u8 = undefined;
    const src = try std.fmt.bufPrintZ(&sbuf, "/tmp/sketerm-xfer-src-{d}", .{c.getpid()});
    const dst = try std.fmt.bufPrintZ(&dbuf, "/tmp/sketerm-xfer-dst-{d}", .{c.getpid()});
    const f = c.fopen(src.ptr, "wb") orelse return error.SkipZigTest;
    _ = c.fwrite("hello transfer", 1, 14, f);
    _ = c.fclose(f);
    defer _ = c.unlink(src.ptr);
    defer _ = c.unlink(dst.ptr);
    const r = try @import("mcp_term.zig").localCopyAtomic(arena, src, dst);
    try t.expect(r == .ok);
    try t.expectEqual(@as(u64, 14), r.ok.bytes);
    try t.expectEqual(@as(?u64, 14), @import("mcp_term.zig").fileSize(dst));
    const src_sha = @import("mcp_term.zig").sha256File(src).?;
    try t.expectEqualStrings(&src_sha, &r.ok.sha);
    // Missing source is a described error, not a crash.
    const bad = try @import("mcp_term.zig").localCopyAtomic(arena, "/nonexistent/nope", dst);
    try t.expect(bad == .err);
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

test "buildLaunchArgv: args array appends; string command + args = bare executable" {
    const t = std.testing;
    const a = t.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parse = struct {
        fn go(al: std.mem.Allocator, json: []const u8) std.json.Value {
            return std.json.parseFromSliceLeaky(std.json.Value, al, json, .{}) catch unreachable;
        }
    }.go;

    // String command alone: shell-wrapped (unchanged behavior).
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        const r = try buildLaunchArgv(arena, &argv, parse(arena, "{\"command\":\"echo hi\"}"));
        try t.expect(r == .ok and !r.ok.argv_form);
        try t.expectEqual(@as(usize, 3), argv.items.len);
        try t.expectEqualStrings("/bin/sh", argv.items[0]);
        try t.expectEqualStrings("echo hi", argv.items[2]);
    }
    // String command + args: BARE executable + argv — the regression
    // (args used to be silently dropped, so the app saw argc==1).
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        const r = try buildLaunchArgv(arena, &argv, parse(arena, "{\"command\":\"/opt/game/bin\",\"args\":[\"/data/dir\",\"-w\",\"-nobink\"]}"));
        try t.expect(r == .ok and r.ok.argv_form);
        try t.expectEqual(@as(usize, 4), argv.items.len);
        try t.expectEqualStrings("/opt/game/bin", argv.items[0]);
        try t.expectEqualStrings("/data/dir", argv.items[1]);
        try t.expectEqualStrings("-nobink", argv.items[3]);
    }
    // Array command + args: appended.
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        const r = try buildLaunchArgv(arena, &argv, parse(arena, "{\"command\":[\"/opt/game/bin\",\"-w\"],\"args\":[\"-nobink\"]}"));
        try t.expect(r == .ok and r.ok.argv_form);
        try t.expectEqual(@as(usize, 3), argv.items.len);
        try t.expectEqualStrings("-nobink", argv.items[2]);
    }
    // Bad shapes are described errors, not silent drops.
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        const r = try buildLaunchArgv(arena, &argv, parse(arena, "{\"command\":\"x\",\"args\":\"-w\"}"));
        try t.expect(r == .err);
    }
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        const r = try buildLaunchArgv(arena, &argv, parse(arena, "{\"args\":[\"-w\"]}"));
        try t.expect(r == .err);
    }
}

test "applyDebugWrap: gdb_commands become crash-point -ex args before --args" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parse = struct {
        fn go(al: std.mem.Allocator, json: []const u8) std.json.Value {
            return std.json.parseFromSliceLeaky(std.json.Value, al, json, .{}) catch unreachable;
        }
    }.go;

    // gdb + gdb_commands: -ex pairs land AFTER info registers, BEFORE --args.
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        try argv.appendSlice(arena, &.{ "/opt/app", "-w" });
        const r = try applyDebugWrap(arena, &argv, parse(arena, "{\"debug\":\"gdb\",\"gdb_commands\":[\"frame 3\",\"p *ctx\"]}"));
        try t.expect(r == .note);
        const has = struct {
            fn go(items: []const []const u8, needle: []const u8) bool {
                for (items) |it| {
                    if (std.mem.eql(u8, it, needle)) return true;
                }
                return false;
            }
        }.go;
        try t.expectEqualStrings("gdb", argv.items[0]);
        try t.expectEqualStrings("-batch", argv.items[2]);
        // Nuisance signals are passed through, or batch mode reports
        // the wrong stop and quits before the real fault.
        try t.expect(has(argv.items, "handle SIGPIPE nostop noprint pass"));
        try t.expect(has(argv.items, "handle SIG33 nostop noprint pass"));
        // A worker-thread crash needs every thread's stack.
        try t.expect(has(argv.items, "thread apply all bt full"));
        try t.expect(has(argv.items, "info registers"));
        // run precedes the reporting commands.
        var run_at: usize = 0;
        var bt_at: usize = 0;
        for (argv.items, 0..) |it, i| {
            if (std.mem.eql(u8, it, "run")) run_at = i;
            if (std.mem.eql(u8, it, "thread apply all bt full")) bt_at = i;
        }
        try t.expect(run_at > 0 and bt_at > run_at);
        // User commands run at the crash point, in order, last.
        const tail = argv.items[argv.items.len - 7 ..];
        const want_tail = [_][]const u8{ "-ex", "frame 3", "-ex", "p *ctx", "--args", "/opt/app", "-w" };
        for (want_tail, tail) |w, g| try t.expectEqualStrings(w, g);
        try t.expect(std.mem.indexOf(u8, r.note, "2 extra gdb command(s)") != null);
    }
    // Plain gdb: unchanged shape, --args directly after info registers.
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        try argv.append(arena, "/opt/app");
        const r = try applyDebugWrap(arena, &argv, parse(arena, "{\"debug\":\"gdb\"}"));
        try t.expect(r == .note);
        try t.expectEqualStrings("--args", argv.items[argv.items.len - 2]);
    }
    // gdb_commands without/with the wrong wrapper: described errors.
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        try argv.append(arena, "x");
        try t.expect((try applyDebugWrap(arena, &argv, parse(arena, "{\"gdb_commands\":[\"bt\"]}"))) == .err);
        try t.expect((try applyDebugWrap(arena, &argv, parse(arena, "{\"debug\":\"valgrind\",\"gdb_commands\":[\"bt\"]}"))) == .err);
        try t.expect((try applyDebugWrap(arena, &argv, parse(arena, "{\"debug\":\"gdb\",\"gdb_commands\":[\"\"]}"))) == .err);
        try t.expect((try applyDebugWrap(arena, &argv, parse(arena, "{\"debug\":\"gdb\",\"gdb_commands\":\"bt\"}"))) == .err);
        try t.expectEqualStrings("x", argv.items[0]); // argv untouched on error
    }
    // No debug param: no-op.
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        try argv.append(arena, "x");
        const r = try applyDebugWrap(arena, &argv, parse(arena, "{}"));
        try t.expect(r == .note and r.note.len == 0);
        try t.expectEqual(@as(usize, 1), argv.items.len);
    }
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

    const def = mcp_tools.find(tool) orelse return error.UnknownTool;
    const schema_text = def.output_schema orelse return error.NoOutputSchema;
    const schema = (try std.json.parseFromSliceLeaky(std.json.Value, arena, schema_text, .{})).object;
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

test "commandCompletionResult: facts in structuredContent, compact prose in the text lane" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const done = try commandCompletionResult(
        arena,
        .{ .state = .completed, .exit_status = 0, .source = .shell_integration },
        true,
        "hello world",
        "command",
        null,
    );
    const parsed = try expectToolResultShape(arena, "term_wait_command", done);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expectEqualStrings("completed", sc.get("state").?.string);
    try t.expect(sc.get("command_sent").?.bool);
    try t.expectEqual(@as(i64, 0), sc.get("exit_status").?.integer);
    try t.expect(!sc.get("timed_out").?.bool);
    try t.expectEqualStrings("shell_integration", sc.get("completion_source").?.string);
    try t.expectEqualStrings("hello world", sc.get("output").?.string);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expectEqualStrings("completed: exit 0 (shell_integration)\n--- command ---\nhello world", text);
    // Soft outcomes are facts, never tool errors.
    try t.expect(parsed.object.get("isError") == null);
}

test "commandCompletionResult: a refused send stays a soft failure" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const refused = try commandCompletionResult(
        arena,
        .{ .state = .unsupported },
        false,
        null,
        null,
        "shell integration is unavailable for this shell",
    );
    const parsed = try expectToolResultShape(arena, "term_wait_command", refused);
    const obj = parsed.object;
    try t.expect(obj.get("isError") == null);
    const sc = obj.get("structuredContent").?.object;
    try t.expectEqualStrings("unsupported", sc.get("state").?.string);
    try t.expect(!sc.get("command_sent").?.bool);
    try t.expectEqual(std.json.Value{ .null = {} }, sc.get("exit_status").?);
    const text = obj.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, text, "the command was NOT sent") != null);
    try t.expect(std.mem.indexOf(u8, text, "shell integration is unavailable") != null);

    // A timed-out still-running command: also isError:false.
    const running = try commandCompletionResult(
        arena,
        .{ .state = .running, .timed_out = true },
        true,
        "partial output",
        "screen",
        "timeout expired while the command was still running",
    );
    const rparsed = try expectToolResultShape(arena, "term_run", running);
    try t.expect(rparsed.object.get("isError") == null);
    try t.expect(rparsed.object.get("structuredContent").?.object.get("timed_out").?.bool);
}

test "list_terminals flattens the GUI's tabs into addressable panes" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reply = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"ok":true,"tabs":[
        \\{"id":1,"window":3,"title":"shell","selected":true,"panes":[
        \\{"id":4,"title":"zsh","cwd":"/home/u","pid":0,"rows":24,"cols":80,"focused":true,"zoomed":false},
        \\{"id":5,"title":"logs","cwd":"/var/log","pid":0,"rows":12,"cols":80,"focused":false,"zoomed":true}]},
        \\{"id":2,"window":3,"title":"docs","selected":false,"panes":[]}]}
    , .{});

    const out = try listTerminalsResult(arena, reply);
    const parsed = try expectToolResultShape(arena, "list_terminals", out);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expectEqual(@as(i64, 2), sc.get("count").?.integer);
    try t.expectEqual(@as(i64, 2), sc.get("tabs").?.integer);
    const terms = sc.get("terminals").?.array.items;
    try t.expectEqual(@as(usize, 2), terms.len);
    try t.expectEqual(@as(i64, 4), terms[0].object.get("pane").?.integer);
    try t.expectEqual(@as(i64, 1), terms[0].object.get("tab").?.integer);
    try t.expectEqual(@as(i64, 3), terms[0].object.get("window").?.integer);
    try t.expect(terms[0].object.get("focused").?.bool);
    try t.expect(terms[1].object.get("zoomed").?.bool);
    try t.expectEqualStrings("/var/log", terms[1].object.get("cwd").?.string);
    // Tab-level identity rides every pane, so nothing is lost by
    // flattening — and the text lane is one line per pane.
    try t.expectEqualStrings("shell", terms[1].object.get("tab_title").?.string);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.startsWith(u8, text, "2 pane(s) in 2 tab(s)"));
    try t.expect(std.mem.indexOf(u8, text, "pane 4  tab 1  80x24  focused  zsh  [/home/u]") != null);
    try t.expect(std.mem.indexOf(u8, text, "pane 5  tab 1  80x12  zoomed  logs  [/var/log]") != null);

    // A GUI with nothing open answers the same shape, not an error.
    const empty = try listTerminalsResult(arena, try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"ok\":true,\"tabs\":[]}", .{}));
    const eparsed = try expectToolResultShape(arena, "list_terminals", empty);
    try t.expectEqual(@as(i64, 0), eparsed.object.get("structuredContent").?.object.get("count").?.integer);
}

test "fs failures carry the code their cause deserves" {
    const t = std.testing;
    try t.expectEqual(ErrCode.unavailable, fsErrCode(fsdrive.Error.NotConnected, ""));
    try t.expectEqual(ErrCode.timeout, fsErrCode(fsdrive.Error.Timeout, ""));
    try t.expectEqual(ErrCode.invalid_args, fsErrCode(fsdrive.Error.BadRequest, ""));
    try t.expectEqual(ErrCode.conflict, fsErrCode(fsdrive.Error.Conflict, ""));
    // Only the daemon's own message distinguishes a missing path from
    // any other refusal.
    try t.expectEqual(ErrCode.not_found, fsErrCode(fsdrive.Error.FsOpFailed, "open: No such file or directory"));
    // The spelling the daemon actually sends: a bare errno tag.
    try t.expectEqual(ErrCode.not_found, fsErrCode(fsdrive.Error.FsOpFailed, "NOENT"));
    try t.expectEqual(ErrCode.not_found, fsErrCode(fsdrive.Error.FsOpFailed, "ENOENT"));
    try t.expectEqual(ErrCode.io_failed, fsErrCode(fsdrive.Error.FsOpFailed, "ACCES"));
    try t.expectEqual(ErrCode.io_failed, fsErrCode(fsdrive.Error.FsOpFailed, "permission denied"));
    try t.expect(!ErrCode.not_found.retryable());
    try t.expect(ErrCode.timeout.retryable());
}

test "panel failures are typed by delivery phase, then by what they say" {
    const t = std.testing;
    const pre = IpcReply{ .ok = false, .value = .null, .err = "x", .delivery = .pre_delivery };
    try t.expectEqual(ErrCode.unavailable, uiFailCode(pre));
    const uncertain = IpcReply{ .ok = false, .value = .null, .err = "x", .delivery = .uncertain_delivery };
    try t.expectEqual(ErrCode.io_failed, uiFailCode(uncertain));
    const gone = IpcReply{ .ok = false, .value = .null, .err = "origin session s is no longer present on its exact daemon" };
    try t.expectEqual(ErrCode.not_found, uiFailCode(gone));
    const nogui = IpcReply{ .ok = false, .value = .null, .err = "no compatible GUI is attached to origin session s" };
    try t.expectEqual(ErrCode.unavailable, uiFailCode(nogui));
    const odd = IpcReply{ .ok = false, .value = .null, .err = "the presenter said something new" };
    try t.expectEqual(ErrCode.failed, uiFailCode(odd));

    // Addressing is the CALLER's fault or a missing panel, never io.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bad = try uiResolveErr(arena, .{ .err = "panel_id must be a positive integer (the handle ui_show returned)" });
    try t.expect(std.mem.indexOf(u8, bad, "\"code\":\"invalid_args\"") != null);
    const missing = try uiResolveErr(arena, .{ .err = "no LIVE panel named \"train\" in session s1" });
    try t.expect(std.mem.indexOf(u8, missing, "\"code\":\"not_found\"") != null);
}

test "ui_wait_event's one result shape: timeout and events, both isError:false" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const idle = try uiEventsResult(arena, 7, 250, null, 0, 250);
    const iparsed = try expectToolResultShape(arena, "ui_wait_event", idle);
    try t.expect(iparsed.object.get("isError") == null);
    const isc = iparsed.object.get("structuredContent").?.object;
    try t.expect(isc.get("timed_out").?.bool);
    try t.expectEqual(@as(usize, 0), isc.get("events").?.array.items.len);

    const evs = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\[{"seq":4,"component":"amount","kind":"change","value":12.5,"ts":9}]
    , .{});
    const got = try uiEventsResult(arena, 7, 90, evs, 3, 5000);
    const parsed = try expectToolResultShape(arena, "ui_wait_event", got);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expect(!sc.get("timed_out").?.bool);
    try t.expectEqual(@as(i64, 1), sc.get("count").?.integer);
    try t.expectEqual(@as(i64, 3), sc.get("dropped").?.integer);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, text, "--- events ---\n4 change amount = 12.5") != null);
}
