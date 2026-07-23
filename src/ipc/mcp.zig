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
const template = @import("../util/template.zig");
const ocr = @import("../util/ocr.zig");
const png_util = @import("../util/png.zig");
const mcpassets = @import("mcpassets.zig");
const cdp = @import("cdp.zig");
const shellquote = @import("../util/shellquote.zig");

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
    no_record: bool = false,
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
            } else if (std.mem.eql(u8, a, "--no-record")) {
                o.no_record = true;
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
    var fired: std.atomic.Value(bool) = .init(false);
    var hard_ms: i64 = 150_000;

    fn begin() void {
        _ = c.pthread_mutex_lock(&mu);
        defer _ = c.pthread_mutex_unlock(&mu);
        fd_count = 0;
        for (app_state.apps.values()) |a| addFd(a.conn.fd);
        for (term_state.terms.values()) |t| addFd(t.conn.fd);
        for (forward_state.forwards.values()) |f| addFd(f.term.conn.fd);
        for (browser_state.sessions.values()) |s| {
            if (s.client.fd >= 0) addFd(s.client.fd);
        }
        fired.store(false, .release);
        started_ms = monoMs();
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

    fn loop() void {
        while (true) {
            var ts = c.struct_timespec{ .tv_sec = 1, .tv_nsec = 0 };
            _ = c.nanosleep(&ts, null);
            _ = c.pthread_mutex_lock(&mu);
            const overdue = started_ms != 0 and !fired.load(.acquire) and monoMs() - started_ms > hard_ms;
            if (overdue) {
                fired.store(true, .release);
                for (fds[0..fd_count]) |fd| _ = c.shutdown(fd, c.SHUT_RDWR);
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
    defer Journal.deinitAll();
    // Headless terminal tools run on the private daemon (isolated
    // mode only); --shared keeps the GUI-backed terminal tools.
    term_state = .{
        .allocator = allocator,
        .mux_sock = if (iso) |i| i.sock else null,
    };
    defer term_state.deinit();
    forward_state = .{ .allocator = allocator };
    defer forward_state.deinit();
    rec_state = .{ .allocator = allocator, .enabled = !opts.no_record };
    defer rec_state.deinit();
    browser_state = .{ .allocator = allocator };
    defer browser_state.deinit();
    srv_mode = if (opts.shared) "shared" else if (iso != null and iso.?.durable) "durable" else "isolated";
    srv_gui_socket = sock_path != null;

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
    browser_state.deinit();
    forward_state.deinit();
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
        const tools = renderedToolsJson(arena) catch return null;
        const result = std.fmt.allocPrint(arena, "{{\"tools\":{s}}}", .{tools}) catch return null;
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
    return imageResultTagged(arena, caption, png_bytes, "");
}

/// Like imageResult, but the --log trace file gets a "-tag" filename
/// suffix (img-<pid>-NNNN-click.png) so shot kinds sort apart.
fn imageResultTagged(arena: std.mem.Allocator, caption: []const u8, png_bytes: []const u8, tag: []const u8) ?[]const u8 {
    if (mcp_log) |*l| l.logImage(caption, png_bytes, tag);
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
    return imagesResultTagged(arena, caption, pngs, null);
}

/// Like imagesResult, with an optional per-image tag list (parallel
/// to `pngs`) for the --log trace filenames.
fn imagesResultTagged(arena: std.mem.Allocator, caption: []const u8, pngs: []const []const u8, tags: ?[]const []const u8) ?[]const u8 {
    const enc = std.base64.standard.Encoder;
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":") catch return null;
    std.json.Stringify.value(caption, .{}, w) catch return null;
    w.writeAll("}") catch return null;
    for (pngs, 0..) |p, i| {
        if (mcp_log) |*l| l.logImage(caption, p, if (tags) |ts| (if (i < ts.len) ts[i] else "") else "");
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
    @setEvalBranchQuota(300_000);
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
    \\{"name":"run_command","description":"Type a shell command, press Enter, wait until OUTPUT settles, and return the resulting screen text. Output idle does not imply that a silent foreground command exited. Pass output_only=true to get ONLY a completed OSC 133 command zone when one is already available. For reliable headless completion use term_run with wait_for=command; for interactive programs prefer send_text/send_keys + read_screen.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"},"command":{"type":"string"},"timeout_ms":{"type":"integer","description":"Max output-idle wait (default 15000)"},"quiet_ms":{"type":"integer","description":"No-output window that counts as idle (default 400)"},"output_only":{"type":"boolean","description":"Return just a completed command zone and exit code instead of the whole screen"}},"required":["command"]}},
    \\{"name":"wait_idle","description":"Wait until a pane produced no output for quiet_ms (or timeout_ms elapsed). Output idle does NOT imply that the foreground command exited.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"},"timeout_ms":{"type":"integer"},"quiet_ms":{"type":"integer"}}}},
    \\{"name":"new_tab","description":"Open a new shell tab in the GUI. Returns the new tab and pane ids. With no GUI running it falls back to opening a HEADLESS terminal and returns its term id instead (drive that one with term_* tools).","inputSchema":{"type":"object","properties":{"cwd":{"type":"string"},"title":{"type":"string"}}}},
    \\{"name":"split_pane","description":"Split a pane. direction 'h' = side by side, 'v' = stacked. Returns the new pane id.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"},"direction":{"type":"string","enum":["h","v"]}}}},
    \\{"name":"focus_pane","description":"Focus a pane (selects its tab and grabs keyboard focus).","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"}},"required":["pane"]}},
    \\{"name":"close_pane","description":"Close a pane. Destructive: the shell and any running process in it are terminated.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"}},"required":["pane"]}},
    \\{"name":"list_installed_apps","description":"List installed GUI apps on the host (name + launch command), from its .desktop entries. Pass host for a remote machine. Use before launch_app to discover what can run.","inputSchema":{"type":"object","properties":{"host":{"type":"string","description":"SSH host (user@box); omit = local"}}}},
    \\{"name":"launch_app","description":"Launch a GUI (Wayland) application HEADLESSLY: it renders into sketerm's mux daemon, never appears on any screen, and survives disconnects. Returns the app id, the child pid on the daemon's host (attach a debugger with gdb -p; with a string command the pid is the wrapping /bin/sh — pass an argv array to make it the app itself), its windows AND the first window's screenshot inline (launch-and-look in one call). If the app exits early, the reply includes exit status, terminating signal and its recent output. Drive it with get_app_state/app_click/app_type/app_key; read its stdout/stderr with app_output. TIP for apps you can rebuild: have the code print the escape \\033]5522;my-label\\033\\\\ at interesting moments — each becomes a labelled app_log line WITH a stashed screenshot of the window at that instant (see app_log), a build-it-in tracing primitive far more precise than polling screenshots.","inputSchema":{"type":"object","properties":{"command":{"description":"argv array (preferred) or a shell command string","anyOf":[{"type":"array","items":{"type":"string"}},{"type":"string"}]},"args":{"type":"array","items":{"type":"string"},"description":"Extra argv entries appended after command. With a string command, the command then runs as the bare EXECUTABLE (argv[0], NOT shell-parsed)."},"host":{"type":"string","description":"SSH host (user@box) to run on; omit = local daemon"},"cwd":{"type":"string","description":"Working directory for the app"},"env":{"type":"object","description":"Extra environment variables, e.g. {\"FOO\":\"1\"}","additionalProperties":{"type":"string"}},"wait_for":{"type":"string","enum":["window","exit"],"description":"What to wait for before replying: first window (default) or process exit (short-lived/CLI runs)"},"wait_ms":{"type":"integer","description":"Max wait (default 10000)"},"cols":{"type":"integer"},"rows":{"type":"integer"},"layout":{"type":"string","description":"Session keyboard layout: us (default), gb, fr, be, de"},"gpu":{"type":"boolean","description":"Render on the host's real GPU via linux-dmabuf instead of software GL. Needs a driver whose linear buffers allow CPU mmap."},"audio":{"type":"string","enum":["forward","none"],"description":"forward (default): PULSE_SERVER points at sketerm's per-session audio sink, which paces playback in real time (samples are discarded unless a GUI viewer is attached). none: no PULSE_SERVER, so the app falls back to its own dummy/null audio driver."},"audio_path":{"type":"string","description":"Capture the app's audio to WAV at this absolute path base ON THE DAEMON'S HOST (first stream: <base>.wav, later streams: <base>-N.wav; a trailing .wav in the base is stripped). Playback pacing is unaffected — this tees the PCM the sink consumes, so you can verify the app actually produced sound. Incompatible with audio:\"none\"."},"debug":{"type":"string","enum":["gdb","valgrind"],"description":"Run the app under a debug wrapper: gdb (batch mode — on a crash the full backtrace + registers land in app_log) or valgrind (report in app_log at exit). The reported pid is the wrapper's."},"gdb_commands":{"type":"array","items":{"type":"string"},"description":"With debug:\"gdb\" only: extra gdb commands executed AT THE CRASH POINT after the automatic bt full + info registers (e.g. [\"frame 3\",\"p *ctx\",\"x/8xw $rcx\",\"info locals\"]); their output lands in app_log with the backtrace, so one crashing run captures the state you'd otherwise relaunch for. Commands run in order and may switch frames."}},"required":["command"]}},
    \\{"name":"list_apps","description":"List launched headless apps and their windows.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"app_windows","description":"List one app's rendered windows (ids, sizes, titles).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"}}}},
    \\{"name":"screenshot_app","description":"Screenshot a headless app window as a lossless PNG (inline image). Optional region crop and integer zoom for pixel-level inspection; downscaled when larger than max_px. The caption tells you how to map image coordinates back to app_click coordinates. wait_change=true blocks until the window renders something NEWER than your last screenshot (verify a click did something); stable_ms waits until repainting stops before capturing (settle-then-capture — combine both to catch 'changed, then went quiet'). stats_only=true skips the image and just reports whether/how much the window changed since your last look (cheap polling). burst=N captures up to N frames over burst_ms, each at least min_change_pct different from the previous — one call across an animated transition.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer","description":"Window id (omit = the PRIMARY toplevel: the most recently painted non-popup window)"},"max_px":{"type":"integer","description":"Bound on the longest image dimension (default 1568, 0 = full size)"},"region":{"type":"object","description":"Crop to a sub-rectangle in surface pixels. Also SCOPES change detection: stats_only's diff_pct is measured inside this rect only, and with min_change_pct set, wait_change/stable_ms/burst gate on changes inside it — assert 'did THIS area change' without eyeballing images","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}},"zoom":{"type":"integer","description":"Nearest-neighbor integer upscale (1-32) — crop a small region and zoom to inspect pixels"},"wait_change":{"type":"boolean","description":"Wait until the window content changed since the last screenshot before capturing. Combine with min_change_pct to ignore trivial repaints (a software cursor)."},"stable_ms":{"type":"integer","description":"Capture only after the window committed no new frame for this long (settle-then-capture). With min_change_pct set, frames changing less than that %% don't reset the timer (VISUAL settle — works on continuously-animating apps)."},"stats_only":{"type":"boolean","description":"Return {changed, diff_pct, resized, w, h, frames} instead of an image"},"burst":{"type":"integer","description":"Capture up to N distinct frames (2-8) over burst_ms"},"burst_ms":{"type":"integer","description":"Burst time window (default 5000)"},"min_change_pct":{"type":"number","description":"Pixel-change threshold (%%): burst frames must differ this much from the previous one (default 1.0), and when set it also gates wait_change and turns stable_ms into a visual settle (default 0 = any repaint counts)"},"timeout_ms":{"type":"integer","description":"Bound for wait_change/stable_ms (default 10000)"}}}},
    \\{"name":"get_app_state","description":"One-call app observation: window list + screenshot of one window (inline PNG) with coordinate mapping. Prefer this over separate app_windows + screenshot_app. If the app exited, reports exit status, signal and recent output instead. Accepts the same region/zoom/wait_change/stable_ms/stats_only/burst options as screenshot_app.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer","description":"Window id (omit = the PRIMARY toplevel: the most recently painted non-popup window)"},"max_px":{"type":"integer"},"region":{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}},"zoom":{"type":"integer"},"wait_change":{"type":"boolean"},"stable_ms":{"type":"integer"},"stats_only":{"type":"boolean"},"burst":{"type":"integer"},"burst_ms":{"type":"integer"},"min_change_pct":{"type":"number"},"timeout_ms":{"type":"integer"}}}},
    \\{"name":"app_output","description":"Read a headless app's stdout/stderr (its PTY output as RENDERED BY A TERMINAL — a fixed-width grid, so long lines wrap and scrolled-off content needs scrollback=true; right for TUI-style redraws). For log-style output app_log is the SOURCE OF TRUTH: indexed unwrapped lines with stable ids, re-readable in full — prefer it. When the grid mirror is blank after an exit, the log ring's last lines are served instead. Also reports exit status + signal when the app has died.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"scrollback":{"type":"boolean"}}}},
    \\{"name":"app_log","description":"A headless app's stdout/stderr as an INDEXED LOG: each complete line gets a stable numeric id and a timestamp; the tail view shortens long lines (marked [+]) and any line can be re-read in full by id. The ring is bounded (oldest lines drop; the reply says how many). MARKERS: the app (or your injected code) can emit the escape  printf '\\033]5522;my-label\\033\\\\'  — it becomes a labelled log line AND sketerm stashes a screenshot of the app window at that exact instant; fetch label+image with {\"id\":<that line's id>}. Variant printf '\\033]5522;+N;my-label\\033\\\\' captures the Nth FUTURE frame commit instead (e.g. +1 = the next repaint after this point; resolved with the final frame if the app exits first). Markers are rate-limited (burst 8, then 2/s; excess are dropped and counted) so escape-laden files cat'ed to the terminal cannot flood the log. Survives app exit: the final log is delivered with the exit. Reliable on frame-flooding apps: a reply delayed behind streamed frame data is refetched over a FRESH daemon connection automatically; failing that, the last cached snapshot is served with a [STALE] banner, then the PTY grid mirror (no line ids) — an error only when nothing at all is reachable.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"tail":{"type":"integer","description":"Last N lines (default 60, max 500)"},"from_id":{"type":"integer","description":"Return lines starting at this id instead of the tail"},"id":{"type":"integer","description":"Return ONE line in full; for a marker line also returns the stashed screenshot"}}}},
    \\{"name":"app_click","description":"Click inside an app window at surface-local pixel coordinates (from screenshot_app; apply the caption's multiplier if the image was downscaled). To target a widget by name/role instead, prefer app_perform_action (coordinate-free, more reliable). button: 1 left (default), 2 middle, 3 right. By DEFAULT the reply is a post-click screenshot with a crosshair at the exact click pixel — where the click landed AND what it did, in one image (mark:false for a plain text reply; screenshot=true for the frame without the marker). HOLD/REPEAT/RETRY: the button stays DOWN for hold_ms between press and release (human-like — an instantaneous click can be collapsed into one sample by apps that poll input edges per tick, and a LONG hold exercises press-and-hold repeat widgets); count:2 sends a real double-click (two separate app_click calls are always too far apart to register as one); retry re-clicks when no qualifying repaint arrives in time, for apps whose buttons genuinely need a second press. CLICK-AND-SETTLE: the capture waits (bounded) for a frame committed AFTER the click, then a short settle (settle_ms) so mid-repaint frames aren't captured; the caption states 'repainted Nms after the input' or 'NO repaint within Nms'. HONESTY LIMITS: on a continuously-animating app (blinking LEDs, a game) ANY commit counts as a repaint — set min_change_pct (1-2) there or the dead/live distinction is meaningless; and 'NO repaint within Nms' is not proof of a dead click on an app that reacts with multi-second latency — retry with a larger timeout_ms before concluding. If the app EXITS during the post-click wait (the click triggered a crash/quit), the reply says so explicitly with the signal and exit summary instead of a failed-screenshot message.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"x":{"type":"integer"},"y":{"type":"integer"},"button":{"type":"integer"},"hold_ms":{"type":"integer","description":"How long the button stays down between press and release, ms (%HOLD_DEF%; max 10000). Long values drive press-and-hold repeat controls."},"count":{"type":"integer","description":"Clicks in quick succession, ~80ms apart: 2 = double-click, 3 = triple (default 1)"},"retry":{"type":"integer","description":"If no qualifying repaint arrives within timeout_ms, click again, up to this many EXTRA attempts (%RETRY_DEF%; max 5). Pair with min_change_pct on animating apps, or the first attempt always looks alive."},"mark":{"type":"boolean","description":"Crosshair-marked post-click screenshot (DEFAULT true; false = no image unless screenshot is set)"},"screenshot":{"type":"boolean","description":"Return the post-click frame without the marker"},"wait_change":{"type":"boolean","description":"Wait for a post-click frame commit before returning (defaults ON when an image is returned; false = capture immediately)"},"settle_ms":{"type":"integer","description":"After the first post-click frame, wait until repainting pauses this long before capturing (%SETTLE_DEF%; 0 = capture the first frame)"},"min_change_pct":{"type":"number","description":"Only frames changing at least this % of pixels count as change — REQUIRED for a meaningful dead/live verdict on continuously-animating apps. Deliberately per-call only (never an env default): it decides the VERDICT, not a timing bound."},"region":{"type":"object","description":"Scope min_change_pct's pixel diffing to this rect (surface pixels) — assert that THIS area (a viewport, a status bar) repainted, ignoring changes elsewhere","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}},"timeout_ms":{"type":"integer","description":"Bound for the post-click wait (%TIMEOUT_DEF%; raised to at least 5000 when wait_change/settle_ms is explicit)"},"max_px":{"type":"integer","description":"Bound on the screenshot's longest dimension (default 1568)"}},"required":["window","x","y"]}},
    \\{"name":"app_actions","description":"Execute an ORDERED batch of interaction steps against one app in a single call — collapses click/wait/screenshot round-trips (driving menus, games, wizards). 'actions' is an array of step objects, each holding exactly one of: {\"move\":[x,y]} | {\"move_rel\":[dx,dy]} (relative pointer, see app_mouse_move) | {\"click\":[x,y]} (optional \"hold_ms\" and \"count\":2 for double-click, as in app_click) | {\"drag\":[x1,y1,x2,y2]} | {\"key\":\"space-separated chords\"} (optional \"hold_ms\" per chord, as in app_key) | {\"type\":\"text\"} | {\"scroll\":[dx,dy]} (optional \"at\":[x,y]) | {\"wait\":ms} (MILLISECONDS, max 30000) | {\"wait_idle\":{\"quiet_ms\":400,\"timeout_ms\":10000,\"change_pct\":2}} (with change_pct = VISUAL settle: blocks until frames change less than that %% — use for scene transitions of unknown duration instead of guessing a fixed wait) | {\"wait_change\":timeout_ms or {\"timeout_ms\":N,\"min_change_pct\":P}} (P = ignore repaints below that %% of pixels; wait_idle/wait_change steps also take \"region\":{x,y,w,h} to scope the %% to that rect; add \"required\":true to a wait_idle/wait_change step to make a timeout FAIL the batch instead of continuing — a timeout is then structurally distinct from success) | {\"screenshot\":true or {\"max_px\":N}} | {\"wait_image\":{\"template\":name,\"timeout_ms\":N,\"click\":true}} (wait for a saved template to appear, optionally click its center) | {\"click_image\":{\"template\":name}} (find + click NOW, error if absent) | {\"wait_text\":{\"text\":s,\"click\":true}} (OCR-wait for a string, optionally click it) — these three make batches STATE-driven instead of coordinate/timing-driven. MARKERS: add \"mark\":true to a click/move/move_rel/drag/scroll step to draw a labelled crosshair at that step's position (red = click, cyan = move; the number is the step index) onto the NEXT screenshot — several marked steps can share one image. Combine in one step: {\"click\":[x,y],\"mark\":true,\"screenshot\":true} captures the post-click frame with the click point marked. Leftover marks with no later screenshot are flushed as a final image automatically. Optional per-step \"window\" and \"button\" (click/drag). Steps run in order server-side; execution stops with a per-step report when one fails or the app exits. Returns per-step results plus every screenshot taken (max 8) as inline images.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer","description":"Default window for all steps"},"actions":{"type":"array","items":{"type":"object"}}},"required":["actions"]}},
    \\{"name":"app_mouse_move","description":"Move the pointer in an app window WITHOUT clicking. Absolute: x,y in surface pixels (hover a widget, position before a click; NOTE: a pointer-LOCKED app suppresses absolute motion and only sees deltas — use dx/dy there). Relative: dx,dy — a delta from the current pointer position, for apps that consume RELATIVE mouse motion (SDL games, DOSBox, anything with pointer-lock): sketerm derives relative_motion events from the move, so the app's own cursor moves by exactly your delta. Calibration for such apps: one large negative move (e.g. dx:-30000, dy:-30000) slams their internal cursor to the top-left corner, after which exact deltas land where you aim. With neither x/y nor dx/dy it just returns the tracked pointer position.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer","description":"Window id (omit = window under the pointer, else first toplevel)"},"x":{"type":"number","description":"Absolute surface x (with y)"},"y":{"type":"number"},"dx":{"type":"number","description":"Relative delta x (with dy; exclusive with x/y)"},"dy":{"type":"number"}}}},
    \\{"name":"app_perform_action","description":"Invoke a widget's default AT-SPI action (press/activate/toggle) directly by element id — the reliable coordinate-free way to 'click' a button, menu item or checkbox. 'element' is an id from app_a11y_tree. Works for GTK/Qt apps that publish accessibility.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"element":{"type":"string"},"index":{"type":"integer","description":"Action index (default 0 = the default action)"}},"required":["element"]}},
    \\{"name":"app_set_value","description":"Write a value straight into a widget via AT-SPI: 'text' replaces a text field's content (EditableText), 'value' sets a slider/spinner (Value). Faster and more reliable than typing.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"element":{"type":"string"},"text":{"type":"string"},"value":{"type":"number"}},"required":["element"]}},
    \\{"name":"app_wait_for_element","description":"Wait until a widget appears in the app's accessibility tree (dialog opened, page loaded, ...). Match by role number and/or case-insensitive name substring; returns the matched node with its id and rect.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"role":{"type":"integer","description":"AT-SPI role number (e.g. 42 push-button)"},"name":{"type":"string","description":"Name substring, case-insensitive"},"timeout_ms":{"type":"integer","description":"Default 10000"}}}},
    \\{"name":"app_drag","description":"Press-move-release drag inside an app window (sliders, drag-and-drop, text selection). Surface-local pixel coordinates. screenshot=true returns the post-drag frame, captured only after the window repaints (wait_change/settle_ms/timeout_ms as in app_click).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"x1":{"type":"integer"},"y1":{"type":"integer"},"x2":{"type":"integer"},"y2":{"type":"integer"},"button":{"type":"integer"},"screenshot":{"type":"boolean"},"wait_change":{"type":"boolean"},"settle_ms":{"type":"integer"},"min_change_pct":{"type":"number"},"region":{"type":"object","description":"Scope min_change_pct's pixel diffing to this rect (surface pixels) — assert that THIS area repainted, ignoring changes elsewhere","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}},"timeout_ms":{"type":"integer"},"max_px":{"type":"integer"}},"required":["window","x1","y1","x2","y2"]}},
    \\{"name":"app_type","description":"Type literal text into an app window. Non-ASCII text is delivered via a clipboard paste (Ctrl+V) automatically. screenshot=true returns the post-typing frame, captured only after the window repaints (wait_change/settle_ms/timeout_ms as in app_click).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"text":{"type":"string"},"screenshot":{"type":"boolean"},"wait_change":{"type":"boolean"},"settle_ms":{"type":"integer"},"min_change_pct":{"type":"number"},"region":{"type":"object","description":"Scope min_change_pct's pixel diffing to this rect (surface pixels) — assert that THIS area repainted, ignoring changes elsewhere","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}},"timeout_ms":{"type":"integer"},"max_px":{"type":"integer"}},"required":["text"]}},
    \\{"name":"app_clipboard_get","description":"Read what the app last copied to the clipboard (requires the app to have copied something).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"timeout_ms":{"type":"integer"}}}},
    \\{"name":"app_clipboard_set","description":"Offer text to the app as the host clipboard. Set paste=true to immediately press Ctrl+V in a window.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"text":{"type":"string"},"paste":{"type":"boolean"},"window":{"type":"integer"}},"required":["text"]}},
    \\{"name":"app_key","description":"Press key chords in an app window: space-separated, e.g. 'ctrl+s', 'enter', 'alt+F4', 'down down enter'. hold_ms keeps each chord's key DOWN that long before releasing — the app's own key-repeat fires during the hold (hold-to-scroll, hold-to-increment). screenshot=true returns the post-keypress frame, captured only after the window repaints (wait_change/settle_ms/timeout_ms as in app_click).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"keys":{"type":"string"},"hold_ms":{"type":"integer","description":"Hold each chord's key down this long before releasing, ms (default 0 = tap; max 10000)"},"screenshot":{"type":"boolean"},"wait_change":{"type":"boolean"},"settle_ms":{"type":"integer"},"min_change_pct":{"type":"number"},"region":{"type":"object","description":"Scope min_change_pct's pixel diffing to this rect (surface pixels) — assert that THIS area repainted, ignoring changes elsewhere","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}},"timeout_ms":{"type":"integer"},"max_px":{"type":"integer"}},"required":["keys"]}},
    \\{"name":"app_scroll","description":"Scroll inside an app window. dy>0 scrolls down, dx>0 right (wheel steps). screenshot=true returns the post-scroll frame, captured only after the window repaints (wait_change/settle_ms/timeout_ms as in app_click).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"x":{"type":"integer"},"y":{"type":"integer"},"dx":{"type":"integer"},"dy":{"type":"integer"},"screenshot":{"type":"boolean"},"wait_change":{"type":"boolean"},"settle_ms":{"type":"integer"},"min_change_pct":{"type":"number"},"region":{"type":"object","description":"Scope min_change_pct's pixel diffing to this rect (surface pixels) — assert that THIS area repainted, ignoring changes elsewhere","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}},"timeout_ms":{"type":"integer"},"max_px":{"type":"integer"}},"required":["window"]}},
    \\{"name":"app_resize","description":"Ask an app window to redraw at a new size (deterministic screenshots).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}},"required":["window","w","h"]}},
    \\{"name":"app_wait","description":"Wait until an app stopped producing new frames for quiet_ms (render quiescence), or — pass change_pct — until each new frame changes less than that percentage of pixels for quiet_ms (VISUAL quiescence: use this for games and other continuously-animating apps, which never stop committing frames but do reach a visually stable screen). Reports which outcome happened and returns the window list.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer","description":"Window for change_pct pixel diffing (omit = the PRIMARY toplevel: the most recently painted non-popup window)"},"quiet_ms":{"type":"integer"},"timeout_ms":{"type":"integer"},"change_pct":{"type":"number","description":"Settle when frames change less than this %% of pixels (e.g. 2). Omit = strict no-new-frames quiescence"},"region":{"type":"object","description":"Scope change_pct's pixel diffing to this rect (surface pixels)","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}}}}},
    \\{"name":"app_a11y_tree","description":"Read the app's accessibility (AT-SPI) tree as JSON: every widget's role, name, description, states and screen rectangle. Target elements by name/role instead of pixel-hunting a screenshot. Works for GTK/Qt apps; empty for apps without accessibility (games, some Electron).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"timeout_ms":{"type":"integer"}}}},
    \\{"name":"app_record_start","description":"Start recording a window's frames (a visual log of what you do). Default format is WebM/VP9 (smaller, higher quality); pass format:\"gif\" for an animated GIF. Frames are captured while other app tools run; finish with app_record_stop.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"format":{"type":"string","enum":["webm","gif"],"description":"Default webm"},"max_px":{"type":"integer","description":"Bound on the longest dimension (default 1280 webm / 800 gif)"},"fps":{"type":"integer","description":"Cap the capture rate (frames/second, 1-60; default = every committed frame)"}}}},
    \\{"name":"app_record_stop","description":"Stop the recording and save it (WebM or GIF per app_record_start). Returns the file path and frame count.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"path":{"type":"string","description":"Output path (extension set automatically if omitted)"}}}},
    \\{"name":"app_read_text","description":"OCR: read the TEXT rendered in an app window (or a region of it) — for custom-drawn UIs and games with no accessibility tree, this turns pixels into assertable strings. Returns the recognized text plus per-word boxes in surface coordinates with click centers (cx,cy) — read a label, then app_click its cx/cy. Needs tesseract installed on the machine running the MCP server (loaded at runtime; install tesseract + tesseract-data-eng). Crop with region for speed and accuracy; small pixel fonts are auto-upscaled (override with scale).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer","description":"Window id (omit = the PRIMARY toplevel)"},"region":{"type":"object","description":"Read only this sub-rectangle (surface pixels)","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}},"scale":{"type":"integer","description":"Integer pre-upscale for tiny bitmap fonts (1-8; 0/omit = auto)"},"psm":{"type":"integer","description":"Tesseract page segmentation: 6 uniform text block (default, dialogs), 11 sparse scattered labels, 7 single line, 3 full auto"},"lang":{"type":"string","description":"Language code(s), default eng (e.g. \"eng+deu\")"}}}},
    \\{"name":"app_wait_text","description":"Wait until a text string becomes visible in an app window (OCR-polled, case-insensitive substring) — assert 'the dialog opened' / 'the menu lists Repairs' without eyeballing screenshots. click=true also clicks the matched words' center (coordinate-free clicking by label for apps without an a11y tree). Returns the match box; on timeout returns the last text read so you see what WAS on screen.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"text":{"type":"string"},"region":{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}},"timeout_ms":{"type":"integer","description":"Default 15000"},"click":{"type":"boolean","description":"Click the matched text's center once found"},"scale":{"type":"integer"},"psm":{"type":"integer"},"lang":{"type":"string"}},"required":["text"]}},
    \\{"name":"app_template_save","description":"Save a named image template for visual matching: crop a distinctive UI element (a button, sprite, dialog frame) out of an app window via region, or pass image_b64 (PNG). Stored persistently ($XDG_STATE_HOME/sketerm/templates), shared across sessions. Transparent template pixels are ignored during matching (non-rectangular sprites). Use with app_find_image/app_wait_image and the wait_image/click_image action steps.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"app":{"type":"integer"},"window":{"type":"integer"},"region":{"type":"object","description":"Crop rectangle in surface pixels (required when capturing from a window)","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}},"required":["w","h"]},"image_b64":{"type":"string","description":"Inline PNG instead of capturing from a window"}},"required":["name"]}},
    \\{"name":"app_templates","description":"List saved image templates (name + dimensions), or delete one.","inputSchema":{"type":"object","properties":{"delete":{"type":"string","description":"Template name to delete"}}}},
    \\{"name":"app_find_image","description":"Find a saved template (or inline PNG) in an app window RIGHT NOW by pixel matching — 'is the conversation frame on screen, and where?'. Returns non-overlapping matches best-first with surface coordinates and click centers (cx,cy). min_score is 0..1 similarity (default 0.9; exact sprites score ~1.0).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"template":{"type":"string","description":"A saved template name"},"image_b64":{"type":"string","description":"Inline PNG instead of a saved template"},"region":{"type":"object","description":"Search only this sub-rectangle","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}},"min_score":{"type":"number"},"max_matches":{"type":"integer"}}}},
    \\{"name":"app_wait_image","description":"Wait until a template appears in an app window (pixel matching, polled), then optionally click its center (click=true) — the coordinate-free 'wait for this sprite, then click it' primitive for apps without an accessibility tree. Returns the match position and score.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"template":{"type":"string"},"image_b64":{"type":"string"},"region":{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}},"min_score":{"type":"number"},"timeout_ms":{"type":"integer","description":"Default 10000"},"click":{"type":"boolean"},"button":{"type":"integer"}}}},
    \\{"name":"app_macro_save","description":"Save a named, replayable input macro. Two sources: (a) the automatic per-app input JOURNAL — every successful app_click/app_key/app_type/app_scroll/app_drag/app_mouse_move and app_actions step is recorded; last_steps:N saves the journal tail with think-time gaps preserved as waits ('record what I just did'); (b) an explicit 'actions' array (app_actions vocabulary, incl. wait_image/click_image/wait_text — robust coordinate-free macros). Persisted in $XDG_STATE_HOME/sketerm/macros, shared across sessions. Inspect the journal with app_macros journal:true.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"app":{"type":"integer","description":"Journal source app (omit with explicit actions)"},"last_steps":{"type":"integer","description":"Save only the last N journal steps"},"actions":{"type":"array","items":{"type":"object"},"description":"Explicit step list instead of the journal"}},"required":["name"]}},
    \\{"name":"app_macro_run","description":"Replay a saved macro against an app: runs its steps through the app_actions engine (deterministic order, per-step report, stops on failure/exit; wait_image/wait_text steps make the replay state-driven rather than timing-driven). Reach a deep app state in one call, then vary the next step by hand.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"name":{"type":"string"},"window":{"type":"integer","description":"Default window for all steps"}},"required":["name"]}},
    \\{"name":"app_macros","description":"List saved macros; show one's steps (show); delete one (delete); or view an app's recorded input journal (journal:true + app) to pick last_steps for app_macro_save.","inputSchema":{"type":"object","properties":{"delete":{"type":"string"},"show":{"type":"string"},"journal":{"type":"boolean"},"app":{"type":"integer"}}}},
    \\{"name":"close_app_window","description":"Ask the app to close one window (like the titlebar button; the app decides).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"}},"required":["window"]}},
    \\{"name":"close_app","description":"Kill a headless app session outright. Destructive.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"}}}},
    \\{"name":"term_open","description":"Open a HEADLESS shell terminal on the private mux daemon (isolated mode) — a real PTY with no GUI, nothing of the user's reachable. Returns a term id. Drive with term_run/term_send_text/term_read. Pass 'host' for a PERSISTENT SSH session (keepalives preconfigured, survives long provisioning waits): run remote commands in it with term_exec for structured output + exit status. Every headless terminal is AUTO-RECORDED as an asciicast v2 .cast file (the reply names the path; replay later with asciinema play).","inputSchema":{"type":"object","properties":{"command":{"description":"argv array or shell string to run instead of the login shell (optional; with 'host' a string is the remote command)","anyOf":[{"type":"array","items":{"type":"string"}},{"type":"string"}]},"host":{"type":"string","description":"SSH destination (user@box): opens ssh -tt with ServerAlive keepalives. Auth prompts appear on the screen — answer with term_send_text."},"cols":{"type":"integer"},"rows":{"type":"integer"}}}},
    \\{"name":"term_list","description":"List open headless terminals: exit state + real exit_status, pending command/exec trackers, the last rendered screen line (drained first, so a finished process never shows a stale progress frame), and each terminal's asciicast recording path.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"term_run","description":"Run a command line in a headless terminal. wait_for=idle (default, backward compatible) returns after OUTPUT quiescence and does not imply child exit. wait_for=command waits for an OSC 133 command boundary (or tracked shell exit), returns structured running/completed state, exact exit_status, timed_out, and completion_source, and refuses to send (command_sent=false) when shell integration is unavailable or a foreground command started outside command mode is still running. If it times out, use term_wait_command to continue waiting without resending. output_only selects the completed command zone instead of the rendered screen.","inputSchema":{"type":"object","properties":{"term":{"type":"integer"},"command":{"type":"string"},"wait_for":{"type":"string","enum":["idle","command"],"description":"idle (default) waits for output quiescence; command waits for actual shell-command completion"},"quiet_ms":{"type":"integer","description":"Idle mode only: no-output window (default 400)"},"timeout_ms":{"type":"integer","description":"Default 30000"},"output_only":{"type":"boolean","description":"Return just the command's output instead of the whole screen"}},"required":["command"]}},
    \\{"name":"term_send_text","description":"Write text to a headless terminal's PTY. 'enter' appends a carriage return.","inputSchema":{"type":"object","properties":{"term":{"type":"integer"},"text":{"type":"string"},"enter":{"type":"boolean"}},"required":["text"]}},
    \\{"name":"term_send_keys","description":"Press named key chords in a headless terminal: 'ctrl+c', 'enter', 'up', 'tab', space-separated.","inputSchema":{"type":"object","properties":{"term":{"type":"integer"},"keys":{"type":"string"}},"required":["keys"]}},
    \\{"name":"term_read","description":"Read a headless terminal's rendered screen text. 'scrollback' true dumps the scrollback too.","inputSchema":{"type":"object","properties":{"term":{"type":"integer"},"scrollback":{"type":"boolean"}}}},
    \\{"name":"term_wait_idle","description":"Wait until a headless terminal's output stops changing (or timeout). Output idle does NOT imply that the foreground command exited.","inputSchema":{"type":"object","properties":{"term":{"type":"integer"},"quiet_ms":{"type":"integer"},"timeout_ms":{"type":"integer"}}}},
    \\{"name":"term_wait_command","description":"Continue waiting for a term_run wait_for=command request that timed out. Returns structured running/completed state, exact exit_status, timed_out, and completion_source without resending the command.","inputSchema":{"type":"object","properties":{"term":{"type":"integer"},"timeout_ms":{"type":"integer","description":"Default 30000"},"output_only":{"type":"boolean","description":"Return just the completed command's output instead of the whole screen"}}}},
    \\{"name":"term_resize","description":"Resize a headless terminal's grid.","inputSchema":{"type":"object","properties":{"term":{"type":"integer"},"cols":{"type":"integer"},"rows":{"type":"integer"}}}},
    \\{"name":"term_close","description":"Close a headless terminal (kills its shell). Destructive.","inputSchema":{"type":"object","properties":{"term":{"type":"integer"}}}},
    \\{"name":"term_exec","description":"Run one command inside a LIVE interactive shell (including a persistent SSH session from term_open host) and get STRUCTURED results: exact exit_status and the exact output between sentinel markers, independent of shell integration. By default the command runs ISOLATED in a fresh `sh` (works typed into any shell dialect — fish/zsh/bash, local or remote — and cd/export/set -e cannot leak into or kill the session; the feedback scenario 'set -e + failing probe closed my SSH connection' cannot happen). Pass subshell=false to run IN the session shell so state persists (cd/export) — that mode needs a POSIX-ish shell (bash/zsh/dash, not fish). A command that does not complete comes back with pending:true, its tracker id, the LIVE RENDERED SCREEN, alt_screen, output_idle_ms and interactive_prompt — and when the output goes quiet behind something that looks like a question (apt's [Y/n], a password ask, a needrestart dialog) the call returns EARLY with interactive_prompt:true instead of burning the timeout: answer via term_send_text/term_send_keys, then term_exec_wait picks up the completion. The tracker survives client-side timeouts and aborted tool calls — term_exec_wait always reattaches; never resend. Not for fully interactive programs (editors, REPLs) — use term_send_text/term_send_keys for those.","inputSchema":{"type":"object","properties":{"term":{"type":"integer"},"command":{"type":"string"},"subshell":{"type":"boolean","description":"Default true (isolated, dialect-independent). false = run in the session shell itself: state persists, POSIX shells only"},"noninteractive":{"type":"boolean","description":"Export DEBIAN_FRONTEND=noninteractive + debconf/needrestart/apt-listchanges equivalents for THIS command only (package-manager runs that must not prompt). Needs the default isolated transport."},"output_file":{"type":"string","description":"Write the FULL untruncated output to this absolute LOCAL path; the inline reply keeps a short tail (large diagnostic dumps)"},"timeout_ms":{"type":"integer","description":"Default 30000, clamped to 120000 — for longer commands keep calling term_exec_wait"},"shell":{"type":"string","description":"Interpreter for the command file (e.g. bash for pipefail/array semantics; default sh). Needs the default isolated transport. The command travels inside a temp script, never on a process command line (ps/pgrep stay clean)"}},"required":["command"]}},
    \\{"name":"term_exec_wait","description":"Continue waiting for a pending term_exec without resending — always attachable, including after a client-side tool timeout or abort. Same structured reply as term_exec (pending replies carry the live screen, interactive_prompt and the tracker id; returns early when the command is visibly waiting for input).","inputSchema":{"type":"object","properties":{"term":{"type":"integer"},"timeout_ms":{"type":"integer","description":"Default 30000, clamped to 120000"},"output_file":{"type":"string","description":"Write the full output to this absolute local path on completion"}}}},
    \\{"name":"term_wait_exit","description":"Wait until a headless terminal's child PROCESS exits (distinct from output idleness — a silent scp can be running while output is idle, and an exited one can leave a stale progress frame). Returns the real exit status and the final screen tail.","inputSchema":{"type":"object","properties":{"term":{"type":"integer"},"timeout_ms":{"type":"integer","description":"Default 30000"}}}},
    \\{"name":"upload_file","description":"Copy a LOCAL file to a host with integrity + atomicity built in: scp to a staged temp file, remote SHA-256 verify against the local hash, then an atomic mv into place (a corrupt transfer is discarded, never half-written). The staged name PRESERVES the extension (x.service → x.sketerm-part.service) so suffix-sensitive validators accept it, and 'verify_command' runs a remote check against the staged file BEFORE the move ({} = the staged path, appended if absent; nonzero exit = upload discarded, destination untouched — e.g. \"systemd-analyze verify {}\"). Omit 'host' for a checksummed atomic local copy. Requires key/agent SSH auth (BatchMode).","inputSchema":{"type":"object","properties":{"host":{"type":"string","description":"SSH destination (user@box); omit = local copy"},"local_path":{"type":"string"},"remote_path":{"type":"string","description":"Destination path (on the host, or locally when host is omitted)"},"verify_command":{"type":"string","description":"Remote validation run against the staged file before the atomic move; {} substitutes the staged path"},"timeout_ms":{"type":"integer","description":"scp budget, default 120000"}},"required":["local_path","remote_path"]}},
    \\{"name":"download_file","description":"Copy a remote file here with integrity + atomicity: scp to <local>.sketerm-part, SHA-256 compare against the remote hash, atomic rename into place. Omit 'host' for a local copy.","inputSchema":{"type":"object","properties":{"host":{"type":"string"},"remote_path":{"type":"string","description":"Source path on the host"},"local_path":{"type":"string","description":"Destination path here"},"timeout_ms":{"type":"integer","description":"Default 120000"}},"required":["local_path","remote_path"]}},
    \\{"name":"port_forward_open","description":"Open a STRUCTURED SSH port forward (ssh -N -L with keepalives + ExitOnForwardFailure): picks a free local port when none is given, verifies the listener actually accepts before replying, and returns a forward id. Health-check/reconnect with port_forward_check. Requires key/agent auth (BatchMode).","inputSchema":{"type":"object","properties":{"host":{"type":"string","description":"SSH destination (user@box)"},"remote_port":{"type":"integer","description":"Port on the remote side"},"remote_host":{"type":"string","description":"Remote-side connect address (default 127.0.0.1)"},"local_port":{"type":"integer","description":"Local listen port (omit = auto-pick a free one; the reply tells you which)"},"timeout_ms":{"type":"integer","description":"Readiness budget, default 20000"}},"required":["host","remote_port"]}},
    \\{"name":"port_forward_list","description":"List open port forwards with liveness and reconnect counts.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"port_forward_check","description":"Health-check one forward: verifies the ssh process AND that the local port accepts connections; if the ssh died (network blip, sshd restart) it RECONNECTS by respawning the same spec on the same local port.","inputSchema":{"type":"object","properties":{"forward":{"type":"integer"},"timeout_ms":{"type":"integer","description":"Reconnect readiness budget, default 20000"}}}},
    \\{"name":"port_forward_close","description":"Close a port forward (kills its ssh).","inputSchema":{"type":"object","properties":{"forward":{"type":"integer"}},"required":["forward"]}},
    \\{"name":"capabilities","description":"Preflight report of what THIS MCP server can do right now: isolation mode, GUI socket presence, OCR (tesseract) availability, which browser binary browser_open would use, ssh/scp presence, the directory terminal asciicast recordings land in, the EFFECTIVE input-timing defaults (hold_ms/settle_ms/timeout_ms/click_retry, each marked when a SKETERM_MCP_* env override changed it from the built-in), and open session counts. Call it before starting GUI/OCR/browser work to avoid discovering a missing dependency mid-flow.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"browser_open","description":"Launch a Chromium-family browser HEADLESSLY (Wayland, never on any screen) with DevTools (CDP) attached: you get real DOM access — browser_read (text/html/links), browser_elements, browser_click, browser_fill, browser_wait, browser_eval — plus everything an app has (screenshot via get_app_state, app_key for keyboard, app_scroll). Wayland + remote-debugging flags are applied automatically; renderer accessibility is enabled. Replies with the app id, DevTools port, page info and a first screenshot. Local daemon only.","inputSchema":{"type":"object","properties":{"url":{"type":"string","description":"Initial page (default about:blank)"},"profile":{"type":"string","description":"Named PERSISTENT profile (cookies/logins survive across sessions); omit = throwaway profile"},"browser_path":{"type":"string","description":"Specific browser binary (default: first Chromium-family binary on PATH)"},"width":{"type":"integer","description":"Window width, default 1280"},"height":{"type":"integer","description":"Window height, default 900"},"wait_ms":{"type":"integer","description":"Startup budget, default 25000"}}}},
    \\{"name":"browser_info","description":"Current URL, title, readyState, scroll position and viewport of a browser_open app — confirm soft navigations without reading the address bar pixels.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"timeout_ms":{"type":"integer"}}}},
    \\{"name":"browser_navigate","description":"Navigate a browser_open app: a URL (https:// assumed when schemeless), or \"back\"/\"forward\"/\"reload\". Waits for document readyState complete (bounded) and returns the landed URL + title.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"url":{"type":"string"},"timeout_ms":{"type":"integer","description":"Load wait, default 20000"}},"required":["url"]}},
    \\{"name":"browser_read","description":"Read the page as DATA instead of pixels: format text (rendered innerText, default), html (outerHTML) or links (anchor list with hrefs). Scope with a CSS 'selector'. The reply is prefixed with the page URL + title.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"format":{"type":"string","enum":["text","html","links"]},"selector":{"type":"string","description":"CSS selector to scope the read (omit = whole page)"},"max_chars":{"type":"integer","description":"Default 20000"},"timeout_ms":{"type":"integer"}}}},
    \\{"name":"browser_elements","description":"List VISIBLE interactive elements with their text and viewport-CSS-pixel centers — the map for browser_click/browser_fill targeting. Traverses OPEN SHADOW ROOTS (custom elements like pl-input/pl-switch are listed, including their inner control's name/value/checked state, computed role, associated label, aria-expanded/disabled and select options). Filter with 'selector' (CSS) and/or 'text' (substring of text/label/aria/placeholder).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"selector":{"type":"string"},"text":{"type":"string"},"timeout_ms":{"type":"integer"}}}},
    \\{"name":"browser_click","description":"Click a page element by CSS 'selector' and/or visible 'text' (tightest text match first; 'nth' disambiguates): scrolls it into view, then dispatches a TRUSTED click via CDP at its center. Alternatively pass explicit viewport x/y. Element lookup pierces open shadow roots. Reports what was clicked and where the page is afterwards; an unfinished load is flagged navigation_pending (never silently reported as the final page), a URL change is reported as navigated. wait_navigation=true blocks (bounded by nav_timeout_ms) until the resulting document finishes loading — use it when the click submits a long-running form.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"selector":{"type":"string"},"text":{"type":"string","description":"Visible text / label / aria / placeholder substring"},"nth":{"type":"integer","description":"Which match (0-based, default 0)"},"button":{"type":"integer","description":"1 left (default), 2 middle, 3 right"},"clicks":{"type":"integer","description":"1 single (default), 2 double"},"x":{"type":"number","description":"Explicit viewport CSS x (with y; skips element lookup)"},"y":{"type":"number"},"wait_navigation":{"type":"boolean","description":"After the click, wait until the document finishes loading before reporting"},"nav_timeout_ms":{"type":"integer","description":"wait_navigation budget, default 15000"},"timeout_ms":{"type":"integer"}}}},
    \\{"name":"browser_fill","description":"Fill a form field: locate by CSS 'selector' or 'text_label' (placeholder/label/aria text — matching a custom element's label finds its editable input through the OPEN SHADOW ROOT, e.g. text_label 'Email' fills the input inside <pl-input>), focus, select-all, then type the value as TRUSTED input (frameworks see real events). <select> dropdowns pick the option matching the value (custom dropdowns: use browser_choose). enter=true presses Enter after. Reads the field back for confirmation — password fields report only the character count; when a submit detached the field or started a navigation the reply says so (field_detached_after_submit / navigation_started) instead of reporting a misleading empty value.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"selector":{"type":"string"},"text_label":{"type":"string"},"value":{"type":"string"},"nth":{"type":"integer"},"enter":{"type":"boolean"},"timeout_ms":{"type":"integer"}},"required":["value"]}},
    \\{"name":"browser_wait","description":"Wait until the page reaches a state: 'selector' visible, 'text' present, a URL condition, 'gone' (selector absent/hidden), and/or 'network_idle' (no requests in flight and none for 500ms — catches slow form submissions/XHR). URL matching: url_contains (substring — beware /admin/certificates also matching /admin/certificates-request), url_exact (whole href), url_path (exact location.pathname), url_regex (JS RegExp on the href). Combine freely; ALL given conditions must hold. On timeout the reply is an ERROR that says which condition failed and where the page currently is — a timeout can never read as success.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"selector":{"type":"string"},"text":{"type":"string"},"url_contains":{"type":"string"},"url_exact":{"type":"string"},"url_path":{"type":"string","description":"Exact pathname, e.g. /admin/certificates"},"url_regex":{"type":"string"},"gone":{"type":"string","description":"CSS selector that must be absent/hidden (spinners, modals)"},"network_idle":{"type":"boolean"},"timeout_ms":{"type":"integer","description":"Default 15000"}}}},
    \\{"name":"browser_scroll","description":"DETERMINISTIC page scrolling: to \"top\"/\"bottom\", a CSS 'selector' into view (block center), an absolute 'y', or a relative 'dy' in CSS pixels — no wheel-delta guessing. Returns the resulting scroll position and document height.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"to":{"type":"string","enum":["top","bottom"]},"selector":{"type":"string"},"y":{"type":"integer"},"dy":{"type":"integer"}}}},
    \\{"name":"browser_eval","description":"Evaluate JavaScript in the page (awaits promises, returns the value as JSON). The escape hatch when the structured browser tools don't cover it.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"js":{"type":"string"},"timeout_ms":{"type":"integer","description":"Default 10000"}},"required":["js"]}},
    \\{"name":"browser_form_state","description":"One-call FORM inventory, traversing open shadow roots: every form control (native inputs/selects/textareas, ARIA-role widgets, and custom elements like pl-input/pl-select/pl-switch wrapping a shadow control) with its name, id, computed label, type/role, current value (password fields: character count only), checked state, select/listbox options with the selected one marked, disabled/required, the browser's validationMessage, the inner shadow input's name, the owning form, visibility and click center. THE tool for understanding and verifying custom-element forms — call it before and after filling instead of poking with browser_eval.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"selector":{"type":"string","description":"Scope to the first match of this CSS selector (e.g. a form or dialog); omit = whole page"},"timeout_ms":{"type":"integer"}}}},
    \\{"name":"browser_choose","description":"Pick an option in ANY dropdown-ish control by its text or value: native <select> (chosen directly with input+change events), a custom element wrapping a shadow <select>, or an ARIA combobox / open-shadow custom dropdown (pl-select) — those get a trusted click to open, a shadow-piercing poll for the appearing [role=option]/option items, and a trusted click on the matching one, then read the control back. Locate the control by CSS 'selector' or visible/label 'text'. On failure the reply lists the option texts that WERE visible.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"selector":{"type":"string"},"text":{"type":"string","description":"Control label/visible text (like browser_fill text_label)"},"value":{"type":"string","description":"Option text or value to pick (exact match first, then substring)"},"nth":{"type":"integer"},"timeout_ms":{"type":"integer","description":"Budget for the options to appear, default 8000"}},"required":["value"]}},
    \\{"name":"browser_network","description":"Structured network inspection (Playwright-style): the requests the page made — method, URL, status, resource type, mime, redirect count, failure reason (TLS/DNS/abort), in_flight state, and the request-body FIELD NAMES (values are never captured — secrets stay out of the log). Capture is on from browser_open; the log keeps the last 300 requests. Filter with 'filter' (URL substring), page with 'limit', reset with clear=true. Diagnose form submissions, redirect chains and hung XHRs without leaving the browser tool family.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"filter":{"type":"string"},"limit":{"type":"integer","description":"Max requests returned (default 30, newest kept)"},"clear":{"type":"boolean"}}}}
    \\]
;

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
const CATCHUP_MS: i64 = 2_500;

const Tuning = struct {
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
    var hold_ms: Item = .{ .name = "hold_ms", .value = 100, .built_in = 100, .env = "SKETERM_MCP_HOLD_MS", .min = 0, .max = 10_000 };
    var settle_ms: Item = .{ .name = "settle_ms", .value = 250, .built_in = 250, .env = "SKETERM_MCP_SETTLE_MS", .min = 0, .max = 30_000 };
    /// Post-input repaint wait when the wait is defaulted-on.
    var timeout_ms: Item = .{ .name = "timeout_ms", .value = 1_500, .built_in = 1_500, .env = "SKETERM_MCP_TIMEOUT_MS", .min = 100, .max = 30_000 };
    /// Extra app_click attempts when no qualifying repaint arrives.
    var click_retry: Item = .{ .name = "click_retry", .value = 0, .built_in = 0, .env = "SKETERM_MCP_CLICK_RETRY", .min = 0, .max = 5 };

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

/// TOOLS_JSON with the %..._DEF% timing tokens replaced by the
/// EFFECTIVE defaults (env overrides included), so the description
/// the assistant reads always states the value the server will use.
fn renderedToolsJson(arena: std.mem.Allocator) ![]const u8 {
    var buf: [128]u8 = undefined;
    var out: []const u8 = TOOLS_JSON;
    out = try replaceAll(arena, out, "%HOLD_DEF%", Tuning.defText(&buf, &Tuning.hold_ms));
    out = try replaceAll(arena, out, "%SETTLE_DEF%", Tuning.defText(&buf, &Tuning.settle_ms));
    out = try replaceAll(arena, out, "%TIMEOUT_DEF%", Tuning.defText(&buf, &Tuning.timeout_ms));
    out = try replaceAll(arena, out, "%RETRY_DEF%", Tuning.defText(&buf, &Tuning.click_retry));
    return out;
}

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

/// Server mode facts for the `capabilities` preflight tool.
var srv_mode: []const u8 = "isolated";
var srv_gui_socket: bool = false;

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

var rec_state: RecState = .{ .allocator = undefined };

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
    mkdirs(dir);
    var probe: [4096]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&probe, "{s}", .{dir}) catch {
        a.free(dir);
        return null;
    };
    if (c.access(dir_z.ptr, c.W_OK) != 0) {
        a.free(dir);
        return null;
    }
    rec_state.dir = dir;
    return rec_state.dir;
}

/// Start recording a REGISTERED terminal; returns the cast path (kept
/// in rec_state for term_list) or null when recording is off.
fn recordRegisteredTerm(t: *termdrive.Term, term_id: u32) ?[]const u8 {
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
fn recordAuxTerm(t: *termdrive.Term, label: []const u8) void {
    const dir = recDir() orelse return;
    const a = rec_state.allocator;
    rec_state.aux_counter += 1;
    const path = std.fmt.allocPrint(a, "{s}/aux-{d}-{s}.cast", .{ dir, rec_state.aux_counter, label }) catch return;
    defer a.free(path);
    t.startRecording(path);
}

/// One structured SSH port forward: an owned `ssh -N -L` headless
/// terminal plus its spec, so it can be health-checked and respawned.
const Forward = struct {
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

    fn removeOne(self: *ForwardState, f: *Forward) void {
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

var forward_state: ForwardState = .{ .allocator = undefined };

fn forwardFromArgs(args: std.json.Value) ?*Forward {
    if (argInt(args, "forward")) |id| {
        if (id < 0) return null;
        return forward_state.forwards.get(@intCast(id));
    }
    if (forward_state.forwards.count() == 1) return forward_state.forwards.values()[0];
    return null;
}

/// CDP session per browser app id (browser_open populates it).
const BrowserSession = struct {
    client: cdp.Client,
};

const BrowserState = struct {
    allocator: std.mem.Allocator,
    sessions: std.AutoArrayHashMapUnmanaged(u32, *BrowserSession) = .empty,

    fn remove(self: *BrowserState, app_id: u32) void {
        if (self.sessions.fetchSwapRemove(app_id)) |kv| {
            kv.value.client.deinit();
            self.allocator.destroy(kv.value);
        }
    }

    fn deinit(self: *BrowserState) void {
        for (self.sessions.values()) |s| {
            s.client.deinit();
            self.allocator.destroy(s);
        }
        self.sessions.deinit(self.allocator);
        self.sessions = .empty;
    }
};

var browser_state: BrowserState = .{ .allocator = undefined };

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

fn commandCompletionResult(
    arena: std.mem.Allocator,
    result: termdrive.CommandCompletion,
    command_sent: bool,
    output: ?[]const u8,
    output_kind: ?[]const u8,
    reason: ?[]const u8,
) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{\"state\":");
    try std.json.Stringify.value(@tagName(result.state), .{}, w);
    try w.print(",\"command_sent\":{},\"exit_status\":", .{command_sent});
    if (result.exit_status) |status| try w.print("{d}", .{status}) else try w.writeAll("null");
    try w.print(",\"timed_out\":{},\"completion_source\":", .{result.timed_out});
    try std.json.Stringify.value(@tagName(result.source), .{}, w);
    if (output_kind) |kind| {
        try w.writeAll(",\"output_kind\":");
        try std.json.Stringify.value(kind, .{}, w);
    }
    if (output) |text| {
        try w.writeAll(",\"output\":");
        try std.json.Stringify.value(text, .{}, w);
    }
    if (reason) |text| {
        try w.writeAll(",\"reason\":");
        try std.json.Stringify.value(text, .{}, w);
    }
    try w.writeAll("}");
    return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
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
        "{s}{s}window {d}: {d}x{d} (scale {d}){s}{s} — {s}{s}{s}",
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
            // Set only when drainLive timed out: the frame stream is
            // still catching up, so pixels may lag the app.
            if (app.behind or app.lagging) " [WARNING: frame stream still catching up — this capture may lag the app; retry with wait_change or stable_ms]" else "",
            browserPageSuffix(arena, app),
        },
    );
}

/// " | page: <url> — <title>" for apps with a live CDP session, so
/// every screenshot confirms soft navigation without reading the
/// address bar pixels. Empty when not a browser (or CDP is down —
/// screenshots must not stall on a wedged page).
fn browserPageSuffix(arena: std.mem.Allocator, app: *appdrive.App) []const u8 {
    const bs = browser_state.sessions.get(appIdOf(app)) orelse return "";
    if (!bs.client.connected()) return "";
    const r = bs.client.eval(arena, "location.href + '\\u0001' + document.title", 1_500) catch return "";
    const vj = r.value_json orelse return "";
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, vj, .{}) catch return "";
    if (parsed != .string) return "";
    const sep = std.mem.indexOfScalar(u8, parsed.string, 1) orelse return "";
    const url = parsed.string[0..sep];
    const title = parsed.string[sep + 1 ..];
    return std.fmt.allocPrint(arena, "\npage: {s}{s}{s}", .{ url, if (title.len > 0) " — " else "", title }) catch "";
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
        "app_click",          "app_drag",          "app_type",
        "app_key",            "app_scroll",        "app_resize",
        "app_mouse_move",     "app_clipboard_get", "app_clipboard_set",
        "app_perform_action", "app_set_value",     "app_wait_for_element",
        "app_a11y_tree",      "app_record_start",  "close_app_window",
        "app_read_text",      "app_wait_text",     "app_find_image",
        "app_wait_image",     "app_macro_run",
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
fn firstToplevelId(app: *appdrive.App) u32 {
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
fn clickTuned(app: *appdrive.App, win_id: u32, x: f64, y: f64, button: u32) appdrive.Error!void {
    return app.clickEx(win_id, x, y, button, Tuning.hold_ms.value, 1);
}

/// Click-and-settle: captured BEFORE injecting input so the post-input
/// wait can tell "the app repainted in response" from "the frame on
/// screen predates the input" — the old idle-only wait returned
/// instantly-quiet on an app that takes a moment to react, so a
/// post-click screenshot was frequently the PRE-click frame.
const PostInputWait = struct {
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
    /// Set by finish(): the app exited during the wait — the input
    /// likely triggered a crash/quit, not a dead area.
    exited: bool = false,

    /// `want_shot` = a post-input screenshot was requested; wait_change
    /// then defaults ON (pass wait_change:false to capture immediately).
    fn begin(args: std.json.Value, app: *appdrive.App, win_id: u32, want_shot: bool) PostInputWait {
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
            .t0 = monoMs(),
        };
    }

    /// Run AFTER the input. Returns a caption note ("" = nothing to
    /// report); a dry wait yields an explicit NO-repaint note so a
    /// dead click is structurally distinct from a late frame.
    fn finish(self: *PostInputWait, arena: std.mem.Allocator, app: *appdrive.App, win_id: u32) ![]const u8 {
        defer if (self.ref) |*r| r.deinit(app.allocator);
        if (!self.wait or self.ref == null) {
            _ = app.waitIdle(200, 2_000);
            return "";
        }
        if (app.waitChangeSince(win_id, &self.ref.?, self.timeout_ms, self.min_pct, self.region)) {
            self.repainted = true;
            const elapsed = monoMs() - self.t0;
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
        if (app.exited or (app.windowGone(win_id) and app.settleExit(1_000))) {
            self.exited = true;
            return try std.fmt.allocPrint(
                arena,
                " — app EXITED during the post-input wait (status {d}{s}): the input likely triggered it; backtrace/report in app_log",
                .{ app.exit_status, try exitSuffix(arena, app.exit_status) },
            );
        }
        return try std.fmt.allocPrint(
            arena,
            " — NO repaint{s} within {d}ms after the input: it may have hit a dead area, or the app reacts without redrawing (any frame shown predates the input)",
            .{ if (self.region != null and self.min_pct > 0) " in the given region" else "", self.timeout_ms },
        );
    }
};

/// Shared tail for app_key/app_type/app_drag/app_scroll: finish the
/// post-input wait, then answer with a screenshot (when asked) or a
/// text result carrying the repaint note.
fn inputResult(
    arena: std.mem.Allocator,
    app: *appdrive.App,
    args: std.json.Value,
    win_id: u32,
    piw: *PostInputWait,
    desc: []const u8,
) ![]const u8 {
    const note = try piw.finish(arena, app, win_id);
    if (piw.exited) {
        // Skip the screenshot attempt (it would fail as "no pixels
        // yet?" and mask the crash) — report the exit with full detail.
        const summary = try appSummary(arena, app);
        const msg = try std.fmt.allocPrint(arena, "{s}{s}\n{s}", .{ desc, note, summary });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (argBool(args, "screenshot") and win_id != 0) {
        const max_px: u32 = @intCast(std.math.clamp(argInt(args, "max_px") orelse 1568, 0, 8192));
        const shot = app.screenshotPng(win_id, max_px, null, 1) catch {
            const msg = try std.fmt.allocPrint(arena, "{s}{s}, but the post-input screenshot failed (no pixels yet?)", .{ desc, note });
            return toolResult(arena, msg, false) orelse error.OutOfMemory;
        };
        defer app_state.allocator.free(shot.png);
        const extra = try std.fmt.allocPrint(arena, "{s}{s}", .{ desc, note });
        const caption = try screenshotCaption(arena, app, win_id, shot, extra);
        return imageResult(arena, caption, shot.png) orelse error.OutOfMemory;
    }
    if (note.len > 0) {
        const msg = try std.fmt.allocPrint(arena, "{s}{s}", .{ desc, note });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    const msg = try std.fmt.allocPrint(arena, "{s}", .{desc});
    return toolResult(arena, msg, false) orelse error.OutOfMemory;
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
        try w.print("{s}: ERROR — screenshot failed (no pixels yet?)\n", .{prefix});
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

// ── input journal, macros, template matching, OCR ─────────────────

/// Per-app journal of successfully injected input steps (canonical
/// step JSON, the app_actions vocabulary). app_macro_save snapshots
/// its tail into a named replayable macro — "record what I just did".
const Journal = struct {
    const Entry = struct { step: []u8, t: i64 };
    const MAX_ENTRIES = 400;
    var map: std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(Entry)) = .empty;

    /// Best-effort: OOM just loses the entry.
    fn record(app_id: u32, step_json: []const u8) void {
        if (app_id == 0 or step_json.len == 0) return;
        const a = app_state.allocator;
        const gop = map.getOrPut(a, app_id) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const copy = a.dupe(u8, step_json) catch return;
        gop.value_ptr.append(a, .{ .step = copy, .t = monoMs() }) catch {
            a.free(copy);
            return;
        };
        while (gop.value_ptr.items.len > MAX_ENTRIES) {
            const old = gop.value_ptr.orderedRemove(0);
            a.free(old.step);
        }
    }

    fn entriesOf(app_id: u32) []Entry {
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

/// Format-and-record one journal step for `app` (bounded; an
/// overlong step is dropped, not truncated into invalid JSON).
fn journalStep(app: *appdrive.App, comptime fmt: []const u8, fmt_args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, fmt_args) catch return;
    Journal.record(appIdOf(app), s);
}

/// Journal a step whose payload needs real JSON escaping (type text).
/// `extra_raw` is appended verbatim inside the object ("" = none),
/// e.g. ",\"hold_ms\":500".
fn journalStepJson(app: *appdrive.App, arena: std.mem.Allocator, key: []const u8, text: []const u8, extra_raw: []const u8) void {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.print("{{\"{s}\":", .{key}) catch return;
    std.json.Stringify.value(text, .{}, w) catch return;
    w.writeAll(extra_raw) catch return;
    w.writeAll("}") catch return;
    Journal.record(appIdOf(app), aw.written());
}

/// Optional {"region":{x,y,w,h}} sub-object of a tool/step arg.
fn regionFrom(v: std.json.Value) ?appdrive.App.Region {
    if (v != .object) return null;
    const r = v.object.get("region") orelse return null;
    if (r != .object) return null;
    const x = argInt(r, "x") orelse 0;
    const y = argInt(r, "y") orelse 0;
    const w = argInt(r, "w") orelse return null;
    const h = argInt(r, "h") orelse return null;
    if (x < 0 or y < 0 or w <= 0 or h <= 0) return null;
    return .{ .x = @intCast(x), .y = @intCast(y), .w = @intCast(w), .h = @intCast(h) };
}

const Needle = struct { px: []u8, w: u32, h: u32, name: []const u8 };

/// Resolve a template reference: "template" (a saved name) or
/// "image_b64" (inline PNG). Pixels land in the arena.
fn resolveNeedle(arena: std.mem.Allocator, v: std.json.Value) !union(enum) { needle: Needle, err: []const u8 } {
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
const FoundMatch = struct { x: u32, y: u32, cx: u32, cy: u32, score: f64 };

/// Match `needle` against a window's current pixels. `.err` is a
/// human message (no pixels / bad template); an empty `.matches`
/// slice just means "not there right now".
fn findInWindow(
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

const OcrOut = struct { text: []u8, words: []ocr.Word, scale: u32 };

/// OCR a window (optionally a region), word boxes mapped back to
/// SURFACE coordinates. scale_req 0 = auto (upscale small captures;
/// game bitmap fonts need it). Results live in the arena.
fn ocrWindow(
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
    var scale: u32 = @min(scale_req, 8);
    if (scale == 0) scale = std.math.clamp(4096 / @max(1, @max(shot.w, shot.h)), 1, 3);
    var px: []const u8 = shot.px;
    var w = shot.w;
    var h = shot.h;
    if (scale > 1) {
        px = png_util.upscaleRgba(arena, shot.px, w, h, scale) catch return error.OutOfMemory;
        w *= scale;
        h *= scale;
    }
    const res = ocr.recognize(arena, px, w, h, .{ .lang = lang, .psm = psm }) catch |err| return .{ .err = switch (err) {
        ocr.Error.Unavailable => "OCR unavailable: libtesseract was not found on this machine. Install tesseract plus a language pack (e.g. tesseract-data-eng) — sketerm loads it at runtime, no rebuild needed.",
        ocr.Error.InitFailed => "tesseract loaded but could not initialize the language — install its traineddata (e.g. tesseract-data-eng) or set TESSDATA_PREFIX",
        ocr.Error.OutOfMemory => return error.OutOfMemory,
        else => "text recognition failed",
    } };
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
fn findWordRun(words: []const ocr.Word, query: []const u8) ?struct { x: u32, y: u32, w: u32, h: u32 } {
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
fn buildLaunchArgv(arena: std.mem.Allocator, argv: *std.ArrayList([]const u8), args: std.json.Value) !LaunchArgv {
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
fn applyDebugWrap(arena: std.mem.Allocator, argv: *std.ArrayList([]const u8), args: std.json.Value) !DebugWrap {
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
        try wrapped.appendSlice(arena, &.{ "gdb", "-q", "-batch", "-ex", "run", "-ex", "bt full", "-ex", "info registers" });
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
            try std.fmt.allocPrint(arena, "\ndebug wrapper: gdb — the reported pid is gdb, not the app; on a crash the backtrace, registers, and your {d} extra gdb command(s) land in app_log", .{n_extra})
        else
            "\ndebug wrapper: gdb — the reported pid is gdb, not the app; on a crash the full backtrace lands in app_log";
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

fn appTool(arena: std.mem.Allocator, name: []const u8, args: std.json.Value) ![]const u8 {
    const eql = std.mem.eql;
    if (!app_state.ready)
        return appErr(arena, "app tools unavailable (server not fully started)");

    if (eql(u8, name, "launch_app")) {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        const built = switch (try buildLaunchArgv(arena, &argv, args)) {
            .ok => |b| b,
            .err => |msg| return appErr(arena, msg),
        };
        // Chromium-family binaries default to X11 and die in the
        // Wayland-only session; inject the ozone flag unless the
        // caller chose one (argv form only — a shell string cannot be
        // rewritten safely).
        var browser_note: []const u8 = "";
        const argv_form = built.argv_form;
        if (argv_form and chromiumFamily(argv.items[0])) {
            var has_ozone = false;
            for (argv.items) |a| {
                if (std.mem.startsWith(u8, a, "--ozone-platform")) has_ozone = true;
            }
            if (!has_ozone) {
                try argv.insert(arena, 1, "--ozone-platform=wayland");
                browser_note = "\n(auto-added --ozone-platform=wayland: Chromium-family app in a Wayland-only session)";
            }
        }
        const debug_note = switch (try applyDebugWrap(arena, &argv, args)) {
            .note => |n| n,
            .err => |e| return appErr(arena, e),
        };
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
        var user_set_ozone_hint = false;
        if (args == .object) {
            if (args.object.get("env")) |e| {
                if (e != .object) return appErr(arena, "'env' must be an object of KEY: \"value\" strings");
                var it = e.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* != .string)
                        return appErr(arena, "'env' values must be strings");
                    if (std.mem.eql(u8, entry.key_ptr.*, "ELECTRON_OZONE_PLATFORM_HINT")) user_set_ozone_hint = true;
                    try env_list.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.string }));
                }
            }
        }
        // Electron apps honor this hint and ignore it otherwise; the
        // session has no X server, so wayland is the right default.
        if (!user_set_ozone_hint)
            try env_list.append(arena, "ELECTRON_OZONE_PLATFORM_HINT=wayland");
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
        if (browser_note.len > 0) summary = try std.fmt.allocPrint(arena, "{s}{s}", .{ summary, browser_note });
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

    if (eql(u8, name, "app_templates")) {
        if (argStr(args, "delete")) |del| {
            mcpassets.delete(app_state.allocator, .template, del) catch |err| return appErr(arena, switch (err) {
                mcpassets.Error.NotFound => "no such template",
                mcpassets.Error.BadName => "invalid template name",
                else => "delete failed",
            });
            return toolResult(arena, "template deleted", false) orelse error.OutOfMemory;
        }
        const names = mcpassets.list(app_state.allocator, .template) catch
            return appErr(arena, "listing templates failed");
        defer {
            for (names) |nm| app_state.allocator.free(nm);
            app_state.allocator.free(names);
        }
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("[");
        for (names, 0..) |nm, i| {
            if (i > 0) try w.writeAll(",");
            var dims: []const u8 = "";
            if (mcpassets.load(arena, .template, nm)) |bytes| {
                if (png_util.decodeRgba(arena, bytes)) |dec| {
                    arena.free(dec.rgba);
                    dims = try std.fmt.allocPrint(arena, ",\"w\":{d},\"h\":{d}", .{ dec.w, dec.h });
                } else |_| {}
            } else |_| {}
            try w.print("{{\"name\":{f}{s}}}", .{ std.json.fmt(nm, .{}), dims });
        }
        try w.writeAll("]");
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_template_save")) {
        const tname = argStr(args, "name") orelse return appErr(arena, "app_template_save requires 'name'");
        if (!mcpassets.validName(tname))
            return appErr(arena, "invalid template name (letters, digits, . _ - only, max 64)");
        var png_bytes: []const u8 = undefined;
        var dw: u32 = 0;
        var dh: u32 = 0;
        if (argStr(args, "image_b64")) |b64| {
            const decoder = std.base64.standard.Decoder;
            const max = decoder.calcSizeForSlice(b64) catch return appErr(arena, "image_b64 is not valid base64");
            const raw = try arena.alloc(u8, max);
            decoder.decode(raw, b64) catch return appErr(arena, "image_b64 is not valid base64");
            const dec = png_util.decodeRgba(arena, raw) catch
                return appErr(arena, "image_b64 does not decode as an image");
            arena.free(dec.rgba);
            dw = dec.w;
            dh = dec.h;
            png_bytes = raw;
        } else {
            const capp = appFromArgs(args) orelse
                return appErr(arena, "pass 'app' (capture from its window) or 'image_b64' (inline PNG)");
            capp.drain();
            const region = regionFrom(args) orelse
                return appErr(arena, "capturing needs 'region' {x,y,w,h} — crop JUST the distinctive UI element (a whole window makes a useless template)");
            const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(capp);
            if (wid == 0) return appErr(arena, "no rendered window yet (try app_wait first)");
            const shot = capp.snapshotRgba(wid, region) catch
                return appErr(arena, "no rendered pixels in that window (yet?)");
            defer app_state.allocator.free(shot.px);
            dw = shot.w;
            dh = shot.h;
            png_bytes = png_util.encodeRgba(arena, shot.px, shot.w, shot.h) catch return error.OutOfMemory;
        }
        mcpassets.save(app_state.allocator, .template, tname, png_bytes) catch |err| return appErr(arena, switch (err) {
            mcpassets.Error.TooBig => "template too large (8 MB cap)",
            else => "saving the template failed (state dir not writable?)",
        });
        const msg = try std.fmt.allocPrint(arena, "template \"{s}\" saved ({d}x{d}) — match it with app_find_image / app_wait_image or the wait_image / click_image action steps", .{ tname, dw, dh });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_macros")) {
        if (argStr(args, "delete")) |del| {
            mcpassets.delete(app_state.allocator, .macro, del) catch |err| return appErr(arena, switch (err) {
                mcpassets.Error.NotFound => "no such macro",
                mcpassets.Error.BadName => "invalid macro name",
                else => "delete failed",
            });
            return toolResult(arena, "macro deleted", false) orelse error.OutOfMemory;
        }
        if (argStr(args, "show")) |nm| {
            const bytes = mcpassets.load(arena, .macro, nm) catch |err| return appErr(arena, switch (err) {
                mcpassets.Error.NotFound => "no such macro",
                mcpassets.Error.BadName => "invalid macro name",
                mcpassets.Error.OutOfMemory => return error.OutOfMemory,
                else => "macro load failed",
            });
            return toolResult(arena, bytes, false) orelse error.OutOfMemory;
        }
        if (argBool(args, "journal")) {
            const capp = appFromArgs(args) orelse
                return appErr(arena, "the journal view needs 'app' (recorded steps are per app)");
            const entries = Journal.entriesOf(appIdOf(capp));
            var aw: std.Io.Writer.Allocating = .init(arena);
            const w = &aw.writer;
            try w.print("{d} recorded input step(s), oldest first (save the tail with app_macro_save last_steps:N):\n", .{entries.len});
            for (entries, 0..) |e, i| {
                try w.print("{d}. {s}\n", .{ i + 1, e.step });
            }
            return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
        }
        const names = mcpassets.list(app_state.allocator, .macro) catch
            return appErr(arena, "listing macros failed");
        defer {
            for (names) |nm| app_state.allocator.free(nm);
            app_state.allocator.free(names);
        }
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("[");
        for (names, 0..) |nm, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{f}", .{std.json.fmt(nm, .{})});
        }
        try w.writeAll("]");
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_macro_save")) {
        const mname = argStr(args, "name") orelse return appErr(arena, "app_macro_save requires 'name'");
        if (!mcpassets.validName(mname))
            return appErr(arena, "invalid macro name (letters, digits, . _ - only, max 64)");
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("{\"actions\":[");
        var count: usize = 0;
        var from_journal = false;
        if (args == .object and args.object.get("actions") != null) {
            const av = args.object.get("actions").?;
            if (av != .array or av.array.items.len == 0)
                return appErr(arena, "'actions' must be a non-empty array of step objects");
            if (av.array.items.len > 200) return appErr(arena, "too many steps (max 200)");
            for (av.array.items, 0..) |st, i| {
                if (st != .object) return appErr(arena, "each action step must be an object");
                if (i > 0) try w.writeAll(",");
                std.json.Stringify.value(st, .{}, w) catch return error.OutOfMemory;
            }
            count = av.array.items.len;
        } else {
            from_journal = true;
            const capp = appFromArgs(args) orelse
                return appErr(arena, "recording from the journal needs 'app' (or pass explicit 'actions')");
            const entries = Journal.entriesOf(appIdOf(capp));
            if (entries.len == 0)
                return appErr(arena, "no recorded input steps for this app yet — drive it (app_click / app_key / app_actions / ...), then save");
            var take: usize = entries.len;
            if (argInt(args, "last_steps")) |ls| {
                if (ls <= 0) return appErr(arena, "'last_steps' must be positive");
                take = @min(take, @as(usize, @intCast(ls)));
            }
            var first = true;
            var prev_t: i64 = 0;
            for (entries[entries.len - take ..], 0..) |e, i| {
                // Preserve think-time between recorded inputs as wait
                // steps (clamped) so the replay paces like the drive.
                if (i > 0 and e.t - prev_t >= 250) {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try w.print("{{\"wait\":{d}}}", .{@min(e.t - prev_t, 10_000)});
                }
                prev_t = e.t;
                if (!first) try w.writeAll(",");
                first = false;
                try w.writeAll(e.step);
                count += 1;
            }
        }
        try w.writeAll("]}");
        mcpassets.save(app_state.allocator, .macro, mname, aw.written()) catch |err| return appErr(arena, switch (err) {
            mcpassets.Error.TooBig => "macro too large",
            else => "saving the macro failed (state dir not writable?)",
        });
        const msg = try std.fmt.allocPrint(arena, "macro \"{s}\" saved ({d} step(s){s}) — replay with app_macro_run, inspect with app_macros show", .{
            mname, count, if (from_journal) ", wait gaps preserved" else "",
        });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }

    const app = appFromArgs(args) orelse
        return appErr(arena, "unknown app (pass 'app' from launch_app; use list_apps)");
    // Catch up to the LIVE frame before any observation or input
    // baseline. The 100ms-boxed drain() only chewed part of a between-
    // calls backlog, so screenshots lagged by whole screens on busy
    // apps (SDL games) — the daemon now pauses streaming to a
    // backlogged MCP client and replays current state once we drain;
    // drainLive waits for that replay (bounded).
    _ = app.drainLive(CATCHUP_MS);

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
        const fetch = app.logGet(req, 5_000) catch |err| switch (err) {
            appdrive.Error.Timeout => {
                // Both the primary connection AND a fresh side
                // connection failed — serve the PTY grid mirror as the
                // last resort (content without line ids beats nothing),
                // with liveness data so "log stuck" and "app wedged"
                // read differently.
                var frames: u64 = 0;
                for (app.windows.items) |w| frames += w.frames;
                if (app.output(false)) |grid| {
                    defer app_state.allocator.free(grid);
                    const msg = try std.fmt.allocPrint(
                        arena,
                        "[log path timed out even over a fresh daemon connection (app alive: {}, windows: {d}, frames committed: {d}) — serving the PTY grid mirror instead; NO line ids, wrapped at the grid width]\n{s}",
                        .{ !app.exited, app.windows.items.len, frames, grid },
                    );
                    return toolResult(arena, msg, false) orelse error.OutOfMemory;
                } else |_| {}
                const msg = try std.fmt.allocPrint(
                    arena,
                    "the daemon's log reply did not arrive within 5s, a fresh side connection also failed, and no grid mirror is available (app alive: {}, windows: {d}, frames committed: {d})",
                    .{ !app.exited, app.windows.items.len, frames },
                );
                return appErr(arena, msg);
            },
            else => return appErr(arena, "no log data for this app"),
        };
        const reply = fetch.json;
        defer app_state.allocator.free(reply);
        if (fetch.stale and line_id != 0)
            return appErr(arena, "the daemon's log reply did not arrive within 5s; only a stale cached snapshot is available, which cannot answer a single-line fetch honestly — retry in a moment");
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
                l.id,                                                          age_s,
                if (l.truncated) ", was longer than the 4KB line cap" else "", l.text,
            });
            return toolResult(arena, msg, false) orelse error.OutOfMemory;
        }

        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        if (fetch.stale)
            try w.writeAll("[STALE: the daemon's fresh log reply was still queued behind streamed frame data after 5s — serving the last cached snapshot instead; retry app_log for current lines]\n");
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
                        l.id,                                     age_s, l.text,
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
            win_id = firstToplevelId(app);
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
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 10_000, 0, Watchdog.hard_ms);
        // min_change_pct also thresholds wait_change/stable_ms so
        // continuously-animating apps (a 60Hz software cursor) can
        // still signal/settle on CONTENT changes. Burst reads its own
        // copy below (different default).
        const wait_min_pct: f64 = argFloat(args, "min_change_pct") orelse 0;
        // Region is parsed BEFORE the waits/stats: it scopes not just
        // the crop but every pixel-change percentage below — "did THIS
        // rectangle change" is assertable without eyeballing the image.
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
        // Percentages only scope to the rect when a threshold gates
        // them — a bare region stays a plain crop.
        const diff_region: ?appdrive.App.Region = if (wait_min_pct > 0) region else null;
        if (argBool(args, "wait_change")) {
            // Block (bounded) until the window commits a frame newer
            // than its last screenshot — "did my click do anything".
            if (!app.waitWindowChange(win_id, timeout_ms, wait_min_pct, diff_region))
                return appErr(arena, if (diff_region != null)
                    "the region's content did not change before the timeout"
                else
                    "window content did not change before the timeout");
        }
        var settle_note: []const u8 = "";
        if (argInt(args, "stable_ms")) |sm| {
            // Settle-then-capture: wait until the window stops
            // repainting before shooting (composes with wait_change:
            // "changed, then went quiet"). With a threshold this is
            // VISUAL settle: sub-threshold repaints don't reset it.
            const settled = if (sm <= 0)
                true
            else if (wait_min_pct > 0)
                app.waitVisualSettle(win_id, sm, timeout_ms, wait_min_pct, diff_region)
            else
                app.waitWindowSettle(win_id, sm, timeout_ms);
            if (!settled)
                settle_note = "\n[note: frames were still arriving at timeout_ms — captured anyway]";
        }
        if (argBool(args, "stats_only")) {
            // Cheap change probe: no PNG, just "did it change and how
            // much" vs whatever the caller last saw. With a region the
            // diff_pct is computed inside that rect only.
            const st = app.diffStats(win_id, region) catch
                return appErr(arena, "no such window / no pixels yet");
            const msg = try std.fmt.allocPrint(
                arena,
                "{{\"changed\":{},\"diff_pct\":{d:.2},\"resized\":{},\"w\":{d},\"h\":{d},\"frames\":{d}{s}}}{s}",
                .{ st.changed, st.diff_pct, st.resized, st.w, st.h, st.frames, if (region != null) ",\"diff_scope\":\"region\"" else "", settle_note },
            );
            return toolResult(arena, msg, false) orelse error.OutOfMemory;
        }
        const max_px: u32 = @intCast(std.math.clamp(argInt(args, "max_px") orelse 1568, 0, 8192));
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
                    if (app.peekDiffPct(win_id, region) < min_pct) {
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
        var piw = PostInputWait.begin(args, app, win_id, argBool(args, "screenshot"));
        app.drag(
            win_id,
            @floatFromInt(x1),
            @floatFromInt(y1),
            @floatFromInt(x2),
            @floatFromInt(y2),
            button,
        ) catch return appErr(arena, "drag failed (bad window?)");
        journalStep(app, "{{\"drag\":[{d},{d},{d},{d}],\"button\":{d},\"window\":{d}}}", .{ x1, y1, x2, y2, button, win_id });
        const desc = try std.fmt.allocPrint(arena, "dragged ({d},{d}) -> ({d},{d}) button {d}", .{ x1, y1, x2, y2, button });
        return inputResult(arena, app, args, win_id, &piw, desc);
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
        const hold_ms: i64 = std.math.clamp(argInt(args, "hold_ms") orelse Tuning.hold_ms.value, 0, 10_000);
        const count: u32 = @intCast(std.math.clamp(argInt(args, "count") orelse 1, 1, 3));
        const retries: i64 = std.math.clamp(argInt(args, "retry") orelse Tuning.click_retry.value, 0, 5);
        // Crosshair-marked post-click screenshot is the DEFAULT: it
        // answers "did the click land where I aimed, and did it do
        // anything" in one image. mark:false (without screenshot)
        // restores the plain text reply.
        const want_mark = if (args == .object and args.object.get("mark") != null)
            argBool(args, "mark")
        else
            true;
        const want_shot = want_mark or argBool(args, "screenshot");
        var attempts: i64 = 0;
        var note: []const u8 = "";
        var repainted = false;
        while (true) {
            var piw = PostInputWait.begin(args, app, win_id, want_shot);
            app.clickEx(win_id, @floatFromInt(x), @floatFromInt(y), button, hold_ms, count) catch
                return appErr(arena, "click failed (bad window?)");
            attempts += 1;
            note = try piw.finish(arena, app, win_id);
            repainted = piw.repainted;
            // Auto-retry only on a WAITED no-repaint verdict — a click
            // that visibly landed must never get a second press, and
            // without a wait there is no verdict to retry on.
            if (repainted or !piw.wait or attempts > retries or app.exited) break;
        }
        journalStep(app, "{{\"click\":[{d},{d}],\"button\":{d},\"window\":{d},\"hold_ms\":{d},\"count\":{d}}}", .{ x, y, button, win_id, hold_ms, count });
        if (app.exited) {
            // Don't attempt the screenshot — it fails as "no pixels
            // yet?" and masks the crash the click just triggered.
            const summary = try appSummary(arena, app);
            const msg = try std.fmt.allocPrint(arena, "clicked ({d},{d}) button {d}{s}\n{s}", .{ x, y, button, note, summary });
            return toolResult(arena, msg, false) orelse error.OutOfMemory;
        }
        if (attempts > 1) {
            note = try std.fmt.allocPrint(arena, " — auto-retried: {d} attempts, earlier clicks produced no qualifying repaint{s}", .{ attempts, note });
        }
        const qual: []const u8 = if (count > 1)
            try std.fmt.allocPrint(arena, " x{d} ({s}, held {d}ms each)", .{ count, if (count == 2) "double-click" else "triple-click", hold_ms })
        else if (hold_ms > 0)
            try std.fmt.allocPrint(arena, " (held {d}ms)", .{hold_ms})
        else
            "";
        if (want_shot) {
            // Post-click frame, optionally with the click point drawn
            // in — one call shows where the click landed AND what the
            // UI did with it. The frame is captured only after the
            // window commits something NEWER than the click (bounded),
            // and the caption says explicitly when it never did.
            const annot = [_]marks_mod.Mark{.{ .x = @floatFromInt(x), .y = @floatFromInt(y) }};
            const max_px: u32 = @intCast(std.math.clamp(argInt(args, "max_px") orelse 1568, 0, 8192));
            const shot = app.screenshotPngMarked(win_id, max_px, null, 1, if (want_mark) &annot else &.{}) catch
                return toolResult(arena, "clicked, but the post-click screenshot failed (no pixels yet?)", false) orelse error.OutOfMemory;
            defer app_state.allocator.free(shot.png);
            const extra = try std.fmt.allocPrint(arena, "clicked ({d},{d}) button {d}{s}{s}{s}", .{
                x, y, button, qual, note,
                if (want_mark)
                    " — the red crosshair marks the click point on the post-click frame. Coordinates are delivered to the app verbatim; a pointer-LOCKED app tracks its own cursor from relative deltas, so its internal cursor can differ (calibrate with app_mouse_move dx/dy)."
                else
                    "",
            });
            const caption = try screenshotCaption(arena, app, win_id, shot, extra);
            return imageResultTagged(arena, caption, shot.png, "click") orelse error.OutOfMemory;
        }
        if (note.len > 0 or qual.len > 0) {
            const msg = try std.fmt.allocPrint(arena, "clicked ({d},{d}) button {d}{s}{s}", .{ x, y, button, qual, note });
            return toolResult(arena, msg, false) orelse error.OutOfMemory;
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
        return runActionSteps(arena, app, steps, win_arg, true, "");
    }
    return appToolTail(arena, name, args, app);
}

/// Execute an ordered batch of action steps against `app` — the
/// app_actions vocabulary, shared with macro replay (app_macro_run).
/// `record` journals each successful step for app_macro_save; `intro`
/// is written ahead of the per-step report.
fn runActionSteps(
    arena: std.mem.Allocator,
    app: *appdrive.App,
    steps: []const std.json.Value,
    win_arg: ?u32,
    record: bool,
    intro: []const u8,
) ![]const u8 {
    const MAX_SHOTS = 8;

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    var pngs: std.ArrayList([]const u8) = .empty;
    defer {
        for (pngs.items) |p| app_state.allocator.free(p);
        pngs.deinit(arena);
    }
    // Per-image trace-filename tags, parallel to `pngs`.
    var shot_tags: std.ArrayList([]const u8) = .empty;
    defer shot_tags.deinit(arena);
    var stopped = false;
    // Marks accumulated by `"mark": true` steps; drawn onto (and
    // consumed by) the next screenshot so several clicks can share
    // one annotated image, each labelled with its step number.
    var pending_marks: std.ArrayList(marks_mod.Mark) = .empty;
    defer pending_marks.deinit(arena);
    if (intro.len > 0) try w.writeAll(intro);
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
            const hold_ms: i64 = std.math.clamp(argInt(st, "hold_ms") orelse Tuning.hold_ms.value, 0, 10_000);
            const cnt: u32 = @intCast(std.math.clamp(argInt(st, "count") orelse 1, 1, 3));
            app.clickEx(wid, xy[0], xy[1], button, hold_ms, cnt) catch {
                try w.print("step {d}: ERROR — click failed (bad window?)\n", .{n});
                stopped = true;
                break;
            };
            _ = app.waitIdle(100, 1_000);
            const marked = argBool(st, "mark");
            if (marked) pending_marks.append(arena, .{ .x = xy[0], .y = xy[1], .kind = .click, .label = @intCast(n) }) catch {};
            if (cnt > 1) {
                try w.print("step {d}: clicked ({d:.0},{d:.0}) x{d} button {d} window {d}{s}\n", .{ n, xy[0], xy[1], cnt, button, wid, if (marked) " [marked]" else "" });
            } else {
                try w.print("step {d}: clicked ({d:.0},{d:.0}) button {d} window {d}{s}\n", .{ n, xy[0], xy[1], button, wid, if (marked) " [marked]" else "" });
            }
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
            const khold: i64 = std.math.clamp(argInt(st, "hold_ms") orelse 0, 0, 10_000);
            var bad = false;
            var it = std.mem.tokenizeScalar(u8, kv.string, ' ');
            while (it.next()) |spec| {
                app.pressKeyHold(win_step, spec, khold) catch {
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
                settled = if (wid == 0) false else app.waitVisualSettle(wid, quiet_ms, timeout_ms, pct, if (wv == .object) regionFrom(wv) else null);
            } else {
                settled = app.waitIdle(quiet_ms, timeout_ms);
            }
            if (!settled and (argBool(st, "required") or (wv == .object and argBool(wv, "required")))) {
                try w.print("step {d}: ERROR — wait_idle did not settle before timeout (required); remaining steps skipped\n", .{n});
                stopped = true;
                break;
            }
            try w.print("step {d}: wait_idle — {s}\n", .{ n, if (app.exited) "app EXITED during the wait (summary below)" else if (settled) "settled" else "TIMED OUT (still rendering)" });
        } else if (st.object.get("wait_change")) |wv| {
            var timeout_ms: i64 = 10_000;
            var min_pct: f64 = 0;
            if (wv == .integer) {
                timeout_ms = wv.integer;
            } else if (wv == .object) {
                if (argInt(wv, "timeout_ms")) |t| timeout_ms = t;
                if (argFloat(wv, "min_change_pct")) |p| min_pct = p;
            }
            const wid = win_step orelse firstToplevelId(app);
            const changed = if (wid == 0) false else app.waitWindowChange(wid, timeout_ms, min_pct, if (wv == .object and min_pct > 0) regionFrom(wv) else null);
            if (!changed and (argBool(st, "required") or (wv == .object and argBool(wv, "required")))) {
                try w.print("step {d}: ERROR — wait_change saw no change before timeout (required); remaining steps skipped\n", .{n});
                stopped = true;
                break;
            }
            try w.print("step {d}: wait_change — {s}\n", .{ n, if (changed) "content changed" else if (app.exited) "app EXITED during the wait (summary below)" else "TIMED OUT (no change)" });
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
            if (!try actionsCapture(arena, app, w, &pngs, &shot_tags, &pending_marks, wid, max_px, prefix)) {
                stopped = true;
                break;
            }
            continue;
        } else if (st.object.get("wait_image") != null or st.object.get("click_image") != null) {
            const is_wait = st.object.get("wait_image") != null;
            const wv = st.object.get("wait_image") orelse st.object.get("click_image").?;
            if (wv != .object) {
                try w.print("step {d}: ERROR — \"{s}\" wants an object with 'template' or 'image_b64'\n", .{ n, if (is_wait) "wait_image" else "click_image" });
                stopped = true;
                break;
            }
            const needle = switch (try resolveNeedle(arena, wv)) {
                .needle => |nd| nd,
                .err => |e| {
                    try w.print("step {d}: ERROR — {s}\n", .{ n, e });
                    stopped = true;
                    break;
                },
            };
            const min_score = argFloat(wv, "min_score") orelse 0.9;
            const timeout_ms: i64 = if (is_wait) (argInt(wv, "timeout_ms") orelse 10_000) else 0;
            // click_image clicks by definition; wait_image opts in.
            const do_click = if (is_wait) argBool(wv, "click") else true;
            const btn: u32 = @intCast(argInt(wv, "button") orelse 1);
            const region = regionFrom(wv);
            const wid = win_step orelse firstToplevelId(app);
            const deadline = monoMs() + timeout_ms;
            var found: ?FoundMatch = null;
            while (true) {
                switch (try findInWindow(arena, app, wid, region, needle, min_score, 1)) {
                    .matches => |ms| if (ms.len > 0) {
                        found = ms[0];
                    },
                    .err => {}, // window not rendered yet — keep waiting
                }
                if (found != null or app.exited or monoMs() >= deadline) break;
                _ = app.pumpOnce(50);
            }
            const m = found orelse {
                try w.print("step {d}: ERROR — template \"{s}\" not found{s}\n", .{ n, needle.name, if (is_wait) " before timeout" else "" });
                stopped = true;
                break;
            };
            if (do_click) {
                clickTuned(app, wid, @floatFromInt(m.cx), @floatFromInt(m.cy), btn) catch {
                    try w.print("step {d}: ERROR — template matched but the click failed (bad window?)\n", .{n});
                    stopped = true;
                    break;
                };
                _ = app.waitIdle(100, 1_000);
                if (argBool(st, "mark"))
                    pending_marks.append(arena, .{ .x = @floatFromInt(m.cx), .y = @floatFromInt(m.cy), .kind = .click, .label = @intCast(n) }) catch {};
            }
            try w.print("step {d}: template \"{s}\" matched at ({d},{d}) score {d:.3}{s}\n", .{ n, needle.name, m.x, m.y, m.score, if (do_click) " — clicked its center" else "" });
        } else if (st.object.get("wait_text")) |wv| {
            if (wv != .object) {
                try w.print("step {d}: ERROR — \"wait_text\" wants an object with 'text'\n", .{n});
                stopped = true;
                break;
            }
            const query = argStr(wv, "text") orelse {
                try w.print("step {d}: ERROR — \"wait_text\" requires 'text'\n", .{n});
                stopped = true;
                break;
            };
            const timeout_ms: i64 = argInt(wv, "timeout_ms") orelse 15_000;
            const do_click = argBool(wv, "click");
            const region = regionFrom(wv);
            const scale: u32 = @intCast(std.math.clamp(argInt(wv, "scale") orelse 0, 0, 8));
            const psm: i32 = @intCast(argInt(wv, "psm") orelse 6);
            const lang = argStr(wv, "lang") orelse "eng";
            const wid = win_step orelse firstToplevelId(app);
            const deadline = monoMs() + timeout_ms;
            var seen: ?OcrOut = null;
            var fatal: ?[]const u8 = null;
            while (true) {
                switch (try ocrWindow(arena, app, wid, region, scale, psm, lang)) {
                    .out => |o| {
                        if (std.ascii.indexOfIgnoreCase(o.text, query) != null) seen = o;
                    },
                    .err => |e| {
                        // "not rendered yet" is transient; a missing
                        // OCR engine never resolves — stop now.
                        if (!std.mem.startsWith(u8, e, "no rendered")) fatal = e;
                    },
                }
                if (seen != null or fatal != null or app.exited or monoMs() >= deadline) break;
                _ = app.waitIdle(std.math.maxInt(i32), 300); // pumped sleep between OCR passes
            }
            if (fatal) |e| {
                try w.print("step {d}: ERROR — {s}\n", .{ n, e });
                stopped = true;
                break;
            }
            const o = seen orelse {
                try w.print("step {d}: ERROR — text \"{s}\" not visible before timeout\n", .{ n, query });
                stopped = true;
                break;
            };
            var note: []const u8 = "";
            if (do_click) {
                const box = findWordRun(o.words, query) orelse {
                    try w.print("step {d}: ERROR — text \"{s}\" is visible but OCR gave no clickable word box for it\n", .{ n, query });
                    stopped = true;
                    break;
                };
                clickTuned(app, wid, @floatFromInt(box.x + box.w / 2), @floatFromInt(box.y + box.h / 2), 1) catch {
                    try w.print("step {d}: ERROR — text found but the click failed (bad window?)\n", .{n});
                    stopped = true;
                    break;
                };
                _ = app.waitIdle(100, 1_000);
                if (argBool(st, "mark"))
                    pending_marks.append(arena, .{ .x = @floatFromInt(box.x + box.w / 2), .y = @floatFromInt(box.y + box.h / 2), .kind = .click, .label = @intCast(n) }) catch {};
                note = " — clicked it";
            }
            try w.print("step {d}: text \"{s}\" is visible{s}\n", .{ n, query, note });
        } else {
            try w.print("step {d}: ERROR — unknown step (want move/move_rel/click/drag/key/type/scroll/wait/wait_idle/wait_change/screenshot/wait_image/click_image/wait_text)\n", .{n});
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
                _ = try actionsCapture(arena, app, w, &pngs, &shot_tags, &pending_marks, wid, 1568, prefix);
            }
        }
        // Journal the step VERBATIM once it succeeded (pure
        // screenshot steps `continue`d above and are not steps a
        // macro needs to repeat).
        if (record) {
            var jw: std.Io.Writer.Allocating = .init(arena);
            std.json.Stringify.value(st, .{}, &jw.writer) catch {};
            Journal.record(appIdOf(app), jw.written());
        }
    }
    // `mark` without any screenshot still yields an image: capture
    // the final state with the leftover marks drawn in.
    if (pending_marks.items.len > 0 and pngs.items.len < MAX_SHOTS) {
        const wid = win_arg orelse firstToplevelId(app);
        if (wid != 0)
            _ = try actionsCapture(arena, app, w, &pngs, &shot_tags, &pending_marks, wid, 1568, "end of batch");
    }
    if (!stopped) try w.print("all {d} steps completed\n", .{steps.len});
    if (app.exited) try w.writeAll(try appSummary(arena, app));
    if (pngs.items.len > 0)
        return imagesResultTagged(arena, aw.written(), pngs.items, shot_tags.items) orelse error.OutOfMemory;
    return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
}

/// Continuation of appTool (split around the step engine so
/// runActionSteps can live between the two halves).
fn appToolTail(arena: std.mem.Allocator, name: []const u8, args: std.json.Value, app: *appdrive.App) ![]const u8 {
    const eql = std.mem.eql;
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
        if (has_abs) {
            journalStep(app, "{{\"move\":[{d:.0},{d:.0}]}}", .{ pos.x, pos.y });
        } else if (has_rel) {
            journalStep(app, "{{\"move_rel\":[{d:.0},{d:.0}]}}", .{ argFloat(args, "dx") orelse 0, argFloat(args, "dy") orelse 0 });
        }
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
            app.drain();
            if (app.exited) {
                const summary = try appSummary(arena, app);
                const msg = try std.fmt.allocPrint(arena, "the app exited while waiting for an element\n{s}", .{summary});
                return toolResult(arena, msg, true) orelse error.OutOfMemory;
            }
            if (Watchdog.fired.load(.acquire))
                return appErr(arena, "element wait aborted by the MCP hard timeout");
            if (monoMs() >= deadline)
                return appErr(arena, "element did not appear before the timeout");
            var ts = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 300 * 1000 * 1000 };
            _ = c.nanosleep(&ts, null);
        }
    }
    if (eql(u8, name, "app_type")) {
        const text = argStr(args, "text") orelse return appErr(arena, "app_type requires 'text'");
        const win: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
        const wait_win: u32 = win orelse firstToplevelId(app);
        var piw = PostInputWait.begin(args, app, wait_win, argBool(args, "screenshot"));
        app.typeText(win, text) catch |err| return appErr(arena, switch (err) {
            appdrive.Error.BadKey => "text contains a character outside the us keymap",
            else => "type failed (no window?)",
        });
        journalStepJson(app, arena, "type", text, "");
        const desc = try std.fmt.allocPrint(arena, "typed {d} chars", .{text.len});
        return inputResult(arena, app, args, wait_win, &piw, desc);
    }
    if (eql(u8, name, "app_key")) {
        const keys = argStr(args, "keys") orelse return appErr(arena, "app_key requires 'keys'");
        const win: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
        const wait_win: u32 = win orelse firstToplevelId(app);
        const hold_ms: i64 = std.math.clamp(argInt(args, "hold_ms") orelse 0, 0, 10_000);
        var piw = PostInputWait.begin(args, app, wait_win, argBool(args, "screenshot"));
        var it = std.mem.tokenizeScalar(u8, keys, ' ');
        while (it.next()) |spec| {
            app.pressKeyHold(win, spec, hold_ms) catch |err| return appErr(arena, switch (err) {
                appdrive.Error.BadKey => "unknown key chord",
                else => "key press failed (no window?)",
            });
        }
        const extra: []const u8 = if (hold_ms > 0)
            try std.fmt.allocPrint(arena, ",\"hold_ms\":{d}", .{hold_ms})
        else
            "";
        journalStepJson(app, arena, "key", keys, extra);
        const desc = if (hold_ms > 0)
            try std.fmt.allocPrint(arena, "pressed (each held {d}ms): {s}", .{ hold_ms, keys })
        else
            try std.fmt.allocPrint(arena, "pressed: {s}", .{keys});
        return inputResult(arena, app, args, wait_win, &piw, desc);
    }
    if (eql(u8, name, "app_scroll")) {
        const win_id: u32 = @intCast(argInt(args, "window") orelse
            return appErr(arena, "app_scroll requires 'window'"));
        const x = argInt(args, "x") orelse 10;
        const y = argInt(args, "y") orelse 10;
        const dx = argInt(args, "dx") orelse 0;
        const dy = argInt(args, "dy") orelse 0;
        var piw = PostInputWait.begin(args, app, win_id, argBool(args, "screenshot"));
        app.scroll(win_id, @floatFromInt(x), @floatFromInt(y), @floatFromInt(dx), @floatFromInt(dy)) catch
            return appErr(arena, "scroll failed (bad window?)");
        journalStep(app, "{{\"scroll\":[{d},{d}],\"at\":[{d},{d}],\"window\":{d}}}", .{ dx, dy, x, y, win_id });
        const desc = try std.fmt.allocPrint(arena, "scrolled ({d},{d}) at ({d},{d})", .{ dx, dy, x, y });
        return inputResult(arena, app, args, win_id, &piw, desc);
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
        const was_exited = app.exited;
        var outcome: []const u8 = undefined;
        if (argFloat(args, "change_pct")) |pct| {
            // Visual quiescence: frames may keep committing (a game
            // always renders) — settle when they stop CHANGING much.
            // A region scopes the percentage to that rect.
            const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
            if (wid == 0) return appErr(arena, "no rendered window yet (change_pct needs one)");
            outcome = if (app.waitVisualSettle(wid, quiet_ms, timeout_ms, pct, regionFrom(args)))
                try std.fmt.allocPrint(arena, "settled (frames changed <{d:.1}% of pixels for {d}ms)", .{ pct, quiet_ms })
            else
                try std.fmt.allocPrint(arena, "timeout: still changing >{d:.1}% of pixels per frame after {d}ms", .{ pct, timeout_ms });
        } else {
            outcome = if (app.waitIdle(quiet_ms, timeout_ms))
                "settled (no new frames)"
            else
                "timeout: still rendering — a continuously-animating app never settles this way; pass change_pct (e.g. 2) to wait for VISUAL quiescence instead";
        }
        // The settle waits return "settled" on exit — say what really
        // happened, with the signal, instead of a bogus quiet verdict.
        if (app.exited) {
            outcome = if (was_exited)
                "the app has already exited (details below)"
            else
                try std.fmt.allocPrint(arena, "app EXITED during the wait (status {d}{s}) — backtrace/report in app_log", .{ app.exit_status, try exitSuffix(arena, app.exit_status) });
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
            win_id = firstToplevelId(app);
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
    if (eql(u8, name, "app_read_text")) {
        const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
        if (wid == 0) return appErr(arena, "no rendered window yet (try app_wait first)");
        const region = regionFrom(args);
        const scale: u32 = @intCast(std.math.clamp(argInt(args, "scale") orelse 0, 0, 8));
        const psm: i32 = @intCast(std.math.clamp(argInt(args, "psm") orelse 6, 0, 13));
        const lang = argStr(args, "lang") orelse "eng";
        switch (try ocrWindow(arena, app, wid, region, scale, psm, lang)) {
            .err => |e| return appErr(arena, e),
            .out => |o| {
                var aw: std.Io.Writer.Allocating = .init(arena);
                const w = &aw.writer;
                try w.print("{{\"window\":{d},\"ocr_scale\":{d},\"text\":", .{ wid, o.scale });
                try std.json.Stringify.value(o.text, .{}, w);
                try w.writeAll(",\"words\":[");
                for (o.words, 0..) |wd, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.print("{{\"text\":{f},\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d},\"cx\":{d},\"cy\":{d},\"conf\":{d:.0}}}", .{
                        std.json.fmt(wd.text, .{}), wd.x,            wd.y,    wd.w, wd.h,
                        wd.x + wd.w / 2,            wd.y + wd.h / 2, wd.conf,
                    });
                }
                try w.writeAll("]}");
                return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
            },
        }
    }
    if (eql(u8, name, "app_wait_text")) {
        const query = argStr(args, "text") orelse return appErr(arena, "app_wait_text requires 'text'");
        const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
        if (wid == 0) return appErr(arena, "no rendered window yet (try app_wait first)");
        const region = regionFrom(args);
        const scale: u32 = @intCast(std.math.clamp(argInt(args, "scale") orelse 0, 0, 8));
        const psm: i32 = @intCast(std.math.clamp(argInt(args, "psm") orelse 6, 0, 13));
        const lang = argStr(args, "lang") orelse "eng";
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 15_000;
        const do_click = argBool(args, "click");
        const deadline = monoMs() + timeout_ms;
        var seen: ?OcrOut = null;
        var last_text: []const u8 = "";
        while (true) {
            switch (try ocrWindow(arena, app, wid, region, scale, psm, lang)) {
                .out => |o| {
                    last_text = o.text;
                    if (std.ascii.indexOfIgnoreCase(o.text, query) != null) seen = o;
                },
                .err => |e| {
                    if (!std.mem.startsWith(u8, e, "no rendered")) return appErr(arena, e);
                },
            }
            if (seen != null or app.exited or monoMs() >= deadline) break;
            _ = app.waitIdle(std.math.maxInt(i32), 300); // pumped sleep between OCR passes
        }
        const o = seen orelse {
            const tail = if (last_text.len > 500) last_text[last_text.len - 500 ..] else last_text;
            const msg = try std.fmt.allocPrint(arena, "text \"{s}\" not visible before timeout; last OCR read:\n{s}", .{ query, tail });
            return toolResult(arena, msg, true) orelse error.OutOfMemory;
        };
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.print("{{\"found\":true,\"window\":{d}", .{wid});
        if (findWordRun(o.words, query)) |box| {
            try w.print(",\"match\":{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d},\"cx\":{d},\"cy\":{d}}}", .{
                box.x, box.y, box.w, box.h, box.x + box.w / 2, box.y + box.h / 2,
            });
            if (do_click) {
                clickTuned(app, wid, @floatFromInt(box.x + box.w / 2), @floatFromInt(box.y + box.h / 2), 1) catch
                    return appErr(arena, "text found but the click failed (bad window?)");
                _ = app.waitIdle(100, 1_000);
                // Journal as a replayable wait_text step (the macro
                // form of "wait for this label, then click it").
                {
                    var jw: std.Io.Writer.Allocating = .init(arena);
                    const jwr = &jw.writer;
                    jwr.writeAll("{\"wait_text\":{\"text\":") catch return error.OutOfMemory;
                    std.json.Stringify.value(query, .{}, jwr) catch return error.OutOfMemory;
                    jwr.writeAll(",\"click\":true}}") catch return error.OutOfMemory;
                    Journal.record(appIdOf(app), jw.written());
                }
                try w.writeAll(",\"clicked\":true");
            }
        } else if (do_click) {
            try w.writeAll(",\"match\":null,\"clicked\":false,\"note\":\"text visible but OCR gave no clickable word box\"");
        } else {
            try w.writeAll(",\"match\":null");
        }
        try w.writeAll("}");
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_find_image")) {
        const needle = switch (try resolveNeedle(arena, args)) {
            .needle => |nd| nd,
            .err => |e| return appErr(arena, e),
        };
        const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
        if (wid == 0) return appErr(arena, "no rendered window yet (try app_wait first)");
        const min_score = argFloat(args, "min_score") orelse 0.9;
        const max_matches: usize = @intCast(std.math.clamp(argInt(args, "max_matches") orelse 8, 1, 32));
        switch (try findInWindow(arena, app, wid, regionFrom(args), needle, min_score, max_matches)) {
            .err => |e| return appErr(arena, e),
            .matches => |ms| {
                var aw: std.Io.Writer.Allocating = .init(arena);
                const w = &aw.writer;
                try w.print("{{\"template\":{f},\"template_w\":{d},\"template_h\":{d},\"window\":{d},\"matches\":[", .{
                    std.json.fmt(needle.name, .{}), needle.w, needle.h, wid,
                });
                for (ms, 0..) |m, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.print("{{\"x\":{d},\"y\":{d},\"cx\":{d},\"cy\":{d},\"score\":{d:.3}}}", .{ m.x, m.y, m.cx, m.cy, m.score });
                }
                try w.writeAll("]}");
                return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
            },
        }
    }
    if (eql(u8, name, "app_wait_image")) {
        const needle = switch (try resolveNeedle(arena, args)) {
            .needle => |nd| nd,
            .err => |e| return appErr(arena, e),
        };
        const wid: u32 = if (argInt(args, "window")) |v| @intCast(v) else firstToplevelId(app);
        if (wid == 0) return appErr(arena, "no rendered window yet (try app_wait first)");
        const region = regionFrom(args);
        const min_score = argFloat(args, "min_score") orelse 0.9;
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 10_000;
        const do_click = argBool(args, "click");
        const btn: u32 = @intCast(argInt(args, "button") orelse 1);
        const deadline = monoMs() + timeout_ms;
        var found: ?FoundMatch = null;
        while (true) {
            switch (try findInWindow(arena, app, wid, region, needle, min_score, 1)) {
                .matches => |ms| if (ms.len > 0) {
                    found = ms[0];
                },
                .err => {}, // window not rendered yet — keep waiting
            }
            if (found != null or app.exited or monoMs() >= deadline) break;
            _ = app.pumpOnce(50);
        }
        const m = found orelse {
            const msg = try std.fmt.allocPrint(arena, "template \"{s}\" did not appear before timeout", .{needle.name});
            return toolResult(arena, msg, true) orelse error.OutOfMemory;
        };
        var clicked = false;
        if (do_click) {
            clickTuned(app, wid, @floatFromInt(m.cx), @floatFromInt(m.cy), btn) catch
                return appErr(arena, "template matched but the click failed (bad window?)");
            _ = app.waitIdle(100, 1_000);
            clicked = true;
            // Journal as a replayable step (named templates only —
            // an inline image has no stable reference to replay).
            if (!std.mem.eql(u8, needle.name, "(inline)"))
                journalStep(app, "{{\"wait_image\":{{\"template\":\"{s}\",\"click\":true,\"min_score\":{d:.2}}}}}", .{ needle.name, min_score });
        }
        const msg = try std.fmt.allocPrint(arena, "{{\"found\":true,\"window\":{d},\"x\":{d},\"y\":{d},\"cx\":{d},\"cy\":{d},\"score\":{d:.3},\"clicked\":{}}}", .{
            wid, m.x, m.y, m.cx, m.cy, m.score, clicked,
        });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_macro_run")) {
        const mname = argStr(args, "name") orelse return appErr(arena, "app_macro_run requires 'name'");
        const bytes = mcpassets.load(arena, .macro, mname) catch |err| return appErr(arena, switch (err) {
            mcpassets.Error.NotFound => try std.fmt.allocPrint(arena, "no saved macro \"{s}\" (list with app_macros)", .{mname}),
            mcpassets.Error.BadName => "invalid macro name",
            mcpassets.Error.OutOfMemory => return error.OutOfMemory,
            else => "macro load failed",
        });
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch
            return appErr(arena, "stored macro is not valid JSON");
        if (parsed != .object) return appErr(arena, "stored macro is malformed (want {\"actions\":[...]})");
        const av = parsed.object.get("actions") orelse return appErr(arena, "stored macro has no 'actions'");
        if (av != .array or av.array.items.len == 0) return appErr(arena, "stored macro has no steps");
        if (av.array.items.len > 200) return appErr(arena, "macro too long (max 200 steps)");
        const win_arg: ?u32 = if (argInt(args, "window")) |v| @intCast(v) else null;
        const intro = try std.fmt.allocPrint(arena, "replaying macro \"{s}\" ({d} steps)\n", .{ mname, av.array.items.len });
        return runActionSteps(arena, app, av.array.items, win_arg, false, intro);
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
        browser_state.remove(id);
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

/// Spawn + register a headless terminal; returns its id.
fn spawnRegisteredTerm(argv: ?[]const []const u8, cols: u16, rows: u16) !u32 {
    const t = termdrive.Term.spawn(term_state.allocator, argv, cols, rows, term_state.mux_sock) catch
        return error.SpawnFailed;
    const id = term_state.next_id;
    term_state.next_id += 1;
    term_state.terms.put(term_state.allocator, id, t) catch {
        t.deinit();
        return error.OutOfMemory;
    };
    _ = recordRegisteredTerm(t, id);
    return id;
}

/// Last non-empty rendered line of a term's screen (for term_list), or
/// "". Arena-owned.
fn termLastLine(arena: std.mem.Allocator, t: *termdrive.Term) []const u8 {
    const text = t.readScreen(false) catch return "";
    defer term_state.allocator.free(text);
    var it = std.mem.splitBackwardsScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        const cap = @min(trimmed.len, 160);
        return arena.dupe(u8, trimmed[0..cap]) catch "";
    }
    return "";
}

/// Serialize a termdrive exec outcome as the term_exec reply. On a
/// pending outcome the reply carries everything needed to understand a
/// blocked command WITHOUT further calls: the live screen tail, the
/// alt-screen flag, output idleness, an interactive-prompt hint and
/// the tracker id. `output_file` (optional, absolute, local) receives
/// the FULL untruncated output; the inline payload then keeps a tail.
fn execResultJson(arena: std.mem.Allocator, r: termdrive.ExecOutcome, t: *termdrive.Term, output_file: ?[]const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("{{\"completed\":{},\"exit_status\":", .{r.completed});
    if (r.exit_status) |st| try w.print("{d}", .{st}) else try w.writeAll("null");
    try w.print(",\"timed_out\":{},\"truncated\":{},\"shell_died\":{}", .{ r.timed_out, r.truncated, r.shell_died });
    if (r.pending) {
        try w.writeAll(",\"pending\":true");
        if (r.tracker) |nonce| try w.print(",\"tracker\":\"{s}\"", .{nonce});
        try w.print(",\"alt_screen\":{},\"output_idle_ms\":{d},\"interactive_prompt\":{}", .{ r.alt_screen, r.idle_ms, r.interactive_hint });
        // The live rendered screen: an interactive dialog (apt's
        // needrestart, a password ask) must be VISIBLE in the reply,
        // never hidden behind a bare timeout.
        if (t.readScreen(false)) |screen_text| {
            defer term_state.allocator.free(screen_text);
            try w.writeAll(",\"screen\":");
            try std.json.Stringify.value(tailLines(screen_text, 20), .{}, w);
        } else |_| {}
    }
    var file_note: ?[]const u8 = null;
    var inline_out: []const u8 = r.output;
    var inline_cap: usize = 200_000;
    if (output_file) |path| {
        if (path.len == 0 or path[0] != '/') {
            file_note = "output_file must be an absolute local path — ignored, full output inline";
        } else if (writeFileBytes(path, r.output)) {
            try w.writeAll(",\"output_file\":");
            try std.json.Stringify.value(path, .{}, w);
            try w.print(",\"output_bytes\":{d}", .{r.output.len});
            inline_cap = 2_000;
        } else {
            file_note = "output_file could not be written (dir missing / not writable?) — full output inline";
        }
    }
    if (inline_out.len > inline_cap) {
        try w.print(",\"output_dropped_chars\":{d}", .{inline_out.len - inline_cap});
        inline_out = inline_out[inline_out.len - inline_cap ..];
    }
    try w.writeAll(",\"output\":");
    try std.json.Stringify.value(inline_out, .{}, w);
    if (file_note) |n| {
        try w.writeAll(",\"output_file_note\":");
        try std.json.Stringify.value(n, .{}, w);
    }
    if (r.pending and r.interactive_hint) {
        try w.writeAll(",\"reason\":\"the command appears to be WAITING FOR INPUT (see screen) — answer it with term_send_text/term_send_keys; the tracker stays attached and term_exec_wait picks up the completion afterwards\"");
    } else if (r.pending) {
        try w.writeAll(",\"reason\":\"still running — continue with term_exec_wait (do not resend); the tracker survives client-side timeouts and aborts\"");
    }
    if (r.shell_died) try w.writeAll(",\"reason\":\"the shell/connection died before the command finished\"");
    try w.writeAll("}");
    return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
}

/// A safe interpreter name/path for term_exec's `shell` option: it is
/// interpolated into the transport script, so it must not carry shell
/// metacharacters.
fn validShellName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    if (std.mem.indexOf(u8, s, "..") != null) return false;
    for (s) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-' or ch == '/';
        if (!ok) return false;
    }
    return true;
}

test "validShellName" {
    const t = std.testing;
    try t.expect(validShellName("bash"));
    try t.expect(validShellName("/usr/bin/zsh"));
    try t.expect(validShellName("busybox-sh"));
    try t.expect(!validShellName(""));
    try t.expect(!validShellName("bash; rm -rf /"));
    try t.expect(!validShellName("bash $(x)"));
    try t.expect(!validShellName("../../bin/sh"));
}

/// Write bytes to an absolute local path; false on any failure.
fn writeFileBytes(path: []const u8, bytes: []const u8) bool {
    var pbuf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&pbuf, "{s}", .{path}) catch return false;
    const f = c.fopen(path_z.ptr, "wb") orelse return false;
    const n = if (bytes.len == 0) 0 else c.fwrite(bytes.ptr, 1, bytes.len, f);
    const bad = c.fclose(f) != 0;
    return n == bytes.len and !bad;
}

fn termTool(arena: std.mem.Allocator, name: []const u8, args: std.json.Value) ![]const u8 {
    const eql = std.mem.eql;
    if (term_state.mux_sock == null)
        return appErr(arena, "headless terminal tools need isolated mode; in --shared mode use the GUI-backed terminal tools (list_terminals, run_command, ...)");

    if (eql(u8, name, "term_open")) {
        const cols: u16 = @intCast(std.math.clamp(argInt(args, "cols") orelse 120, 10, 500));
        const rows: u16 = @intCast(std.math.clamp(argInt(args, "rows") orelse 40, 4, 300));
        var argv_store: std.ArrayList([]const u8) = .empty;
        defer argv_store.deinit(arena);
        const host = argStr(args, "host");
        if (host) |h| {
            // Persistent SSH session with keepalives: survives long
            // provisioning waits; interactive (auth prompts reach the
            // screen — drive them with term_send_text).
            try argv_store.appendSlice(arena, &.{
                "ssh", "-tt",
                "-o",  "ServerAliveInterval=15",
                "-o",  "ServerAliveCountMax=4",
            });
            try argv_store.append(arena, h);
        }
        if (args == .object) {
            if (args.object.get("command")) |cmd| switch (cmd) {
                .string => {
                    if (host != null) {
                        try argv_store.append(arena, cmd.string);
                    } else {
                        try argv_store.appendSlice(arena, &.{ "/bin/sh", "-c", cmd.string });
                    }
                },
                .array => {
                    for (cmd.array.items) |item| {
                        if (item != .string) return appErr(arena, "command array must be strings");
                        try argv_store.append(arena, item.string);
                    }
                },
                else => {},
            };
        }
        const argv: ?[]const []const u8 = if (argv_store.items.len > 0) argv_store.items else null;
        const id = spawnRegisteredTerm(argv, cols, rows) catch |err| switch (err) {
            error.SpawnFailed => return appErr(arena, "spawn failed (mux daemon unreachable?)"),
            else => return err,
        };
        const t = term_state.terms.get(id).?;
        // Let the shell print its first prompt.
        _ = t.waitIdle(250, 3_000);
        const where = if (host) |h|
            try std.fmt.allocPrint(arena, " running ssh to {s} (watch term_read for auth prompts; term_exec gives structured remote command results)", .{h})
        else
            "";
        const rec_note = if (rec_state.casts.get(id)) |p|
            try std.fmt.allocPrint(arena, "\nrecording: {s} (asciicast v2, replayable with asciinema)", .{p})
        else
            "";
        const msg = try std.fmt.allocPrint(arena, "opened headless terminal {d} ({d}x{d}){s}{s}", .{ id, cols, rows, where, rec_note });
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
            t.drain();
            try w.print("{{\"term\":{d},\"exited\":{}", .{ e.key_ptr.*, t.exited });
            if (t.exited and t.exit_status_known) try w.print(",\"exit_status\":{d}", .{t.exit_status});
            if (t.hasPendingCommand()) try w.writeAll(",\"pending_command\":true");
            if (t.hasPendingExec()) try w.writeAll(",\"pending_exec\":true");
            const last = termLastLine(arena, t);
            if (last.len > 0) {
                try w.writeAll(",\"last_line\":");
                try std.json.Stringify.value(last, .{}, w);
            }
            if (rec_state.casts.get(e.key_ptr.*)) |p| {
                try w.writeAll(",\"recording\":");
                try std.json.Stringify.value(p, .{}, w);
            }
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
        t.drain();
        const sb = argBool(args, "scrollback");
        const text = t.readScreen(sb) catch return appErr(arena, "read failed (terminal exited?)");
        defer term_state.allocator.free(text);
        if (t.exited) {
            // Make an exited terminal's state unambiguous: the final
            // rendered frame plus the real exit status, so a stale
            // progress line (scp "1%") cannot be mistaken for truth.
            const msg = if (t.exit_status_known)
                try std.fmt.allocPrint(arena, "[process exited with status {d} — final rendered screen below]\n{s}", .{ t.exit_status, text })
            else
                try std.fmt.allocPrint(arena, "[process exited (status unknown) — final rendered screen below]\n{s}", .{text});
            return toolResult(arena, msg, false) orelse error.OutOfMemory;
        }
        return toolResult(arena, try arena.dupe(u8, text), false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "term_exec")) {
        const cmd = argStr(args, "command") orelse return appErr(arena, "term_exec requires 'command'");
        // Clamped below the 150s watchdog: one blocked call must never
        // wedge the single-threaded loop long enough to starve
        // term_list/term_read or trip the connection-aborting cap.
        // Longer waits = repeated term_exec_wait calls.
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
        // Default true: the isolated transport works typed into ANY
        // shell dialect (fish/zsh/bash, local or remote); false is the
        // POSIX-only state-persisting mode.
        const subshell = if (args == .object) blk: {
            const v = args.object.get("subshell") orelse break :blk true;
            break :blk v == .bool and v.bool;
        } else true;
        const noninteractive = argBool(args, "noninteractive");
        if (noninteractive and !subshell)
            return appErr(arena, "'noninteractive' needs the default isolated transport (drop subshell:false)");
        const shell = argStr(args, "shell");
        if (shell) |sh| {
            if (!subshell)
                return appErr(arena, "'shell' needs the default isolated transport (drop subshell:false)");
            if (!validShellName(sh))
                return appErr(arena, "invalid 'shell' (a command name or absolute path: letters, digits, . _ - / only)");
        }
        if (t.hasPendingExec()) {
            // A previously timed-out exec may have finished since;
            // resolve it silently so the new send is accepted.
            if (t.waitExecResult(0)) |r0| term_state.allocator.free(r0.output);
            if (t.hasPendingExec())
                return appErr(arena, "a previous term_exec is still running in this terminal; continue it with term_exec_wait (or interrupt with term_send_keys ctrl+c)");
        }
        if (t.hasPendingCommand())
            return appErr(arena, "a term_run wait_for=command command is still tracked; resolve it with term_wait_command first");
        const r = t.execCommand(cmd, subshell, noninteractive, shell, timeout_ms) catch |err| return appErr(arena, switch (err) {
            termdrive.Error.NotConnected => "terminal exited",
            else => "exec failed",
        });
        defer term_state.allocator.free(r.output);
        return execResultJson(arena, r, t, argStr(args, "output_file"));
    }
    if (eql(u8, name, "term_exec_wait")) {
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
        const r = t.waitExecResult(timeout_ms) orelse
            return appErr(arena, "no pending term_exec in this terminal");
        defer term_state.allocator.free(r.output);
        return execResultJson(arena, r, t, argStr(args, "output_file"));
    }
    if (eql(u8, name, "term_wait_exit")) {
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
        const exited = t.waitExit(timeout_ms);
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.print("{{\"exited\":{}", .{exited});
        if (exited and t.exit_status_known) try w.print(",\"exit_status\":{d}", .{t.exit_status});
        if (!exited) try w.writeAll(",\"timed_out\":true");
        const tail = blk: {
            const text = t.readScreen(false) catch break :blk "";
            defer term_state.allocator.free(text);
            break :blk try arena.dupe(u8, tailLines(text, 8));
        };
        if (tail.len > 0) {
            try w.writeAll(",\"screen_tail\":");
            try std.json.Stringify.value(tail, .{}, w);
        }
        try w.writeAll("}");
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "term_run")) {
        const cmd = argStr(args, "command") orelse return appErr(arena, "term_run requires 'command'");
        const quiet_ms: i64 = argInt(args, "quiet_ms") orelse 400;
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
        const wait_for = argStr(args, "wait_for") orelse "idle";
        if (!eql(u8, wait_for, "idle") and !eql(u8, wait_for, "command"))
            return appErr(arena, "wait_for must be 'idle' or 'command'");
        if (eql(u8, wait_for, "command")) {
            // A tracked command may have completed since its timeout:
            // one short drain clears it so the new send is accepted.
            if (t.hasPendingCommand()) _ = t.waitPendingCommand(0);
            if (t.hasPendingCommand()) {
                return commandCompletionResult(arena, .{ .state = .running }, false, null, null, "a previously timed-out command is still running; use term_wait_command instead of resending");
            }
            // The token wait spends from the same budget as the
            // completion wait, so the call never outlives timeout_ms.
            const started = monoMs();
            const token_res = t.commandToken(@min(timeout_ms, 10_000)) catch return appErr(arena, "command completion unavailable (terminal exited?)");
            const token = switch (token_res) {
                .unsupported => return commandCompletionResult(arena, .{ .state = .unsupported }, false, null, null, "shell integration is unavailable for this shell; command was not sent and no exit status was fabricated"),
                .not_ready => return commandCompletionResult(arena, .{ .state = .unsupported, .timed_out = true }, false, null, null, "shell integration is injected but no prompt mark has arrived yet (shell still starting, or its rc files broke the injection); command was not sent — retry shortly"),
                .busy => return commandCompletionResult(arena, .{ .state = .running }, false, null, null, "a foreground command started outside command mode is still running; its completion would be misattributed. Wait for it (term_wait_idle) before sending in command mode"),
                .token => |tok| tok,
            };
            const line = try std.fmt.allocPrint(arena, "{s}\r", .{cmd});
            t.sendText(line) catch return appErr(arena, "send failed (terminal exited?)");
            t.trackCommand(token);
            const result = t.waitCommand(token, @max(0, timeout_ms - (monoMs() - started)));

            var owned_output: ?[]u8 = null;
            defer if (owned_output) |text| term_state.allocator.free(text);
            var output_kind: []const u8 = "screen";
            if (result.state == .completed and result.source == .shell_integration and argBool(args, "output_only")) {
                if (t.lastCommand() catch null) |lc| {
                    owned_output = lc.text;
                    output_kind = "command";
                }
            }
            if (owned_output == null) {
                owned_output = t.readScreen(false) catch null;
            }
            return commandCompletionResult(arena, result, true, owned_output, output_kind, switch (result.state) {
                .running => "timeout expired while the command was still running; output may have been idle",
                .unknown => "terminal disconnected before a reliable completion status was received",
                .unsupported => unreachable,
                .completed => null,
            });
        }
        // Idle mode must not run a NEW command while a command-mode
        // token is unresolved: the interloper's OSC 133 D would be
        // reported by term_wait_command as the tracked command's exit.
        if (t.hasPendingCommand()) _ = t.waitPendingCommand(0);
        if (t.hasPendingCommand())
            return appErr(arena, "a command-mode command is still being tracked; resolve it with term_wait_command before running another command, or its exit status would be misattributed");
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
    if (eql(u8, name, "term_wait_command")) {
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
        const result = t.waitPendingCommand(timeout_ms) orelse
            return appErr(arena, "no timed-out command is being tracked");
        var owned_output: ?[]u8 = null;
        defer if (owned_output) |text| term_state.allocator.free(text);
        var output_kind: []const u8 = "screen";
        if (result.state == .completed and result.source == .shell_integration and argBool(args, "output_only")) {
            if (t.lastCommand() catch null) |lc| {
                owned_output = lc.text;
                output_kind = "command";
            }
        }
        if (owned_output == null) owned_output = t.readScreen(false) catch null;
        return commandCompletionResult(arena, result, true, owned_output, output_kind, switch (result.state) {
            .running => "timeout expired while the command was still running; output may have been idle",
            .unknown => "terminal disconnected before a reliable completion status was received",
            .unsupported => unreachable,
            .completed => null,
        });
    }
    if (eql(u8, name, "term_wait_idle")) {
        const quiet_ms: i64 = argInt(args, "quiet_ms") orelse 500;
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
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
        // The daemon finalizes the cast with the session; keep the
        // path out of future term_list output.
        if (rec_state.casts.fetchSwapRemove(id)) |kv| rec_state.allocator.free(kv.value);
        return toolResult(arena, "terminal closed", false) orelse error.OutOfMemory;
    }
    return appErr(arena, "unknown tool");
}

// ── File transfer + port forwards ─────────────────────────────────

/// Streaming SHA-256 of a local file; null when unreadable.
fn sha256File(path: []const u8) ?[64]u8 {
    var pbuf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&pbuf, "{s}", .{path}) catch return null;
    const f = c.fopen(path_z.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    var hex: [64]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[i * 2] = alphabet[b >> 4];
        hex[i * 2 + 1] = alphabet[b & 0xf];
    }
    return hex;
}

fn fileSize(path: []const u8) ?u64 {
    var pbuf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&pbuf, "{s}", .{path}) catch return null;
    var st: c.struct_stat = undefined;
    if (c.stat(path_z.ptr, &st) != 0) return null;
    return @intCast(@max(st.st_size, 0));
}

/// Local copy with checksum + atomic rename (the host==null transfer path).
fn localCopyAtomic(arena: std.mem.Allocator, src: []const u8, dst: []const u8) !union(enum) { ok: struct { bytes: u64, sha: [64]u8 }, err: []const u8 } {
    var sbuf: [4096]u8 = undefined;
    const src_z = std.fmt.bufPrintZ(&sbuf, "{s}", .{src}) catch return .{ .err = "path too long" };
    const part = try std.fmt.allocPrint(arena, "{s}.sketerm-part", .{dst});
    var dbuf: [4096]u8 = undefined;
    const part_z = std.fmt.bufPrintZ(&dbuf, "{s}", .{part}) catch return .{ .err = "path too long" };
    const in = c.fopen(src_z.ptr, "rb") orelse return .{ .err = "cannot read the source file" };
    defer _ = c.fclose(in);
    const out = c.fopen(part_z.ptr, "wb") orelse return .{ .err = "cannot write the destination (parent dir missing or not writable?)" };
    var total: u64 = 0;
    var buf: [65536]u8 = undefined;
    var write_failed = false;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, in);
        if (n == 0) break;
        if (c.fwrite(&buf, 1, n, out) != n) {
            write_failed = true;
            break;
        }
        total += n;
    }
    const flush_bad = c.fclose(out) != 0;
    if (write_failed or flush_bad) {
        _ = c.unlink(part_z.ptr);
        return .{ .err = "short write copying the file (disk full?)" };
    }
    const src_sha = sha256File(src) orelse return .{ .err = "cannot hash the source file" };
    const part_sha = sha256File(part) orelse return .{ .err = "cannot hash the copied file" };
    if (!std.mem.eql(u8, &src_sha, &part_sha)) {
        _ = c.unlink(part_z.ptr);
        return .{ .err = "checksum mismatch after local copy" };
    }
    var fbuf: [4096]u8 = undefined;
    const dst_z = std.fmt.bufPrintZ(&fbuf, "{s}", .{dst}) catch return .{ .err = "path too long" };
    if (c.rename(part_z.ptr, dst_z.ptr) != 0) {
        _ = c.unlink(part_z.ptr);
        return .{ .err = "atomic rename to the destination failed" };
    }
    return .{ .ok = .{ .bytes = total, .sha = src_sha } };
}

/// Ask the kernel for a free loopback TCP port.
fn pickFreePort() ?u16 {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = 0;
    _ = c.inet_pton(c.AF_INET, "127.0.0.1", &addr.sin_addr);
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) != 0) return null;
    var out: c.struct_sockaddr_in = undefined;
    var olen: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
    if (c.getsockname(fd, @ptrCast(&out), &olen) != 0) return null;
    const port = std.mem.bigToNative(u16, out.sin_port);
    if (port == 0) return null;
    return port;
}

/// Can something be connected to on 127.0.0.1:port right now?
fn tcpListening(port: u16, timeout_ms: i64) bool {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
    var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = c.htons(port);
    _ = c.inet_pton(c.AF_INET, "127.0.0.1", &addr.sin_addr);
    const rc = c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in));
    if (rc == 0) return true;
    if (std.posix.errno(rc) != .INPROGRESS) return false;
    var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLOUT, .revents = 0 };
    if (c.poll(&pfd, 1, @intCast(std.math.clamp(timeout_ms, 1, 30_000))) <= 0) return false;
    var so_err: c_int = 0;
    var slen: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &so_err, &slen) != 0) return false;
    return so_err == 0;
}

