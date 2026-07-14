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
const platform = @import("../util/platform.zig");
const protocol = @import("protocol.zig");
const appdrive = @import("appdrive.zig");
const termdrive = @import("termdrive.zig");
const marks_mod = @import("../util/marks.zig");

const MCP_HELP =
    \\Usage: sketerm mcp [--shared | --durable | --name NAME] [--socket PATH]
    \\                   [--log DIR]
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
    \\                 across MCP restarts (instance name "default")
    \\  --name NAME    named durable instance; a later `sketerm mcp
    \\                 --name NAME` reconnects to the same daemon
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
    \\  --log DIR      trace everything to DIR: each session gets its
    \\                 own datetime subfolder DIR/YYYYMMDD-HHMMSS/
    \\                 holding every JSON-RPC request and response as
    \\                 one line in mcp-<pid>.jsonl (long lines
    \\                 truncated) and every inline screenshot as
    \\                 img-<pid>-NNNN.png
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
    \\Headless terminal tools (isolated mode; real shells on the
    \\private daemon, no GUI): term_open, term_run, term_send_text,
    \\term_send_keys, term_read, term_wait_idle, term_resize,
    \\term_list, term_close.
    \\
;

const PROTOCOL_VERSION = "2025-06-18";
const SERVER_VERSION = "0.1.0";

/// Pluggable side-effects so the dispatch logic unit-tests without a
/// GUI, sockets, or real sleeps.
pub const Backend = struct {
    ctx: *anyopaque,
    /// One JSON request line to the GUI socket → the JSON response
    /// line (caller frees). The line has no trailing newline.
    talk: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, line: []const u8) anyerror![]u8,
    sleepMs: *const fn (ctx: *anyopaque, ms: u32) void,
    nowMs: *const fn (ctx: *anyopaque) i64,
};

/// Parsed `sketerm mcp` flags. Pure so flag combos unit-test.
pub const Opts = struct {
    socket: ?[]const u8 = null,
    shared: bool = false,
    durable: bool = false,
    name: ?[]const u8 = null,
    log_dir: ?[]const u8 = null,
    help: bool = false,

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
            } else if (std.mem.eql(u8, a, "--help")) {
                o.help = true;
            } else {
                return error.UnknownFlag;
            }
        }
        if (o.shared and (o.durable or o.name != null)) return error.SharedConflict;
        return o;
    }
};

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
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&ts.tv_sec, &tm);
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
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&ts.tv_sec, &tm);
        const ms: u32 = @intCast(@divTrunc(ts.tv_nsec, 1_000_000));
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
            @as(u32, @intCast(@as(i64, tm.tm_year) + 1900)), @as(u32, @intCast(tm.tm_mon + 1)),
            @as(u32, @intCast(tm.tm_mday)), @as(u32, @intCast(tm.tm_hour)),
            @as(u32, @intCast(tm.tm_min)),  @as(u32, @intCast(tm.tm_sec)),
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

    /// Save an inline screenshot as img-<pid>-NNNN.png + a trace entry.
    fn logImage(self: *McpLog, caption: []const u8, png: []const u8) void {
        self.img_seq += 1;
        var z: [4096]u8 = undefined;
        const path = std.fmt.bufPrintZ(&z, "{s}/img-{d}-{d:0>4}.png", .{ self.dir, c.getpid(), self.img_seq }) catch return;
        if (c.fopen(path.ptr, "wb")) |f| {
            _ = c.fwrite(png.ptr, 1, png.len, f);
            _ = c.fclose(f);
        }
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        var aw: std.Io.Writer.Allocating = .init(arena_state.allocator());
        const w = &aw.writer;
        var tbuf: [40]u8 = undefined;
        w.print("{{\"ts\":\"{s}\",\"event\":\"image\",\"file\":\"img-{d}-{d:0>4}.png\",\"bytes\":{d},\"caption\":", .{ stamp(&tbuf), c.getpid(), self.img_seq, png.len }) catch return;
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
    errdefer allocator.free(dir);
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
    const muxclient = @import("../mux/client.zig");
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
    const muxdaemon = @import("../mux/daemon.zig");
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
        muxdaemon.removeTreeBestEffort(dir);
    }
}

