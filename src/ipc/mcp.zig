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

const MCP_HELP =
    \\Usage: sketerm mcp [--socket PATH]
    \\
    \\Runs a Model Context Protocol server on stdio that drives the
    \\running sketerm instance. Register it in an MCP client (Claude
    \\Code, etc.) as command "sketerm" with args ["mcp"].
    \\
    \\Tools exposed: list_terminals, read_screen, send_text,
    \\send_keys, run_command, wait_idle, new_tab, split_pane,
    \\focus_pane, close_pane.
    \\
    \\Socket resolution: --socket, then $SKETERM_SOCKET, then the
    \\single *.sock under $XDG_RUNTIME_DIR/sketerm/.
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

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    var socket_arg: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--socket") and i + 1 < args.len) {
            i += 1;
            socket_arg = args[i];
        } else if (std.mem.eql(u8, args[i], "--help")) {
            _ = c.fputs(MCP_HELP, platform.stdout());
            return 0;
        } else {
            _ = c.fprintf(platform.stderr(), "sketerm mcp: unknown flag\n");
            return 2;
        }
    }

    const sock_path = @import("client.zig").resolveSocket(allocator, socket_arg) orelse {
        _ = c.fprintf(platform.stderr(), "sketerm mcp: no socket found (is sketerm running? use --socket or $SKETERM_SOCKET)\n");
        return 1;
    };
    var real = RealBackend{ .sock_path = sock_path };
    defer allocator.free(sock_path);
    const backend = Backend{
        .ctx = @ptrCast(&real),
        .talk = RealBackend.talk,
        .sleepMs = RealBackend.sleepMs,
        .nowMs = RealBackend.nowMs,
    };

    // stdin loop: one JSON-RPC message per line.
    var lineptr: [*c]u8 = null;
    var linecap: usize = 0;
    defer if (lineptr != null) c.free(lineptr);
    while (true) {
        const n = c.getline(&lineptr, &linecap, platform.stdin());
        if (n < 0) break; // EOF — client closed us down.
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
    return 0;
}

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
    @setEvalBranchQuota(20_000);
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
    \\{"name":"read_screen","description":"Read a pane's rendered screen: text content plus cursor position, size and flags. This is the parsed terminal grid (what a human sees), not raw output.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer","description":"Pane id (omit = focused pane)"},"scrollback":{"type":"integer","description":"Also include up to N scrollback lines"}}}},
    \\{"name":"send_text","description":"Type literal text into a pane's terminal. Set enter=true to press Enter afterwards. Use send_keys for control keys.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"},"text":{"type":"string"},"enter":{"type":"boolean","description":"Press Enter after the text"}},"required":["text"]}},
    \\{"name":"send_keys","description":"Press named keys in a pane: space-separated chords like 'ctrl+c', 'enter', 'up', 'escape', 'f5', 'alt+x', 'shift+tab', 'pagedown'. Single characters are typed literally.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"},"keys":{"type":"string"}},"required":["keys"]}},
    \\{"name":"run_command","description":"Type a shell command, press Enter, wait until output settles, and return the resulting screen text. For interactive programs prefer send_text/send_keys + read_screen.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"},"command":{"type":"string"},"timeout_ms":{"type":"integer","description":"Max wait (default 15000)"},"quiet_ms":{"type":"integer","description":"Idle window that counts as settled (default 400)"}},"required":["command"]}},
    \\{"name":"wait_idle","description":"Wait until a pane produced no output for quiet_ms (or timeout_ms elapsed). Returns whether it settled.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"},"timeout_ms":{"type":"integer"},"quiet_ms":{"type":"integer"}}}},
    \\{"name":"new_tab","description":"Open a new shell tab. Returns the new tab and pane ids.","inputSchema":{"type":"object","properties":{"cwd":{"type":"string"},"title":{"type":"string"}}}},
    \\{"name":"split_pane","description":"Split a pane. direction 'h' = side by side, 'v' = stacked. Returns the new pane id.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"},"direction":{"type":"string","enum":["h","v"]}}}},
    \\{"name":"focus_pane","description":"Focus a pane (selects its tab and grabs keyboard focus).","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"}},"required":["pane"]}},
    \\{"name":"close_pane","description":"Close a pane. Destructive: the shell and any running process in it are terminated.","inputSchema":{"type":"object","properties":{"pane":{"type":"integer"}},"required":["pane"]}}
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

fn callTool(arena: std.mem.Allocator, backend: Backend, name: []const u8, args: std.json.Value) ![]const u8 {
    const eql = std.mem.eql;
    const pane = paneFromArgs(args);

    if (eql(u8, name, "list_terminals")) {
        const resp = try ipc(arena, backend, .{ .cmd = "list" });
        return toolResult(arena, resp, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "read_screen")) {
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
        var blob = try readScreenText(arena, backend, pane, 0);
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