/// Run a short-lived argv (scp / ssh command) in an unregistered
/// headless terminal, wait for its exit, and hand back status + the
/// rendered output. `.output` is arena-owned.
const ArgvRun = struct { exited: bool, status: i32, status_known: bool, output: []const u8 };
fn runArgvTerm(arena: std.mem.Allocator, argv: []const []const u8, timeout_ms: i64) !union(enum) { run: ArgvRun, err: []const u8 } {
    const t = termdrive.Term.spawn(term_state.allocator, argv, 120, 30, term_state.mux_sock) catch
        return .{ .err = "spawn failed (mux daemon unreachable?)" };
    defer t.deinit();
    recordAuxTerm(t, std.fs.path.basename(argv[0]));
    const exited = t.waitExit(timeout_ms);
    const output = blk: {
        const text = t.readScreen(true) catch break :blk "";
        defer term_state.allocator.free(text);
        break :blk try arena.dupe(u8, std.mem.trim(u8, text, "\n "));
    };
    return .{ .run = .{
        .exited = exited,
        .status = t.exit_status,
        .status_known = t.exit_status_known,
        .output = output,
    } };
}

/// Shell-quote into an arena string.
fn quoted(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(arena);
    try shellquote.appendQuoted(&list, arena, s);
    return arena.dupe(u8, list.items);
}