/// Central hard timeout — ONE watchdog covering EVERY tool call, not
/// per-tool special cases. If a call exceeds the cap, the watchdog
/// shuts down all mux connection fds registered at call start; every
/// bounded IO loop on them then errors within its own (much shorter)
/// deadline, the call returns an error, and the server keeps serving.
/// A backstop for wedges no per-path deadline anticipated — not a
/// substitute for them. Affected app sessions surface as exited/
/// disconnected afterwards: harsh, but strictly better than a hung
/// server an agent can neither cancel nor distinguish from "slow".
const Watchdog = struct {
    /// Monotonic ms when the in-flight call started; 0 = idle. The
    /// release-store in begin() publishes fds/fd_count (written only
    /// while idle, so the watchdog never reads them concurrently).
    var started_ms: std.atomic.Value(i64) = .init(0);
    /// Conn fds snapshotted at call start. An fd closed AND reused
    /// mid-call could be shut down wrongly, but a wedged main thread
    /// cannot close fds, and normal calls finish far under the cap.
    var fds: [128]c_int = undefined;
    var fd_count: usize = 0;
    var fired: bool = false;
    var hard_ms: i64 = 150_000;

    fn begin() void {
        started_ms.store(0, .release);
        fd_count = 0;
        for (app_state.apps.values()) |a| addFd(a.conn.fd);
        for (term_state.terms.values()) |t| addFd(t.conn.fd);
        fired = false;
        started_ms.store(monoMs(), .release);
    }

    fn addFd(fd: c_int) void {
        if (fd_count < fds.len) {
            fds[fd_count] = fd;
            fd_count += 1;
        }
    }

    fn end() void {
        started_ms.store(0, .release);
    }

    fn loop() void {
        while (true) {
            var ts = c.struct_timespec{ .tv_sec = 1, .tv_nsec = 0 };
            _ = c.nanosleep(&ts, null);
            const started = started_ms.load(.acquire);
            if (started != 0 and !fired and monoMs() - started > hard_ms) {
                fired = true;
                for (fds[0..fd_count]) |fd| _ = c.shutdown(fd, c.SHUT_RDWR);
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

/// No-op SIGPIPE handler (same rationale as mux_main.zig: the SIG_IGN
/// macro fails translate-c). Equivalent to ignoring: write() returns
/// EPIPE, the process doesn't die.
fn sigNoop(_: c_int) callconv(.c) void {}

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
    sa.__sigaction_handler.sa_handler = onQuitSignal;
    sa.sa_flags = 0;
    _ = c.sigaction(c.SIGTERM, &sa, null);
    _ = c.sigaction(c.SIGINT, &sa, null);
    var sp: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
    sp.__sigaction_handler.sa_handler = sigNoop;
    _ = c.sigaction(c.SIGPIPE, &sp, null);
}

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const opts = Opts.parse(args) catch |err| {
        const msg = switch (err) {
            error.UnknownFlag => "sketerm mcp: unknown flag (see --help)\n",
            error.MissingValue => "sketerm mcp: flag needs a value\n",
            error.BadName => "sketerm mcp: --name must be 1-48 chars of [A-Za-z0-9_-]\n",
            error.SharedConflict => "sketerm mcp: --shared conflicts with --durable/--name\n",
        };
        _ = c.fputs(msg, platform.stderr());
        return 2;
    };
    if (opts.help) {
        _ = c.fputs(MCP_HELP, platform.stdout());
        return 0;
    }

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
        .sleepMs = RealBackend.sleepMs,
        .nowMs = RealBackend.nowMs,
    } else Backend{
        .ctx = @ptrCast(&stub),
        .talk = StubBackend.talk,
        .sleepMs = RealBackend.sleepMs,
        .nowMs = RealBackend.nowMs,
    };
    app_state = .{
        .allocator = allocator,
        .mux_sock = if (iso) |i| i.sock else null,
        .keep_apps = if (iso) |i| i.durable else false,
    };
    defer app_state.deinit();
    // Headless terminal tools run on the private daemon (isolated
    // mode only); --shared keeps the GUI-backed terminal tools.
    term_state = .{
        .allocator = allocator,
        .mux_sock = if (iso) |i| i.sock else null,
    };
    defer term_state.deinit();

    // Named/durable instance: pick up app sessions still running on
    // the private daemon from a previous run.
    if (iso) |i| {
        if (i.durable) reattachApps(i.sock);
    }

    installQuitSignals();

    // Central hard timeout (SKETERM_MCP_HARD_TIMEOUT_MS overrides;
    // min 30s so it always outlasts the per-path deadlines).
    if (c.getenv("SKETERM_MCP_HARD_TIMEOUT_MS")) |v| {
        const span = std.mem.span(@as([*:0]const u8, @ptrCast(v)));
        if (std.fmt.parseInt(i64, span, 10)) |ms| {
            Watchdog.hard_ms = @max(ms, 30_000);
        } else |_| {}
    }
    if (std.Thread.spawn(.{}, Watchdog.loop, .{})) |t| t.detach() else |_| {}

    if (mcp_log) |*l| {
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
        if (Watchdog.fired) {
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
    term_state.deinit();
    app_state.deinit();
    if (iso) |i| {
        if (!i.durable) {
            shutdownDaemonAt(allocator, i.sock);
            @import("../mux/daemon.zig").removeTreeBestEffort(i.dir);
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

    fn sleepMs(_: *anyopaque, ms: u32) void {
        var ts: c.struct_timespec = .{
            .tv_sec = ms / 1000,
            .tv_nsec = @as(c_long, ms % 1000) * 1_000_000,
        };
        _ = c.nanosleep(&ts, null);
    }

    fn nowMs(_: *anyopaque) i64 {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
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
        const result = std.fmt.allocPrint(arena, "{{\"tools\":{s}}}", .{TOOLS_JSON}) catch return null;
        return rpcResult(arena, id, result);
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        if (params != .object) return rpcError(arena, id, -32602, "tools/call needs params");
        const name_v = params.object.get("name") orelse return rpcError(arena, id, -32602, "missing tool name");
        if (name_v != .string) return rpcError(arena, id, -32602, "bad tool name");
        const args: std.json.Value = params.object.get("arguments") orelse .null;
        const outcome = callTool(arena, backend, name_v.string, args) catch |err| {
            const msg = std.fmt.allocPrint(arena, "tool failed: {s}", .{@errorName(err)}) catch return null;
            return rpcResult(arena, id, toolResult(arena, msg, true) orelse return null);
        };
        if (is_notification) return null;
        return rpcResult(arena, id, outcome);
    }
    if (is_notification) return null;
    return rpcError(arena, id, -32601, "method not found");
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

/// Wrap a PNG (+ a text caption) as an MCP tool result with an
/// inline image content block. base64 emits no newlines, so the
/// NDJSON framing is safe.
fn imageResult(arena: std.mem.Allocator, caption: []const u8, png_bytes: []const u8) ?[]const u8 {
    if (mcp_log) |*l| l.logImage(caption, png_bytes);
    const enc = std.base64.standard.Encoder;
    const b64 = arena.alloc(u8, enc.calcSize(png_bytes.len)) catch return null;
    _ = enc.encode(b64, png_bytes);
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":") catch return null;
    std.json.Stringify.value(caption, .{}, w) catch return null;
    w.writeAll("},{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"") catch return null;
    w.writeAll(b64) catch return null;
    w.writeAll("\"}]}") catch return null;
    return aw.written();
}

/// Multi-image tool result: one caption text block, then every PNG as
/// its own inline image content block (burst capture).
fn imagesResult(arena: std.mem.Allocator, caption: []const u8, pngs: []const []const u8) ?[]const u8 {
    const enc = std.base64.standard.Encoder;
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":") catch return null;
    std.json.Stringify.value(caption, .{}, w) catch return null;
    w.writeAll("}") catch return null;
    for (pngs) |p| {
        if (mcp_log) |*l| l.logImage(caption, p);
        const b64 = arena.alloc(u8, enc.calcSize(p.len)) catch return null;
        _ = enc.encode(b64, p);
        w.writeAll(",{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"") catch return null;
        w.writeAll(b64) catch return null;
        w.writeAll("\"}") catch return null;
    }
    w.writeAll("]}") catch return null;
    return aw.written();
}

/// Wrap plain text as an MCP tool result: {"content":[{"type":"text",...}]}.
fn toolResult(arena: std.mem.Allocator, text: []const u8, is_error: bool) ?[]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":") catch return null;
    std.json.Stringify.value(text, .{}, w) catch return null;
    w.writeAll("}]") catch return null;
    if (is_error) w.writeAll(",\"isError\":true") catch return null;
    w.writeAll("}") catch return null;
    return aw.written();
}

// ── Tools ─────────────────────────────────────────────────────────

/// Newline-free (MCP stdio framing is one JSON object per line; a
/// raw '\n' inside a response splits it). Kept readable as a
/// multiline literal; newlines stripped at comptime.
const TOOLS_JSON = blk: {
    @setEvalBranchQuota(60_000);
    var buf: [TOOLS_JSON_RAW.len]u8 = undefined;
    var n: usize = 0;
    for (TOOLS_JSON_RAW) |ch| {
        if (ch == '\n') continue;
        buf[n] = ch;
        n += 1;
    }
    const out = buf[0..n].*;
    break :blk &out;
};

const TOOLS_JSON_RAW =
    \\[
    \\{"name":"list_terminals","description":"List all sketerm tabs and panes (ids, titles, sizes, cwd, focus). Pane ids address every other tool.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"read_screen","description":"Read a pane's rendered screen: text content plus cursor position, size and flags. This is the parsed terminal grid (what a human sees), not raw output. Pass last_command=true to get ONLY the last completed command's output and exit code (precise — no prompt noise; requires shell integration, which sketerm injects by default).","inputSchema":{"type":"object","properties":{"pane":{"type":"integer","description":"Pane id (omit = focused pane)"},"scrollback":{"type":"integer","description":"Also include up to N scrollback lines"},"last_command":{"type":"boolean","description":"Return only the last completed command's output + exit code"}}}},
    \\{"name":"screenshot_pane","description":"Screenshot a terminal pane as a lossless PNG (inline image) exactly as rendered, including colours, cursor and any shader. Needs a running sketerm window.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer","description":"Pane id (omit = focused pane)"}}}},
    \\{"name":"record_pane_start","description":"Start recording a terminal pane's session as an asciicast v2 (.cast) file — raw output with timestamps, playable with asciinema. Recorded by the session daemon (no wrapper); a remote session records to a path on ITS host.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer","description":"Pane id (omit = focused pane)"},"path":{"type":"string","description":"Absolute output path ending in .cast"}},"required":["path"]}},
    \\{"name":"record_pane_stop","description":"Stop the asciicast recording of a terminal pane's session.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer","description":"Pane id (omit = focused pane)"}}}},
    \\{"name":"send_text","description":"Type literal text into a pane's terminal. Set enter=true to press Enter afterwards. Use send_keys for control keys.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"},"text":{"type":"string"},"enter":{"type":"boolean","description":"Press Enter after the text"}},"required":["text"]}},
    \\{"name":"send_keys","description":"Press named keys in a pane: space-separated chords like 'ctrl+c', 'enter', 'up', 'escape', 'f5', 'alt+x', 'shift+tab', 'pagedown'. Single characters are typed literally.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"},"keys":{"type":"string"}},"required":["keys"]}},
    \\{"name":"run_command","description":"Type a shell command, press Enter, wait until output settles, and return the resulting screen text. Pass output_only=true to get ONLY the command's output + exit code (no prompt/echo noise; needs shell integration, on by default). For interactive programs prefer send_text/send_keys + read_screen.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"},"command":{"type":"string"},"timeout_ms":{"type":"integer","description":"Max wait (default 15000)"},"quiet_ms":{"type":"integer","description":"Idle window that counts as settled (default 400)"},"output_only":{"type":"boolean","description":"Return just the command's output and exit code instead of the whole screen"}},"required":["command"]}},
    \\{"name":"wait_idle","description":"Wait until a pane produced no output for quiet_ms (or timeout_ms elapsed). Returns whether it settled.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"},"timeout_ms":{"type":"integer"},"quiet_ms":{"type":"integer"}}}},
    \\{"name":"new_tab","description":"Open a new shell tab. Returns the new tab and pane ids.","inputSchema":{"type":"object","properties":{"cwd":{"type":"string"},"title":{"type":"string"}}}},
    \\{"name":"split_pane","description":"Split a pane. direction 'h' = side by side, 'v' = stacked. Returns the new pane id.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"},"direction":{"type":"string","enum":["h","v"]}}}},
    \\{"name":"focus_pane","description":"Focus a pane (selects its tab and grabs keyboard focus).","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"}},"required":["pane"]}},
    \\{"name":"close_pane","description":"Close a pane. Destructive: the shell and any running process in it are terminated.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"}},"required":["pane"]}},
    \\{"name":"list_installed_apps","description":"List installed GUI apps on the host (name + launch command), from its .desktop entries. Pass host for a remote machine. Use before launch_app to discover what can run.","inputSchema":{"type":"object","properties":{"host":{"type":"string","description":"SSH host (user@box); omit = local"}}}},
    \\{"name":"launch_app","description":"Launch a GUI (Wayland) application HEADLESSLY: it renders into sketerm's mux daemon, never appears on any screen, and survives disconnects. Returns the app id, the child pid on the daemon's host (attach a debugger with gdb -p; with a string command the pid is the wrapping /bin/sh — pass an argv array to make it the app itself), its windows AND the first window's screenshot inline (launch-and-look in one call). If the app exits early, the reply includes exit status, terminating signal and its recent output. Drive it with get_app_state/app_click/app_type/app_key; read its stdout/stderr with app_output.","inputSchema":{"type":"object","properties":{"command":{"description":"argv array (preferred) or a shell command string","anyOf":[{"type":"array","items":{"type":"string"}},{"type":"string"}]},"host":{"type":"string","description":"SSH host (user@box) to run on; omit = local daemon"},"cwd":{"type":"string","description":"Working directory for the app"},"env":{"type":"object","description":"Extra environment variables, e.g. {\"FOO\":\"1\"}","additionalProperties":{"type":"string"}},"wait_for":{"type":"string","enum":["window","exit"],"description":"What to wait for before replying: first window (default) or process exit (short-lived/CLI runs)"},"wait_ms":{"type":"integer","description":"Max wait (default 10000)"},"cols":{"type":"integer"},"rows":{"type":"integer"},"layout":{"type":"string","description":"Session keyboard layout: us (default), gb, fr, be, de"},"gpu":{"type":"boolean","description":"Render on the host's real GPU via linux-dmabuf instead of software GL. Needs a driver whose linear buffers allow CPU mmap."},"audio":{"type":"string","enum":["forward","none"],"description":"forward (default): PULSE_SERVER points at sketerm's per-session audio sink, which paces playback in real time (samples are discarded unless a GUI viewer is attached). none: no PULSE_SERVER, so the app falls back to its own dummy/null audio driver."},"audio_path":{"type":"string","description":"Capture the app's audio to WAV at this absolute path base ON THE DAEMON'S HOST (first stream: <base>.wav, later streams: <base>-N.wav; a trailing .wav in the base is stripped). Playback pacing is unaffected — this tees the PCM the sink consumes, so you can verify the app actually produced sound. Incompatible with audio:\"none\"."},"debug":{"type":"string","enum":["gdb","valgrind"],"description":"Run the app under a debug wrapper: gdb (batch mode — on a crash the full backtrace + registers land in app_log) or valgrind (report in app_log at exit). The reported pid is the wrapper's."}},"required":["command"]}},
    \\{"name":"list_apps","description":"List launched headless apps and their windows.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"app_windows","description":"List one app's rendered windows (ids, sizes, titles).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"}}}},
    \\{"name":"screenshot_app","description":"Screenshot a headless app window as a lossless PNG (inline image). Optional region crop and integer zoom for pixel-level inspection; downscaled when larger than max_px. The caption tells you how to map image coordinates back to app_click coordinates. wait_change=true blocks until the window renders something NEWER than your last screenshot (verify a click did something); stable_ms waits until repainting stops before capturing (settle-then-capture — combine both to catch 'changed, then went quiet'). stats_only=true skips the image and just reports whether/how much the window changed since your last look (cheap polling). burst=N captures up to N frames over burst_ms, each at least min_change_pct different from the previous — one call across an animated transition.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer","description":"Window id (omit = first toplevel)"},"max_px":{"type":"integer","description":"Bound on the longest image dimension (default 1568, 0 = full size)"},"region":{"type":"object","description":"Crop to a sub-rectangle in surface pixels","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}},"zoom":{"type":"integer","description":"Nearest-neighbor integer upscale (1-32) — crop a small region and zoom to inspect pixels"},"wait_change":{"type":"boolean","description":"Wait until the window content changed since the last screenshot before capturing"},"stable_ms":{"type":"integer","description":"Capture only after the window committed no new frame for this long (settle-then-capture)"},"stats_only":{"type":"boolean","description":"Return {changed, diff_pct, resized, w, h, frames} instead of an image"},"burst":{"type":"integer","description":"Capture up to N distinct frames (2-8) over burst_ms"},"burst_ms":{"type":"integer","description":"Burst time window (default 5000)"},"min_change_pct":{"type":"number","description":"Minimum %% of pixels changed vs the previous burst frame (default 1.0)"},"timeout_ms":{"type":"integer","description":"Bound for wait_change/stable_ms (default 10000)"}}}},
    \\{"name":"get_app_state","description":"One-call app observation: window list + screenshot of one window (inline PNG) with coordinate mapping. Prefer this over separate app_windows + screenshot_app. If the app exited, reports exit status, signal and recent output instead. Accepts the same region/zoom/wait_change/stable_ms/stats_only/burst options as screenshot_app.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer","description":"Window id (omit = first toplevel)"},"max_px":{"type":"integer"},"region":{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}},"zoom":{"type":"integer"},"wait_change":{"type":"boolean"},"stable_ms":{"type":"integer"},"stats_only":{"type":"boolean"},"burst":{"type":"integer"},"burst_ms":{"type":"integer"},"min_change_pct":{"type":"number"},"timeout_ms":{"type":"integer"}}}},
    \\{"name":"app_output","description":"Read a headless app's stdout/stderr (its PTY output as RENDERED BY A TERMINAL — a fixed-width grid, so long lines wrap and scrolled-off content needs scrollback=true; right for TUI-style redraws). For log-style output app_log is the SOURCE OF TRUTH: indexed unwrapped lines with stable ids, re-readable in full — prefer it. When the grid mirror is blank after an exit, the log ring's last lines are served instead. Also reports exit status + signal when the app has died.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"scrollback":{"type":"boolean"}}}},
    \\{"name":"app_log","description":"A headless app's stdout/stderr as an INDEXED LOG: each complete line gets a stable numeric id and a timestamp; the tail view shortens long lines (marked [+]) and any line can be re-read in full by id. The ring is bounded (oldest lines drop; the reply says how many). MARKERS: the app (or your injected code) can emit the escape  printf '\\033]5522;my-label\\033\\\\'  — it becomes a labelled log line AND sketerm stashes a screenshot of the app window at that exact instant; fetch label+image with {\"id\":<that line's id>}. Variant printf '\\033]5522;+N;my-label\\033\\\\' captures the Nth FUTURE frame commit instead (e.g. +1 = the next repaint after this point; resolved with the final frame if the app exits first). Markers are rate-limited (burst 8, then 2/s; excess are dropped and counted) so escape-laden files cat'ed to the terminal cannot flood the log. Survives app exit: the final log is delivered with the exit.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"tail":{"type":"integer","description":"Last N lines (default 60, max 500)"},"from_id":{"type":"integer","description":"Return lines starting at this id instead of the tail"},"id":{"type":"integer","description":"Return ONE line in full; for a marker line also returns the stashed screenshot"}}}},
    \\{"name":"app_click","description":"Click inside an app window at surface-local pixel coordinates (from screenshot_app; apply the caption's multiplier if the image was downscaled). To target a widget by name/role instead, prefer app_perform_action (coordinate-free, more reliable). button: 1 left (default), 2 middle, 3 right. mark=true returns a post-click screenshot with a crosshair drawn at the exact click pixel — see where the click landed relative to the UI AND what it did, in one image; screenshot=true returns the post-click frame without the marker.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"x":{"type":"integer"},"y":{"type":"integer"},"button":{"type":"integer"},"mark":{"type":"boolean","description":"Return a post-click screenshot with a crosshair marker at the click point"},"screenshot":{"type":"boolean","description":"Return a post-click screenshot (no marker)"},"max_px":{"type":"integer","description":"Bound on the screenshot's longest dimension (default 1568)"}},"required":["window","x","y"]}},
    \\{"name":"app_actions","description":"Execute an ORDERED batch of interaction steps against one app in a single call — collapses click/wait/screenshot round-trips (driving menus, games, wizards). 'actions' is an array of step objects, each holding exactly one of: {\"move\":[x,y]} | {\"move_rel\":[dx,dy]} (relative pointer, see app_mouse_move) | {\"click\":[x,y]} | {\"drag\":[x1,y1,x2,y2]} | {\"key\":\"space-separated chords\"} | {\"type\":\"text\"} | {\"scroll\":[dx,dy]} (optional \"at\":[x,y]) | {\"wait\":ms} (MILLISECONDS, max 30000) | {\"wait_idle\":{\"quiet_ms\":400,\"timeout_ms\":10000,\"change_pct\":2}} (with change_pct = VISUAL settle: blocks until frames change less than that %% — use for scene transitions of unknown duration instead of guessing a fixed wait) | {\"wait_change\":timeout_ms} | {\"screenshot\":true or {\"max_px\":N}}. MARKERS: add \"mark\":true to a click/move/move_rel/drag/scroll step to draw a labelled crosshair at that step's position (red = click, cyan = move; the number is the step index) onto the NEXT screenshot — several marked steps can share one image. Combine in one step: {\"click\":[x,y],\"mark\":true,\"screenshot\":true} captures the post-click frame with the click point marked. Leftover marks with no later screenshot are flushed as a final image automatically. Optional per-step \"window\" and \"button\" (click/drag). Steps run in order server-side; execution stops with a per-step report when one fails or the app exits. Returns per-step results plus every screenshot taken (max 8) as inline images.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer","description":"Default window for all steps"},"actions":{"type":"array","items":{"type":"object"}}},"required":["actions"]}},
    \\{"name":"app_mouse_move","description":"Move the pointer in an app window WITHOUT clicking. Absolute: x,y in surface pixels (hover a widget, position before a click). Relative: dx,dy — a delta from the current pointer position, for apps that consume RELATIVE mouse motion (SDL games, DOSBox, anything with pointer-lock): sketerm derives relative_motion events from the move, so the app's own cursor moves by exactly your delta. Calibration for such apps: one large negative move (e.g. dx:-30000, dy:-30000) slams their internal cursor to the top-left corner, after which exact deltas land where you aim. With neither x/y nor dx/dy it just returns the tracked pointer position.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer","description":"Window id (omit = window under the pointer, else first toplevel)"},"x":{"type":"number","description":"Absolute surface x (with y)"},"y":{"type":"number"},"dx":{"type":"number","description":"Relative delta x (with dy; exclusive with x/y)"},"dy":{"type":"number"}}}},
    \\{"name":"app_perform_action","description":"Invoke a widget's default AT-SPI action (press/activate/toggle) directly by element id — the reliable coordinate-free way to 'click' a button, menu item or checkbox. 'element' is an id from app_a11y_tree. Works for GTK/Qt apps that publish accessibility.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"element":{"type":"string"},"index":{"type":"integer","description":"Action index (default 0 = the default action)"}},"required":["element"]}},
    \\{"name":"app_set_value","description":"Write a value straight into a widget via AT-SPI: 'text' replaces a text field's content (EditableText), 'value' sets a slider/spinner (Value). Faster and more reliable than typing.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"element":{"type":"string"},"text":{"type":"string"},"value":{"type":"number"}},"required":["element"]}},
    \\{"name":"app_wait_for_element","description":"Wait until a widget appears in the app's accessibility tree (dialog opened, page loaded, ...). Match by role number and/or case-insensitive name substring; returns the matched node with its id and rect.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"role":{"type":"integer","description":"AT-SPI role number (e.g. 42 push-button)"},"name":{"type":"string","description":"Name substring, case-insensitive"},"timeout_ms":{"type":"integer","description":"Default 10000"}}}},
    \\{"name":"app_drag","description":"Press-move-release drag inside an app window (sliders, drag-and-drop, text selection). Surface-local pixel coordinates.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"x1":{"type":"integer"},"y1":{"type":"integer"},"x2":{"type":"integer"},"y2":{"type":"integer"},"button":{"type":"integer"}},"required":["window","x1","y1","x2","y2"]}},
    \\{"name":"app_type","description":"Type literal text into an app window. Non-ASCII text is delivered via a clipboard paste (Ctrl+V) automatically.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"text":{"type":"string"}},"required":["text"]}},
    \\{"name":"app_clipboard_get","description":"Read what the app last copied to the clipboard (requires the app to have copied something).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"timeout_ms":{"type":"integer"}}}},
    \\{"name":"app_clipboard_set","description":"Offer text to the app as the host clipboard. Set paste=true to immediately press Ctrl+V in a window.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"text":{"type":"string"},"paste":{"type":"boolean"},"window":{"type":"integer"}},"required":["text"]}},
    \\{"name":"app_key","description":"Press key chords in an app window: space-separated, e.g. 'ctrl+s', 'enter', 'alt+F4', 'down down enter'.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"keys":{"type":"string"}},"required":["keys"]}},
    \\{"name":"app_scroll","description":"Scroll inside an app window. dy>0 scrolls down, dx>0 right (wheel steps).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"x":{"type":"integer"},"y":{"type":"integer"},"dx":{"type":"integer"},"dy":{"type":"integer"}},"required":["window"]}},
    \\{"name":"app_resize","description":"Ask an app window to redraw at a new size (deterministic screenshots).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}},"required":["window","w","h"]}},
    \\{"name":"app_wait","description":"Wait until an app stopped producing new frames for quiet_ms (render quiescence), or — pass change_pct — until each new frame changes less than that percentage of pixels for quiet_ms (VISUAL quiescence: use this for games and other continuously-animating apps, which never stop committing frames but do reach a visually stable screen). Reports which outcome happened and returns the window list.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer","description":"Window for change_pct pixel diffing (omit = first toplevel)"},"quiet_ms":{"type":"integer"},"timeout_ms":{"type":"integer"},"change_pct":{"type":"number","description":"Settle when frames change less than this %% of pixels (e.g. 2). Omit = strict no-new-frames quiescence"}}}},
    \\{"name":"app_a11y_tree","description":"Read the app's accessibility (AT-SPI) tree as JSON: every widget's role, name, description, states and screen rectangle. Target elements by name/role instead of pixel-hunting a screenshot. Works for GTK/Qt apps; empty for apps without accessibility (games, some Electron).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"timeout_ms":{"type":"integer"}}}},
    \\{"name":"app_record_start","description":"Start recording a window's frames (a visual log of what you do). Default format is WebM/VP9 (smaller, higher quality); pass format:\"gif\" for an animated GIF. Frames are captured while other app tools run; finish with app_record_stop.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"format":{"type":"string","enum":["webm","gif"],"description":"Default webm"},"max_px":{"type":"integer","description":"Bound on the longest dimension (default 1280 webm / 800 gif)"},"fps":{"type":"integer","description":"Cap the capture rate (frames/second, 1-60; default = every committed frame)"}}}},
    \\{"name":"app_record_stop","description":"Stop the recording and save it (WebM or GIF per app_record_start). Returns the file path and frame count.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"path":{"type":"string","description":"Output path (extension set automatically if omitted)"}}}},
    \\{"name":"close_app_window","description":"Ask the app to close one window (like the titlebar button; the app decides).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"}},"required":["window"]}},
    \\{"name":"close_app","description":"Kill a headless app session outright. Destructive.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"}}}},
    \\{"name":"term_open","description":"Open a HEADLESS shell terminal on the private mux daemon (isolated mode) — a real PTY with no GUI, nothing of the user's reachable. Returns a term id. Drive with term_run/term_send_text/term_read.","inputSchema":{"type":"object","properties":{"command":{"description":"argv array or shell string to run instead of the login shell (optional)","anyOf":[{"type":"array","items":{"type":"string"}},{"type":"string"}]},"cols":{"type":"integer"},"rows":{"type":"integer"}}}},
    \\{"name":"term_list","description":"List open headless terminals and their exit state.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"term_run","description":"Run a command line in a headless terminal and return the screen once output settles (like run_command but for headless shells). Pass output_only=true to get ONLY the command's output + exit code (no prompt/echo noise; needs shell integration, on by default).","inputSchema":{"type":"object","properties":{"term":{"type":"integer"},"command":{"type":"string"},"quiet_ms":{"type":"integer","description":"Idle window that counts as settled (default 400)"},"timeout_ms":{"type":"integer","description":"Default 30000"},"output_only":{"type":"boolean","description":"Return just the command's output and exit code instead of the whole screen"}},"required":["command"]}},
    \\{"name":"term_send_text","description":"Write text to a headless terminal's PTY. 'enter' appends a carriage return.","inputSchema":{"type":"object","properties":{"term":{"type":"integer"},"text":{"type":"string"},"enter":{"type":"boolean"}},"required":["text"]}},
    \\{"name":"term_send_keys","description":"Press named key chords in a headless terminal: 'ctrl+c', 'enter', 'up', 'tab', space-separated.","inputSchema":{"type":"object","properties":{"term":{"type":"integer"},"keys":{"type":"string"}},"required":["keys"]}},
    \\{"name":"term_read","description":"Read a headless terminal's rendered screen text. 'scrollback' true dumps the scrollback too.","inputSchema":{"type":"object","properties":{"term":{"type":"integer"},"scrollback":{"type":"boolean"}}}},
    \\{"name":"term_wait_idle","description":"Wait until a headless terminal's output stops changing (or timeout).","inputSchema":{"type":"object","properties":{"term":{"type":"integer"},"quiet_ms":{"type":"integer"},"timeout_ms":{"type":"integer"}}}},
    \\{"name":"term_resize","description":"Resize a headless terminal's grid.","inputSchema":{"type":"object","properties":{"term":{"type":"integer"},"cols":{"type":"integer"},"rows":{"type":"integer"}}}},
    \\{"name":"term_close","description":"Close a headless terminal (kills its shell). Destructive.","inputSchema":{"type":"object","properties":{"term":{"type":"integer"}}}}
    \\]
;

fn argInt(args: std.json.Value, key: []const u8) ?i64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .integer => v.integer,
        else => null,
    };
}

fn argStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .string => v.string,
        else => null,
    };
}

