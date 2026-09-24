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
const procinv = @import("procinv.zig");

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
        /// The session child's pid, which is how a session is tied to its worker process.
        pid: i64 = 0,
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
                    "skew, active MCP servers, GUI sockets, terminfo install, and every\n" ++
                    "running sketerm process of this user (daemons, session workers,\n" ++
                    "helpers), warning about a daemon its own socket no longer reaches.\n" ++
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
    warns += checkProcesses(allocator, palette);
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

const SocketState = enum { serving, gone, taken, refused, unknown };

const DaemonProbe = struct {
    path: []const u8 = "",
    state: SocketState = .unknown,
    /// Process answering the socket instead, when `state` is `.taken`.
    peer: c.pid_t = 0,
    /// Live sessions the daemon listed; null when it could not be asked.
    sessions: ?u32 = null,
};

/// Session names keyed by the listed process holding each session.
const SessionNames = std.AutoHashMapUnmanaged(c.pid_t, std.ArrayList([]const u8));

/// Resolve a daemon's socket, check the daemon itself answers it, and note which listed
/// process holds each of its sessions. Reads only; a socket it cannot reach is reported.
fn probeDaemon(a: std.mem.Allocator, inv: *const procinv.Inventory, p: *const procinv.Proc, names: *SessionNames) DaemonProbe {
    const env_buf = a.alloc(u8, 1 << 16) catch return .{};
    const path = (procinv.daemonSocket(a, p, platform.environOfPid(p.pid, env_buf)) catch null) orelse return .{};
    const raw = mux_client.Conn.connect(a, path) catch
        return .{ .path = path, .state = if (pathExists(path)) .refused else .gone };
    const peer = platform.unixPeerPid(raw.fd) orelse p.pid;
    if (peer != p.pid) {
        var other = raw;
        other.deinit();
        return .{ .path = path, .state = .taken, .peer = peer };
    }
    var probe = DaemonProbe{ .path = path, .state = .serving };
    var conn = mux_client.Conn.probe(a, raw) catch return probe;
    defer conn.deinit();
    conn.sendFrame(.list, "") catch return probe;
    const frame = conn.recvExpectFor(&.{.welcome}, 3_000) catch return probe;
    defer frame.deinit(a);
    const welcome = std.json.parseFromSliceLeaky(Welcome, a, frame.payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return probe;
    var live: u32 = 0;
    for (welcome.sessions) |s| {
        if (s.exited) continue;
        live += 1;
        const holder = inv.sessionHolder(std.math.cast(c.pid_t, s.pid) orelse continue) orelse continue;
        const entry = names.getOrPut(a, holder.pid) catch continue;
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        entry.value_ptr.append(a, s.name) catch {};
    }
    probe.sessions = live;
    return probe;
}

/// Warnings a probe raises: a live daemon no client can reach.
fn probeWarns(p: *const procinv.Proc, probe: DaemonProbe) u32 {
    if (!p.isDaemon()) return 0;
    return switch (probe.state) {
        .gone, .taken, .refused => 1,
        .serving, .unknown => 0,
    };
}

fn formatAge(buf: []u8, ms: i64) []const u8 {
    if (ms < 0) return "up ?";
    const s: u64 = @intCast(@divTrunc(ms, 1000));
    return (if (s < 60)
        std.fmt.bufPrint(buf, "up {d}s", .{s})
    else if (s < 3600)
        std.fmt.bufPrint(buf, "up {d}m", .{s / 60})
    else if (s < 86400)
        std.fmt.bufPrint(buf, "up {d}h{d:0>2}m", .{ s / 3600, s / 60 % 60 })
    else
        std.fmt.bufPrint(buf, "up {d}d{d}h", .{ s / 86400, s / 3600 % 24 })) catch "up ?";
}

/// Most session names printed on one daemon row before the rest collapse into a count.
const max_row_sessions = 6;

fn writeProcRow(writer: *std.Io.Writer, palette: Palette, p: *const procinv.Proc, probe: DaemonProbe, sessions: []const []const u8) !void {
    const indent = 10 + 2 * @as(usize, p.depth);
    for (0..indent) |_| try writer.writeByte(' ');
    var label_buf: [96]u8 = undefined;
    var age_buf: [24]u8 = undefined;
    // Unsigned: a signed integer given a width prints its sign ("+101").
    try writer.print("{s}pid {d:<7}{s} {s:<18} {s}{s:<9}{s}", .{
        zspan(palette.pid),
        @as(u32, @intCast(@max(p.pid, 0))),
        zspan(palette.reset),
        p.label(&label_buf),
        zspan(palette.dim),
        formatAge(&age_buf, p.age_ms),
        zspan(palette.reset),
    });
    if (p.isDaemon()) switch (probe.state) {
        .serving => {
            try writer.print(" {s}", .{probe.path});
            if (probe.sessions) |n| try writer.print("  {d} session(s)", .{n});
        },
        .gone => try writer.print(" {s}socket gone: {s}{s}", .{ zspan(palette.warn), probe.path, zspan(palette.reset) }),
        .taken => try writer.print(" {s}{s} is answered by pid {d}{s}", .{ zspan(palette.warn), probe.path, probe.peer, zspan(palette.reset) }),
        .refused => try writer.print(" {s}{s} refuses connections{s}", .{ zspan(palette.warn), probe.path, zspan(palette.reset) }),
        .unknown => try writer.print(" {s}socket unknown{s}", .{ zspan(palette.dim), zspan(palette.reset) }),
    };
    for (sessions[0..@min(sessions.len, max_row_sessions)], 0..) |name, i| {
        try writer.print("{s}'{s}'", .{ if (i == 0) " " else ", ", name });
    }
    if (sessions.len > max_row_sessions) try writer.print(" +{d} more", .{sessions.len - max_row_sessions});
    if (p.folded > 0) try writer.print(" +{d} subprocess(es)", .{p.folded});
    if (p.replaced) try writer.print(" {s}[binary replaced since start]{s}", .{ zspan(palette.note), zspan(palette.reset) });
    try writer.writeByte('\n');

    if (probeWarns(p, probe) == 0) return;
    for (0..indent + 2) |_| try writer.writeByte(' ');
    const why = switch (probe.state) {
        .gone => "its socket file was removed",
        .taken => "another daemon now answers its socket",
        else => "its socket refuses connections",
    };
    try writer.print("{s}WARN unreachable: {s}; its sessions live on with no way in (kill {d} ends them){s}\n", .{
        zspan(palette.warn), why, p.pid, zspan(palette.reset),
    });
}

/// List every sketerm process of this user as a tree, warning about daemons nobody can reach.
fn checkProcesses(allocator: std.mem.Allocator, palette: Palette) u32 {
    var inv = procinv.scan(allocator, c.getpid()) catch |err| {
        printLabel(palette, "processes");
        switch (err) {
            error.Unsupported => {
                _ = c.printf("%snot inspectable on this platform%s\n", palette.dim, palette.reset);
                return 0;
            },
            error.OutOfMemory => {
                _ = c.printf("%sout of memory while scanning%s\n", palette.warn, palette.reset);
                return 1;
            },
        }
    };
    defer inv.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var names: SessionNames = .empty;
    const probes = a.alloc(DaemonProbe, inv.procs.len) catch return 1;
    var folded: u32 = 0;
    for (inv.procs, probes) |*p, *probe| {
        probe.* = if (p.isDaemon()) probeDaemon(a, &inv, p, &names) else .{};
        folded += p.folded;
    }

    printLabel(palette, "processes");
    if (inv.procs.len == 0) {
        _ = c.printf("%snone running%s\n", palette.dim, palette.reset);
        return 0;
    }
    _ = c.printf("%u running", @as(c_uint, @intCast(inv.procs.len)));
    if (folded > 0) _ = c.printf(", plus %u browser subprocess(es)", @as(c_uint, folded));
    _ = c.printf("\n");

    var warns: u32 = 0;
    for (inv.procs, probes) |*p, probe| {
        const held: []const []const u8 = if (names.get(p.pid)) |list| list.items else &.{};
        var aw: std.Io.Writer.Allocating = .init(a);
        writeProcRow(&aw.writer, palette, p, probe, held) catch continue;
        const row = aw.written();
        _ = c.fwrite(row.ptr, 1, row.len, platform.stdout());
        warns += probeWarns(p, probe);
    }
    return warns;
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

test "doctor process rows nest by depth and name what a daemon serves" {
    const allocator = std.testing.allocator;
    const contains = struct {
        fn f(haystack: []const u8, needle: []const u8) !void {
            if (std.mem.indexOf(u8, haystack, needle) == null) {
                std.debug.print("missing '{s}' in: {s}\n", .{ needle, haystack });
                return error.TestUnexpectedResult;
            }
        }
    }.f;

    const worker = procinv.Proc{ .pid = 101, .ppid = 100, .age_ms = 3_725_000, .argv = "sketerm-mux\x00--broker", .name = "sketerm-mux", .replaced = false, .role = .worker, .mode = .daemon, .depth = 1 };
    var plain: std.Io.Writer.Allocating = .init(allocator);
    defer plain.deinit();
    try writeProcRow(&plain.writer, Palette.init(false), &worker, .{}, &.{"main"});
    try std.testing.expectStringStartsWith(plain.written(), "            pid 101 ");
    try contains(plain.written(), "session worker");
    try contains(plain.written(), "up 1h02m");
    try contains(plain.written(), " 'main'");
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, plain.written(), 0x1b));
    try std.testing.expectEqual(@as(u32, 0), probeWarns(&worker, .{}));

    const broker = procinv.Proc{ .pid = 100, .ppid = 1, .age_ms = 90_000_000, .argv = "sketerm-mux\x00--broker", .name = "sketerm-mux", .replaced = true, .role = .daemon, .mode = .daemon };
    const gone = DaemonProbe{ .path = "/run/user/1000/sketerm/mux.sock", .state = .gone };
    var warned: std.Io.Writer.Allocating = .init(allocator);
    defer warned.deinit();
    try writeProcRow(&warned.writer, Palette.init(false), &broker, gone, &.{});
    try contains(warned.written(), " daemon ");
    try contains(warned.written(), "up 1d1h");
    try contains(warned.written(), "socket gone: /run/user/1000/sketerm/mux.sock");
    try contains(warned.written(), "[binary replaced since start]");
    try contains(warned.written(), "WARN unreachable: its socket file was removed");
    try contains(warned.written(), "kill 100");
    try std.testing.expectEqual(@as(u32, 1), probeWarns(&broker, gone));

    var serving: std.Io.Writer.Allocating = .init(allocator);
    defer serving.deinit();
    try writeProcRow(&serving.writer, Palette.init(false), &broker, .{ .path = "/tmp/a/mux.sock", .state = .serving, .sessions = 2 }, &.{});
    try contains(serving.written(), "/tmp/a/mux.sock  2 session(s)");
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, serving.written(), "WARN"));
}

test "doctor ages read at a glance" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("up ?", formatAge(&buf, -1));
    try std.testing.expectEqualStrings("up 59s", formatAge(&buf, 59_999));
    try std.testing.expectEqualStrings("up 12m", formatAge(&buf, 12 * 60_000));
    try std.testing.expectEqualStrings("up 3h05m", formatAge(&buf, (3 * 3600 + 5 * 60) * 1000));
    try std.testing.expectEqualStrings("up 2d4h", formatAge(&buf, (2 * 86400 + 4 * 3600) * 1000));
}