/// Staged-transfer temp name that PRESERVES the file extension, so
/// suffix-sensitive validators (systemd-analyze verify needs .service)
/// accept the staged file: "a/b.service" → "a/b.sketerm-part.service";
/// extensionless paths get a plain ".sketerm-part" suffix.
fn stagedPartPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const base_start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| s + 1 else 0;
    const base = path[base_start..];
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        if (dot > 0 and dot + 1 < base.len) {
            return std.fmt.allocPrint(arena, "{s}{s}.sketerm-part.{s}", .{ path[0..base_start], base[0..dot], base[dot + 1 ..] });
        }
    }
    return std.fmt.allocPrint(arena, "{s}.sketerm-part", .{path});
}

/// Wrap a POSIX script for execution on a REMOTE host regardless of
/// the login shell sshd hands it to (fish included): base64 → sh.
fn remoteShLine(arena: std.mem.Allocator, script: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const b64 = try arena.alloc(u8, enc.calcSize(script.len));
    _ = enc.encode(b64, script);
    return std.fmt.allocPrint(arena, "echo {s} | base64 -d | sh", .{b64});
}

/// Find a 64-char lowercase-hex token in text (remote sha output).
fn findHex64(text: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 64 <= text.len) : (i += 1) {
        var ok = true;
        var j: usize = 0;
        while (j < 64) : (j += 1) {
            const ch = text[i + j];
            if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) {
                ok = false;
                break;
            }
        }
        if (ok) {
            // Must not be part of a longer run.
            const before_ok = i == 0 or !std.ascii.isHex(text[i - 1]);
            const after_ok = i + 64 == text.len or !std.ascii.isHex(text[i + 64]);
            if (before_ok and after_ok) return text[i .. i + 64];
        }
    }
    return null;
}

