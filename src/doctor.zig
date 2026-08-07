//! `sketerm doctor [host]` — health check for the pieces that bite:
//! binary/daemon version skew (the running daemon keeps old code
//! after an upgrade), socket liveness, terminfo, capability flags.
//! With a host argument it also probes the REMOTE daemon (SSH/UDP).

const std = @import("std");
const c = @import("c.zig").c;
const platform = @import("util/platform.zig");
const wire = @import("mux/wire.zig");
const mux_client = @import("mux/client.zig");
const mux_cli = @import("ipc/mux_cli.zig");
const mux_daemon = @import("mux/daemon.zig");
const ipc_client = @import("ipc/client.zig");
const mcp_registry = @import("ipc/mcp_registry.zig");
const version = @import("version.zig");
const build_options = @import("build_options");
const opuscodec = @import("mux/opuscodec.zig");

/// Daemon `list` reply; pre-doctor daemons omit version/caps fields
/// and show up as version "" (reported as "pre-0.1.0 or stale").
const Welcome = struct {
    proto: u32,
    daemon_pid: i64 = 0,
    server_proto: ?u32 = null,
    version: []const u8 = "",
    audio_opus: bool = false,
    video: bool = false,
    sessions: []const Sess = &.{},

    const Sess = struct {
        name: []const u8 = "",
        app: bool = false,
        exited: bool = false,
    };
};

const Palette = struct {
    label: [*:0]const u8,
    good: [*:0]const u8,
    warn: [*:0]const u8,
    note: [*:0]const u8,
    pid: [*:0]const u8,
    isolated: [*:0]const u8,
    durable: [*:0]const u8,
    shared: [*:0]const u8,
    dim: [*:0]const u8,
    reset: [*:0]const u8,

    fn init(enabled: bool) Palette {
        if (!enabled) return .{
            .label = "",
            .good = "",
            .warn = "",
            .note = "",
            .pid = "",
            .isolated = "",
            .durable = "",
            .shared = "",
            .dim = "",
            .reset = "",
        };
        return .{
            .label = "\x1b[1;36m",
            .good = "\x1b[32m",
            .warn = "\x1b[1;31m",
            .note = "\x1b[33m",
            .pid = "\x1b[1m",
            .isolated = "\x1b[36m",
            .durable = "\x1b[35m",
            .shared = "\x1b[33m",
            .dim = "\x1b[2m",
            .reset = "\x1b[0m",
        };
    }
};

fn colorAllowed(is_tty: bool, no_color: bool, term: []const u8) bool {
    return is_tty and !no_color and !std.mem.eql(u8, term, "dumb");
}

fn outputPalette() Palette {
    const term = if (c.getenv("TERM")) |value| std.mem.span(@as([*:0]const u8, @ptrCast(value))) else "";
    return Palette.init(colorAllowed(c.isatty(1) != 0, c.getenv("NO_COLOR") != null, term));
}

fn printLabel(palette: Palette, label: [*:0]const u8) void {
    _ = c.printf("%s%-10s%s", palette.label, label, palette.reset);
}

fn onOff(b: bool) [*:0]const u8 {
    return if (b) "on" else "off";
}

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const palette = outputPalette();
    var host: ?[]const u8 = null;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            _ = c.fputs(
                "Usage: sketerm doctor [host]\n\n" ++
                    "Checks: local daemon reachability + PID + version/proto/capability\n" ++
                    "skew, active MCP servers, GUI sockets, and terminfo install.\n" ++
                    "With a host ([domain.<name>], user@box or udp:box): probes the\n" ++
                    "remote sketerm-mux for the same skew.\n\nExit: 0 healthy, 1 warnings.\n",
                platform.stdout(),
            );
            return 0;
        }
        host = a;
    }

    var warns: u32 = 0;

    printLabel(palette, "binary");
    _ = c.printf(
        "%s  proto %u  opus:%s video:%s\n",
        @as([*:0]const u8, version.string),
        @as(c_uint, wire.PROTO_VERSION),
        onOff(opuscodec.available()),
        onOff(build_options.video),
    );

    warns += checkDaemon(allocator, null, palette);
    warns += checkMcp(allocator, palette);
    warns += checkGui(allocator, palette);
    warns += checkTerminfo(allocator, palette);

    if (host) |h_raw| {
        // [domain.<name>] resolution, like the mux CLI.
        var cfg = @import("config.zig").Config.load(allocator);
        defer cfg.deinit();
        const spec = cfg.resolveDomain(h_raw, allocator);
        defer if (spec) |s| allocator.free(s);
        warns += checkDaemon(allocator, if (spec) |s| s else h_raw, palette);
    }

    if (warns == 0) {
        _ = c.printf("%sall checks passed%s\n", palette.good, palette.reset);
        return 0;
    }
    _ = c.printf("%s%u warning(s)%s\n", palette.warn, @as(c_uint, warns), palette.reset);
    return 1;
}