fn argBool(args: std.json.Value, key: []const u8) bool {
    if (args != .object) return false;
    const v = args.object.get(key) orelse return false;
    return switch (v) {
        .bool => v.bool,
        else => false,
    };
}

fn argFloat(args: std.json.Value, key: []const u8) ?f64 {
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
fn ipc(arena: std.mem.Allocator, backend: Backend, req: protocol.Request) ![]u8 {
    const line = try reqLine(arena, req);
    return backend.talk(backend.ctx, arena, line);
}

const IpcReply = struct {
    ok: bool,
    /// Parsed response object (arena-owned).
    value: std.json.Value,
    /// Error message when !ok.
    err: []const u8,
};

fn ipcParsed(arena: std.mem.Allocator, backend: Backend, req: protocol.Request) !IpcReply {
    const resp = try ipc(arena, backend, req);
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, resp, .{}) catch
        return .{ .ok = false, .value = .null, .err = "bad IPC response" };
    if (v != .object) return .{ .ok = false, .value = .null, .err = "bad IPC response" };
    const ok = if (v.object.get("ok")) |o| (o == .bool and o.bool) else false;
    const err: []const u8 = if (v.object.get("error")) |e|
        (if (e == .string) e.string else "unknown error")
    else
        "unknown error";
    return .{ .ok = ok, .value = v, .err = err };
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

/// Read screen text + metadata as one human/assistant-readable blob.
fn readScreenText(arena: std.mem.Allocator, backend: Backend, pane: ?u32, scrollback: u32) ![]const u8 {
    const info = try ipcParsed(arena, backend, .{ .cmd = "screen-info", .pane = pane });
    if (!info.ok) return error.NoSuchPane;
    const text_reply = try ipcParsed(arena, backend, .{ .cmd = "get-text", .pane = pane, .scrollback = scrollback });
    if (!text_reply.ok) return error.NoSuchPane;
    const text = (if (text_reply.value.object.get("text")) |t|
        (if (t == .string) t.string else "")
    else
        "");

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    const screen = info.value.object.get("screen").?;
    try w.writeAll("screen: ");
    try std.json.Stringify.value(screen, .{}, w);
    try w.writeAll("\n---\n");
    try w.writeAll(text);
    return aw.written();
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

var app_state: AppState = .{ .allocator = undefined, .ready = false };

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

var term_state: TermState = .{ .allocator = undefined };

fn termFromArgs(args: std.json.Value) ?*termdrive.Term {
    if (argInt(args, "term")) |id| {
        if (id < 0) return null;
        return term_state.terms.get(@intCast(id));
    }
    if (term_state.terms.count() == 1) return term_state.terms.values()[0];
    return null;
}

fn termIdOf(t: *termdrive.Term) u32 {
    var it = term_state.terms.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == t) return e.key_ptr.*;
    }
    return 0;
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
        const app = appdrive.App.attachExisting(a, r.name, null, sock) catch continue;
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

fn appFromArgs(args: std.json.Value) ?*appdrive.App {
    const id = argInt(args, "app") orelse {
        // Single-app convenience: omit `app` when only one exists.
        if (app_state.apps.count() == 1) return app_state.apps.values()[0];
        return null;
    };
    if (id < 0) return null;
    return app_state.apps.get(@intCast(id));
}

fn appIdOf(app: *appdrive.App) u32 {
    var it = app_state.apps.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == app) return e.key_ptr.*;
    }
    return 0;
}