fn xferOk(arena: std.mem.Allocator, direction: []const u8, path: []const u8, bytes: ?u64, sha: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("{{\"ok\":true,\"direction\":\"{s}\",\"path\":", .{direction});
    try std.json.Stringify.value(path, .{}, w);
    if (bytes) |b| try w.print(",\"bytes\":{d}", .{b});
    try w.print(",\"sha256\":\"{s}\",\"verified\":true,\"atomic\":true}}", .{sha});
    return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
}

fn xferTool(arena: std.mem.Allocator, name: []const u8, args: std.json.Value) ![]const u8 {
    const eql = std.mem.eql;
    if (term_state.mux_sock == null)
        return appErr(arena, "file transfer / port forward tools need isolated mode (they run over private headless terminals)");

    if (eql(u8, name, "upload_file") or eql(u8, name, "download_file")) {
        const upload = eql(u8, name, "upload_file");
        const local = argStr(args, "local_path") orelse return appErr(arena, "requires 'local_path'");
        const remote = argStr(args, "remote_path") orelse return appErr(arena, "requires 'remote_path'");
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 120_000;
        const host = argStr(args, "host");

        if (host == null) {
            const src = if (upload) local else remote;
            const dst = if (upload) remote else local;
            switch (try localCopyAtomic(arena, src, dst)) {
                .ok => |r| return xferOk(arena, if (upload) "upload" else "download", dst, r.bytes, &r.sha),
                .err => |e| return appErr(arena, e),
            }
        }
        const h = host.?;

        if (upload) {
            const local_sha = sha256File(local) orelse return appErr(arena, "cannot read/hash the local file");
            const bytes = fileSize(local);
            const tmp = try stagedPartPath(arena, remote);
            const spec = try std.fmt.allocPrint(arena, "{s}:{s}", .{ h, tmp });
            switch (try runArgvTerm(arena, &.{ "scp", "-q", "-o", "BatchMode=yes", local, spec }, timeout_ms)) {
                .err => |e| return appErr(arena, e),
                .run => |r| {
                    if (!r.exited) return appErr(arena, "scp still running at timeout; the transfer terminal was killed — retry with a larger timeout_ms");
                    if (!r.status_known or r.status != 0)
                        return appErr(arena, try std.fmt.allocPrint(arena, "scp failed (status {d}):\n{s}", .{ r.status, r.output }));
                },
            }
            // Checksum + optional caller validation + atomic move in
            // ONE remote script (b64→sh so the remote login shell's
            // dialect is irrelevant); echo tokens report the branch.
            var verify_layer: []const u8 = "mv -f \"$SK_TMP\" \"$SK_DST\" && echo SK_MOVED || echo SK_MVFAIL";
            if (argStr(args, "verify_command")) |vc| {
                // "{}" marks where the staged path goes; without it
                // the path is appended as the final argument.
                const resolved = if (std.mem.indexOf(u8, vc, "{}")) |at|
                    try std.fmt.allocPrint(arena, "{s}\"$SK_TMP\"{s}", .{ vc[0..at], vc[at + 2 ..] })
                else
                    try std.fmt.allocPrint(arena, "{s} \"$SK_TMP\"", .{vc});
                verify_layer = try std.fmt.allocPrint(
                    arena,
                    "if ( {s} ); then mv -f \"$SK_TMP\" \"$SK_DST\" && echo SK_MOVED || echo SK_MVFAIL; else echo \"SK_VERIFYFAIL:$?\"; rm -f \"$SK_TMP\"; fi",
                    .{resolved},
                );
            }
            const script = try std.fmt.allocPrint(
                arena,
                "SK_TMP={s}\nSK_DST={s}\nsha=$(sha256sum \"$SK_TMP\" 2>/dev/null | cut -c1-64) || sha=fail\nif [ \"$sha\" = \"{s}\" ]; then {s}; else echo \"SK_SHA:$sha\"; rm -f \"$SK_TMP\"; fi\n",
                .{ try quoted(arena, tmp), try quoted(arena, remote), local_sha, verify_layer },
            );
            switch (try runArgvTerm(arena, &.{ "ssh", "-o", "BatchMode=yes", h, try remoteShLine(arena, script) }, 60_000)) {
                .err => |e| return appErr(arena, e),
                .run => |r| {
                    if (std.mem.indexOf(u8, r.output, "SK_MOVED") != null)
                        return xferOk(arena, "upload", remote, bytes, &local_sha);
                    if (std.mem.indexOf(u8, r.output, "SK_VERIFYFAIL") != null)
                        return appErr(arena, try std.fmt.allocPrint(arena, "verify_command rejected the staged file — upload discarded, destination untouched:\n{s}", .{r.output}));
                    if (std.mem.indexOf(u8, r.output, "SK_MVFAIL") != null)
                        return appErr(arena, "checksum verified but the atomic move failed on the remote (target dir not writable?)");
                    if (std.mem.indexOf(u8, r.output, "SK_SHA:fail") != null)
                        return appErr(arena, "remote has no usable sha256sum — cannot verify; file left absent (partial removed)");
                    return appErr(arena, try std.fmt.allocPrint(arena, "remote checksum mismatch — corrupt transfer discarded:\n{s}", .{r.output}));
                },
            }
        }

        // download
        const part = try stagedPartPath(arena, local);
        const spec = try std.fmt.allocPrint(arena, "{s}:{s}", .{ h, remote });
        switch (try runArgvTerm(arena, &.{ "scp", "-q", "-o", "BatchMode=yes", spec, part }, timeout_ms)) {
            .err => |e| return appErr(arena, e),
            .run => |r| {
                if (!r.exited) return appErr(arena, "scp still running at timeout; the transfer terminal was killed — retry with a larger timeout_ms");
                if (!r.status_known or r.status != 0)
                    return appErr(arena, try std.fmt.allocPrint(arena, "scp failed (status {d}):\n{s}", .{ r.status, r.output }));
            },
        }
        const part_sha = sha256File(part) orelse return appErr(arena, "downloaded file vanished before hashing");
        const bytes = fileSize(part);
        const script = try std.fmt.allocPrint(arena, "sha256sum {s} 2>/dev/null | cut -c1-64\n", .{try quoted(arena, remote)});
        switch (try runArgvTerm(arena, &.{ "ssh", "-o", "BatchMode=yes", h, try remoteShLine(arena, script) }, 30_000)) {
            .err => |e| return appErr(arena, e),
            .run => |r| {
                const remote_sha = findHex64(r.output) orelse
                    return appErr(arena, try std.fmt.allocPrint(arena, "remote sha256sum gave no hash — cannot verify (partial kept at {s}):\n{s}", .{ part, r.output }));
                if (!std.mem.eql(u8, remote_sha, &part_sha)) {
                    var pbuf: [4096]u8 = undefined;
                    if (std.fmt.bufPrintZ(&pbuf, "{s}", .{part})) |pz| _ = c.unlink(pz.ptr) else |_| {}
                    return appErr(arena, "checksum mismatch — corrupt download discarded");
                }
            },
        }
        var pbuf: [4096]u8 = undefined;
        var dbuf: [4096]u8 = undefined;
        const part_z = std.fmt.bufPrintZ(&pbuf, "{s}", .{part}) catch return appErr(arena, "path too long");
        const local_z = std.fmt.bufPrintZ(&dbuf, "{s}", .{local}) catch return appErr(arena, "path too long");
        if (c.rename(part_z.ptr, local_z.ptr) != 0)
            return appErr(arena, "atomic rename into place failed");
        return xferOk(arena, "download", local, bytes, &part_sha);
    }

    if (eql(u8, name, "port_forward_open")) {
        const h = argStr(args, "host") orelse return appErr(arena, "port_forward_open requires 'host'");
        const rp_i = argInt(args, "remote_port") orelse return appErr(arena, "port_forward_open requires 'remote_port'");
        if (rp_i < 1 or rp_i > 65535) return appErr(arena, "remote_port out of range");
        const rp: u16 = @intCast(rp_i);
        const rh = argStr(args, "remote_host") orelse "127.0.0.1";
        const lp: u16 = if (argInt(args, "local_port")) |v| blk: {
            if (v < 1 or v > 65535) return appErr(arena, "local_port out of range");
            break :blk @intCast(v);
        } else pickFreePort() orelse return appErr(arena, "could not pick a free local port");
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 20_000;

        const t = spawnForwardTerm(arena, h, lp, rh, rp) catch
            return appErr(arena, "spawn failed (mux daemon unreachable?)");
        switch (try waitForwardReady(arena, t, lp, timeout_ms)) {
            .ready => {},
            .err => |e| {
                t.deinit();
                return appErr(arena, e);
            },
        }
        const a = forward_state.allocator;
        const f = a.create(Forward) catch {
            t.deinit();
            return error.OutOfMemory;
        };
        f.* = .{
            .id = forward_state.next_id,
            .host = a.dupe(u8, h) catch return error.OutOfMemory,
            .local_port = lp,
            .remote_host = a.dupe(u8, rh) catch return error.OutOfMemory,
            .remote_port = rp,
            .term = t,
        };
        forward_state.next_id += 1;
        forward_state.forwards.put(a, f.id, f) catch {
            t.deinit();
            return error.OutOfMemory;
        };
        const msg = try std.fmt.allocPrint(arena, "{{\"forward\":{d},\"local_port\":{d},\"remote\":\"{s}:{d}\",\"host\":\"{s}\",\"listening\":true}}", .{ f.id, lp, rh, rp, h });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "port_forward_list")) {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("[");
        for (forward_state.forwards.values(), 0..) |f, i| {
            if (i > 0) try w.writeAll(",");
            f.term.drain();
            try w.print("{{\"forward\":{d},\"host\":\"{s}\",\"local_port\":{d},\"remote\":\"{s}:{d}\",\"alive\":{},\"reconnects\":{d}}}", .{ f.id, f.host, f.local_port, f.remote_host, f.remote_port, !f.term.exited, f.reconnects });
        }
        try w.writeAll("]");
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }

    const f = forwardFromArgs(args) orelse
        return appErr(arena, "no such forward (pass 'forward' from port_forward_open, or omit it when only one is open)");

    if (eql(u8, name, "port_forward_check")) {
        f.term.drain();
        var reconnected = false;
        if (f.term.exited) {
            // The ssh process died (network blip, sshd restart):
            // respawn the same spec — this IS the reconnect behavior.
            const nt = spawnForwardTerm(arena, f.host, f.local_port, f.remote_host, f.remote_port) catch
                return appErr(arena, "forward is dead and respawn failed (mux daemon unreachable?)");
            switch (try waitForwardReady(arena, nt, f.local_port, argInt(args, "timeout_ms") orelse 20_000)) {
                .ready => {
                    f.term.deinit();
                    f.term = nt;
                    f.reconnects += 1;
                    reconnected = true;
                },
                .err => |e| {
                    nt.deinit();
                    return appErr(arena, try std.fmt.allocPrint(arena, "forward is dead and the reconnect failed: {s}", .{e}));
                },
            }
        }
        const listening = tcpListening(f.local_port, 2_000);
        const msg = try std.fmt.allocPrint(arena, "{{\"forward\":{d},\"alive\":{},\"listening\":{},\"reconnected\":{},\"local_port\":{d}}}", .{ f.id, !f.term.exited, listening, reconnected, f.local_port });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "port_forward_close")) {
        forward_state.removeOne(f);
        return toolResult(arena, "forward closed", false) orelse error.OutOfMemory;
    }
    return appErr(arena, "unknown tool");
}