/// Probe one daemon (null = local, no autostart) and report version,
/// proto, capabilities and session count. Returns warning count.
fn checkDaemon(allocator: std.mem.Allocator, host: ?[]const u8, palette: Palette) u32 {
    const label: [*:0]const u8 = if (host == null) "daemon" else "remote";

    var conn: mux_client.Conn = undefined;
    var peer_pid: c.pid_t = 0;
    if (host == null) {
        // Deliberately no autostart: doctor reports, it doesn't mutate.
        const path = mux_daemon.defaultSocketPath(allocator) catch return 1;
        defer allocator.free(path);
        const raw = mux_client.Conn.connect(allocator, path) catch {
            printLabel(palette, "daemon");
            _ = c.printf("%snot running (autostarts on demand) - ok%s\n", palette.dim, palette.reset);
            return 0;
        };
        peer_pid = platform.unixPeerPid(raw.fd) orelse 0;
        conn = mux_client.Conn.probe(allocator, raw) catch {
            printLabel(palette, "daemon");
            _ = c.printf("%saccepts connections but the handshake failed%s\n", palette.warn, palette.reset);
            return 1;
        };
    } else {
        conn = mux_cli.muxConnect(allocator, host) orelse {
            printLabel(palette, "remote");
            _ = c.printf("%.*s: %sUNREACHABLE%s (see error above)\n", @as(c_int, @intCast(host.?.len)), host.?.ptr, palette.warn, palette.reset);
            return 1;
        };
    }
    defer conn.deinit();

    conn.sendFrame(.list, "") catch {
        printLabel(palette, label);
        _ = c.printf("%sconnected but list failed%s\n", palette.warn, palette.reset);
        return 1;
    };
    const f = conn.recvExpectFor(&.{.welcome}, 10_000) catch {
        printLabel(palette, label);
        _ = c.printf("%sconnected but no welcome reply%s\n", palette.warn, palette.reset);
        return 1;
    };
    defer f.deinit(allocator);
    const parsed = std.json.parseFromSlice(Welcome, allocator, f.payload, .{
        .ignore_unknown_fields = true,
    }) catch {
        printLabel(palette, label);
        _ = c.printf("%smalformed list reply%s\n", palette.warn, palette.reset);
        return 1;
    };
    defer parsed.deinit();
    const w = parsed.value;
    const server_proto = w.server_proto orelse w.proto;

    var live: u32 = 0;
    var apps: u32 = 0;
    for (w.sessions) |s| {
        if (!s.exited) {
            live += 1;
            if (s.app) apps += 1;
        }
    }
    const daemon_pid: c.pid_t = if (w.daemon_pid > 0) @intCast(w.daemon_pid) else peer_pid;

    const ver: []const u8 = if (w.version.len > 0) w.version else "pre-0.1.0 or stale";
    if (host) |h| {
        printLabel(palette, "remote");
        _ = c.printf("%.*s: ", @as(c_int, @intCast(h.len)), h.ptr);
    } else {
        printLabel(palette, "daemon");
    }
    _ = c.printf("%.*s  ", @as(c_int, @intCast(ver.len)), ver.ptr);
    if (daemon_pid > 0) {
        _ = c.printf("%spid %d%s  ", palette.pid, daemon_pid, palette.reset);
    } else {
        _ = c.printf("%spid ?%s  ", palette.dim, palette.reset);
    }
    _ = c.printf(
        "proto %u (selected %u)  opus:%s video:%s  %u session(s), %u app\n",
        @as(c_uint, server_proto),
        @as(c_uint, w.proto),
        onOff(w.audio_opus),
        onOff(w.video),
        @as(c_uint, live),
        @as(c_uint, apps),
    );

    var warns: u32 = 0;
    if (w.proto == 0) {
        _ = c.printf("          %swarning: no shared terminal profile; sessions are preserved but cannot be attached%s\n", palette.warn, palette.reset);
        warns += 1;
    }
    if (server_proto != wire.PROTO_VERSION) {
        _ = c.printf("          %snote: protocol skew uses negotiated profile %u%s\n", palette.note, @as(c_uint, w.proto), palette.reset);
    }
    if (!std.mem.eql(u8, w.version, version.string)) {
        _ = c.printf(
            "          %snote: version skew vs binary %s; running sessions stay on their current daemon%s\n",
            palette.note,
            @as([*:0]const u8, version.string),
            palette.reset,
        );
    }
    if (opuscodec.available() != w.audio_opus) {
        _ = c.printf("          %snote: opus mismatch (binary %s, daemon %s) - audio falls back to raw PCM%s\n", palette.note, onOff(opuscodec.available()), onOff(w.audio_opus), palette.reset);
    }
    return warns;
}