/// Human name for the common fatal signals (exit_status = -signo).
fn signalName(signo: i32) []const u8 {
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
fn exitSuffix(arena: std.mem.Allocator, status: i32) ![]const u8 {
    if (status < 0)
        return std.fmt.allocPrint(arena, " = killed by {s} (signal {d})", .{ signalName(-status), -status });
    if (status >= 129 and status <= 128 + 31)
        return std.fmt.allocPrint(arena, " (= 128+{d}: the wrapping shell reports the app was killed by {s})", .{ status - 128, signalName(status - 128) });
    return "";
}

/// The daemon's log_get reply / pre-exit log stash, JSON shape.
const LogLineJ = struct {
    id: u64 = 0,
    t: i64 = 0,
    text: []const u8 = "",
    truncated: bool = false,
    cut: bool = false,
    marker: bool = false,
};
const LogReplyJ = struct {
    next_id: u64 = 0,
    dropped: u64 = 0,
    markers_dropped: u64 = 0,
    lines: []const LogLineJ = &.{},
};

/// Last `n` non-marker lines from the app's stashed log ring (the
/// daemon pushes the final log ahead of `.exit`), newline-joined.
/// Null when no stash exists or it holds no output lines — unlike the
/// grid mirror these lines are escape-free and never wrapped.
fn logStashTail(arena: std.mem.Allocator, app: *appdrive.App, n: usize) ?[]const u8 {
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
fn tailLines(text: []const u8, n: usize) []const u8 {
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

/// JSON summary of an app's windows (arena-owned).
fn appSummary(arena: std.mem.Allocator, app: *appdrive.App) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("{{\"app\":{d},\"session\":", .{appIdOf(app)});
    try std.json.Stringify.value(app.name, .{}, w);
    // The daemon-host pid: a debugger handle (`gdb -p`). For a string
    // command this is the wrapping /bin/sh, not the app itself.
    if (app.pid != 0 and !app.exited) try w.print(",\"pid\":{d}", .{app.pid});
    if (app.exited) {
        try w.print(",\"exited\":true,\"exit_status\":{d}", .{app.exit_status});
        // decodeStatus convention: negative = killed by that signal.
        if (app.exit_status < 0) {
            try w.print(",\"signaled\":true,\"signal\":{d},\"signal_name\":\"{s}\"", .{ -app.exit_status, signalName(-app.exit_status) });
            if (crashSignal(-app.exit_status)) try w.writeAll(",\"crashed\":true");
        } else if (app.exit_status >= 129 and app.exit_status <= 128 + 31) {
            // A string `command` runs under /bin/sh, which reports a
            // child killed by signal N as exit 128+N.
            try w.print(",\"likely_signal\":{d},\"likely_signal_name\":\"{s}\",\"exit_status_note\":\"exit {d} = 128+{d}: shell-wrapped commands report signal deaths this way\"", .{
                app.exit_status - 128, signalName(app.exit_status - 128),
                app.exit_status,       app.exit_status - 128,
            });
            if (crashSignal(app.exit_status - 128)) try w.writeAll(",\"crashed\":true");
        }
    }
    try w.writeAll(",\"windows\":[");
    var first = true;
    for (app.windows.items) |win| {
        if (win.frames == 0) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{{\"window\":{d},\"w\":{d},\"h\":{d},\"scale\":{d}", .{ win.id, win.w, win.h, win.scale });
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
    // An app that died is otherwise a dead end — inline what it
    // printed so one call shows WHY. The log-ring stash (pushed by
    // the daemon ahead of `.exit`) is preferred: escape-free FULL
    // lines, never wrapped at the grid width, includes scrolled-off
    // output. The rendered-grid tail is only the fallback.
    if (app.exited) {
        if (logStashTail(arena, app, 15)) |tail_text| {
            try w.writeAll(",\"recent_output\":");
            try std.json.Stringify.value(tail_text, .{}, w);
            try w.writeAll(",\"recent_output_source\":\"app_log (indexed; read more/older lines with the app_log tool)\"");
        } else if (app.output(false)) |text| {
            defer app_state.allocator.free(text);
            try w.writeAll(",\"recent_output\":");
            try std.json.Stringify.value(tailLines(text, 25), .{}, w);
        } else |_| {}
        if (std.mem.indexOf(u8, app.log_buf.items, "Sanitizer") != null or
            std.mem.indexOf(u8, app.log_buf.items, "runtime error:") != null)
            try w.writeAll(",\"sanitizer_report\":true,\"sanitizer_note\":\"a sanitizer wrote a report to stderr — read it in full with app_log\"");
        // A gdb wrapper exits 0 after catching the fault; the log
        // headline is the real story.
        if (std.mem.indexOf(u8, app.log_buf.items, "Program received signal ") != null)
            try w.writeAll(",\"debugger_caught_signal\":true,\"debugger_note\":\"the debug wrapper caught a fatal signal — backtrace in app_log\"");
    }
    try w.writeAll("}");
    return aw.written();
}

fn appErr(arena: std.mem.Allocator, msg: []const u8) ![]const u8 {
    return toolResult(arena, msg, true) orelse error.OutOfMemory;
}

/// Screenshot caption: window identity + how to map image coordinates
/// back to app_click surface coordinates (crop origin + scale).
/// `extra` (a summary, or "") is prepended on its own line.
fn screenshotCaption(arena: std.mem.Allocator, app: *appdrive.App, win_id: u32, shot: appdrive.App.Shot, extra: []const u8) ![]const u8 {
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
        "{s}{s}window {d}: {d}x{d} (scale {d}){s}{s} — {s}",
        .{
            extra,
            if (extra.len > 0) "\n" else "",
            win.id,
            win.w,
            win.h,
            win.scale,
            if (win.title != null) " title=" else "",
            win.title orelse "",
            coord_note,
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

fn a11yFetch(arena: std.mem.Allocator, app: *appdrive.App, timeout_ms: i64) A11yFetch {
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

/// DFS for the first node matching `role` (when non-null) and/or a
/// case-insensitive `name` substring (when non-null).
fn a11yFindMatch(node: std.json.Value, role: ?i64, name_sub: ?[]const u8) ?std.json.Value {
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
fn a11yNodeSummary(arena: std.mem.Allocator, node: std.json.Value) ![]const u8 {
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
fn needsLiveApp(name: []const u8) bool {
    const live = [_][]const u8{
        "app_click",         "app_drag",          "app_type",
        "app_key",           "app_scroll",        "app_resize",
        "app_mouse_move",    "app_clipboard_get", "app_clipboard_set",
        "app_perform_action", "app_set_value",    "app_wait_for_element",
        "app_a11y_tree",     "app_record_start",  "close_app_window",
    };
    for (live) |l| {
        if (std.mem.eql(u8, name, l)) return true;
    }
    return false;
}

/// First rendered non-popup window (0 = none yet).
fn firstToplevelId(app: *appdrive.App) u32 {
    for (app.windows.items) |win| {
        if (!win.popup and win.frames > 0) return win.id;
    }
    return 0;
}

/// Fixed-length array of numbers out of a JSON value ([x,y], …).
fn numArray(v: std.json.Value, comptime n: usize) ?[n]f64 {
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

fn monoMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

/// Wall-clock ms, matching the daemon's log-line timestamps. Full ms
/// precision — a seconds-truncated "now" makes fresh lines look like
/// they are from the future ("-0.5s ago").
fn wallNowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

/// One app_actions screenshot: draws (and consumes) the pending step
/// marks, stores the PNG, writes the report line. Returns false when
/// the capture failed (the caller decides whether that is fatal).
fn actionsCapture(
    arena: std.mem.Allocator,
    app: *appdrive.App,
    w: *std.Io.Writer,
    pngs: *std.ArrayList([]const u8),
    pending: *std.ArrayList(marks_mod.Mark),
    wid: u32,
    max_px: u32,
    prefix: []const u8,
) !bool {
    const marks_n = pending.items.len;
    const shot = app.screenshotPngMarked(wid, max_px, null, 1, pending.items) catch {
        try w.print("{s}: ERROR — screenshot failed (no pixels yet?)\n", .{prefix});
        return false;
    };
    pngs.append(arena, shot.png) catch {
        app_state.allocator.free(shot.png);
        return error.OutOfMemory;
    };
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

fn appTool(arena: std.mem.Allocator, name: []const u8, args: std.json.Value) ![]const u8 {
    const eql = std.mem.eql;
    if (!app_state.ready)
        return appErr(arena, "app tools unavailable (server not fully started)");

    if (eql(u8, name, "launch_app")) {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        if (args == .object) {
            if (args.object.get("command")) |cmd| switch (cmd) {
                .string => {
                    try argv.append(arena, "/bin/sh");
                    try argv.append(arena, "-c");
                    try argv.append(arena, cmd.string);
                },
                .array => for (cmd.array.items) |item| {
                    if (item != .string) return appErr(arena, "command array must be strings");
                    try argv.append(arena, item.string);
                },
                else => {},
            };
        }
        if (argv.items.len == 0) return appErr(arena, "launch_app requires 'command' (string or argv array)");
        var debug_note: []const u8 = "";
        if (argStr(args, "debug")) |dm| {
            // Run-under-wrapper: the wrapper's report (backtrace,
            // leak/error output) goes to the PTY = app_log. Works for
            // string commands too: gdb/valgrind follow the exec that
            // /bin/sh performs for a simple command.
            var wrapped: std.ArrayList([]const u8) = .empty;
            defer wrapped.deinit(arena);
            if (eql(u8, dm, "gdb")) {
                try wrapped.appendSlice(arena, &.{ "gdb", "-q", "-batch", "-ex", "run", "-ex", "bt full", "-ex", "info registers", "--args" });
                debug_note = "\ndebug wrapper: gdb — the reported pid is gdb, not the app; on a crash the full backtrace lands in app_log";
            } else if (eql(u8, dm, "valgrind")) {
                try wrapped.appendSlice(arena, &.{ "valgrind", "--track-origins=yes" });
                debug_note = "\ndebug wrapper: valgrind — the reported pid is valgrind; its report lands in app_log when the app exits";
            } else {
                return appErr(arena, "'debug' must be \"gdb\" or \"valgrind\"");
            }
            try wrapped.appendSlice(arena, argv.items);
            argv.clearRetainingCapacity();
            try argv.appendSlice(arena, wrapped.items);
        }
        const audio_mode = argStr(args, "audio") orelse "forward";
        if (!eql(u8, audio_mode, "forward") and !eql(u8, audio_mode, "none"))
            return appErr(arena, "'audio' must be \"forward\" or \"none\"");
        const audio_path = argStr(args, "audio_path");
        if (audio_path) |ap| {
            if (eql(u8, audio_mode, "none"))
                return appErr(arena, "'audio_path' needs the sink: drop audio:\"none\"");
            if (ap.len == 0 or ap[0] != '/')
                return appErr(arena, "'audio_path' must be an absolute path (it lands on the daemon's host)");
        }
        const cols: u16 = @intCast(std.math.clamp(argInt(args, "cols") orelse 80, 10, 500));
        const rows: u16 = @intCast(std.math.clamp(argInt(args, "rows") orelse 24, 4, 300));
        const wait_ms: i64 = argInt(args, "wait_ms") orelse 10_000;
        var env_list: std.ArrayList([]const u8) = .empty;
        defer env_list.deinit(arena);
        if (args == .object) {
            if (args.object.get("env")) |e| {
                if (e != .object) return appErr(arena, "'env' must be an object of KEY: \"value\" strings");
                var it = e.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* != .string)
                        return appErr(arena, "'env' values must be strings");
                    try env_list.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.string }));
                }
            }
        }
        const app = appdrive.App.launch(app_state.allocator, argv.items, .{
            .cols = cols,
            .rows = rows,
            .host = argStr(args, "host"),
            .kb_layout = argStr(args, "layout"),
            .local_sock = app_state.mux_sock,
            .gpu = argBool(args, "gpu"),
            .no_audio = eql(u8, audio_mode, "none"),
            .audio_capture = audio_path,
            .cwd = argStr(args, "cwd"),
            .env = env_list.items,
        }) catch |err|
            return appErr(arena, switch (err) {
                appdrive.Error.SpawnFailed => blk: {
                    const why = appdrive.lastLaunchErr();
                    break :blk if (why.len > 0)
                        try std.fmt.allocPrint(arena, "spawn failed — {s}", .{why})
                    else
                        "spawn failed (mux daemon unreachable or spawn refused)";
                },
                appdrive.Error.BadLayout => "unknown keyboard layout (available: us, gb, fr, be, de)",
                else => "launch failed",
            });
        const id = app_state.next_id;
        app_state.next_id += 1;
        app_state.apps.put(app_state.allocator, id, app) catch {
            app.deinit();
            return error.OutOfMemory;
        };
        const wait_for = argStr(args, "wait_for") orelse "window";
        if (eql(u8, wait_for, "exit")) {
            const deadline = monoMs() + wait_ms;
            while (!app.exited and monoMs() < deadline) _ = app.pumpOnce(50);
        } else {
            _ = app.waitFirstWindow(wait_ms);
        }
        var summary = try appSummary(arena, app);
        if (debug_note.len > 0) summary = try std.fmt.allocPrint(arena, "{s}{s}", .{ summary, debug_note });
        if (audio_path) |ap| {
            const stem = if (std.mem.endsWith(u8, ap, ".wav")) ap[0 .. ap.len - 4] else ap;
            summary = try std.fmt.allocPrint(arena, "{s}\naudio capture: {s}.wav on the daemon host (later streams: {s}-N.wav; finalized when the stream or app closes)", .{ summary, stem, stem });
        }
        // Launch-and-look is THE common case: when a window rendered,
        // fold the first screenshot into the launch reply.
        var shot_win: u32 = 0;
        for (app.windows.items) |win| {
            if (!win.popup and win.frames > 0) {
                shot_win = win.id;
                break;
            }
        }
        if (shot_win != 0) {
            if (app.screenshotPng(shot_win, 1568, null, 1)) |shot| {
                defer app_state.allocator.free(shot.png);
                const caption = try screenshotCaption(arena, app, shot_win, shot, summary);
                if (imageResult(arena, caption, shot.png)) |r| return r;
            } else |_| {}
        }
        return toolResult(arena, summary, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "list_installed_apps")) {
        const listing = appdrive.listInstalledApps(app_state.allocator, argStr(args, "host"), app_state.mux_sock) catch |err|
            return appErr(arena, switch (err) {
                appdrive.Error.SpawnFailed => "cannot reach the daemon (is sketerm-mux running / host reachable?)",
                else => "app discovery failed",
            });
        defer app_state.allocator.free(listing);
        return toolResult(arena, listing, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "list_apps")) {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("[");
        var first = true;
        for (app_state.apps.values()) |app| {
            app.drain();
            if (!first) try w.writeAll(",");
            first = false;
            try w.writeAll(try appSummary(arena, app));
        }
        try w.writeAll("]");
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }

    const app = appFromArgs(args) orelse
        return appErr(arena, "unknown app (pass 'app' from launch_app; use list_apps)");
    app.drain();

    // "The app exited" is a NORMAL state, handled centrally: every
    // interaction tool answers with the exit summary IMMEDIATELY
    // (short-lived programs and observing crashes are routine).
    // Observation tools (output/log/windows/screenshot/state/actions/
    // wait/record_stop) handle exit themselves; close_app stays
    // idempotent.
    if (app.exited and needsLiveApp(name)) {
        const summary = try appSummary(arena, app);
        const msg = try std.fmt.allocPrint(arena, "the app has exited — {s} needs a running app\n{s}", .{ name, summary });
        return toolResult(arena, msg, true) orelse error.OutOfMemory;
    }

    if (eql(u8, name, "app_windows")) {
        const summary = try appSummary(arena, app);
        return toolResult(arena, summary, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_output")) {
        const text = app.output(argBool(args, "scrollback")) catch
            return appErr(arena, "no terminal mirror for this app (output unavailable)");
        defer app_state.allocator.free(text);
        var msg: []const u8 = try arena.dupe(u8, text);
        if (std.mem.trim(u8, text, " \n\t\r").len == 0) {
            // A blank grid mirror does not mean "no output" — the log
            // ring (app_log) is the source of truth for line output.
            // Only the post-exit stash is served here; a live app's
            // log_buf may hold a stale earlier log_get reply.
            if (if (app.exited) logStashTail(arena, app, 25) else null) |tail_text| {
                msg = try std.fmt.allocPrint(arena, "(terminal grid mirror is blank — serving the last lines from the log ring instead; app_log is the source of truth for line output)\n{s}", .{tail_text});
            } else {
                msg = if (argBool(args, "scrollback"))
                    "(the app has written nothing to its stdout/stderr PTY — GUI apps often print little; stderr redirected elsewhere by the app itself is not visible here. app_log is the indexed view of the same PTY)"
                else
                    "(no output on the visible terminal grid — pass scrollback:true for scrolled-off history, or use app_log for indexed lines)";
            }
        }
        if (app.exited) {
            msg = try std.fmt.allocPrint(arena, "[app exited, status {d}{s}]\n{s}", .{
                app.exit_status,
                try exitSuffix(arena, app.exit_status),
                msg,
            });
        }
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_log")) {
        const line_id: u64 = @intCast(@max(argInt(args, "id") orelse 0, 0));
        const from_id: u64 = @intCast(@max(argInt(args, "from_id") orelse 0, 0));
        const tail: i64 = std.math.clamp(argInt(args, "tail") orelse 60, 1, 500);
        const req = try std.fmt.allocPrint(
            arena,
            "{{\"tail\":{d},\"from_id\":{d},\"id\":{d},\"max_chars\":300}}",
            .{ tail, from_id, line_id },
        );
        const reply = app.logGet(req, 5_000) catch |err| return appErr(arena, switch (err) {
            appdrive.Error.Timeout => "daemon did not answer the log request in time",
            else => "no log data for this app",
        });
        defer app_state.allocator.free(reply);
        const parsed = std.json.parseFromSlice(LogReplyJ, arena, reply, .{
            .ignore_unknown_fields = true,
        }) catch return appErr(arena, "malformed log reply");
        const r = parsed.value;
        const now_wall: i64 = wallNowMs();

        if (line_id != 0) {
            // One line in full — the post-exit stash may return the whole
            // final log, so filter by id here.
            var found: ?LogLineJ = null;
            for (r.lines) |l| {
                if (l.id == line_id) found = l;
            }
            const l = found orelse
                return appErr(arena, "line not available (dropped from the ring, never emitted, or beyond the post-exit stash)");
            const age_s = @as(f64, @floatFromInt(now_wall - l.t)) / 1000.0;
            if (l.marker) {
                if (app.markerImage(line_id)) |img| {
                    const note = if (img.shared_from != 0)
                        try std.fmt.allocPrint(arena, " — window at that instant below (frame unchanged since marker {d}; screenshot shared)", .{img.shared_from})
                    else
                        " — window at that instant below";
                    const cap = try std.fmt.allocPrint(arena, "marker line {d} ({d:.1}s ago): '{s}'{s}", .{
                        l.id, age_s, l.text, note,
                    });
                    if (imageResult(arena, cap, img.png)) |res| return res;
                }
                const cap = try std.fmt.allocPrint(
                    arena,
                    "marker line {d} ({d:.1}s ago): '{s}' (no screenshot was stashed: no rendered window at the time, or the marker aged out)",
                    .{ l.id, age_s, l.text },
                );
                return toolResult(arena, cap, false) orelse error.OutOfMemory;
            }
            const msg = try std.fmt.allocPrint(arena, "line {d} ({d:.1}s ago{s}):\n{s}", .{
                l.id, age_s,
                if (l.truncated) ", was longer than the 4KB line cap" else "",
                l.text,
            });
            return toolResult(arena, msg, false) orelse error.OutOfMemory;
        }

        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        if (r.lines.len == 0) {
            try w.writeAll("(log empty — the app has not printed any complete line yet)");
        } else {
            try w.print("log lines {d}..{d} (newest id {d})", .{
                r.lines[0].id, r.lines[r.lines.len - 1].id, r.next_id - 1,
            });
            if (r.dropped > 0) try w.print(", {d} oldest dropped by the ring cap", .{r.dropped});
            if (r.markers_dropped > 0) try w.print(", {d} markers rate-limited", .{r.markers_dropped});
            try w.writeAll(" — [+] = shortened, fetch in full with {\"id\":N}\n");
            for (r.lines) |l| {
                const age_s = @as(f64, @floatFromInt(now_wall - l.t)) / 1000.0;
                if (l.marker) {
                    const has_shot = app.markerImage(l.id) != null;
                    try w.print("{d} [-{d:.1}s] [marker '{s}'{s}]\n", .{
                        l.id, age_s, l.text,
                        if (has_shot) " — screenshot stashed, view it via {\"id\":this line's id}" else "",
                    });
                } else {
                    try w.print("{d} [-{d:.1}s] {s}{s}\n", .{
                        l.id, age_s, l.text,
                        if (l.cut or l.truncated) " [+]" else "",
                    });
                }
            }
        }
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "screenshot_app") or eql(u8, name, "get_app_state")) {
        var win_id: u32 = 0;
        if (argInt(args, "window")) |v| {
            win_id = @intCast(v);
        } else {
            for (app.windows.items) |win| {
                if (!win.popup and win.frames > 0) {
                    win_id = win.id;
                    break;
                }
            }
        }
        if (win_id == 0) {
            // "No window" and "the app died" are different answers —
            // report the exit (status, signal, output) when it applies.
            if (app.exited) {
                const summary = try appSummary(arena, app);
                const msg = try std.fmt.allocPrint(arena, "the app has exited — no window to screenshot\n{s}", .{summary});
                return toolResult(arena, msg, true) orelse error.OutOfMemory;
            }
            return appErr(arena, "no rendered window yet (try app_wait first)");
        }
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 10_000;
        if (argBool(args, "wait_change")) {
            // Block (bounded) until the window commits a frame newer
            // than its last screenshot — "did my click do anything".
            if (!app.waitWindowChange(win_id, timeout_ms))
                return appErr(arena, "window content did not change before the timeout");
        }
        var settle_note: []const u8 = "";
        if (argInt(args, "stable_ms")) |sm| {
            // Settle-then-capture: wait until the window stops
            // repainting before shooting (composes with wait_change:
            // "changed, then went quiet").
            if (sm > 0 and !app.waitWindowSettle(win_id, sm, timeout_ms))
                settle_note = "\n[note: frames were still arriving at timeout_ms — captured anyway]";
        }
        if (argBool(args, "stats_only")) {
            // Cheap change probe: no PNG, just "did it change and how
            // much" vs whatever the caller last saw.
            const st = app.diffStats(win_id) catch
                return appErr(arena, "no such window / no pixels yet");
            const msg = try std.fmt.allocPrint(
                arena,
                "{{\"changed\":{},\"diff_pct\":{d:.2},\"resized\":{},\"w\":{d},\"h\":{d},\"frames\":{d}}}{s}",
                .{ st.changed, st.diff_pct, st.resized, st.w, st.h, st.frames, settle_note },
            );
            return toolResult(arena, msg, false) orelse error.OutOfMemory;
        }
        const max_px: u32 = @intCast(std.math.clamp(argInt(args, "max_px") orelse 1568, 0, 8192));
        var region: ?appdrive.App.Region = null;
        if (args == .object) {
            if (args.object.get("region")) |rv| {
                if (rv != .object) return appErr(arena, "'region' must be {x,y,w,h}");
                const gi = struct {
                    fn f(o: std.json.Value, k: []const u8) ?i64 {
                        const v = o.object.get(k) orelse return null;
                        return if (v == .integer) v.integer else null;
                    }
                }.f;
                const rx = gi(rv, "x") orelse 0;
                const ry = gi(rv, "y") orelse 0;
                const rw = gi(rv, "w") orelse return appErr(arena, "'region' must be {x,y,w,h}");
                const rh = gi(rv, "h") orelse return appErr(arena, "'region' must be {x,y,w,h}");
                if (rx < 0 or ry < 0 or rw <= 0 or rh <= 0) return appErr(arena, "'region' values must be non-negative (w/h > 0)");
                region = .{ .x = @intCast(rx), .y = @intCast(ry), .w = @intCast(rw), .h = @intCast(rh) };
            }
        }
        const zoom: u32 = @intCast(std.math.clamp(argInt(args, "zoom") orelse 1, 1, 32));

        if (argInt(args, "burst")) |bn| if (bn > 1) {
            // Burst: up to N shots over a window of time, each gated on
            // a minimum pixel change vs the PREVIOUS shot — one call
            // instead of a screenshot-poll loop across a transition.
            const count: usize = @intCast(@min(bn, 8));
            const burst_ms: i64 = argInt(args, "burst_ms") orelse 5_000;
            const min_pct: f64 = argFloat(args, "min_change_pct") orelse 1.0;
            var pngs: std.ArrayList([]const u8) = .empty;
            defer {
                for (pngs.items) |p| app_state.allocator.free(p);
                pngs.deinit(arena);
            }
            var offsets: std.ArrayList(i64) = .empty;
            defer offsets.deinit(arena);
            const t0 = monoMs();
            var first: ?appdrive.App.Shot = null;
            while (monoMs() - t0 < burst_ms and pngs.items.len < count) {
                if (pngs.items.len > 0) {
                    _ = app.pumpOnce(25);
                    if (app.peekDiffPct(win_id) < min_pct) {
                        if (app.exited) break;
                        continue;
                    }
                }
                const shot = app.screenshotPng(win_id, max_px, region, zoom) catch break;
                pngs.append(arena, shot.png) catch {
                    app_state.allocator.free(shot.png);
                    break;
                };
                offsets.append(arena, monoMs() - t0) catch break;
                if (first == null) first = shot;
                if (app.exited) break;
            }
            const fshot = first orelse
                return appErr(arena, "no such window / no pixels yet (a region must lie inside the window)");
            var ob: std.ArrayList(u8) = .empty;
            defer ob.deinit(arena);
            for (offsets.items, 0..) |o, i| {
                var nb: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&nb, "{s}{d}ms", .{ if (i > 0) ", " else "", o }) catch break;
                try ob.appendSlice(arena, s);
            }
            const extra: []const u8 = if (eql(u8, name, "get_app_state")) try appSummary(arena, app) else "";
            const base_caption = try screenshotCaption(arena, app, win_id, fshot, extra);
            const caption = try std.fmt.allocPrint(arena, "{s}\nburst: {d} frame(s) captured at [{s}] (each >= {d:.1}% changed from the previous){s}", .{
                base_caption, pngs.items.len, ob.items, min_pct, settle_note,
            });
            return imagesResult(arena, caption, pngs.items) orelse error.OutOfMemory;
        };

        const shot = app.screenshotPng(win_id, max_px, region, zoom) catch
            return appErr(arena, "no such window / no pixels yet (a region must lie inside the window)");
        defer app_state.allocator.free(shot.png);
        const extra: []const u8 = if (eql(u8, name, "get_app_state")) try appSummary(arena, app) else "";
        const base_caption = try screenshotCaption(arena, app, win_id, shot, extra);
        const caption = if (settle_note.len > 0)
            try std.fmt.allocPrint(arena, "{s}{s}", .{ base_caption, settle_note })
        else
            base_caption;
        return imageResult(arena, caption, shot.png) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_drag")) {
        const win_id: u32 = @intCast(argInt(args, "window") orelse
            return appErr(arena, "app_drag requires 'window'"));
        const x1 = argInt(args, "x1") orelse return appErr(arena, "app_drag requires x1,y1,x2,y2");
        const y1 = argInt(args, "y1") orelse return appErr(arena, "app_drag requires x1,y1,x2,y2");
        const x2 = argInt(args, "x2") orelse return appErr(arena, "app_drag requires x1,y1,x2,y2");
        const y2 = argInt(args, "y2") orelse return appErr(arena, "app_drag requires x1,y1,x2,y2");
        const button: u32 = @intCast(argInt(args, "button") orelse 1);
        app.drag(
            win_id,
            @floatFromInt(x1),
            @floatFromInt(y1),
            @floatFromInt(x2),
            @floatFromInt(y2),
            button,
        ) catch return appErr(arena, "drag failed (bad window?)");
        _ = app.waitIdle(200, 2_000);
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_clipboard_get")) {
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 3_000;
        const bytes = app.getClipboard(timeout_ms) catch |err| return appErr(arena, switch (err) {
            appdrive.Error.NoClipboard => "the app has not announced a clipboard selection (copy something in it first)",
            appdrive.Error.Timeout => "app did not deliver clipboard data in time",
            else => "clipboard fetch failed",
        });
        defer app_state.allocator.free(bytes);
        const copy = try arena.dupe(u8, bytes);
        return toolResult(arena, copy, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_clipboard_set")) {
        const text = argStr(args, "text") orelse
            return appErr(arena, "app_clipboard_set requires 'text'");
        app.setClipboard(text) catch return appErr(arena, "clipboard set failed");
        if (argBool(args, "paste")) {
            const win: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
            app.pressKey(win, "ctrl+v") catch return appErr(arena, "paste keystroke failed (no window?)");
            _ = app.waitIdle(200, 2_000);
        }
        return toolResult(arena, "ok (the app sees this as the host clipboard)", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_click")) {
        const button: u32 = @intCast(argInt(args, "button") orelse 1);
        const win_id: u32 = @intCast(argInt(args, "window") orelse
            return appErr(arena, "app_click requires 'window' and x/y. To target a widget by name/role use app_perform_action (coordinate-free)."));
        const x = argInt(args, "x") orelse return appErr(arena, "app_click requires 'x'");
        const y = argInt(args, "y") orelse return appErr(arena, "app_click requires 'y'");
        app.click(win_id, @floatFromInt(x), @floatFromInt(y), button) catch
            return appErr(arena, "click failed (bad window?)");
        _ = app.waitIdle(200, 2_000);
        const want_mark = argBool(args, "mark");
        if (want_mark or argBool(args, "screenshot")) {
            // Post-click frame, optionally with the click point drawn
            // in — one call shows where the click landed AND what the
            // UI did with it.
            const annot = [_]marks_mod.Mark{.{ .x = @floatFromInt(x), .y = @floatFromInt(y) }};
            const max_px: u32 = @intCast(std.math.clamp(argInt(args, "max_px") orelse 1568, 0, 8192));
            const shot = app.screenshotPngMarked(win_id, max_px, null, 1, if (want_mark) &annot else &.{}) catch
                return toolResult(arena, "clicked, but the post-click screenshot failed (no pixels yet?)", false) orelse error.OutOfMemory;
            defer app_state.allocator.free(shot.png);
            const extra = try std.fmt.allocPrint(arena, "clicked ({d},{d}) button {d}{s}", .{
                x, y, button,
                if (want_mark)
                    " — the red crosshair marks the click point on the post-click frame. Coordinates are delivered to the app verbatim; a pointer-LOCKED app tracks its own cursor from relative deltas, so its internal cursor can differ (calibrate with app_mouse_move dx/dy)."
                else
                    "",
            });
            const caption = try screenshotCaption(arena, app, win_id, shot, extra);
            return imageResult(arena, caption, shot.png) orelse error.OutOfMemory;
        }
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_actions")) {
        const actions_v = (if (args == .object) args.object.get("actions") else null) orelse
            return appErr(arena, "app_actions requires 'actions' (an array of step objects)");
        if (actions_v != .array) return appErr(arena, "'actions' must be an array of step objects");
        const steps = actions_v.array.items;
        if (steps.len == 0) return appErr(arena, "'actions' is empty");
        if (steps.len > 32) return appErr(arena, "too many steps (max 32)");
        const win_arg: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
        const MAX_SHOTS = 8;

        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        var pngs: std.ArrayList([]const u8) = .empty;
        defer {
            for (pngs.items) |p| app_state.allocator.free(p);
            pngs.deinit(arena);
        }
        var stopped = false;
        // Marks accumulated by `"mark": true` steps; drawn onto (and
        // consumed by) the next screenshot so several clicks can share
        // one annotated image, each labelled with its step number.
        var pending_marks: std.ArrayList(marks_mod.Mark) = .empty;
        defer pending_marks.deinit(arena);
        for (steps, 0..) |st, idx| {
            const n = idx + 1;
            if (app.exited) {
                try w.print("step {d}: SKIPPED — app exited (status {d}{s}); remaining steps skipped\n", .{ n, app.exit_status, try exitSuffix(arena, app.exit_status) });
                stopped = true;
                break;
            }
            if (st != .object) {
                try w.print("step {d}: ERROR — each step must be an object\n", .{n});
                stopped = true;
                break;
            }
            const win_step: ?u32 = if (argInt(st, "window")) |v| @intCast(v) else win_arg;
            const button: u32 = @intCast(argInt(st, "button") orelse 1);

            if (st.object.get("wait")) |wv| {
                const ms: i64 = std.math.clamp(if (wv == .integer) wv.integer else 0, 0, 30_000);
                _ = app.waitIdle(std.math.maxInt(i32), ms); // pure pumped sleep
                try w.print("step {d}: waited {d}ms\n", .{ n, ms });
            } else if (st.object.get("move")) |mv| {
                const xy = numArray(mv, 2) orelse {
                    try w.print("step {d}: ERROR — \"move\" wants [x,y]\n", .{n});
                    stopped = true;
                    break;
                };
                const pos = app.moveMouse(win_step, xy[0], xy[1]) catch {
                    try w.print("step {d}: ERROR — move failed (bad window?)\n", .{n});
                    stopped = true;
                    break;
                };
                const marked = argBool(st, "mark");
                if (marked) pending_marks.append(arena, .{ .x = pos.x, .y = pos.y, .kind = .move, .label = @intCast(n) }) catch {};
                try w.print("step {d}: moved to ({d:.0},{d:.0}) window {d}{s}\n", .{ n, pos.x, pos.y, pos.win, if (marked) " [marked]" else "" });
            } else if (st.object.get("move_rel")) |mv| {
                const dd = numArray(mv, 2) orelse {
                    try w.print("step {d}: ERROR — \"move_rel\" wants [dx,dy]\n", .{n});
                    stopped = true;
                    break;
                };
                const pos = app.moveMouseRel(win_step, dd[0], dd[1]) catch {
                    try w.print("step {d}: ERROR — move_rel failed (bad window?)\n", .{n});
                    stopped = true;
                    break;
                };
                const marked = argBool(st, "mark");
                if (marked) pending_marks.append(arena, .{ .x = pos.x, .y = pos.y, .kind = .move, .label = @intCast(n) }) catch {};
                try w.print("step {d}: moved by ({d:.0},{d:.0}) to ({d:.0},{d:.0}) window {d}{s}\n", .{ n, dd[0], dd[1], pos.x, pos.y, pos.win, if (marked) " [marked]" else "" });
            } else if (st.object.get("click")) |cv| {
                const xy = numArray(cv, 2) orelse {
                    try w.print("step {d}: ERROR — \"click\" wants [x,y]\n", .{n});
                    stopped = true;
                    break;
                };
                const wid = win_step orelse firstToplevelId(app);
                app.click(wid, xy[0], xy[1], button) catch {
                    try w.print("step {d}: ERROR — click failed (bad window?)\n", .{n});
                    stopped = true;
                    break;
                };
                _ = app.waitIdle(100, 1_000);
                const marked = argBool(st, "mark");
                if (marked) pending_marks.append(arena, .{ .x = xy[0], .y = xy[1], .kind = .click, .label = @intCast(n) }) catch {};
                try w.print("step {d}: clicked ({d:.0},{d:.0}) button {d} window {d}{s}\n", .{ n, xy[0], xy[1], button, wid, if (marked) " [marked]" else "" });
            } else if (st.object.get("drag")) |dv| {
                const q = numArray(dv, 4) orelse {
                    try w.print("step {d}: ERROR — \"drag\" wants [x1,y1,x2,y2]\n", .{n});
                    stopped = true;
                    break;
                };
                const wid = win_step orelse firstToplevelId(app);
                app.drag(wid, q[0], q[1], q[2], q[3], button) catch {
                    try w.print("step {d}: ERROR — drag failed (bad window?)\n", .{n});
                    stopped = true;
                    break;
                };
                _ = app.waitIdle(100, 1_000);
                const marked = argBool(st, "mark");
                if (marked) {
                    // Start point unlabelled (hover color), end point
                    // carries the step number.
                    pending_marks.append(arena, .{ .x = q[0], .y = q[1], .kind = .move }) catch {};
                    pending_marks.append(arena, .{ .x = q[2], .y = q[3], .kind = .click, .label = @intCast(n) }) catch {};
                }
                try w.print("step {d}: dragged ({d:.0},{d:.0})→({d:.0},{d:.0}) window {d}{s}\n", .{ n, q[0], q[1], q[2], q[3], wid, if (marked) " [marked]" else "" });
            } else if (st.object.get("key")) |kv| {
                if (kv != .string) {
                    try w.print("step {d}: ERROR — \"key\" wants a string of chords\n", .{n});
                    stopped = true;
                    break;
                }
                var bad = false;
                var it = std.mem.tokenizeScalar(u8, kv.string, ' ');
                while (it.next()) |spec| {
                    app.pressKey(win_step, spec) catch {
                        bad = true;
                        break;
                    };
                }
                if (bad) {
                    try w.print("step {d}: ERROR — key press failed (unknown chord / no window?)\n", .{n});
                    stopped = true;
                    break;
                }
                _ = app.waitIdle(100, 1_000);
                try w.print("step {d}: pressed \"{s}\"\n", .{ n, kv.string });
            } else if (st.object.get("type")) |tv| {
                if (tv != .string) {
                    try w.print("step {d}: ERROR — \"type\" wants a string\n", .{n});
                    stopped = true;
                    break;
                }
                app.typeText(win_step, tv.string) catch {
                    try w.print("step {d}: ERROR — type failed (no window?)\n", .{n});
                    stopped = true;
                    break;
                };
                _ = app.waitIdle(100, 1_000);
                try w.print("step {d}: typed {d} chars\n", .{ n, tv.string.len });
            } else if (st.object.get("scroll")) |sv| {
                const dd = numArray(sv, 2) orelse {
                    try w.print("step {d}: ERROR — \"scroll\" wants [dx,dy]\n", .{n});
                    stopped = true;
                    break;
                };
                var sx: f64 = 10;
                var sy: f64 = 10;
                if (st.object.get("at")) |atv| {
                    if (numArray(atv, 2)) |at| {
                        sx = at[0];
                        sy = at[1];
                    }
                } else if (app.pointerPos()) |p| {
                    sx = p.x;
                    sy = p.y;
                }
                const wid = win_step orelse firstToplevelId(app);
                app.scroll(wid, sx, sy, dd[0], dd[1]) catch {
                    try w.print("step {d}: ERROR — scroll failed (bad window?)\n", .{n});
                    stopped = true;
                    break;
                };
                _ = app.waitIdle(100, 1_000);
                const marked = argBool(st, "mark");
                if (marked) pending_marks.append(arena, .{ .x = sx, .y = sy, .kind = .move, .label = @intCast(n) }) catch {};
                try w.print("step {d}: scrolled ({d:.0},{d:.0}) at ({d:.0},{d:.0}) window {d}{s}\n", .{ n, dd[0], dd[1], sx, sy, wid, if (marked) " [marked]" else "" });
            } else if (st.object.get("wait_idle")) |wv| {
                var quiet_ms: i64 = 400;
                var timeout_ms: i64 = 10_000;
                var change_pct: ?f64 = null;
                if (wv == .object) {
                    if (argInt(wv, "quiet_ms")) |q| quiet_ms = q;
                    if (argInt(wv, "timeout_ms")) |t| timeout_ms = t;
                    change_pct = argFloat(wv, "change_pct");
                }
                var settled: bool = undefined;
                if (change_pct) |pct| {
                    const wid = win_step orelse firstToplevelId(app);
                    settled = if (wid == 0) false else app.waitVisualSettle(wid, quiet_ms, timeout_ms, pct);
                } else {
                    settled = app.waitIdle(quiet_ms, timeout_ms);
                }
                try w.print("step {d}: wait_idle — {s}\n", .{ n, if (settled) "settled" else "timeout (still rendering)" });
            } else if (st.object.get("wait_change")) |wv| {
                const timeout_ms: i64 = if (wv == .integer) wv.integer else 10_000;
                const wid = win_step orelse firstToplevelId(app);
                const changed = if (wid == 0) false else app.waitWindowChange(wid, timeout_ms);
                try w.print("step {d}: wait_change — {s}\n", .{ n, if (changed) "content changed" else "no change before timeout" });
            } else if (st.object.get("screenshot")) |sv| {
                const wid = win_step orelse firstToplevelId(app);
                if (wid == 0) {
                    try w.print("step {d}: ERROR — no rendered window to screenshot\n", .{n});
                    stopped = true;
                    break;
                }
                if (pngs.items.len >= MAX_SHOTS) {
                    try w.print("step {d}: screenshot SKIPPED (max {d} per call)\n", .{ n, MAX_SHOTS });
                    continue;
                }
                var max_px: u32 = 1568;
                if (sv == .object) {
                    if (argInt(sv, "max_px")) |m| max_px = @intCast(std.math.clamp(m, 0, 8192));
                }
                if (argBool(st, "mark") or (sv == .object and argBool(sv, "mark"))) {
                    // Mark the current pointer position (hover check).
                    if (app.pointerPos()) |p|
                        pending_marks.append(arena, .{ .x = p.x, .y = p.y, .kind = .move, .label = @intCast(n) }) catch {};
                }
                const prefix = try std.fmt.allocPrint(arena, "step {d}", .{n});
                if (!try actionsCapture(arena, app, w, &pngs, &pending_marks, wid, max_px, prefix)) {
                    stopped = true;
                    break;
                }
                continue;
            } else {
                try w.print("step {d}: ERROR — unknown step (want move/move_rel/click/drag/key/type/scroll/wait/wait_idle/wait_change/screenshot)\n", .{n});
                stopped = true;
                break;
            }
            // Combined form: {"click":[x,y],"screenshot":true} — capture
            // right after the action, with any pending marks drawn in.
            // (Dedicated screenshot steps `continue`d above.)
            if (argBool(st, "screenshot")) {
                const wid = win_step orelse firstToplevelId(app);
                if (pngs.items.len >= MAX_SHOTS) {
                    try w.print("step {d}: screenshot SKIPPED (max {d} per call)\n", .{ n, MAX_SHOTS });
                } else if (wid != 0) {
                    const prefix = try std.fmt.allocPrint(arena, "step {d}", .{n});
                    _ = try actionsCapture(arena, app, w, &pngs, &pending_marks, wid, 1568, prefix);
                }
            }
        }
        // `mark` without any screenshot still yields an image: capture
        // the final state with the leftover marks drawn in.
        if (pending_marks.items.len > 0 and pngs.items.len < MAX_SHOTS) {
            const wid = win_arg orelse firstToplevelId(app);
            if (wid != 0)
                _ = try actionsCapture(arena, app, w, &pngs, &pending_marks, wid, 1568, "end of batch");
        }
        if (!stopped) try w.print("all {d} steps completed\n", .{steps.len});
        if (app.exited) try w.writeAll(try appSummary(arena, app));
        if (pngs.items.len > 0)
            return imagesResult(arena, aw.written(), pngs.items) orelse error.OutOfMemory;
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_mouse_move")) {
        const win: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
        const has_abs = argFloat(args, "x") != null and argFloat(args, "y") != null;
        const has_rel = argFloat(args, "dx") != null or argFloat(args, "dy") != null;
        if (has_abs and has_rel)
            return appErr(arena, "pass x/y (absolute) OR dx/dy (relative), not both");
        var pos: appdrive.App.PtrPos = undefined;
        if (has_abs) {
            pos = app.moveMouse(win, argFloat(args, "x").?, argFloat(args, "y").?) catch
                return appErr(arena, "move failed (bad window?)");
        } else if (has_rel) {
            pos = app.moveMouseRel(win, argFloat(args, "dx") orelse 0, argFloat(args, "dy") orelse 0) catch
                return appErr(arena, "move failed (bad window?)");
        } else {
            pos = app.pointerPos() orelse
                return toolResult(arena, "no pointer position tracked yet (nothing moved/clicked in this app)", false) orelse error.OutOfMemory;
        }
        if (has_abs or has_rel) _ = app.waitIdle(100, 1_000);
        const msg = try std.fmt.allocPrint(arena, "{{\"window\":{d},\"x\":{d:.0},\"y\":{d:.0}}}", .{ pos.win, pos.x, pos.y });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_perform_action")) {
        const elem_id = argStr(args, "element") orelse
            return appErr(arena, "app_perform_action requires 'element' (an id from app_a11y_tree)");
        const index: i64 = argInt(args, "index") orelse 0;
        const payload = try std.fmt.allocPrint(arena, "{{\"op\":\"action\",\"id\":{f},\"index\":{d}}}", .{
            std.json.fmt(elem_id, .{}),
            index,
        });
        const reply = app.a11yOp(payload, argInt(args, "timeout_ms") orelse 5_000) catch
            return appErr(arena, "a11y action failed (daemon unreachable?)");
        defer app_state.allocator.free(reply);
        if (std.mem.indexOf(u8, reply, "\"ok\"") == null)
            return appErr(arena, try arena.dupe(u8, reply));
        _ = app.waitIdle(200, 2_000);
        return toolResult(arena, "action performed", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_set_value")) {
        const elem_id = argStr(args, "element") orelse
            return appErr(arena, "app_set_value requires 'element' (an id from app_a11y_tree)");
        var payload: []const u8 = undefined;
        if (argStr(args, "text")) |text| {
            payload = try std.fmt.allocPrint(arena, "{{\"op\":\"set_text\",\"id\":{f},\"text\":{f}}}", .{
                std.json.fmt(elem_id, .{}),
                std.json.fmt(text, .{}),
            });
        } else if (args == .object and args.object.get("value") != null) {
            const v = args.object.get("value").?;
            const num: f64 = switch (v) {
                .integer => |iv| @floatFromInt(iv),
                .float => |fl| fl,
                else => return appErr(arena, "'value' must be a number"),
            };
            payload = try std.fmt.allocPrint(arena, "{{\"op\":\"set_value\",\"id\":{f},\"value\":{d}}}", .{
                std.json.fmt(elem_id, .{}),
                num,
            });
        } else return appErr(arena, "app_set_value requires 'text' (text fields) or 'value' (sliders/spinners)");
        const reply = app.a11yOp(payload, argInt(args, "timeout_ms") orelse 5_000) catch
            return appErr(arena, "a11y set failed (daemon unreachable?)");
        defer app_state.allocator.free(reply);
        if (std.mem.indexOf(u8, reply, "\"ok\"") == null)
            return appErr(arena, try arena.dupe(u8, reply));
        _ = app.waitIdle(200, 2_000);
        return toolResult(arena, "value set", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_wait_for_element")) {
        const role: ?i64 = argInt(args, "role");
        const name_sub = argStr(args, "name");
        if (role == null and name_sub == null)
            return appErr(arena, "app_wait_for_element requires 'role' and/or 'name'");
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 10_000;
        const deadline = monoMs() + timeout_ms;
        while (true) {
            switch (a11yFetch(arena, app, 5_000)) {
                .tree => |t| if (a11yFindMatch(t, role, name_sub)) |node| {
                    const summary = try a11yNodeSummary(arena, node);
                    return toolResult(arena, summary, false) orelse error.OutOfMemory;
                },
                .err => {}, // tree not up yet — keep polling
            }
            if (monoMs() >= deadline)
                return appErr(arena, "element did not appear before the timeout");
            var ts = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 300 * 1000 * 1000 };
            _ = c.nanosleep(&ts, null);
            app.drain();
        }
    }
    if (eql(u8, name, "app_type")) {
        const text = argStr(args, "text") orelse return appErr(arena, "app_type requires 'text'");
        const win: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
        app.typeText(win, text) catch |err| return appErr(arena, switch (err) {
            appdrive.Error.BadKey => "text contains a character outside the us keymap",
            else => "type failed (no window?)",
        });
        _ = app.waitIdle(200, 2_000);
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_key")) {
        const keys = argStr(args, "keys") orelse return appErr(arena, "app_key requires 'keys'");
        const win: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
        var it = std.mem.tokenizeScalar(u8, keys, ' ');
        while (it.next()) |spec| {
            app.pressKey(win, spec) catch |err| return appErr(arena, switch (err) {
                appdrive.Error.BadKey => "unknown key chord",
                else => "key press failed (no window?)",
            });
        }
        _ = app.waitIdle(200, 2_000);
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_scroll")) {
        const win_id: u32 = @intCast(argInt(args, "window") orelse
            return appErr(arena, "app_scroll requires 'window'"));
        const x = argInt(args, "x") orelse 10;
        const y = argInt(args, "y") orelse 10;
        const dx = argInt(args, "dx") orelse 0;
        const dy = argInt(args, "dy") orelse 0;
        app.scroll(win_id, @floatFromInt(x), @floatFromInt(y), @floatFromInt(dx), @floatFromInt(dy)) catch
            return appErr(arena, "scroll failed (bad window?)");
        _ = app.waitIdle(200, 2_000);
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_resize")) {
        const win_id: u32 = @intCast(argInt(args, "window") orelse
            return appErr(arena, "app_resize requires 'window'"));
        const w = argInt(args, "w") orelse return appErr(arena, "app_resize requires 'w'");
        const h = argInt(args, "h") orelse return appErr(arena, "app_resize requires 'h'");
        app.resizeWindow(win_id, @intCast(w), @intCast(h)) catch
            return appErr(arena, "resize failed (bad window?)");
        _ = app.waitIdle(300, 3_000);
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_wait")) {
        const quiet_ms: i64 = argInt(args, "quiet_ms") orelse 400;
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 10_000;
        var outcome: []const u8 = undefined;
        if (argFloat(args, "change_pct")) |pct| {
            // Visual quiescence: frames may keep committing (a game
            // always renders) — settle when they stop CHANGING much.
            const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
            if (wid == 0) return appErr(arena, "no rendered window yet (change_pct needs one)");
            outcome = if (app.waitVisualSettle(wid, quiet_ms, timeout_ms, pct))
                try std.fmt.allocPrint(arena, "settled (frames changed <{d:.1}% of pixels for {d}ms)", .{ pct, quiet_ms })
            else
                try std.fmt.allocPrint(arena, "timeout: still changing >{d:.1}% of pixels per frame after {d}ms", .{ pct, timeout_ms });
        } else {
            outcome = if (app.waitIdle(quiet_ms, timeout_ms))
                "settled (no new frames)"
            else
                "timeout: still rendering — a continuously-animating app never settles this way; pass change_pct (e.g. 2) to wait for VISUAL quiescence instead";
        }
        const summary = try appSummary(arena, app);
        const msg = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ outcome, summary });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_a11y_tree")) {
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 5_000;
        const tree = app.a11yTree(timeout_ms) catch |err| return appErr(arena, switch (err) {
            appdrive.Error.Timeout => "timed out reading the accessibility tree",
            else => "accessibility read failed",
        });
        defer app_state.allocator.free(tree);
        const copy = try arena.dupe(u8, tree);
        // Prepend the AT-SPI role legend so the assistant can read
        // numeric roles without a lookup.
        const msg = try std.fmt.allocPrint(arena,
            \\AT-SPI tree. Each node has an "id" — pass it to app_perform_action (press/activate/toggle a widget) or app_set_value (write a text field/slider) to drive the app WITHOUT coordinates; that is the reliable path. Roles (common): 8 checkbox, 14 dialog/frame, 18 filler, 25 label, 28 menu, 29 menubar, 30 menuitem, 34 canvas, 35 page-tab, 37 panel, 42 push-button, 43 radiobutton, 44 root/desktop, 46 scrollbar, 60 table, 62 text, 71 toolbar, 74 tree, 75 application, 84 entry. Note: "rect" is unreliable for headless apps (no screen position), so prefer perform_action/set_value over pixel clicks.
            \\{s}
        , .{copy});
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_record_start")) {
        var win_id: u32 = 0;
        if (argInt(args, "window")) |v| {
            win_id = @intCast(v);
        } else {
            for (app.windows.items) |win| {
                if (!win.popup and win.frames > 0) {
                    win_id = win.id;
                    break;
                }
            }
        }
        if (win_id == 0) return appErr(arena, "no rendered window yet (try app_wait first)");
        // WebM/VP9 is the default (smaller, higher quality); format:"gif"
        // for the animated GIF.
        const want_gif = if (argStr(args, "format")) |fmt| std.mem.eql(u8, fmt, "gif") else false;
        const max_px: u32 = @intCast(std.math.clamp(argInt(args, "max_px") orelse (if (want_gif) @as(i64, 800) else 1280), 0, 4096));
        const fps: u32 = @intCast(std.math.clamp(argInt(args, "fps") orelse 0, 0, 60));
        app.recordStart(win_id, max_px, !want_gif, fps) catch return appErr(arena, "no such window");
        return toolResult(arena, "recording — frames are captured while other app tools run (click/type/wait); call app_record_stop to finish", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_record_stop")) {
        const result = app.recordStop() catch |err| return appErr(arena, switch (err) {
            appdrive.Error.NotRecording => "no recording in progress (app_record_start first)",
            else => "recording produced no frames",
        });
        defer app_state.allocator.free(result.data);
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
        const ext = if (result.webm) "webm" else "gif";
        const path = argStr(args, "path") orelse
            try std.fmt.allocPrint(arena, "/tmp/sketerm-rec-{d}-{d}.{s}", .{ c.getpid(), ts.tv_sec, ext });
        const path_z = try std.fmt.allocPrint(arena, "{s}\x00", .{path});
        const f = c.fopen(path_z.ptr, "wb") orelse return appErr(arena, "cannot write the output path");
        const wr = c.fwrite(result.data.ptr, 1, result.data.len, f);
        _ = c.fclose(f);
        if (wr != result.data.len) return appErr(arena, "short write saving the recording");
        const msg = try std.fmt.allocPrint(arena, "saved {d} frames ({d} KiB {s}) to {s}", .{ result.frames, result.data.len / 1024, ext, path });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "close_app_window")) {
        const win_id: u32 = @intCast(argInt(args, "window") orelse
            return appErr(arena, "close_app_window requires 'window'"));
        app.closeWindow(win_id) catch return appErr(arena, "close failed (bad window?)");
        return toolResult(arena, "close requested (the app decides)", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "close_app")) {
        // Idempotent: closing an already-dead app is a no-op success.
        const id = appIdOf(app);
        const was_exited = app.exited;
        const status = app.exit_status;
        _ = app_state.apps.swapRemove(id);
        app.deinit();
        const msg = if (was_exited)
            try std.fmt.allocPrint(arena, "app session closed (the app had already exited with status {d})", .{status})
        else
            "app session killed";
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    return appErr(arena, "unknown tool");
}

// ── headless terminal tools (shell sessions on the private daemon) ─

fn termTool(arena: std.mem.Allocator, name: []const u8, args: std.json.Value) ![]const u8 {
    const eql = std.mem.eql;
    const sock = term_state.mux_sock orelse
        return appErr(arena, "headless terminal tools need isolated mode; in --shared mode use the GUI-backed terminal tools (list_terminals, run_command, ...)");

    if (eql(u8, name, "term_open")) {
        const cols: u16 = @intCast(std.math.clamp(argInt(args, "cols") orelse 120, 10, 500));
        const rows: u16 = @intCast(std.math.clamp(argInt(args, "rows") orelse 40, 4, 300));
        var argv_store: std.ArrayList([]const u8) = .empty;
        defer argv_store.deinit(arena);
        var argv: ?[]const []const u8 = null;
        if (args == .object) {
            if (args.object.get("command")) |cmd| switch (cmd) {
                .string => {
                    try argv_store.append(arena, "/bin/sh");
                    try argv_store.append(arena, "-c");
                    try argv_store.append(arena, cmd.string);
                    argv = argv_store.items;
                },
                .array => {
                    for (cmd.array.items) |item| {
                        if (item != .string) return appErr(arena, "command array must be strings");
                        try argv_store.append(arena, item.string);
                    }
                    if (argv_store.items.len > 0) argv = argv_store.items;
                },
                else => {},
            };
        }
        const t = termdrive.Term.spawn(term_state.allocator, argv, cols, rows, sock) catch
            return appErr(arena, "spawn failed (mux daemon unreachable?)");
        const id = term_state.next_id;
        term_state.next_id += 1;
        term_state.terms.put(term_state.allocator, id, t) catch {
            t.deinit();
            return error.OutOfMemory;
        };
        // Let the shell print its first prompt.
        _ = t.waitIdle(250, 3_000);
        const msg = try std.fmt.allocPrint(arena, "opened headless terminal {d} ({d}x{d})", .{ id, cols, rows });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "term_list")) {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("[");
        var first = true;
        var it = term_state.terms.iterator();
        while (it.next()) |e| {
            if (!first) try w.writeAll(",");
            first = false;
            const t = e.value_ptr.*;
            try w.print("{{\"term\":{d},\"exited\":{}", .{ e.key_ptr.*, t.exited });
            if (t.exited) try w.print(",\"exit_status\":{d}", .{t.exit_status});
            try w.writeAll("}");
        }
        try w.writeAll("]");
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }

    const t = termFromArgs(args) orelse
        return appErr(arena, "no such terminal (pass 'term' id, or omit it when only one is open)");

    if (eql(u8, name, "term_send_text")) {
        const text = argStr(args, "text") orelse return appErr(arena, "term_send_text requires 'text'");
        const data = if (argBool(args, "enter"))
            try std.fmt.allocPrint(arena, "{s}\r", .{text})
        else
            text;
        t.sendText(data) catch return appErr(arena, "send failed (terminal exited?)");
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "term_send_keys")) {
        const keychords = argStr(args, "keys") orelse return appErr(arena, "term_send_keys requires 'keys'");
        t.sendKeys(keychords) catch |err| return appErr(arena, switch (err) {
            termdrive.Error.BadKey => "unknown key chord",
            else => "send failed (terminal exited?)",
        });
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "term_read")) {
        const sb = argBool(args, "scrollback");
        const text = t.readScreen(sb) catch return appErr(arena, "read failed (terminal exited?)");
        defer term_state.allocator.free(text);
        return toolResult(arena, try arena.dupe(u8, text), false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "term_run")) {
        const cmd = argStr(args, "command") orelse return appErr(arena, "term_run requires 'command'");
        const quiet_ms: i64 = argInt(args, "quiet_ms") orelse 400;
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 30_000;
        const line = try std.fmt.allocPrint(arena, "{s}\r", .{cmd});
        t.sendText(line) catch return appErr(arena, "send failed (terminal exited?)");
        const settled = t.waitIdle(quiet_ms, timeout_ms);
        const note = if (settled) "" else "\n[note: output still flowing at timeout]";
        const want_output_only = argBool(args, "output_only");
        if (want_output_only) {
            // OSC 133 zone: output + exit code only. Screen-scrape
            // fallback when no zone completed — announced below,
            // never a silent shape change.
            if (t.lastCommand() catch null) |lc| {
                defer term_state.allocator.free(lc.text);
                const msg = try std.fmt.allocPrint(arena, "exit: {d}\n---\n{s}{s}", .{ lc.exit, lc.text, note });
                return toolResult(arena, msg, false) orelse error.OutOfMemory;
            }
        }
        const text = t.readScreen(false) catch return appErr(arena, "read failed");
        defer term_state.allocator.free(text);
        const fallback_note = if (want_output_only)
            "[output_only unavailable: no completed OSC 133 command zone — shell integration is inactive in this terminal (unsupported shell, or the command emitted no marks); returning the rendered screen]\n"
        else
            "";
        const msg = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ fallback_note, text, note });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "term_wait_idle")) {
        const quiet_ms: i64 = argInt(args, "quiet_ms") orelse 500;
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 30_000;
        const settled = t.waitIdle(quiet_ms, timeout_ms);
        return toolResult(arena, if (settled) "idle" else "still active at timeout", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "term_resize")) {
        const cols: u16 = @intCast(std.math.clamp(argInt(args, "cols") orelse 120, 10, 500));
        const rows: u16 = @intCast(std.math.clamp(argInt(args, "rows") orelse 40, 4, 300));
        t.resize(cols, rows) catch return appErr(arena, "resize failed (terminal exited?)");
        _ = t.waitIdle(200, 2_000);
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "term_close")) {
        const id = termIdOf(t);
        _ = term_state.terms.swapRemove(id);
        t.deinit();
        return toolResult(arena, "terminal closed", false) orelse error.OutOfMemory;
    }
    return appErr(arena, "unknown tool");
}