fn spawnForwardTerm(arena: std.mem.Allocator, host: []const u8, lp: u16, rh: []const u8, rp: u16) !*termdrive.Term {
    const bindspec = try std.fmt.allocPrint(arena, "127.0.0.1:{d}:{s}:{d}", .{ lp, rh, rp });
    const argv = [_][]const u8{
        "ssh",                      "-N",
        "-T",                       "-o",
        "BatchMode=yes",            "-o",
        "ExitOnForwardFailure=yes", "-o",
        "ServerAliveInterval=15",   "-o",
        "ServerAliveCountMax=4",    "-L",
        bindspec,                   host,
    };
    const t = termdrive.Term.spawn(term_state.allocator, &argv, 120, 30, term_state.mux_sock) catch return error.SpawnFailed;
    recordAuxTerm(t, "forward");
    return t;
}

fn waitForwardReady(arena: std.mem.Allocator, t: *termdrive.Term, lp: u16, timeout_ms: i64) !union(enum) { ready, err: []const u8 } {
    const deadline = monoMs() + timeout_ms;
    while (true) {
        t.drain();
        if (t.exited) {
            const tail = blk: {
                const text = t.readScreen(false) catch break :blk "";
                defer term_state.allocator.free(text);
                break :blk try arena.dupe(u8, tailLines(text, 6));
            };
            return .{ .err = try std.fmt.allocPrint(arena, "ssh exited (status {d}) before the forward came up:\n{s}", .{ t.exit_status, tail }) };
        }
        if (tcpListening(lp, 300)) return .ready;
        if (monoMs() >= deadline) {
            const tail = blk: {
                const text = t.readScreen(false) catch break :blk "";
                defer term_state.allocator.free(text);
                break :blk try arena.dupe(u8, tailLines(text, 6));
            };
            return .{ .err = try std.fmt.allocPrint(arena, "the local forward port never started listening within the timeout (auth failure? host unreachable?):\n{s}", .{tail}) };
        }
        _ = t.pumpOnce(200);
    }
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
fn chromiumFamily(arg0: []const u8) bool {
    const base = std.fs.path.basename(arg0);
    const prefixes = [_][]const u8{ "chromium", "chrome", "google-chrome", "brave", "vivaldi", "microsoft-edge", "opera", "electron" };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, base, p)) return true;
    }
    return false;
}