const DaemonStats = struct {
    pid: c.pid_t = 0,
    sessions: u32 = 0,
    apps: u32 = 0,
};

const McpMuxState = union(enum) {
    not_started: void,
    broken: void,
    running: DaemonStats,
};

fn daemonStatsAt(allocator: std.mem.Allocator, socket: []const u8) !DaemonStats {
    const raw = try mux_client.Conn.connect(allocator, socket);
    const peer_pid = platform.unixPeerPid(raw.fd) orelse 0;
    var conn = try mux_client.Conn.probe(allocator, raw);
    defer conn.deinit();
    try conn.sendFrame(.list, "");
    const frame = try conn.recvExpectFor(&.{.welcome}, 10_000);
    defer frame.deinit(allocator);
    const parsed = try std.json.parseFromSlice(Welcome, allocator, frame.payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    var stats = DaemonStats{
        .pid = if (parsed.value.daemon_pid > 0) @intCast(parsed.value.daemon_pid) else peer_pid,
    };
    for (parsed.value.sessions) |session| {
        if (session.exited) continue;
        stats.sessions += 1;
        if (session.app) stats.apps += 1;
    }
    return stats;
}

fn pathExists(path: []const u8) bool {
    var z: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return false;
    return c.access(path_z.ptr, c.F_OK) == 0;
}

fn modeColor(palette: Palette, mode: mcp_registry.Mode) [*:0]const u8 {
    return switch (mode) {
        .isolated => palette.isolated,
        .durable => palette.durable,
        .shared => palette.shared,
    };
}

fn zspan(value: [*:0]const u8) []const u8 {
    return std.mem.span(value);
}

fn writeMcpRow(writer: *std.Io.Writer, palette: Palette, entry: mcp_registry.Entry, state: McpMuxState) !void {
    const identity_raw = entry.displayName();
    const identity = if (identity_raw.len == 0) "-" else identity_raw[0..@min(identity_raw.len, 18)];
    try writer.print("          {s}pid {d}{s}  {s}{s:<9}{s} {s:<18}  ", .{
        zspan(palette.pid),
        entry.pid,
        zspan(palette.reset),
        zspan(modeColor(palette, entry.mode)),
        entry.mode.text(),
        zspan(palette.reset),
        identity,
    });
    switch (state) {
        .not_started => {
            try writer.print("{s}mux not started{s}", .{ zspan(palette.dim), zspan(palette.reset) });
        },
        .broken => {
            try writer.print("{s}mux socket unreachable{s}", .{ zspan(palette.warn), zspan(palette.reset) });
        },
        .running => |stats| {
            if (stats.pid > 0) {
                try writer.print("mux {s}pid {d}{s}  {d} session(s), {d} app", .{
                    zspan(palette.good), stats.pid, zspan(palette.reset), stats.sessions, stats.apps,
                });
            } else {
                try writer.print("mux {s}pid ?{s}  {d} session(s), {d} app", .{
                    zspan(palette.dim), zspan(palette.reset), stats.sessions, stats.apps,
                });
            }
        },
    }
    if (entry.legacy) try writer.print(" {s}[pre-registry]{s}", .{ zspan(palette.dim), zspan(palette.reset) });
    try writer.writeByte('\n');
}

/// Inventory live MCP servers without autostarting any of their mux daemons.
fn checkMcp(allocator: std.mem.Allocator, palette: Palette) u32 {
    const entries = mcp_registry.list(allocator, true) catch {
        printLabel(palette, "mcp");
        _ = c.printf("%scannot read live-server registry%s\n", palette.warn, palette.reset);
        return 1;
    };
    defer mcp_registry.freeEntries(allocator, entries);

    printLabel(palette, "mcp");
    _ = c.printf("%s%u active server(s)%s\n", palette.good, @as(c_uint, @intCast(entries.len)), palette.reset);
    var warns: u32 = 0;
    for (entries) |entry| {
        const state: McpMuxState = if (entry.mux_socket.len == 0)
            .{ .not_started = {} }
        else if (daemonStatsAt(allocator, entry.mux_socket)) |stats|
            .{ .running = stats }
        else |_| if (pathExists(entry.mux_socket)) blk: {
            warns += 1;
            break :blk .{ .broken = {} };
        } else .{ .not_started = {} };
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        writeMcpRow(&aw.writer, palette, entry, state) catch continue;
        const row = aw.written();
        _ = c.fwrite(row.ptr, 1, row.len, platform.stdout());
    }
    return warns;
}

/// Count live GUI instance sockets and unlink stale ones — the same
/// self-heal `sketerm cli` auto-discovery does, so leftovers can't
/// accumulate on machines where discovery never runs (SKETERM_SOCKET
/// set, or an explicit --socket everywhere).
fn checkGui(allocator: std.mem.Allocator, palette: Palette) u32 {
    const rt = platform.runtimeDir();
    const dir_z = std.fmt.allocPrintSentinel(allocator, "{s}/sketerm", .{rt}, 0) catch return 1;
    defer allocator.free(dir_z);
    var live: u32 = 0;
    var stale: u32 = 0;
    if (c.g_dir_open(dir_z.ptr, 0, null)) |dir| {
        defer c.g_dir_close(dir);
        while (c.g_dir_read_name(dir)) |name_c| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(name_c)));
            if (!std.mem.endsWith(u8, name, ".sock")) continue;
            if (std.mem.eql(u8, name, "mux.sock")) continue;
            const path = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir_z, name }, 0) catch continue;
            defer allocator.free(path);
            if (ipc_client.socketAlive(path)) live += 1 else {
                _ = c.unlink(path.ptr);
                stale += 1;
            }
        }
    }
    printLabel(palette, "gui");
    if (stale > 0) {
        _ = c.printf("%u live instance(s); removed %u stale socket(s) (crash leftovers)\n", @as(c_uint, live), @as(c_uint, stale));
    } else {
        _ = c.printf("%u live instance(s)\n", @as(c_uint, live));
    }
    const in_pane = c.getenv("SKETERM_PANE_ID") != null;
    if (in_pane and c.getenv("SKETERM_SOCKET") == null) {
        _ = c.printf("          %sWARN inside a pane but SKETERM_SOCKET is unset%s\n", palette.warn, palette.reset);
        return 1;
    }
    return 0;
}

