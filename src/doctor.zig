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
const version = @import("version.zig");
const build_options = @import("build_options");
const opuscodec = @import("mux/opuscodec.zig");

/// Daemon `list` reply; pre-doctor daemons omit version/caps fields
/// and show up as version "" (reported as "pre-0.1.0 or stale").
const Welcome = struct {
    proto: u32,
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

fn onOff(b: bool) [*:0]const u8 {
    return if (b) "on" else "off";
}

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    var host: ?[]const u8 = null;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            _ = c.fputs(
                "Usage: sketerm doctor [host]\n\n" ++
                    "Checks: local daemon reachability + version/proto/capability\n" ++
                    "skew vs this binary, GUI instance sockets, terminfo install.\n" ++
                    "With a host ([domain.<name>], user@box or udp:box): probes the\n" ++
                    "remote sketerm-mux for the same skew.\n\nExit: 0 healthy, 1 warnings.\n",
                platform.stdout(),
            );
            return 0;
        }
        host = a;
    }

    var warns: u32 = 0;

    _ = c.printf(
        "binary    %s  proto %u  opus:%s video:%s\n",
        @as([*:0]const u8, version.string),
        @as(c_uint, wire.PROTO_VERSION),
        onOff(opuscodec.available()),
        onOff(build_options.video),
    );

    warns += checkDaemon(allocator, null);
    warns += checkGui(allocator);
    warns += checkTerminfo(allocator);

    if (host) |h_raw| {
        // [domain.<name>] resolution, like the mux CLI.
        var cfg = @import("config.zig").Config.load(allocator);
        defer cfg.deinit();
        const spec = cfg.resolveDomain(h_raw, allocator);
        defer if (spec) |s| allocator.free(s);
        warns += checkDaemon(allocator, if (spec) |s| s else h_raw);
    }

    if (warns == 0) {
        _ = c.printf("all checks passed\n");
        return 0;
    }
    _ = c.printf("%u warning(s)\n", @as(c_uint, warns));
    return 1;
}

/// Probe one daemon (null = local, no autostart) and report version,
/// proto, capabilities and session count. Returns warning count.
fn checkDaemon(allocator: std.mem.Allocator, host: ?[]const u8) u32 {
    const label: [*:0]const u8 = if (host == null) "daemon" else "remote";

    var conn: mux_client.Conn = undefined;
    if (host == null) {
        // Deliberately no autostart: doctor reports, it doesn't mutate.
        const path = mux_daemon.defaultSocketPath(allocator) catch return 1;
        defer allocator.free(path);
        const raw = mux_client.Conn.connect(allocator, path) catch {
            _ = c.printf("daemon    not running (autostarts on demand) - ok\n");
            return 0;
        };
        conn = mux_client.Conn.probe(allocator, raw) catch {
            _ = c.printf("daemon    accepts connections but the handshake failed\n");
            return 1;
        };
    } else {
        conn = mux_cli.muxConnect(allocator, host) orelse {
            _ = c.printf("remote    %.*s: UNREACHABLE (see error above)\n", @as(c_int, @intCast(host.?.len)), host.?.ptr);
            return 1;
        };
    }
    defer conn.deinit();

    conn.sendFrame(.list, "") catch {
        _ = c.printf("%s    connected but list failed\n", label);
        return 1;
    };
    const f = conn.recvExpect(&.{.welcome}) catch {
        _ = c.printf("%s    connected but no welcome reply\n", label);
        return 1;
    };
    defer f.deinit(allocator);
    const parsed = std.json.parseFromSlice(Welcome, allocator, f.payload, .{
        .ignore_unknown_fields = true,
    }) catch {
        _ = c.printf("%s    malformed list reply\n", label);
        return 1;
    };
    defer parsed.deinit();
    const w = parsed.value;
    const server_proto = w.server_proto orelse w.proto;

    var live: u32 = 0;
    var apps: u32 = 0;
    for (w.sessions) |s| {
        if (!s.exited) live += 1;
        if (s.app) apps += 1;
    }

    const ver: []const u8 = if (w.version.len > 0) w.version else "pre-0.1.0 or stale";
    if (host) |h| {
        _ = c.printf("remote    %.*s: ", @as(c_int, @intCast(h.len)), h.ptr);
    } else {
        _ = c.printf("daemon    ");
    }
    _ = c.printf(
        "%.*s  proto %u (selected %u)  opus:%s video:%s  %u session(s), %u app\n",
        @as(c_int, @intCast(ver.len)),
        ver.ptr,
        @as(c_uint, server_proto),
        @as(c_uint, w.proto),
        onOff(w.audio_opus),
        onOff(w.video),
        @as(c_uint, live),
        @as(c_uint, apps),
    );

    var warns: u32 = 0;
    if (w.proto == 0) {
        _ = c.printf("          warning: no shared terminal profile; sessions are preserved but cannot be attached\n");
        warns += 1;
    }
    if (server_proto != wire.PROTO_VERSION) {
        _ = c.printf("          note: protocol skew uses negotiated profile %u\n", @as(c_uint, w.proto));
    }
    if (!std.mem.eql(u8, w.version, version.string)) {
        _ = c.printf(
            "          note: version skew vs binary %s; running sessions stay on their current daemon\n",
            @as([*:0]const u8, version.string),
        );
    }
    if (opuscodec.available() != w.audio_opus) {
        _ = c.printf("          note: opus mismatch (binary %s, daemon %s) - audio falls back to raw PCM\n", onOff(opuscodec.available()), onOff(w.audio_opus));
    }
    return warns;
}

/// Count live GUI instance sockets (reaps nothing; read-only probe).
fn checkGui(allocator: std.mem.Allocator) u32 {
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
            if (ipc_client.socketAlive(path)) live += 1 else stale += 1;
        }
    }
    if (stale > 0) {
        _ = c.printf("gui       %u live instance(s), %u stale socket(s) (crash leftovers; the CLI self-heals them)\n", @as(c_uint, live), @as(c_uint, stale));
    } else {
        _ = c.printf("gui       %u live instance(s)\n", @as(c_uint, live));
    }
    const in_pane = c.getenv("SKETERM_PANE_ID") != null;
    if (in_pane and c.getenv("SKETERM_SOCKET") == null) {
        _ = c.printf("          WARN inside a pane but SKETERM_SOCKET is unset\n");
        return 1;
    }
    return 0;
}

/// Look for the compiled sketerm-256color terminfo entry in the
/// usual databases. Missing is only a warning when TERM references
/// it (the default child TERM is xterm-256color).
fn checkTerminfo(allocator: std.mem.Allocator) u32 {
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

    for (dirs_buf[0..n]) |d| {
        const p = std.fmt.allocPrintSentinel(allocator, "{s}/s/sketerm-256color", .{d}, 0) catch continue;
        defer allocator.free(p);
        if (c.fopen(p.ptr, "rb")) |fh| {
            _ = c.fclose(fh);
            _ = c.printf("terminfo  ok  %s\n", p.ptr);
            return 0;
        }
    }
    const term = if (c.getenv("TERM")) |t| std.mem.span(t) else "";
    if (std.mem.startsWith(u8, term, "sketerm")) {
        _ = c.printf("terminfo  WARN TERM=%.*s but sketerm-256color is not installed (tic terminfo/sketerm-256color.src)\n", @as(c_int, @intCast(term.len)), term.ptr);
        return 1;
    }
    _ = c.printf("terminfo  sketerm-256color not installed (fine: children default to xterm-256color)\n");
    return 0;
}
