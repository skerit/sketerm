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

const MCP_HELP =
    \\Usage: sketerm mcp [--shared | --durable | --name NAME] [--socket PATH]
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

var quit_flag: bool = false;

fn onQuitSignal(_: c_int) callconv(.c) void {
    quit_flag = true;
}

/// SIGTERM/SIGINT must interrupt the blocking getline (no SA_RESTART)
/// so an ephemeral run still tears its private daemon down when the
/// MCP client kills us instead of closing stdin.
fn installQuitSignals() void {
    var sa: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
    sa.__sigaction_handler.sa_handler = onQuitSignal;
    sa.sa_flags = 0;
    _ = c.sigaction(c.SIGTERM, &sa, null);
    _ = c.sigaction(c.SIGINT, &sa, null);
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

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const reply = handleMessage(arena_state.allocator(), backend, line);
        if (reply) |r| {
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
    \\{"name":"launch_app","description":"Launch a GUI (Wayland) application HEADLESSLY: it renders into sketerm's mux daemon, never appears on any screen, and survives disconnects. Returns the app id, its windows AND the first window's screenshot inline (launch-and-look in one call). If the app exits early, the reply includes exit status, terminating signal and its recent output. Drive it with get_app_state/app_click/app_type/app_key; read its stdout/stderr with app_output.","inputSchema":{"type":"object","properties":{"command":{"description":"argv array (preferred) or a shell command string","anyOf":[{"type":"array","items":{"type":"string"}},{"type":"string"}]},"host":{"type":"string","description":"SSH host (user@box) to run on; omit = local daemon"},"cwd":{"type":"string","description":"Working directory for the app"},"env":{"type":"object","description":"Extra environment variables, e.g. {\"FOO\":\"1\"}","additionalProperties":{"type":"string"}},"wait_for":{"type":"string","enum":["window","exit"],"description":"What to wait for before replying: first window (default) or process exit (short-lived/CLI runs)"},"wait_ms":{"type":"integer","description":"Max wait (default 10000)"},"cols":{"type":"integer"},"rows":{"type":"integer"},"layout":{"type":"string","description":"Session keyboard layout: us (default), gb, fr, be, de"},"gpu":{"type":"boolean","description":"Render on the host's real GPU via linux-dmabuf instead of software GL. Needs a driver whose linear buffers allow CPU mmap."}},"required":["command"]}},
    \\{"name":"list_apps","description":"List launched headless apps and their windows.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"app_windows","description":"List one app's rendered windows (ids, sizes, titles).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"}}}},
    \\{"name":"screenshot_app","description":"Screenshot a headless app window as a lossless PNG (inline image). Optional region crop and integer zoom for pixel-level inspection; downscaled when larger than max_px. The caption tells you how to map image coordinates back to app_click coordinates. wait_change=true blocks until the window renders something NEWER than your last screenshot (verify a click did something).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer","description":"Window id (omit = first toplevel)"},"max_px":{"type":"integer","description":"Bound on the longest image dimension (default 1568, 0 = full size)"},"region":{"type":"object","description":"Crop to a sub-rectangle in surface pixels","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}},"zoom":{"type":"integer","description":"Nearest-neighbor integer upscale (1-32) — crop a small region and zoom to inspect pixels"},"wait_change":{"type":"boolean","description":"Wait until the window content changed since the last screenshot before capturing"},"timeout_ms":{"type":"integer","description":"Bound for wait_change (default 10000)"}}}},
    \\{"name":"get_app_state","description":"One-call app observation: window list + screenshot of one window (inline PNG) with coordinate mapping. Prefer this over separate app_windows + screenshot_app. If the app exited, reports exit status, signal and recent output instead. Accepts the same region/zoom/wait_change options as screenshot_app.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer","description":"Window id (omit = first toplevel)"},"max_px":{"type":"integer"},"region":{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}},"zoom":{"type":"integer"},"wait_change":{"type":"boolean"},"timeout_ms":{"type":"integer"}}}},
    \\{"name":"app_output","description":"Read a headless app's stdout/stderr (its PTY output as rendered by a terminal). THE tool for 'why did my app print/exit that'. scrollback=true includes history beyond the visible grid. Also reports exit status + signal when the app has died.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"scrollback":{"type":"boolean"}}}},
    \\{"name":"app_click","description":"Click inside an app window at surface-local pixel coordinates (from screenshot_app; apply the caption's multiplier if the image was downscaled). To target a widget by name/role instead, prefer app_perform_action (coordinate-free, more reliable). button: 1 left (default), 2 middle, 3 right.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"x":{"type":"integer"},"y":{"type":"integer"},"button":{"type":"integer"}},"required":["window","x","y"]}},
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
    \\{"name":"app_wait","description":"Wait until an app stopped producing new frames for quiet_ms (render quiescence). Returns the window list.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"quiet_ms":{"type":"integer"},"timeout_ms":{"type":"integer"}}}},
    \\{"name":"app_a11y_tree","description":"Read the app's accessibility (AT-SPI) tree as JSON: every widget's role, name, description, states and screen rectangle. Target elements by name/role instead of pixel-hunting a screenshot. Works for GTK/Qt apps; empty for apps without accessibility (games, some Electron).","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"timeout_ms":{"type":"integer"}}}},
    \\{"name":"app_record_start","description":"Start recording a window's frames (a visual log of what you do). Default format is WebM/VP9 (smaller, higher quality); pass format:\"gif\" for an animated GIF. Frames are captured while other app tools run; finish with app_record_stop.","inputSchema":{"type":"object","properties":{"app":{"type":"integer"},"window":{"type":"integer"},"format":{"type":"string","enum":["webm","gif"],"description":"Default webm"},"max_px":{"type":"integer","description":"Bound on the longest dimension (default 1280 webm / 800 gif)"}}}},
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
    const names = appdrive.listAppSessions(a, sock) catch return;
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    for (names) |n| {
        const app = appdrive.App.attachExisting(a, n, null, sock) catch continue;
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
    if (app.exited) {
        try w.print(",\"exited\":true,\"exit_status\":{d}", .{app.exit_status});
        // decodeStatus convention: negative = killed by that signal.
        if (app.exit_status < 0)
            try w.print(",\"signal\":{d},\"signal_name\":\"{s}\"", .{ -app.exit_status, signalName(-app.exit_status) });
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
    // printed (the last screen lines) so one call shows WHY.
    if (app.exited) {
        if (app.output(false)) |text| {
            defer app_state.allocator.free(text);
            try w.writeAll(",\"recent_output\":");
            try std.json.Stringify.value(tailLines(text, 25), .{}, w);
        } else |_| {}
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

fn monoMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
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
        const summary = try appSummary(arena, app);
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

    if (eql(u8, name, "app_windows")) {
        const summary = try appSummary(arena, app);
        return toolResult(arena, summary, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "app_output")) {
        const text = app.output(argBool(args, "scrollback")) catch
            return appErr(arena, "no terminal mirror for this app (output unavailable)");
        defer app_state.allocator.free(text);
        var msg: []const u8 = try arena.dupe(u8, text);
        if (app.exited) {
            msg = try std.fmt.allocPrint(arena, "[app exited, status {d}{s}]\n{s}", .{
                app.exit_status,
                if (app.exit_status < 0) try std.fmt.allocPrint(arena, " = killed by {s}", .{signalName(-app.exit_status)}) else "",
                msg,
            });
        }
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
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
        if (argBool(args, "wait_change")) {
            // Block (bounded) until the window commits a frame newer
            // than its last screenshot — "did my click do anything".
            const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 10_000;
            if (!app.waitWindowChange(win_id, timeout_ms))
                return appErr(arena, "window content did not change before the timeout");
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
        const shot = app.screenshotPng(win_id, max_px, region, zoom) catch
            return appErr(arena, "no such window / no pixels yet (a region must lie inside the window)");
        defer app_state.allocator.free(shot.png);
        const extra: []const u8 = if (eql(u8, name, "get_app_state")) try appSummary(arena, app) else "";
        const caption = try screenshotCaption(arena, app, win_id, shot, extra);
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
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
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
        const settled = app.waitIdle(quiet_ms, timeout_ms);
        const summary = try appSummary(arena, app);
        const msg = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ if (settled) "settled" else "timeout: still rendering", summary });
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
        app.recordStart(win_id, max_px, !want_gif) catch return appErr(arena, "no such window");
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
        const id = appIdOf(app);
        _ = app_state.apps.swapRemove(id);
        app.deinit();
        return toolResult(arena, "app session killed", false) orelse error.OutOfMemory;
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
    // Errors.
    try t.expectError(error.MissingValue, Opts.parse(&.{"--name"}));
    try t.expectError(error.BadName, Opts.parse(&.{ "--name", "a/b" }));
    try t.expectError(error.BadName, Opts.parse(&.{ "--name", "" }));
    try t.expectError(error.UnknownFlag, Opts.parse(&.{"--bogus"}));
}

test "instance name validation" {
    const t = std.testing;
    try t.expect(validInstanceName("default"));
    try t.expect(validInstanceName("Agent_2-b"));
    try t.expect(!validInstanceName("has space"));
    try t.expect(!validInstanceName("dot.dot"));
    try t.expect(!validInstanceName("a" ** 49));
}