fn findBrowserBinary(arena: std.mem.Allocator) ?[]const u8 {
    for (BROWSER_CANDIDATES) |cand| {
        if (findExecutable(arena, cand)) |p| return p;
    }
    return null;
}

fn capabilitiesTool(arena: std.mem.Allocator) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("{{\"mode\":\"{s}\",\"gui_socket\":{},\"headless_terminals\":{},\"transfers_and_forwards\":{}", .{
        srv_mode, srv_gui_socket, term_state.mux_sock != null, term_state.mux_sock != null,
    });
    const ocr_ok = ocr.available();
    try w.print(",\"ocr\":{}", .{ocr_ok});
    if (!ocr_ok) try w.writeAll(",\"ocr_hint\":\"app_read_text/app_wait_text need libtesseract — install tesseract + tesseract-data-eng on THIS machine\"");
    if (findBrowserBinary(arena)) |bp| {
        try w.writeAll(",\"browser\":");
        try std.json.Stringify.value(bp, .{}, w);
        try w.writeAll(",\"browser_hint\":\"browser_open launches it headless with CDP DOM access (browser_read/click/fill/wait)\"");
    } else {
        try w.writeAll(",\"browser\":null,\"browser_hint\":\"no Chromium-family binary on PATH — browser_* tools unavailable; install chromium\"");
    }
    try w.print(",\"ssh\":{},\"scp\":{}", .{ findExecutable(arena, "ssh") != null, findExecutable(arena, "scp") != null });
    if (rec_state.enabled) {
        try w.writeAll(",\"terminal_recordings\":");
        if (recDir()) |d| try std.json.Stringify.value(d, .{}, w) else try w.writeAll("null");
        try w.writeAll(",\"recordings_hint\":\"every headless terminal is auto-recorded as an asciicast v2 .cast file there (replay with asciinema play)\"");
    } else {
        try w.writeAll(",\"terminal_recordings\":null");
    }
    // Effective input-timing defaults, with any env override marked —
    // config-set defaults must never be invisible state.
    try w.writeAll(",\"input_tuning\":{");
    var any_override = false;
    for (Tuning.all(), 0..) |item, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\"{s}\":{{\"value\":{d},\"built_in\":{d},\"overridden\":{}}}", .{ item.name, item.value, item.built_in, item.overridden });
        if (item.overridden) any_override = true;
    }
    try w.writeAll("}");
    if (any_override) try w.writeAll(",\"input_tuning_hint\":\"values marked overridden were set via SKETERM_MCP_* env (project .mcp.json); the tools/list descriptions already state these effective defaults\"");
    try w.print(",\"open_terms\":{d},\"open_apps\":{d},\"open_forwards\":{d},\"browser_sessions\":{d}}}", .{
        term_state.terms.count(), app_state.apps.count(), forward_state.forwards.count(), browser_state.sessions.count(),
    });
    return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
}

// ── Browser automation (CDP) ─────────────────────────────────────
//
// browser_open launches a Chromium-family binary headlessly under the
// Wayland session with --remote-debugging-port=0, discovers the real
// DevTools port from the app log, and attaches a WebSocket CDP client.
// The browser is a NORMAL app (screenshot_app/app_click/app_key all
// work); the browser_* tools add DOM-level reading, clicking, filling
// and waiting — trusted input goes through CDP Input.dispatch*.

fn sleepMsLocal(ms: u32) void {
    var ts: c.struct_timespec = .{ .tv_sec = ms / 1000, .tv_nsec = @as(c_long, ms % 1000) * 1_000_000 };
    _ = c.nanosleep(&ts, null);
}

fn mkdirs(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            @memcpy(buf[0..i], path[0..i]);
            buf[i] = 0;
            _ = c.mkdir(buf[0..i :0].ptr, 0o700);
        }
    }
}

/// Poll the app's log ring for Chromium's "DevTools listening" line.
fn discoverDevtoolsPort(app: *appdrive.App, timeout_ms: i64) ?u16 {
    const deadline = monoMs() + timeout_ms;
    while (monoMs() < deadline) {
        app.drain();
        if (app.logGet("{\"tail\":300,\"from_id\":0,\"id\":0,\"max_chars\":300}", 3_000)) |reply| {
            defer app_state.allocator.free(reply.json);
            if (cdp.parseDevtoolsPort(reply.json)) |port| return port;
        } else |_| {}
        if (app.exited) return null;
        _ = app.pumpOnce(250);
    }
    return null;
}

/// A JSON string literal (valid JS literal) for embedding in scripts.
fn jsStr(arena: std.mem.Allocator, s: ?[]const u8) ![]const u8 {
    const v = s orelse return "null";
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(v, .{}, &aw.writer);
    return aw.written();
}

const BrowserGet = union(enum) { bs: *BrowserSession, err: []const u8 };

fn browserEnsure(arena: std.mem.Allocator, app: *appdrive.App) !BrowserGet {
    app.drain();
    if (app.exited) {
        const summary = try appSummary(arena, app);
        return .{ .err = try std.fmt.allocPrint(arena, "the browser has exited\n{s}", .{summary}) };
    }
    const bs = browser_state.sessions.get(appIdOf(app)) orelse
        return .{ .err = "this app has no CDP session — open pages with browser_open (or drive it with the app_* tools)" };
    if (!bs.client.connected()) {
        bs.client.attach(5_000) catch
            return .{ .err = "cannot reattach the DevTools socket (browser hung or DevTools disabled?) — screenshots and app_* input still work" };
    }
    return .{ .bs = bs };
}

const BEvalOut = union(enum) { val: ?[]const u8, err: []const u8 };

/// Evaluate JS with one transparent reconnect (navigation can replace
/// the page target, killing the WebSocket).
fn bEval(arena: std.mem.Allocator, bs: *BrowserSession, expr: []const u8, timeout_ms: i64) BEvalOut {
    var attempt: u32 = 0;
    while (true) {
        const r = bs.client.eval(arena, expr, timeout_ms) catch |err| {
            if (attempt == 0 and (err == cdp.Error.Closed or err == cdp.Error.Protocol)) {
                attempt = 1;
                bs.client.attach(5_000) catch
                    return .{ .err = "the DevTools connection dropped and could not be reattached" };
                continue;
            }
            return .{ .err = switch (err) {
                cdp.Error.Timeout => "the page did not answer in time (JS blocked / page hung?)",
                cdp.Error.Closed => "the DevTools connection closed",
                else => "DevTools protocol error",
            } };
        };
        if (r.exception) |ex|
            return .{ .err = std.fmt.allocPrint(arena, "JavaScript exception: {s}", .{ex}) catch "JavaScript exception" };
        return .{ .val = r.value_json };
    }
}

const PageInfo = struct { url: []const u8, title: []const u8, ready: []const u8 };

fn browserPageInfo(arena: std.mem.Allocator, bs: *BrowserSession, timeout_ms: i64) ?PageInfo {
    const out = bEval(arena, bs, "location.href + '\\u0001' + document.title + '\\u0001' + document.readyState", timeout_ms);
    const vj = (switch (out) {
        .val => |v| v,
        .err => null,
    }) orelse return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, vj, .{}) catch return null;
    if (parsed != .string) return null;
    var it = std.mem.splitScalar(u8, parsed.string, 1);
    const url = it.next() orelse return null;
    const title = it.next() orelse "";
    const ready = it.next() orelse "";
    return .{ .url = url, .title = title, .ready = ready };
}

/// Shared JS helpers injected ahead of every element script. deepQuery
/// pierces OPEN shadow roots (custom-element UIs like pl-input);
/// labelText computes an element's accessible label incl. its shadow
/// host's text. Plain constant (inserted via {s}) so its braces never
/// meet std.fmt.
const JS_HELPERS: []const u8 =
    \\let badSelector = false;
    \\const deepQuery = s => { const out = []; const walk = root => { let m = []; try { m = root.querySelectorAll(s); } catch (e) { badSelector = true; return; } out.push(...m); for (const el of root.querySelectorAll('*')) if (el.shadowRoot) walk(el.shadowRoot); }; walk(document); return out; };
    \\const labelText = e => { let t = ''; try { if (e.labels) for (const l of e.labels) t += ' ' + (l.innerText || ''); const al = e.getAttribute('aria-label'); if (al) t += ' ' + al; const alb = e.getAttribute('aria-labelledby'); if (alb) for (const id of alb.split(/\s+/)) { const rn = e.getRootNode(); const lr = (rn.getElementById ? rn.getElementById(id) : null) || document.getElementById(id); if (lr) t += ' ' + (lr.innerText || ''); } const host = e.getRootNode().host; if (host) { t += ' ' + (host.innerText || '').slice(0, 200); const hal = host.getAttribute('aria-label'); if (hal) t += ' ' + hal; } if (!t.trim() && e.shadowRoot) { const sl = e.shadowRoot.querySelector('label'); if (sl) t = sl.innerText || ''; } if (!t.trim() && host) { const rn2 = e.getRootNode(); const sl2 = rn2.querySelector ? rn2.querySelector('label') : null; if (sl2) t = sl2.innerText || ''; } } catch (err) {} return t; };
    \\const vis = e => { const r = e.getBoundingClientRect(); if (r.width <= 0 || r.height <= 0) return false; const s = getComputedStyle(e); return s.visibility !== 'hidden' && s.display !== 'none'; };
    \\const activeDeep = () => { let a = document.activeElement; while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement; return a; };
;

/// The shared element finder: selector and/or visible-text filter over
/// interactive elements (shadow-root piercing); tightest text match
/// first. Custom-element hosts wrapping a native control are included
/// when no selector is given.
fn elementFinderJs(arena: std.mem.Allocator, selector: ?[]const u8, text: ?[]const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\const sel = {s}; const txt = {s};
        \\{s}
        \\let els;
        \\if (sel) els = deepQuery(sel);
        \\else {{ els = deepQuery("a,button,input,select,textarea,summary,[role='button'],[role='link'],[role='tab'],[role='menuitem'],[role='option'],[role='checkbox'],[role='radio'],[role='switch'],[role='combobox'],[onclick],label"); for (const h of deepQuery('*')) if (h.tagName.includes('-') && h.shadowRoot && h.shadowRoot.querySelector('input,select,textarea,button')) els.push(h); els = [...new Set(els)]; }}
        \\els = els.filter(vis);
        \\if (txt) {{ const q = txt.toLowerCase(); els = els.filter(e => ((e.innerText || '') + ' ' + (e.value || '') + ' ' + labelText(e) + ' ' + (e.getAttribute('placeholder') || '') + ' ' + (e.getAttribute('title') || '')).toLowerCase().includes(q)); els.sort((a, b) => ((a.innerText || '').length) - ((b.innerText || '').length)); }}
    , .{ try jsStr(arena, selector), try jsStr(arena, text), JS_HELPERS });
}

fn browserErrOr(arena: std.mem.Allocator, out: BEvalOut) !?[]const u8 {
    switch (out) {
        .err => |e| return @as(?[]const u8, try appErr(arena, e)),
        .val => return null,
    }
}

