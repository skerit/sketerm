//! `sketerm mux` — session management CLI + TUI picker.
//!
//! `sketerm mux` with no arguments opens a raw-mode TUI listing the
//! daemon's sessions: ↑/↓/j/k select, Enter attaches the session as
//! a tab in the running sketerm window, n spawns a new durable tab,
//! x kills the selected session, q/Esc quits.
//!
//! Subcommands for scripting: list, attach <name>, kill <name>, new.

const std = @import("std");
const c = @import("../c.zig").c;
const mux_client = @import("../mux/client.zig");
const mux_daemon = @import("../mux/daemon.zig");
const mux_wire = @import("../mux/wire.zig");
const ipc_client = @import("client.zig");

const MUX_HELP =
    \\Usage: sketerm mux [host] [command]
    \\
    \\No command: interactive session picker (TUI) — local daemon,
    \\or <host>'s daemon over SSH (`sketerm mux user@box`).
    \\  Up/Down or j/k  select        Enter  attach as tab
    \\  n  new durable tab            x      kill selected session
    \\  q / Esc  quit
    \\
    \\Commands (each accepts an optional leading host):
    \\  list                  print sessions
    \\  attach <name>         attach a session as a GUI tab
    \\  new                   spawn a durable tab in the GUI
    \\  kill <name>           kill a session
    \\
    \\`sketerm ssh <host>` = `sketerm mux <host> new` — open a
    \\remote shell that survives disconnects (key auth required).
    \\
;

const SessionInfo = struct {
    name: []const u8,
    rows: u16 = 0,
    cols: u16 = 0,
    clients: u32 = 0,
    exited: bool = false,
    title: []const u8 = "",
};

const Welcome = struct {
    proto: u32 = 0,
    sessions: []SessionInfo = &.{},
};

fn isSubcommand(s2: []const u8) bool {
    const known = [_][]const u8{ "list", "attach", "new", "kill" };
    for (known) |k| {
        if (std.mem.eql(u8, s2, k)) return true;
    }
    return false;
}

pub fn run(allocator: std.mem.Allocator, args_in: []const []const u8) u8 {
    // Optional leading host: anything that isn't a known subcommand
    // or flag ("sketerm mux user@box [cmd]").
    var host: ?[]const u8 = null;
    var args = args_in;
    if (args.len > 0 and !isSubcommand(args[0]) and !std.mem.startsWith(u8, args[0], "-")) {
        host = args[0];
        args = args[1..];
    }
    if (args.len == 0) return tui(allocator, host);
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        _ = c.fputs(MUX_HELP, c.stdout);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "list")) {
        var sessions = fetchSessions(allocator, host) orelse return 1;
        defer sessions.deinit();
        for (sessions.value.sessions) |s| {
            _ = c.printf(
                "%-24.*s %ux%u  %u client(s)%s  %.*s\n",
                @as(c_int, @intCast(s.name.len)),
                s.name.ptr,
                @as(c_uint, s.cols),
                @as(c_uint, s.rows),
                @as(c_uint, s.clients),
                @as([*:0]const u8, if (s.exited) " [exited]" else ""),
                @as(c_int, @intCast(s.title.len)),
                s.title.ptr,
            );
        }
        return 0;
    }
    if (std.mem.eql(u8, cmd, "attach") and args.len >= 2) {
        return if (guiCommand(allocator, "attach-session", args[1], host)) 0 else 1;
    }
    if (std.mem.eql(u8, cmd, "new")) {
        return if (guiCommand(allocator, "new-durable-tab", null, host)) 0 else 1;
    }
    if (std.mem.eql(u8, cmd, "kill") and args.len >= 2) {
        var conn = muxConnect(allocator, host) orelse return 1;
        defer conn.deinit();
        conn.sendJson(.kill, .{ .name = args[1] }) catch return 1;
        const f = conn.recvExpect(&.{.ok}) catch {
            _ = c.fprintf(c.stderr, "sketerm mux: kill failed\n");
            return 1;
        };
        f.deinit(allocator);
        return 0;
    }
    _ = c.fputs(MUX_HELP, c.stdout);
    return 2;
}