/// Look for the compiled sketerm-256color terminfo entry in the
/// usual databases. Missing is only a warning when TERM references
/// it (the default child TERM is xterm-256color).
fn checkTerminfo(allocator: std.mem.Allocator, palette: Palette) u32 {
    const home = if (c.getenv("HOME")) |h| std.mem.span(h) else "";
    var dirs_buf: [6][]const u8 = undefined;
    var n: usize = 0;
    if (c.getenv("TERMINFO")) |t| {
        dirs_buf[n] = std.mem.span(t);
        n += 1;
    }
    const home_ti = std.fmt.allocPrint(allocator, "{s}/.terminfo", .{home}) catch return 1;
    defer allocator.free(home_ti);
    dirs_buf[n] = home_ti;
    n += 1;
    dirs_buf[n] = "/etc/terminfo";
    n += 1;
    dirs_buf[n] = "/usr/lib/terminfo";
    n += 1;
    dirs_buf[n] = "/usr/share/terminfo";
    n += 1;

    // Two on-disk layouts. ncurses buckets entries by first letter
    // ("s/"), but on a case-INSENSITIVE filesystem it uses that
    // letter's hex code instead ("73/") so "s" and "S" cannot collide
    // — which is what macOS's own `tic` writes into ~/.terminfo. Probe
    // both, or an installed entry reads as missing on every Mac.
    const buckets = [_][]const u8{ "s", "73" };
    for (dirs_buf[0..n]) |d| {
        for (buckets) |b| {
            const p = std.fmt.allocPrintSentinel(allocator, "{s}/{s}/sketerm-256color", .{ d, b }, 0) catch continue;
            defer allocator.free(p);
            if (c.fopen(p.ptr, "rb")) |fh| {
                _ = c.fclose(fh);
                printLabel(palette, "terminfo");
                _ = c.printf("%sok%s  %s\n", palette.good, palette.reset, p.ptr);
                return 0;
            }
        }
    }
    const term = if (c.getenv("TERM")) |t| std.mem.span(t) else "";
    if (std.mem.startsWith(u8, term, "sketerm")) {
        printLabel(palette, "terminfo");
        _ = c.printf("%sWARN%s TERM=%.*s but sketerm-256color is not installed (tic terminfo/sketerm-256color.src)\n", palette.warn, palette.reset, @as(c_int, @intCast(term.len)), term.ptr);
        return 1;
    }
    printLabel(palette, "terminfo");
    _ = c.printf("%sketerm-256color not installed (fine: children default to xterm-256color)%s\n", palette.dim, palette.reset);
    return 0;
}