fn callTool(arena: std.mem.Allocator, backend: Backend, name: []const u8, args: std.json.Value) ![]const u8 {
    const eql = std.mem.eql;

    if (eql(u8, name, "launch_app") or eql(u8, name, "list_apps") or eql(u8, name, "close_app") or
        eql(u8, name, "close_app_window") or eql(u8, name, "screenshot_app") or
        eql(u8, name, "get_app_state") or
        eql(u8, name, "list_installed_apps") or std.mem.startsWith(u8, name, "app_"))
    {
        return appTool(arena, name, args);
    }
    if (std.mem.startsWith(u8, name, "term_")) {
        return termTool(arena, name, args);
    }

    const pane = paneFromArgs(args);

    if (eql(u8, name, "list_terminals")) {
        const resp = try ipc(arena, backend, .{ .cmd = "list" });
        return toolResult(arena, resp, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "screenshot_pane")) {
        // The GUI renders the PNG to a temp file (IPC is line-JSON),
        // then we read it back and return it as an inline image.
        const path_z = std.fmt.allocPrint(arena, "/tmp/sketerm-shot-{d}-{d}.png\x00", .{ c.getpid(), backend.nowMs(backend.ctx) }) catch return error.OutOfMemory;
        const path = path_z[0 .. path_z.len - 1];
        const reply = try ipcParsed(arena, backend, .{ .cmd = "screenshot", .pane = pane, .data = path });
        if (!reply.ok) return toolResult(arena, reply.err, true) orelse error.OutOfMemory;
        const f = c.fopen(path_z.ptr, "rb") orelse return appErr(arena, "screenshot file vanished");
        defer _ = c.fclose(f);
        _ = c.fseek(f, 0, c.SEEK_END);
        const len: usize = @intCast(@max(0, c.ftell(f)));
        _ = c.fseek(f, 0, c.SEEK_SET);
        const buf = arena.alloc(u8, len) catch return error.OutOfMemory;
        const rd = c.fread(buf.ptr, 1, len, f);
        _ = c.unlink(path_z.ptr);
        if (rd != len) return appErr(arena, "short read of screenshot");
        return imageResult(arena, "terminal pane screenshot", buf) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "record_pane_start")) {
        const path = argStr(args, "path") orelse
            return toolResult(arena, "record_pane_start requires 'path' (absolute .cast output)", true) orelse error.OutOfMemory;
        const reply = try ipcParsed(arena, backend, .{ .cmd = "record-start", .pane = pane, .data = path });
        if (!reply.ok) return toolResult(arena, reply.err, true) orelse error.OutOfMemory;
        return toolResult(arena, "recording started (asciicast v2; stop with record_pane_stop)", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "record_pane_stop")) {
        const reply = try ipcParsed(arena, backend, .{ .cmd = "record-stop", .pane = pane });
        if (!reply.ok) return toolResult(arena, reply.err, true) orelse error.OutOfMemory;
        return toolResult(arena, "recording stopped", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "read_screen")) {
        if (argBool(args, "last_command")) {
            const reply = try ipcParsed(arena, backend, .{ .cmd = "get-text", .pane = pane, .last_command = true });
            if (!reply.ok) return toolResult(arena, reply.err, true) orelse error.OutOfMemory;
            const last = reply.value.object.get("last") orelse
                return toolResult(arena, "malformed reply", true) orelse error.OutOfMemory;
            const text = (if (last == .object) last.object.get("text") else null) orelse std.json.Value{ .string = "" };
            const exit = (if (last == .object) last.object.get("exit") else null) orelse std.json.Value{ .integer = 0 };
            const blob = try std.fmt.allocPrint(arena, "exit: {d}\n---\n{s}", .{
                if (exit == .integer) exit.integer else 0,
                if (text == .string) text.string else "",
            });
            return toolResult(arena, blob, false) orelse error.OutOfMemory;
        }
        const sb: u32 = if (argInt(args, "scrollback")) |s|
            (if (s > 0) @intCast(@min(s, 100_000)) else 0)
        else
            0;
        const blob = readScreenText(arena, backend, pane, sb) catch |err| switch (err) {
            error.NoSuchPane => return toolResult(arena, "no such pane", true) orelse error.OutOfMemory,
            else => return err,
        };
        return toolResult(arena, blob, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "send_text")) {
        const text = argStr(args, "text") orelse
            return toolResult(arena, "send_text requires 'text'", true) orelse error.OutOfMemory;
        const data = if (argBool(args, "enter"))
            try std.fmt.allocPrint(arena, "{s}\r", .{text})
        else
            text;
        const reply = try ipcParsed(arena, backend, .{ .cmd = "send-text", .pane = pane, .data = data });
        if (!reply.ok) return toolResult(arena, reply.err, true) orelse error.OutOfMemory;
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "send_keys")) {
        const keys = argStr(args, "keys") orelse
            return toolResult(arena, "send_keys requires 'keys'", true) orelse error.OutOfMemory;
        const reply = try ipcParsed(arena, backend, .{ .cmd = "send-keys", .pane = pane, .data = keys });
        if (!reply.ok) return toolResult(arena, reply.err, true) orelse error.OutOfMemory;
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "run_command")) {
        const command = argStr(args, "command") orelse
            return toolResult(arena, "run_command requires 'command'", true) orelse error.OutOfMemory;
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 15_000;
        const quiet_ms: i64 = argInt(args, "quiet_ms") orelse 400;
        const data = try std.fmt.allocPrint(arena, "{s}\r", .{command});
        const send = try ipcParsed(arena, backend, .{ .cmd = "send-text", .pane = pane, .data = data });
        if (!send.ok) return toolResult(arena, send.err, true) orelse error.OutOfMemory;
        const settled = waitIdle(arena, backend, pane, timeout_ms, quiet_ms) catch |err| switch (err) {
            error.NoSuchPane => return toolResult(arena, "no such pane", true) orelse error.OutOfMemory,
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
                        const blob = try std.fmt.allocPrint(arena, "{s}exit: {d}\n---\n{s}", .{
                            if (settled) "" else "[still producing output after timeout]\n",
                            if (exit == .integer) exit.integer else 0,
                            if (text == .string) text.string else "",
                        });
                        return toolResult(arena, blob, false) orelse error.OutOfMemory;
                    }
                }
            }
        }
        var blob = try readScreenText(arena, backend, pane, 0);
        if (want_output_only) {
            blob = try std.fmt.allocPrint(arena, "[output_only unavailable: no completed OSC 133 command zone — shell integration is inactive in this pane (unsupported shell, or the command emitted no marks); returning the rendered screen]\n{s}", .{blob});
        }
        if (!settled) {
            blob = try std.fmt.allocPrint(arena, "[still producing output after timeout]\n{s}", .{blob});
        }
        return toolResult(arena, blob, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "wait_idle")) {
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 15_000;
        const quiet_ms: i64 = argInt(args, "quiet_ms") orelse 400;
        const settled = waitIdle(arena, backend, pane, timeout_ms, quiet_ms) catch |err| switch (err) {
            error.NoSuchPane => return toolResult(arena, "no such pane", true) orelse error.OutOfMemory,
            else => return err,
        };
        return toolResult(arena, if (settled) "settled" else "timeout: still producing output", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "new_tab")) {
        const resp = try ipc(arena, backend, .{ .cmd = "new-tab", .cwd = argStr(args, "cwd"), .title = argStr(args, "title") });
        return toolResult(arena, resp, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "split_pane")) {
        const resp = try ipc(arena, backend, .{ .cmd = "split", .pane = pane, .direction = argStr(args, "direction") });
        return toolResult(arena, resp, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "focus_pane")) {
        if (pane == null) return toolResult(arena, "focus_pane requires 'pane'", true) orelse error.OutOfMemory;
        const reply = try ipcParsed(arena, backend, .{ .cmd = "focus", .pane = pane });
        if (!reply.ok) return toolResult(arena, reply.err, true) orelse error.OutOfMemory;
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "close_pane")) {
        if (pane == null) return toolResult(arena, "close_pane requires 'pane'", true) orelse error.OutOfMemory;
        const reply = try ipcParsed(arena, backend, .{ .cmd = "close-pane", .pane = pane });
        if (!reply.ok) return toolResult(arena, reply.err, true) orelse error.OutOfMemory;
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
    }
    return toolResult(arena, "unknown tool", true) orelse error.OutOfMemory;
}