fn browserTool(arena: std.mem.Allocator, name: []const u8, args: std.json.Value) ![]const u8 {
    const eql = std.mem.eql;
    if (!app_state.ready)
        return appErr(arena, "browser tools unavailable (server not fully started)");

    if (eql(u8, name, "browser_open")) {
        if (argStr(args, "host") != null)
            return appErr(arena, "browser_open is local-only (the DevTools port lives on the daemon host's loopback); for a remote browser, launch_app it and drive it with app_* tools");
        const bin = argStr(args, "browser_path") orelse (findBrowserBinary(arena) orelse
            return appErr(arena, "no Chromium-family browser found on PATH (install chromium) — pass 'browser_path' to use a specific binary"));
        const url = argStr(args, "url") orelse "about:blank";
        const wait_ms: i64 = argInt(args, "wait_ms") orelse 25_000;
        const width: i64 = std.math.clamp(argInt(args, "width") orelse 1280, 320, 3840);
        const height: i64 = std.math.clamp(argInt(args, "height") orelse 900, 240, 2160);

        // Profile: named = persistent under the state dir (cookies and
        // logins survive); default = throwaway per launch.
        var profile_dir: []const u8 = undefined;
        if (argStr(args, "profile")) |p| {
            if (!mcpassets.validName(p)) return appErr(arena, "invalid profile name (letters, digits, . _ - only)");
            const state_base = if (c.getenv("XDG_STATE_HOME")) |sh|
                try std.fmt.allocPrint(arena, "{s}", .{std.mem.span(@as([*:0]const u8, @ptrCast(sh)))})
            else if (c.getenv("HOME")) |home|
                try std.fmt.allocPrint(arena, "{s}/.local/state", .{std.mem.span(@as([*:0]const u8, @ptrCast(home)))})
            else
                return appErr(arena, "no HOME to place the profile in");
            profile_dir = try std.fmt.allocPrint(arena, "{s}/sketerm/browser-profiles/{s}", .{ state_base, p });
        } else {
            const rt = if (c.getenv("XDG_RUNTIME_DIR")) |r| std.mem.span(@as([*:0]const u8, @ptrCast(r))) else "/tmp";
            profile_dir = try std.fmt.allocPrint(arena, "{s}/sketerm/browser-ephemeral-{d}-{d}", .{ rt, c.getpid(), app_state.next_id });
        }
        mkdirs(profile_dir);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        try argv.appendSlice(arena, &.{
            bin,
            "--ozone-platform=wayland",
            "--remote-debugging-port=0",
            try std.fmt.allocPrint(arena, "--user-data-dir={s}", .{profile_dir}),
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-session-crashed-bubble",
            "--hide-crash-restore-bubble",
            "--force-renderer-accessibility",
            try std.fmt.allocPrint(arena, "--window-size={d},{d}", .{ width, height }),
            url,
        });
        const app = appdrive.App.launch(app_state.allocator, argv.items, .{
            .cols = 100,
            .rows = 30,
            .local_sock = app_state.mux_sock,
        }) catch {
            const why = appdrive.lastLaunchErr();
            return appErr(arena, if (why.len > 0)
                try std.fmt.allocPrint(arena, "browser spawn failed — {s}", .{why})
            else
                "browser spawn failed (mux daemon unreachable?)");
        };
        const id = app_state.next_id;
        app_state.next_id += 1;
        app_state.apps.put(app_state.allocator, id, app) catch {
            app.deinit();
            return error.OutOfMemory;
        };
        const started = monoMs();
        _ = app.waitFirstWindow(wait_ms);
        const port = discoverDevtoolsPort(app, @max(0, wait_ms - (monoMs() - started))) orelse {
            const summary = try appSummary(arena, app);
            return toolResult(arena, try std.fmt.allocPrint(arena, "the browser started but never announced a DevTools port — CDP tools unavailable, app_* tools still work (app {d})\n{s}", .{ id, summary }), true) orelse error.OutOfMemory;
        };
        const bs = browser_state.allocator.create(BrowserSession) catch return error.OutOfMemory;
        bs.* = .{ .client = cdp.Client.init(browser_state.allocator, port) };
        browser_state.sessions.put(browser_state.allocator, id, bs) catch {
            bs.client.deinit();
            browser_state.allocator.destroy(bs);
            return error.OutOfMemory;
        };
        // The HTTP endpoint answers slightly before the first page
        // target exists; retry the attach briefly.
        var attach_deadline = monoMs() + 10_000;
        while (true) {
            bs.client.attach(4_000) catch {
                if (monoMs() < attach_deadline) {
                    sleepMsLocal(300);
                    continue;
                }
                const summary = try appSummary(arena, app);
                return toolResult(arena, try std.fmt.allocPrint(arena, "browser is up (app {d}, DevTools port {d}) but no page target became attachable\n{s}", .{ id, port, summary }), true) orelse error.OutOfMemory;
            };
            break;
        }
        // Capture network traffic from the first request on: powers
        // browser_network and browser_wait network_idle.
        bs.client.enableNetwork(5_000) catch {};
        // Best-effort: let the initial page settle.
        attach_deadline = monoMs() + 8_000;
        while (monoMs() < attach_deadline) {
            if (browserPageInfo(arena, bs, 3_000)) |info| {
                if (!eql(u8, info.ready, "loading")) break;
            }
            sleepMsLocal(300);
        }
        _ = app.waitIdle(300, 3_000);
        var summary = try appSummary(arena, app);
        summary = try std.fmt.allocPrint(arena, "browser open: app {d}, DevTools port {d} — read with browser_read/browser_elements, interact with browser_click/browser_fill, verify with browser_info; screenshots via get_app_state\n{s}", .{ id, port, summary });
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

    const app = appFromArgs(args) orelse
        return appErr(arena, "unknown app (pass 'app' from browser_open; use list_apps)");
    const bs = switch (try browserEnsure(arena, app)) {
        .bs => |b| b,
        .err => |e| return toolResult(arena, e, true) orelse error.OutOfMemory,
    };

    if (eql(u8, name, "browser_info")) {
        const out = bEval(arena, bs,
            \\({url: location.href, title: document.title, ready: document.readyState, scroll_y: Math.round(scrollY), doc_height: document.documentElement.scrollHeight, viewport: [innerWidth, innerHeight]})
        , argInt(args, "timeout_ms") orelse 8_000);
        if (try browserErrOr(arena, out)) |e| return e;
        return toolResult(arena, out.val orelse "null", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_navigate")) {
        const url_arg = argStr(args, "url") orelse return appErr(arena, "browser_navigate requires 'url' (or \"back\"/\"forward\"/\"reload\")");
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 20_000;
        if (eql(u8, url_arg, "back") or eql(u8, url_arg, "forward")) {
            const js = if (eql(u8, url_arg, "back")) "history.back(); true" else "history.forward(); true";
            const out = bEval(arena, bs, js, 5_000);
            if (try browserErrOr(arena, out)) |e| return e;
        } else if (eql(u8, url_arg, "reload")) {
            _ = bs.client.call(arena, "Page.reload", "{}", 5_000) catch {};
        } else {
            const url = if (std.mem.indexOf(u8, url_arg, "://") != null)
                url_arg
            else
                try std.fmt.allocPrint(arena, "https://{s}", .{url_arg});
            const params = try std.fmt.allocPrint(arena, "{{\"url\":{s}}}", .{try jsStr(arena, url)});
            const resp = bs.client.call(arena, "Page.navigate", params, 10_000) catch |err| return appErr(arena, switch (err) {
                cdp.Error.Timeout => "navigation request timed out",
                else => "navigation failed (DevTools connection lost?)",
            });
            if (std.mem.indexOf(u8, resp, "\"errorText\"") != null)
                return appErr(arena, try std.fmt.allocPrint(arena, "navigation refused: {s}", .{resp}));
        }
        // Wait for the load to settle (target may be replaced —
        // browserPageInfo reattaches transparently via bEval).
        const deadline = monoMs() + timeout_ms;
        var last: ?PageInfo = null;
        while (monoMs() < deadline) {
            sleepMsLocal(300);
            if (browserPageInfo(arena, bs, 3_000)) |info| {
                last = info;
                if (eql(u8, info.ready, "complete")) break;
            }
        }
        const info = last orelse return appErr(arena, "navigation started but the page never became readable before the timeout");
        const msg = try std.fmt.allocPrint(arena, "{{\"url\":{s},\"title\":{s},\"ready\":\"{s}\"}}", .{ try jsStr(arena, info.url), try jsStr(arena, info.title), info.ready });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_eval")) {
        const js = argStr(args, "js") orelse return appErr(arena, "browser_eval requires 'js'");
        const out = bEval(arena, bs, js, argInt(args, "timeout_ms") orelse 10_000);
        if (try browserErrOr(arena, out)) |e| return e;
        const v = out.val orelse "undefined";
        const capped = if (v.len > 100_000) try std.fmt.allocPrint(arena, "{s}\n[truncated: {d} of {d} chars]", .{ v[0..100_000], @as(usize, 100_000), v.len }) else v;
        return toolResult(arena, capped, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_read")) {
        const format = argStr(args, "format") orelse "text";
        const selector = argStr(args, "selector");
        const max_chars: usize = @intCast(std.math.clamp(argInt(args, "max_chars") orelse 20_000, 200, 200_000));
        var js: []const u8 = undefined;
        if (eql(u8, format, "text")) {
            js = try std.fmt.allocPrint(arena,
                \\(() => {{ const sel = {s}; const el = sel ? document.querySelector(sel) : document.body; if (!el) return null; return el.innerText; }})()
            , .{try jsStr(arena, selector)});
        } else if (eql(u8, format, "html")) {
            js = try std.fmt.allocPrint(arena,
                \\(() => {{ const sel = {s}; const el = sel ? document.querySelector(sel) : document.documentElement; if (!el) return null; return el.outerHTML; }})()
            , .{try jsStr(arena, selector)});
        } else if (eql(u8, format, "links")) {
            js = try std.fmt.allocPrint(arena,
                \\(() => {{ const sel = {s}; const root = sel ? document.querySelector(sel) : document; if (!root) return null; return JSON.stringify(Array.from(root.querySelectorAll('a[href]')).slice(0, 300).map(a => ({{text: (a.innerText || '').trim().slice(0, 120), href: a.href}}))); }})()
            , .{try jsStr(arena, selector)});
        } else {
            return appErr(arena, "'format' must be text, html or links");
        }
        const out = bEval(arena, bs, js, argInt(args, "timeout_ms") orelse 10_000);
        if (try browserErrOr(arena, out)) |e| return e;
        const vj = out.val orelse return appErr(arena, "selector matched nothing");
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, vj, .{}) catch
            return toolResult(arena, vj, false) orelse error.OutOfMemory;
        if (parsed == .null) return appErr(arena, "selector matched nothing");
        const content = if (parsed == .string) parsed.string else vj;
        const info = browserPageInfo(arena, bs, 3_000);
        const header = if (info) |i|
            try std.fmt.allocPrint(arena, "page: {s}{s}{s}\n---\n", .{ i.url, if (i.title.len > 0) " — " else "", i.title })
        else
            "";
        const capped = if (content.len > max_chars)
            try std.fmt.allocPrint(arena, "{s}{s}\n[truncated: showing {d} of {d} chars — narrow with 'selector' or raise 'max_chars']", .{ header, content[0..max_chars], max_chars, content.len })
        else
            try std.fmt.allocPrint(arena, "{s}{s}", .{ header, content });
        return toolResult(arena, capped, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_elements")) {
        const finder = try elementFinderJs(arena, argStr(args, "selector"), argStr(args, "text"));
        const js = try std.fmt.allocPrint(arena,
            \\(() => {{ {s}
            \\if (badSelector) return 'bad selector';
            \\const implicit = el => ({{A: 'link', BUTTON: 'button', SELECT: 'combobox', TEXTAREA: 'textbox', LABEL: 'label', SUMMARY: 'button', INPUT: el.type === 'checkbox' ? 'checkbox' : el.type === 'radio' ? 'radio' : el.type === 'range' ? 'slider' : 'textbox'}})[el.tagName];
            \\return JSON.stringify(els.slice(0, 100).map((e, i) => {{
            \\const r = e.getBoundingClientRect();
            \\const inner = e.shadowRoot ? e.shadowRoot.querySelector('input,select,textarea') : null;
            \\const val = e.value !== undefined ? e.value : (inner ? inner.value : undefined);
            \\const secret = e.type === 'password' || (inner && inner.type === 'password');
            \\const chk = e.checked !== undefined ? e.checked : (inner && inner.checked !== undefined ? inner.checked : (e.getAttribute('aria-checked') ? e.getAttribute('aria-checked') === 'true' : undefined));
            \\const oel = e.tagName === 'SELECT' ? e : (inner && inner.tagName === 'SELECT' ? inner : null);
            \\return {{n: i, tag: e.tagName.toLowerCase(),
            \\role: e.getAttribute('role') || implicit(e) || (e.tagName.includes('-') ? 'custom' : undefined),
            \\text: ((e.innerText || e.value || e.getAttribute('aria-label') || e.getAttribute('placeholder') || '').trim()).slice(0, 100),
            \\label: labelText(e).trim().slice(0, 80) || undefined,
            \\x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), w: Math.round(r.width), h: Math.round(r.height),
            \\href: e.href || undefined, type: e.type || (inner ? inner.type : undefined) || undefined,
            \\name: e.name || e.getAttribute('name') || (inner ? inner.name : undefined) || undefined,
            \\value: secret ? (val && String(val).length ? '(secret: ' + String(val).length + ' chars)' : undefined) : (val !== undefined && val !== null && String(val).length ? String(val).slice(0, 60) : undefined),
            \\checked: chk,
            \\disabled: e.disabled || (inner && inner.disabled) || e.getAttribute('aria-disabled') === 'true' || undefined,
            \\expanded: e.getAttribute('aria-expanded') ? e.getAttribute('aria-expanded') === 'true' : undefined,
            \\options: oel ? Array.from(oel.options).slice(0, 20).map(o => o.text.slice(0, 40)) : undefined,
            \\shadow: e.shadowRoot ? true : undefined}}; }})); }})()
        , .{finder});
        const out = bEval(arena, bs, js, argInt(args, "timeout_ms") orelse 10_000);
        if (try browserErrOr(arena, out)) |e| return e;
        const vj = out.val orelse "[]";
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, vj, .{}) catch
            return toolResult(arena, vj, false) orelse error.OutOfMemory;
        if (parsed == .string and eql(u8, parsed.string, "bad selector"))
            return appErr(arena, "invalid CSS selector");
        const listing = if (parsed == .string) parsed.string else vj;
        return toolResult(arena, try std.fmt.allocPrint(arena, "interactive elements (centers are viewport CSS px, valid for browser_click x/y):\n{s}", .{listing}), false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_click")) {
        const selector = argStr(args, "selector");
        const text = argStr(args, "text");
        var cx: f64 = 0;
        var cy: f64 = 0;
        var desc: []const u8 = "";
        if (argFloat(args, "x")) |xv| {
            cx = xv;
            cy = argFloat(args, "y") orelse return appErr(arena, "'x' needs 'y'");
            desc = try std.fmt.allocPrint(arena, "viewport point ({d:.0},{d:.0})", .{ cx, cy });
        } else {
            if (selector == null and text == null)
                return appErr(arena, "browser_click needs 'selector' and/or 'text' (or explicit x/y viewport coords)");
            const nth: i64 = argInt(args, "nth") orelse 0;
            const finder = try elementFinderJs(arena, selector, text);
            const js = try std.fmt.allocPrint(arena,
                \\(() => {{ {s}
                \\if (badSelector) return {{bad: true}};
                \\const el = els[{d}]; if (!el) return {{found: els.length}};
                \\el.scrollIntoView({{block: 'center', inline: 'center'}});
                \\const r = el.getBoundingClientRect();
                \\return {{found: els.length, x: r.x + r.width / 2, y: r.y + r.height / 2, tag: el.tagName.toLowerCase(), text: ((el.innerText || el.value || '').trim()).slice(0, 80)}}; }})()
            , .{ finder, nth });
            const out = bEval(arena, bs, js, argInt(args, "timeout_ms") orelse 10_000);
            if (try browserErrOr(arena, out)) |e| return e;
            const vj = out.val orelse return appErr(arena, "element lookup returned nothing");
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, vj, .{}) catch
                return appErr(arena, "element lookup returned malformed data");
            if (parsed != .object) return appErr(arena, "element lookup returned malformed data");
            if (parsed.object.get("bad") != null) return appErr(arena, "invalid CSS selector");
            const found: i64 = if (parsed.object.get("found")) |f| (if (f == .integer) f.integer else 0) else 0;
            const xo = parsed.object.get("x") orelse
                return appErr(arena, try std.fmt.allocPrint(arena, "no matching element (matched {d}, wanted index {d}) — browser_elements lists what IS clickable", .{ found, nth }));
            cx = switch (xo) {
                .float => xo.float,
                .integer => @floatFromInt(xo.integer),
                else => 0,
            };
            const yo = parsed.object.get("y").?;
            cy = switch (yo) {
                .float => yo.float,
                .integer => @floatFromInt(yo.integer),
                else => 0,
            };
            const tag = if (parsed.object.get("tag")) |t| (if (t == .string) t.string else "?") else "?";
            const etext = if (parsed.object.get("text")) |t| (if (t == .string) t.string else "") else "";
            desc = try std.fmt.allocPrint(arena, "<{s}> \"{s}\" of {d} match(es) at ({d:.0},{d:.0})", .{ tag, etext, found, cx, cy });
        }
        const button = switch (argInt(args, "button") orelse 1) {
            2 => "middle",
            3 => "right",
            else => "left",
        };
        const clicks: u32 = @intCast(std.math.clamp(argInt(args, "clicks") orelse 1, 1, 3));
        const pre_url: ?[]const u8 = if (browserPageInfo(arena, bs, 3_000)) |pre| pre.url else null;
        bs.client.clickAt(arena, cx, cy, button, clicks, 8_000) catch |err| return appErr(arena, switch (err) {
            cdp.Error.Timeout => "the click was sent but the page did not acknowledge in time",
            else => "click dispatch failed (DevTools connection lost?)",
        });
        _ = app.waitIdle(200, 2_000);
        var msg = try std.fmt.allocPrint(arena, "clicked {s}", .{desc});
        // Navigation may follow a click: report where we landed, and
        // never let an intermediate state read as the final one —
        // ready != complete is flagged as navigation_pending, and
        // wait_navigation=true blocks (bounded) until the load ends.
        var info = browserPageInfo(arena, bs, 3_000);
        if (argBool(args, "wait_navigation")) {
            const nav_deadline = monoMs() + (argInt(args, "nav_timeout_ms") orelse 15_000);
            while (monoMs() < nav_deadline) {
                if (info) |i| {
                    if (eql(u8, i.ready, "complete")) break;
                }
                sleepMsLocal(300);
                info = browserPageInfo(arena, bs, 3_000);
            }
        }
        if (info) |i| {
            msg = try std.fmt.allocPrint(arena, "{s}\npage: {s}{s}{s} ({s})", .{ msg, i.url, if (i.title.len > 0) " — " else "", i.title, i.ready });
            if (pre_url != null and !eql(u8, pre_url.?, i.url))
                msg = try std.fmt.allocPrint(arena, "{s}\nnavigated: {s} -> {s}", .{ msg, pre_url.?, i.url });
            if (!eql(u8, i.ready, "complete"))
                msg = try std.fmt.allocPrint(arena, "{s}\nnavigation_pending: the document is still loading — this URL/title may be an intermediate state (browser_wait url_path/selector, or browser_click wait_navigation=true)", .{msg});
        } else {
            msg = try std.fmt.allocPrint(arena, "{s}\nnavigation_pending: the page is not answering yet (target being replaced?) — verify with browser_info/browser_wait", .{msg});
        }
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_fill")) {
        const selector = argStr(args, "selector");
        const label = argStr(args, "text_label");
        if (selector == null and label == null)
            return appErr(arena, "browser_fill needs 'selector' (CSS) or 'text_label' (placeholder/label/aria text)");
        const text = argStr(args, "value") orelse return appErr(arena, "browser_fill requires 'value' (the text to enter)");
        const finder = try elementFinderJs(arena, selector orelse "input,textarea,select,[contenteditable]", label);
        const nth: i64 = argInt(args, "nth") orelse 0;
        const js = try std.fmt.allocPrint(arena,
            \\(() => {{ {s}
            \\if (badSelector) return {{bad: true}};
            \\const q = 'input,textarea,select,[contenteditable]';
            \\const resolve = e => {{ if (e.matches(q)) return e; if (e.tagName === 'LABEL' && e.control) return e.control; let m = e.querySelector('input,textarea,select'); if (m) return m; if (e.shadowRoot) {{ m = e.shadowRoot.querySelector('input,textarea,select'); if (m) return m; }} const host = e.getRootNode().host; if (host && host.shadowRoot) {{ m = host.shadowRoot.querySelector('input,textarea,select'); if (m) return m; }} return null; }};
            \\els = els.filter(e => resolve(e));
            \\let el = els[{d}]; if (!el) return {{found: els.length}};
            \\el = resolve(el);
            \\el.scrollIntoView({{block: 'center'}});
            \\el.focus();
            \\if (el.tagName === 'SELECT') return {{tag: 'select'}};
            \\if (el.select) el.select();
            \\else if (el.isContentEditable) {{ const r = document.createRange(); r.selectNodeContents(el); const s = getSelection(); s.removeAllRanges(); s.addRange(r); }}
            \\return {{tag: el.tagName.toLowerCase(), name: el.name || el.id || ''}}; }})()
        , .{ finder, nth });
        const out = bEval(arena, bs, js, argInt(args, "timeout_ms") orelse 10_000);
        if (try browserErrOr(arena, out)) |e| return e;
        const vj = out.val orelse return appErr(arena, "field lookup returned nothing");
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, vj, .{}) catch
            return appErr(arena, "field lookup returned malformed data");
        if (parsed != .object) return appErr(arena, "field lookup returned malformed data");
        if (parsed.object.get("bad") != null) return appErr(arena, "invalid CSS selector");
        const tag = if (parsed.object.get("tag")) |t| (if (t == .string) t.string else null) else null;
        if (tag == null) {
            const found: i64 = if (parsed.object.get("found")) |f| (if (f == .integer) f.integer else 0) else 0;
            return appErr(arena, try std.fmt.allocPrint(arena, "no matching editable field (matched {d}) — browser_elements shows the candidates", .{found}));
        }
        if (eql(u8, tag.?, "select")) {
            // Dropdowns: choose the option whose text or value matches.
            const sel_js = try std.fmt.allocPrint(arena,
                \\(() => {{ let el = document.activeElement; while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement; if (!el || el.tagName !== 'SELECT') return 'lost focus';
                \\const want = {s}.toLowerCase();
                \\const idx = Array.from(el.options).findIndex(o => o.value.toLowerCase() === want || o.text.toLowerCase().includes(want));
                \\if (idx < 0) return 'no option matching';
                \\el.selectedIndex = idx; el.dispatchEvent(new Event('input', {{bubbles: true}})); el.dispatchEvent(new Event('change', {{bubbles: true}}));
                \\return 'selected: ' + el.options[idx].text; }})()
            , .{try jsStr(arena, text)});
            const sout = bEval(arena, bs, sel_js, 8_000);
            if (try browserErrOr(arena, sout)) |e| return e;
            return toolResult(arena, sout.val orelse "null", false) orelse error.OutOfMemory;
        }
        if (text.len == 0) {
            const clear = bEval(arena, bs, "(() => { const el = document.activeElement; if (el.isContentEditable) el.textContent = ''; else el.value = ''; el.dispatchEvent(new Event('input', {bubbles: true})); return true; })()", 5_000);
            if (try browserErrOr(arena, clear)) |e| return e;
        } else {
            bs.client.insertText(arena, text, 8_000) catch |err| return appErr(arena, switch (err) {
                cdp.Error.Timeout => "typing was sent but not acknowledged in time",
                else => "typing failed (DevTools connection lost?)",
            });
        }
        const pre_url: ?[]const u8 = if (browserPageInfo(arena, bs, 3_000)) |pre| try arena.dupe(u8, pre.url) else null;
        if (argBool(args, "enter")) {
            _ = bs.client.call(arena, "Input.dispatchKeyEvent", "{\"type\":\"keyDown\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13,\"nativeVirtualKeyCode\":13,\"text\":\"\\r\"}", 5_000) catch {};
            _ = bs.client.call(arena, "Input.dispatchKeyEvent", "{\"type\":\"keyUp\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13,\"nativeVirtualKeyCode\":13}", 5_000) catch {};
            _ = app.waitIdle(200, 2_000);
        }
        // Read back what the field now holds (secrets excepted). A
        // submit can detach the field or replace the page — report
        // THAT instead of a misleading empty value.
        const verify_js = try std.fmt.allocPrint(arena,
            \\(() => {{ {s}
            \\const a = activeDeep();
            \\if (!a || a === document.body) return {{state: 'unfocused'}};
            \\if (!a.isConnected) return {{state: 'detached'}};
            \\if (a.type === 'password') return {{state: 'ok', secret_len: (a.value || '').length}};
            \\return {{state: 'ok', value: ((a.isContentEditable ? a.textContent : a.value) || '').slice(0, 120)}}; }})()
        , .{JS_HELPERS});
        const verify = bEval(arena, bs, verify_js, 5_000);
        var now_holds: []const u8 = "?";
        var nav_note: []const u8 = "";
        switch (verify) {
            .val => |v| blk: {
                const pv = std.json.parseFromSliceLeaky(std.json.Value, arena, v orelse "null", .{}) catch break :blk;
                if (pv != .object) break :blk;
                const state = if (pv.object.get("state")) |s| (if (s == .string) s.string else "") else "";
                if (eql(u8, state, "ok")) {
                    if (pv.object.get("secret_len")) |sl| {
                        if (sl == .integer) now_holds = try std.fmt.allocPrint(arena, "(password field: {d} chars)", .{sl.integer});
                    } else if (pv.object.get("value")) |val| {
                        if (val == .string) now_holds = val.string;
                    }
                } else if (eql(u8, state, "detached")) {
                    now_holds = "(field_detached_after_submit: the element left the document — the form was likely submitted)";
                } else {
                    now_holds = "(field no longer focused — a submit/navigation probably moved focus)";
                }
            },
            .err => now_holds = "(unreadable: the DevTools target was replaced — navigation_started)",
        }
        if (browserPageInfo(arena, bs, 3_000)) |info| {
            if (pre_url != null and !eql(u8, pre_url.?, info.url)) {
                nav_note = try std.fmt.allocPrint(arena, "\nnavigation_started: {s} -> {s} ({s})", .{ pre_url.?, info.url, info.ready });
            } else if (!eql(u8, info.ready, "complete")) {
                nav_note = try std.fmt.allocPrint(arena, "\nnavigation_pending: document readyState is {s}", .{info.ready});
            }
        }
        const msg = try std.fmt.allocPrint(arena, "filled <{s}>{s}; field now holds: {s}{s}", .{ tag.?, if (argBool(args, "enter")) ", pressed Enter" else "", now_holds, nav_note });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_wait")) {
        const selector = argStr(args, "selector");
        const text = argStr(args, "text");
        const url_contains = argStr(args, "url_contains");
        const url_exact = argStr(args, "url_exact");
        const url_path = argStr(args, "url_path");
        const url_regex = argStr(args, "url_regex");
        const gone = argStr(args, "gone");
        const net_idle = argBool(args, "network_idle");
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 15_000;
        if (selector == null and text == null and url_contains == null and url_exact == null and
            url_path == null and url_regex == null and gone == null and !net_idle)
            return appErr(arena, "browser_wait needs at least one of: selector, text, url_contains, url_exact, url_path, url_regex, gone, network_idle");
        if (net_idle and !bs.client.net_enabled)
            bs.client.enableNetwork(5_000) catch return appErr(arena, "network_idle needs DevTools network capture, which could not be enabled");
        const cond_js = try std.fmt.allocPrint(arena,
            \\(() => {{
            \\const sel = {s}, txt = {s}, urlsub = {s}, urlx = {s}, urlp = {s}, urlre = {s}, gone = {s};
            \\let ok = true; const why = [];
            \\if (sel) {{ let m = null; try {{ m = document.querySelector(sel); }} catch (e) {{ return 'bad selector'; }} const visible = m && m.getBoundingClientRect().width > 0; if (!visible) {{ ok = false; why.push('selector not visible'); }} }}
            \\if (txt && !(document.body.innerText || '').toLowerCase().includes(txt.toLowerCase())) {{ ok = false; why.push('text not visible'); }}
            \\if (urlsub && !location.href.includes(urlsub)) {{ ok = false; why.push('url does not contain it'); }}
            \\if (urlx && location.href !== urlx) {{ ok = false; why.push('url is ' + location.href); }}
            \\if (urlp && location.pathname !== urlp) {{ ok = false; why.push('pathname is ' + location.pathname); }}
            \\if (urlre) {{ let re = null; try {{ re = new RegExp(urlre); }} catch (e) {{ return 'bad regex'; }} if (!re.test(location.href)) {{ ok = false; why.push('url does not match the regex (is ' + location.href + ')'); }} }}
            \\if (gone) {{ let m = null; try {{ m = document.querySelector(gone); }} catch (e) {{ return 'bad selector'; }} if (m && m.getBoundingClientRect().width > 0) {{ ok = false; why.push('element still present'); }} }}
            \\return ok ? 'ok' : why.join('; ');
            \\}})()
        , .{ try jsStr(arena, selector), try jsStr(arena, text), try jsStr(arena, url_contains), try jsStr(arena, url_exact), try jsStr(arena, url_path), try jsStr(arena, url_regex), try jsStr(arena, gone) });
        const deadline = monoMs() + timeout_ms;
        var last_why: []const u8 = "condition never evaluated";
        while (true) {
            var js_ok = false;
            const out = bEval(arena, bs, cond_js, 5_000);
            switch (out) {
                .val => |v| {
                    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, v orelse "null", .{}) catch std.json.Value{ .null = {} };
                    if (parsed == .string) {
                        if (eql(u8, parsed.string, "ok")) {
                            js_ok = true;
                        } else {
                            if (eql(u8, parsed.string, "bad selector")) return appErr(arena, "invalid CSS selector");
                            if (eql(u8, parsed.string, "bad regex")) return appErr(arena, "invalid url_regex (JavaScript RegExp syntax)");
                            last_why = parsed.string;
                        }
                    }
                },
                .err => |e| last_why = e,
            }
            if (js_ok and net_idle) {
                // Quiet window over CDP Network events: no requests in
                // flight and none started/finished for 500ms.
                bs.client.pump(150);
                const inflight = bs.client.netInFlight();
                const quiet = monoMs() - bs.client.net_last_ms;
                if (inflight > 0 or quiet < 500) {
                    js_ok = false;
                    last_why = try std.fmt.allocPrint(arena, "network not idle ({d} request(s) in flight, {d}ms since last activity)", .{ inflight, quiet });
                }
            }
            if (js_ok) {
                var msg: []const u8 = "condition met";
                if (browserPageInfo(arena, bs, 3_000)) |info|
                    msg = try std.fmt.allocPrint(arena, "condition met\npage: {s}{s}{s}", .{ info.url, if (info.title.len > 0) " — " else "", info.title });
                return toolResult(arena, msg, false) orelse error.OutOfMemory;
            }
            if (monoMs() >= deadline) break;
            sleepMsLocal(300);
        }
        var fail_msg = try std.fmt.allocPrint(arena, "timeout: {s}", .{last_why});
        if (browserPageInfo(arena, bs, 3_000)) |info|
            fail_msg = try std.fmt.allocPrint(arena, "{s}\ncurrently on: {s}{s}{s}", .{ fail_msg, info.url, if (info.title.len > 0) " — " else "", info.title });
        return toolResult(arena, fail_msg, true) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_form_state")) {
        const selector = argStr(args, "selector");
        const js = try std.fmt.allocPrint(arena,
            \\(() => {{ {s}
            \\const q = 'input,select,textarea,[contenteditable]';
            \\const roleSel = "[role='checkbox'],[role='radio'],[role='switch'],[role='combobox'],[role='listbox'],[role='textbox'],[role='slider'],[role='spinbutton']";
            \\const sel = {s};
            \\let scope = null;
            \\if (sel) {{ const m = deepQuery(sel); if (badSelector) return 'bad selector'; if (!m.length) return 'no scope match'; scope = m[0]; }}
            \\const within = (e, root) => {{ if (!root) return true; let n = e; while (n) {{ if (n === root) return true; n = n.parentNode || n.host; }} return false; }};
            \\const isHostCtl = h => h.tagName.includes('-') && h.shadowRoot && (h.shadowRoot.querySelector(q) || h.matches(roleSel) || h.shadowRoot.querySelector("[role='option'],[role='switch'],[role='checkbox'],[role='radio']"));
            \\let ctls = deepQuery(q + ',' + roleSel);
            \\const hosts = deepQuery('*').filter(isHostCtl);
            \\const covered = new Set(); hosts.forEach(h => {{ for (const i2 of h.shadowRoot.querySelectorAll(q)) covered.add(i2); }});
            \\ctls = ctls.filter(e => !covered.has(e));
            \\const all = [...new Set([...ctls, ...hosts])].filter(e => within(e, scope)).filter(e => e.type !== 'hidden');
            \\const entry = e => {{
            \\const inner = e.shadowRoot ? e.shadowRoot.querySelector(q) : null;
            \\const t = inner || e;
            \\const type = t.type || e.getAttribute('type') || undefined;
            \\const secret = type === 'password';
            \\let value = e.value !== undefined ? e.value : (inner ? inner.value : undefined);
            \\if (value === undefined && e.isContentEditable) value = e.textContent;
            \\const checked = e.checked !== undefined ? e.checked : (inner && inner.checked !== undefined ? inner.checked : (e.getAttribute('aria-checked') ? e.getAttribute('aria-checked') === 'true' : undefined));
            \\let options; const oel = e.tagName === 'SELECT' ? e : (inner && inner.tagName === 'SELECT' ? inner : null);
            \\if (oel) options = Array.from(oel.options).slice(0, 30).map(o => ({{text: o.text.slice(0, 60), value: o.value.slice(0, 60), selected: o.selected || undefined}}));
            \\else {{ const ropts = Array.from(e.querySelectorAll("[role='option']")).concat(e.shadowRoot ? Array.from(e.shadowRoot.querySelectorAll("[role='option']")) : []); if (ropts.length) options = ropts.slice(0, 30).map(o => ({{text: (o.innerText || '').trim().slice(0, 60), selected: o.getAttribute('aria-selected') === 'true' || undefined}})); }}
            \\const fo = t.form || (e.closest ? e.closest('form') : null);
            \\const r = e.getBoundingClientRect();
            \\return {{tag: e.tagName.toLowerCase(),
            \\role: e.getAttribute('role') || undefined,
            \\name: e.name || e.getAttribute('name') || (inner ? inner.name : undefined) || undefined,
            \\id: e.id || undefined,
            \\label: labelText(e).trim().slice(0, 100) || undefined,
            \\type,
            \\value: secret ? (value && String(value).length ? '(secret: ' + String(value).length + ' chars)' : '(empty)') : (value !== undefined && value !== null ? String(value).slice(0, 120) : undefined),
            \\checked, options,
            \\disabled: e.disabled || (inner && inner.disabled) || e.getAttribute('aria-disabled') === 'true' || undefined,
            \\required: t.required || e.getAttribute('aria-required') === 'true' || undefined,
            \\validation: (t.validationMessage && t.validationMessage.slice(0, 120)) || undefined,
            \\shadow_input: inner ? (inner.name || inner.tagName.toLowerCase()) : undefined,
            \\form: fo ? (fo.id || fo.getAttribute('name') || '(unnamed form)') : undefined,
            \\visible: vis(e) || undefined,
            \\x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2)}}; }};
            \\return JSON.stringify(all.slice(0, 80).map(entry)); }})()
        , .{ JS_HELPERS, try jsStr(arena, selector) });
        const out = bEval(arena, bs, js, argInt(args, "timeout_ms") orelse 10_000);
        if (try browserErrOr(arena, out)) |e| return e;
        const vj = out.val orelse "[]";
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, vj, .{}) catch
            return toolResult(arena, vj, false) orelse error.OutOfMemory;
        if (parsed == .string) {
            if (eql(u8, parsed.string, "bad selector")) return appErr(arena, "invalid CSS selector");
            if (eql(u8, parsed.string, "no scope match")) return appErr(arena, "the scope selector matched nothing");
            return toolResult(arena, try std.fmt.allocPrint(arena, "form state (open shadow roots traversed; password values are counts only; centers valid for browser_click x/y):\n{s}", .{parsed.string}), false) orelse error.OutOfMemory;
        }
        return toolResult(arena, vj, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_choose")) {
        const selector = argStr(args, "selector");
        const text = argStr(args, "text");
        const value = argStr(args, "value") orelse return appErr(arena, "browser_choose requires 'value' (the option's text or value)");
        if (selector == null and text == null)
            return appErr(arena, "browser_choose needs 'selector' (CSS) or 'text' (control label text)");
        const nth: i64 = argInt(args, "nth") orelse 0;
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 8_000;
        const finder = try elementFinderJs(arena, selector, text);
        const js = try std.fmt.allocPrint(arena,
            \\(() => {{ {s}
            \\if (badSelector) return {{bad: true}};
            \\const want = {s}.toLowerCase();
            \\const chooseNative = el2 => {{ let idx = Array.from(el2.options).findIndex(o => o.value.toLowerCase() === want || o.text.trim().toLowerCase() === want); if (idx < 0) idx = Array.from(el2.options).findIndex(o => o.text.toLowerCase().includes(want)); if (idx < 0) return {{mode: 'native', err: 'no option matching', options: Array.from(el2.options).slice(0, 20).map(o => o.text)}}; el2.selectedIndex = idx; el2.dispatchEvent(new Event('input', {{bubbles: true}})); el2.dispatchEvent(new Event('change', {{bubbles: true}})); return {{mode: 'native', picked: el2.options[idx].text}}; }};
            \\const selish = e => e.matches('select') || (e.shadowRoot && e.shadowRoot.querySelector('select')) || e.matches("[role='combobox'],[role='listbox']") || e.getAttribute('aria-haspopup') === 'listbox' || e.tagName.includes('-');
            \\const cands = els.filter(selish);
            \\const el = (cands.length ? cands : els)[{d}];
            \\if (!el) return {{found: els.length}};
            \\if (el.tagName === 'SELECT') return chooseNative(el);
            \\const inner = el.shadowRoot ? el.shadowRoot.querySelector('select') : null;
            \\if (inner) return chooseNative(inner);
            \\el.scrollIntoView({{block: 'center'}});
            \\const trg = el.shadowRoot ? el.shadowRoot.querySelector("[part*='trigger'],[aria-haspopup],button,[role='button'],[role='combobox']") : null;
            \\const r = (trg && vis(trg) ? trg : el).getBoundingClientRect();
            \\return {{mode: 'custom', x: r.x + r.width / 2, y: r.y + r.height / 2, tag: el.tagName.toLowerCase(), now: (el.value !== undefined && el.value !== null ? String(el.value) : (el.innerText || '')).trim().slice(0, 60)}}; }})()
        , .{ finder, try jsStr(arena, value), nth });
        const out = bEval(arena, bs, js, 10_000);
        if (try browserErrOr(arena, out)) |e| return e;
        const vj = out.val orelse return appErr(arena, "control lookup returned nothing");
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, vj, .{}) catch
            return appErr(arena, "control lookup returned malformed data");
        if (parsed != .object) return appErr(arena, "control lookup returned malformed data");
        if (parsed.object.get("bad") != null) return appErr(arena, "invalid CSS selector");
        const mode = if (parsed.object.get("mode")) |m| (if (m == .string) m.string else "") else "";
        if (mode.len == 0) {
            const found: i64 = if (parsed.object.get("found")) |f| (if (f == .integer) f.integer else 0) else 0;
            return appErr(arena, try std.fmt.allocPrint(arena, "no matching control (matched {d}) — browser_form_state lists the form controls", .{found}));
        }
        if (eql(u8, mode, "native")) {
            if (parsed.object.get("err") != null) {
                var opts_note: []const u8 = "";
                if (parsed.object.get("options")) |ov| {
                    var ow: std.Io.Writer.Allocating = .init(arena);
                    try std.json.Stringify.value(ov, .{}, &ow.writer);
                    opts_note = try std.fmt.allocPrint(arena, "; available: {s}", .{ow.written()});
                }
                return appErr(arena, try std.fmt.allocPrint(arena, "no <select> option matching \"{s}\"{s}", .{ value, opts_note }));
            }
            const picked = if (parsed.object.get("picked")) |p| (if (p == .string) p.string else "?") else "?";
            return toolResult(arena, try std.fmt.allocPrint(arena, "chose \"{s}\" (native select)", .{picked}), false) orelse error.OutOfMemory;
        }
        // Custom control: trusted-click it open, wait for options to
        // surface (shadow-piercing), click the matching one.
        const tag = if (parsed.object.get("tag")) |t| (if (t == .string) t.string else "?") else "?";
        const was = if (parsed.object.get("now")) |n| (if (n == .string) n.string else "") else "";
        const cxv = parsed.object.get("x") orelse return appErr(arena, "control lookup returned no coordinates");
        const cx: f64 = switch (cxv) {
            .float => cxv.float,
            .integer => @floatFromInt(cxv.integer),
            else => 0,
        };
        const cyv = parsed.object.get("y").?;
        const cy: f64 = switch (cyv) {
            .float => cyv.float,
            .integer => @floatFromInt(cyv.integer),
            else => 0,
        };
        bs.client.clickAt(arena, cx, cy, "left", 1, 8_000) catch
            return appErr(arena, "could not click the control open (DevTools connection lost?)");
        const opt_js = try std.fmt.allocPrint(arena,
            \\(() => {{ {s}
            \\const want = {s}.toLowerCase();
            \\let opts = deepQuery("[role='option'],option,[part='option']").filter(vis);
            \\if (!opts.length) opts = deepQuery("li").filter(vis);
            \\if (!opts.length) return {{count: 0}};
            \\let hit = opts.find(o => (o.innerText || '').trim().toLowerCase() === want || (o.value || '').toLowerCase() === want);
            \\if (!hit) hit = opts.find(o => (o.innerText || '').toLowerCase().includes(want));
            \\if (!hit) return {{count: opts.length, seen: opts.slice(0, 15).map(o => (o.innerText || '').trim().slice(0, 40))}};
            \\hit.scrollIntoView({{block: 'center'}});
            \\const r = hit.getBoundingClientRect();
            \\return {{x: r.x + r.width / 2, y: r.y + r.height / 2, text: (hit.innerText || '').trim().slice(0, 60)}}; }})()
        , .{ JS_HELPERS, try jsStr(arena, value) });
        const deadline = monoMs() + timeout_ms;
        var seen_note: []const u8 = "no visible options appeared";
        while (true) {
            sleepMsLocal(250);
            const oout = bEval(arena, bs, opt_js, 5_000);
            const ovj = switch (oout) {
                .val => |v| v orelse "null",
                .err => "null",
            };
            const op = std.json.parseFromSliceLeaky(std.json.Value, arena, ovj, .{}) catch std.json.Value{ .null = {} };
            if (op == .object) {
                if (op.object.get("x")) |oxv| {
                    const ox: f64 = switch (oxv) {
                        .float => oxv.float,
                        .integer => @floatFromInt(oxv.integer),
                        else => 0,
                    };
                    const oyv = op.object.get("y").?;
                    const oy: f64 = switch (oyv) {
                        .float => oyv.float,
                        .integer => @floatFromInt(oyv.integer),
                        else => 0,
                    };
                    const otext = if (op.object.get("text")) |t2| (if (t2 == .string) t2.string else "?") else "?";
                    bs.client.clickAt(arena, ox, oy, "left", 1, 8_000) catch
                        return appErr(arena, "found the option but could not click it (DevTools connection lost?)");
                    _ = app.waitIdle(150, 1_500);
                    // Read the control back for confirmation.
                    const rb_js = try std.fmt.allocPrint(arena,
                        \\(() => {{ {s}
                        \\const seln = {s}; const txtn = {s};
                        \\let els2 = seln ? deepQuery(seln) : [];
                        \\if (!els2.length && txtn) {{ els2 = deepQuery('*').filter(e => e.tagName.includes('-') && e.shadowRoot).filter(e => labelText(e).toLowerCase().includes(txtn.toLowerCase())); }}
                        \\const el3 = els2[0]; if (!el3) return null;
                        \\return (el3.value !== undefined && el3.value !== null ? String(el3.value) : (el3.innerText || '')).trim().slice(0, 80); }})()
                    , .{ JS_HELPERS, try jsStr(arena, selector), try jsStr(arena, text) });
                    const rb = bEval(arena, bs, rb_js, 5_000);
                    var now: []const u8 = "";
                    if (rb == .val) {
                        if (rb.val) |v2| {
                            const pv = std.json.parseFromSliceLeaky(std.json.Value, arena, v2, .{}) catch std.json.Value{ .null = {} };
                            if (pv == .string) now = pv.string;
                        }
                    }
                    var msg = try std.fmt.allocPrint(arena, "chose \"{s}\" in <{s}>", .{ otext, tag });
                    if (was.len > 0) msg = try std.fmt.allocPrint(arena, "{s} (was: {s})", .{ msg, was });
                    if (now.len > 0) msg = try std.fmt.allocPrint(arena, "{s}; control now shows: {s}", .{ msg, now });
                    return toolResult(arena, msg, false) orelse error.OutOfMemory;
                }
                if (op.object.get("seen")) |sv| {
                    var ow: std.Io.Writer.Allocating = .init(arena);
                    try std.json.Stringify.value(sv, .{}, &ow.writer);
                    seen_note = try std.fmt.allocPrint(arena, "options visible but none match: {s}", .{ow.written()});
                }
            }
            if (monoMs() >= deadline) break;
        }
        // Close whatever popup the click opened before reporting.
        _ = bs.client.call(arena, "Input.dispatchKeyEvent", "{\"type\":\"keyDown\",\"key\":\"Escape\",\"code\":\"Escape\",\"windowsVirtualKeyCode\":27,\"nativeVirtualKeyCode\":27}", 3_000) catch {};
        _ = bs.client.call(arena, "Input.dispatchKeyEvent", "{\"type\":\"keyUp\",\"key\":\"Escape\",\"code\":\"Escape\",\"windowsVirtualKeyCode\":27,\"nativeVirtualKeyCode\":27}", 3_000) catch {};
        return appErr(arena, try std.fmt.allocPrint(arena, "clicked <{s}> open but could not pick \"{s}\": {s} — inspect with browser_form_state/browser_elements and click the option manually", .{ tag, value, seen_note }));
    }
    if (eql(u8, name, "browser_network")) {
        if (!bs.client.net_enabled) {
            bs.client.enableNetwork(5_000) catch return appErr(arena, "could not enable DevTools network capture");
            return toolResult(arena, "network capture was off and is enabled NOW — requests are recorded from this point on; interact/navigate, then call browser_network again", false) orelse error.OutOfMemory;
        }
        bs.client.pump(200);
        if (argBool(args, "clear")) {
            bs.client.netClear();
            return toolResult(arena, "network log cleared", false) orelse error.OutOfMemory;
        }
        const filter = argStr(args, "filter");
        const limit: usize = @intCast(std.math.clamp(argInt(args, "limit") orelse 30, 1, 200));
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.print("{{\"tracked\":{d},\"in_flight\":{d},\"dropped\":{d},\"requests\":[", .{ bs.client.net.items.len, bs.client.netInFlight(), bs.client.net_dropped });
        // Newest last; walk from the tail collecting up to `limit`.
        var idxs: std.ArrayList(usize) = .empty;
        defer idxs.deinit(arena);
        var i = bs.client.net.items.len;
        while (i > 0 and idxs.items.len < limit) {
            i -= 1;
            const e = bs.client.net.items[i];
            if (filter) |f| {
                if (std.mem.indexOf(u8, e.url, f) == null and
                    std.mem.indexOf(u8, e.first_url, f) == null) continue;
            }
            try idxs.append(arena, i);
        }
        var first = true;
        var j = idxs.items.len;
        while (j > 0) {
            j -= 1;
            const e = bs.client.net.items[idxs.items[j]];
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("{{\"seq\":{d},\"method\":\"{s}\",\"url\":", .{ e.seq, e.method });
            try std.json.Stringify.value(if (e.url.len > 200) e.url[0..200] else e.url, .{}, w);
            if (e.status != 0) try w.print(",\"status\":{d}", .{e.status});
            if (e.resource_type.len > 0) try w.print(",\"type\":\"{s}\"", .{e.resource_type});
            if (e.mime.len > 0) {
                try w.writeAll(",\"mime\":");
                try std.json.Stringify.value(e.mime, .{}, w);
            }
            if (!e.finished) try w.writeAll(",\"in_flight\":true");
            if (e.error_text.len > 0) {
                try w.writeAll(",\"failed\":");
                try std.json.Stringify.value(e.error_text, .{}, w);
            }
            if (e.redirects > 0) try w.print(",\"redirects\":{d}", .{e.redirects});
            if (e.first_url.len > 0) {
                try w.writeAll(",\"redirected_from\":");
                try std.json.Stringify.value(if (e.first_url.len > 200) e.first_url[0..200] else e.first_url, .{}, w);
            }
            if (e.post_keys.len > 0) {
                try w.writeAll(",\"post_keys\":");
                try std.json.Stringify.value(e.post_keys, .{}, w);
            }
            try w.writeAll("}");
        }
        try w.writeAll("]}");
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "browser_scroll")) {
        var js: []const u8 = undefined;
        if (argStr(args, "to")) |to| {
            if (eql(u8, to, "top")) {
                js = "window.scrollTo(0, 0)";
            } else if (eql(u8, to, "bottom")) {
                js = "window.scrollTo(0, document.documentElement.scrollHeight)";
            } else {
                return appErr(arena, "'to' must be \"top\" or \"bottom\" (use 'selector' to scroll an element into view)");
            }
        } else if (argStr(args, "selector")) |sel| {
            js = try std.fmt.allocPrint(arena,
                \\(() => {{ let el = null; try {{ el = document.querySelector({s}); }} catch (e) {{ return 'bad selector'; }} if (!el) return 'no match'; el.scrollIntoView({{block: 'center'}}); return true; }})()
            , .{try jsStr(arena, sel)});
        } else if (argInt(args, "y")) |y| {
            js = try std.fmt.allocPrint(arena, "window.scrollTo(0, {d})", .{y});
        } else if (argInt(args, "dy")) |dy| {
            js = try std.fmt.allocPrint(arena, "window.scrollBy(0, {d})", .{dy});
        } else {
            return appErr(arena, "browser_scroll needs one of: to (top/bottom), selector, y (absolute), dy (relative)");
        }
        const out = bEval(arena, bs, js, 8_000);
        if (try browserErrOr(arena, out)) |e| return e;
        if (out.val) |v| {
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, v, .{}) catch std.json.Value{ .null = {} };
            if (parsed == .string) {
                if (eql(u8, parsed.string, "bad selector")) return appErr(arena, "invalid CSS selector");
                if (eql(u8, parsed.string, "no match")) return appErr(arena, "selector matched nothing");
            }
        }
        _ = app.waitIdle(150, 1_500);
        const pos = bEval(arena, bs, "({scroll_y: Math.round(scrollY), doc_height: document.documentElement.scrollHeight, viewport_h: innerHeight})", 5_000);
        return toolResult(arena, switch (pos) {
            .val => |v| v orelse "scrolled",
            .err => "scrolled",
        }, false) orelse error.OutOfMemory;
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
    if (eql(u8, name, "upload_file") or eql(u8, name, "download_file") or
        std.mem.startsWith(u8, name, "port_forward_"))
    {
        return xferTool(arena, name, args);
    }
    if (std.mem.startsWith(u8, name, "browser_")) {
        return browserTool(arena, name, args);
    }
    if (eql(u8, name, "capabilities")) {
        return capabilitiesTool(arena);
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
        const resp = ipc(arena, backend, .{ .cmd = "new-tab", .cwd = argStr(args, "cwd"), .title = argStr(args, "title") }) catch |err| {
            // No GUI reachable: fall back to a headless terminal so the
            // caller can keep working instead of dead-ending.
            if (term_state.mux_sock != null) {
                const id = spawnRegisteredTerm(null, 120, 40) catch
                    return appErr(arena, "no GUI socket, and the headless fallback failed too (mux daemon unreachable?)");
                const t = term_state.terms.get(id).?;
                _ = t.waitIdle(250, 3_000);
                const msg = try std.fmt.allocPrint(arena, "{{\"headless\":true,\"term\":{d},\"note\":\"no GUI is running — opened headless terminal {d} instead; drive it with term_run/term_exec/term_read (term ids, not pane ids)\"}}", .{ id, id });
                return toolResult(arena, msg, false) orelse error.OutOfMemory;
            }
            return err;
        };
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
    try t.expectEqualStrings("/etc/systemd/system/hohenheim.sketerm-part.service", try stagedPartPath(arena, "/etc/systemd/system/hohenheim.service"));
    // Last-suffix preservation (what suffix-sensitive validators need).
    try t.expectEqualStrings("/srv/app.tar.sketerm-part.gz", try stagedPartPath(arena, "/srv/app.tar.gz"));
    try t.expectEqualStrings("/usr/local/bin/hohenheim.sketerm-part", try stagedPartPath(arena, "/usr/local/bin/hohenheim"));
    // Dotfiles and trailing dots don't split.
    try t.expectEqualStrings("/home/x/.bashrc.sketerm-part", try stagedPartPath(arena, "/home/x/.bashrc"));
    try t.expectEqualStrings("/tmp/weird..sketerm-part", try stagedPartPath(arena, "/tmp/weird."));
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
    try t.expectEqualStrings(sha, findHex64("prefix " ++ sha ++ "  /path/file").?);
    try t.expect(findHex64("short deadbeef only") == null);
    // 65 hex chars: not a standalone 64-run.
    try t.expect(findHex64("f" ** 65) == null);
}