test "doctor color policy honors terminal capability and NO_COLOR" {
    try std.testing.expect(colorAllowed(true, false, "xterm-256color"));
    try std.testing.expect(!colorAllowed(false, false, "xterm-256color"));
    try std.testing.expect(!colorAllowed(true, true, "xterm-256color"));
    try std.testing.expect(!colorAllowed(true, false, "dumb"));
}

test "doctor MCP rows are aligned and color is optional" {
    const allocator = std.testing.allocator;
    var entry = mcp_registry.Entry{
        .pid = 4242,
        .mode = .isolated,
        .name = try allocator.dupe(u8, ""),
        .profile = try allocator.dupe(u8, ""),
        .log_dir = try allocator.dupe(u8, "/tmp/logs/project-x/"),
        .mux_socket = try allocator.dupe(u8, "/tmp/mux.sock"),
    };
    defer entry.deinit(allocator);

    var plain: std.Io.Writer.Allocating = .init(allocator);
    defer plain.deinit();
    try writeMcpRow(&plain.writer, Palette.init(false), entry, .{ .running = .{
        .pid = 4343,
        .sessions = 2,
        .apps = 1,
    } });
    try std.testing.expect(std.mem.indexOf(u8, plain.written(), "pid 4242") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain.written(), "isolated") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain.written(), "project-x") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain.written(), "mux pid 4343  2 session(s), 1 app") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, plain.written(), 0x1b) == null);

    var colored: std.Io.Writer.Allocating = .init(allocator);
    defer colored.deinit();
    try writeMcpRow(&colored.writer, Palette.init(true), entry, .{ .not_started = {} });
    try std.testing.expect(std.mem.indexOf(u8, colored.written(), "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored.written(), "mux not started") != null);
}