// ── Tests ─────────────────────────────────────────────────────────

const FakeBackend = struct {
    /// Scripted responses, consumed in order; the request lines are
    /// recorded for assertions.
    responses: []const []const u8,
    requests: std.ArrayList([]u8) = .empty,
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

    fn sleepMs(ctx: *anyopaque, ms: u32) void {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        self.clock_ms += ms;
    }

    fn nowMs(ctx: *anyopaque) i64 {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        return self.clock_ms;
    }

    fn backend(self: *FakeBackend) Backend {
        return .{ .ctx = @ptrCast(self), .talk = talk, .sleepMs = sleepMs, .nowMs = nowMs };
    }

    fn deinit(self: *FakeBackend) void {
        for (self.requests.items) |r| self.allocator.free(r);
        self.requests.deinit(self.allocator);
    }
};

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
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"text\":\"ok\"") != null);
    try std.testing.expectEqual(@as(usize, 1), fake.requests.items.len);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "\"cmd\":\"send-keys\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "\"pane\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "ctrl+c enter") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, resp, "exit: 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "hi\\n") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, resp, "echo hi") != null);
    // The screen metadata rides inside the JSON text value, so its
    // quotes arrive escaped.
    try std.testing.expect(std.mem.indexOf(u8, resp, "\\\"seq\\\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "timeout") == null);
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
    // --durable alone (unnamed durable instance).
    const dur = try Opts.parse(&.{"--durable"});
    try t.expect(dur.durable and dur.name == null);
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
    try t.expectError(error.MissingValue, Opts.parse(&.{"--log"}));
    // Errors.
    try t.expectError(error.MissingValue, Opts.parse(&.{"--name"}));
    try t.expectError(error.BadName, Opts.parse(&.{ "--name", "a/b" }));
    try t.expectError(error.BadName, Opts.parse(&.{ "--name", "" }));
    try t.expectError(error.UnknownFlag, Opts.parse(&.{"--bogus"}));
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
    log.logImage("shot of app 1", "\x89PNG-fake-bytes");
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