test "pickFreePort and tcpListening agree" {
    const t = std.testing;
    const port = pickFreePort() orelse return error.SkipZigTest;
    try t.expect(port > 0);
    // Nothing listens there after the probe socket closed.
    try t.expect(!tcpListening(port, 200));
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
    const r = try localCopyAtomic(arena, src, dst);
    try t.expect(r == .ok);
    try t.expectEqual(@as(u64, 14), r.ok.bytes);
    try t.expectEqual(@as(?u64, 14), fileSize(dst));
    const src_sha = sha256File(src).?;
    try t.expectEqualStrings(&src_sha, &r.ok.sha);
    // Missing source is a described error, not a crash.
    const bad = try localCopyAtomic(arena, "/nonexistent/nope", dst);
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
        const r = try buildLaunchArgv(arena, &argv, parse(arena,
            "{\"command\":\"/opt/game/bin\",\"args\":[\"/data/dir\",\"-w\",\"-nobink\"]}"));
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
        const r = try buildLaunchArgv(arena, &argv, parse(arena,
            "{\"command\":[\"/opt/game/bin\",\"-w\"],\"args\":[\"-nobink\"]}"));
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
        const r = try applyDebugWrap(arena, &argv, parse(arena,
            "{\"debug\":\"gdb\",\"gdb_commands\":[\"frame 3\",\"p *ctx\"]}"));
        try t.expect(r == .note);
        const want = [_][]const u8{
            "gdb",  "-q",           "-batch", "-ex",     "run",  "-ex", "bt full",
            "-ex",  "info registers", "-ex",  "frame 3", "-ex",  "p *ctx",
            "--args", "/opt/app",   "-w",
        };
        try t.expectEqual(want.len, argv.items.len);
        for (want, argv.items) |w, g| try t.expectEqualStrings(w, g);
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