fn muxConnect(allocator: std.mem.Allocator, host: ?[]const u8) ?mux_client.Conn {
    if (host) |h| {
        return mux_client.Conn.connectSsh(allocator, h) catch {
            _ = c.fprintf(c.stderr, "sketerm mux: ssh transport to host failed (key auth? sketerm-mux installed there?)\n");
            return null;
        };
    }
    const path = mux_daemon.defaultSocketPath(allocator) catch return null;
    defer allocator.free(path);
    return mux_client.Conn.connect(allocator, path) catch {
        _ = c.fprintf(c.stderr, "sketerm mux: daemon not running (no durable sessions yet)\n");
        return null;
    };
}

fn fetchSessions(allocator: std.mem.Allocator, host: ?[]const u8) ?std.json.Parsed(Welcome) {
    var conn = muxConnect(allocator, host) orelse return null;
    defer conn.deinit();
    conn.sendFrame(.list, "") catch return null;
    const f = conn.recvExpect(&.{.welcome}) catch return null;
    defer f.deinit(allocator);
    return std.json.parseFromSlice(Welcome, allocator, f.payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

/// Send one command to the running GUI over its IPC socket
/// ($SKETERM_SOCKET inside a pane, auto-discovery otherwise).
fn guiCommand(allocator: std.mem.Allocator, cmd: []const u8, data: ?[]const u8, host: ?[]const u8) bool {
    const sock = ipc_client.resolveSocket(allocator, null) orelse {
        _ = c.fprintf(c.stderr, "sketerm mux: no running sketerm window found\n");
        return false;
    };
    defer allocator.free(sock);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    std.json.Stringify.value(.{ .cmd = cmd, .data = data, .host = host }, .{}, &aw.writer) catch return false;
    aw.writer.writeAll("\n") catch return false;

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var addr: c.struct_sockaddr_un = undefined;
    mux_daemon.fillSockaddrUn(&addr, sock) catch return false;
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) {
        _ = c.fprintf(c.stderr, "sketerm mux: cannot reach the sketerm window\n");
        return false;
    }
    const line = aw.written();
    var off: usize = 0;
    while (off < line.len) {
        const n = c.write(fd, line.ptr + off, line.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    var resp: [4096]u8 = undefined;
    const rn = c.read(fd, &resp, resp.len);
    if (rn <= 0) return false;
    const ok = std.mem.indexOf(u8, resp[0..@intCast(rn)], "\"ok\":true") != null;
    if (!ok) _ = c.fprintf(c.stderr, "sketerm mux: %.*s", @as(c_int, @intCast(rn)), &resp);
    return ok;
}

// ── TUI ─────────────────────────────────────────────────────────

const RawMode = struct {
    orig: c.struct_termios,

    fn enter() ?RawMode {
        if (c.isatty(0) == 0) {
            _ = c.fprintf(c.stderr, "sketerm mux: stdin is not a terminal (use `sketerm mux list`)\n");
            return null;
        }
        var orig: c.struct_termios = undefined;
        if (c.tcgetattr(0, &orig) != 0) return null;
        var raw = orig;
        raw.c_lflag &= ~@as(@TypeOf(raw.c_lflag), c.ICANON | c.ECHO);
        raw.c_cc[c.VMIN] = 1;
        raw.c_cc[c.VTIME] = 0;
        _ = c.tcsetattr(0, c.TCSANOW, &raw);
        _ = c.printf("\x1b[?25l"); // hide cursor
        return .{ .orig = orig };
    }

    fn leave(self: *const RawMode) void {
        _ = c.printf("\x1b[?25h");
        _ = c.fflush(c.stdout);
        _ = c.tcsetattr(0, c.TCSANOW, &self.orig);
    }
};

fn tui(allocator: std.mem.Allocator, host: ?[]const u8) u8 {
    var parsed = fetchSessions(allocator, host) orelse return 1;
    defer parsed.deinit();

    var raw = RawMode.enter() orelse return 1;
    defer raw.leave();

    var selected: usize = 0;
    var drawn_lines: usize = 0;
    while (true) {
        const sessions = parsed.value.sessions;
        drawTui(sessions, selected, &drawn_lines);

        var buf: [8]u8 = undefined;
        const n = c.read(0, &buf, buf.len);
        if (n <= 0) return 1;
        const key = buf[0..@intCast(n)];

        if (key.len == 1 and (key[0] == 'q' or key[0] == 0x1b and n == 1)) {
            eraseTui(&drawn_lines);
            return 0;
        }
        const is_up = (key.len == 1 and key[0] == 'k') or std.mem.eql(u8, key, "\x1b[A");
        const is_down = (key.len == 1 and key[0] == 'j') or std.mem.eql(u8, key, "\x1b[B");
        if (is_up and selected > 0) selected -= 1;
        if (is_down and sessions.len > 0 and selected < sessions.len - 1) selected += 1;

        if (key.len == 1 and (key[0] == '\r' or key[0] == '\n')) {
            if (sessions.len == 0) continue;
            eraseTui(&drawn_lines);
            raw.leave();
            const name = sessions[selected].name;
            if (guiCommand(allocator, "attach-session", name, host)) {
                _ = c.printf("attached '%.*s'\n", @as(c_int, @intCast(name.len)), name.ptr);
                return 0;
            }
            return 1;
        }
        if (key.len == 1 and key[0] == 'n') {
            eraseTui(&drawn_lines);
            raw.leave();
            return if (guiCommand(allocator, "new-durable-tab", null, host)) 0 else 1;
        }
        if (key.len == 1 and key[0] == 'x' and sessions.len > 0) {
            const name = sessions[selected].name;
            if (muxConnect(allocator, host)) |conn_v| {
                var conn = conn_v;
                defer conn.deinit();
                conn.sendJson(.kill, .{ .name = name }) catch {};
                if (conn.recvExpect(&.{.ok})) |f| f.deinit(allocator) else |_| {}
            }
            // Refresh the list.
            parsed.deinit();
            parsed = fetchSessions(allocator, host) orelse {
                eraseTui(&drawn_lines);
                return 1;
            };
            if (selected >= parsed.value.sessions.len and selected > 0) selected -= 1;
        }
    }
}

fn drawTui(sessions: []const SessionInfo, selected: usize, drawn_lines: *usize) void {
    eraseTui(drawn_lines);
    _ = c.printf("\x1b[1msketerm sessions\x1b[0m  (Enter attach · n new · x kill · q quit)\r\n");
    var lines: usize = 1;
    if (sessions.len == 0) {
        _ = c.printf("  \x1b[2m(none — press n to start one)\x1b[0m\r\n");
        lines += 1;
    }
    for (sessions, 0..) |s, i| {
        const marker: [*:0]const u8 = if (i == selected) "\x1b[7m \xe2\x96\xb8 " else "   ";
        _ = c.printf(
            "%s%-24.*s %3ux%-3u %u client(s)%s  \x1b[2m%.*s\x1b[0m\x1b[27m\r\n",
            marker,
            @as(c_int, @intCast(s.name.len)),
            s.name.ptr,
            @as(c_uint, s.cols),
            @as(c_uint, s.rows),
            @as(c_uint, s.clients),
            @as([*:0]const u8, if (s.exited) " [exited]" else ""),
            @as(c_int, @intCast(@min(s.title.len, 30))),
            s.title.ptr,
        );
        lines += 1;
    }
    _ = c.fflush(c.stdout);
    drawn_lines.* = lines;
}

fn eraseTui(drawn_lines: *usize) void {
    if (drawn_lines.* == 0) return;
    var i: usize = 0;
    while (i < drawn_lines.*) : (i += 1) _ = c.printf("\x1b[A\x1b[2K");
    _ = c.fflush(c.stdout);
    drawn_lines.* = 0;
}
