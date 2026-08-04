//! `sketerm-mux display ...` manages native headless Wayland displays.
//!
//! Persistent `create` sessions are normal named mux APP sessions whose
//! child is a daemon-owned keeper. `run` adds the xvfb-run-shaped lifecycle:
//! it creates a display, runs one outside command with the exact environment,
//! forwards termination signals, returns the command status, and destroys the
//! display. Socket paths always come from the daemon; callers never derive
//! broker/worker naming details.

const std = @import("std");
const c = @import("../c.zig").c;
const client = @import("client.zig");
const daemon = @import("daemon.zig");
const platform = @import("../util/platform.zig");
const wlcomp = @import("../wlhost/compositor.zig");
const xwayland = @import("xwayland.zig");

pub const HELP =
    \\Usage: sketerm-mux display <command> [options]
    \\
    \\  create [--name NAME] [--size WxH] [--isolated] [--gpu]
    \\         [--xwayland|--no-xwayland]
    \\         [--ttl SECS] [--json]
    \\  run    [--name NAME] [--size WxH] [--isolated] [--gpu]
    \\         [--xwayland|--no-xwayland]
    \\         [--ttl SECS] -- COMMAND [ARG...]
    \\  inspect NAME [--json]
    \\  list [--json]
    \\  destroy NAME [--json]
    \\
    \\`create` is durable. `run` is command-scoped like xvfb-run: it applies
    \\the display environment itself, returns COMMAND's status, and cleans up.
    \\Names are generated when omitted. The default output is 1920x1080;
    \\use --size when layout tests require deterministic geometry.
    \\
    \\Global options: --socket PATH   talk to a specific daemon instance
    \\                -h, --help      show command help
    \\
;

const CREATE_HELP =
    \\Usage: sketerm-mux display create [options]
    \\
    \\Options:
    \\  --name NAME    persistent session name (generated when omitted)
    \\  --size WxH     virtual output pixels (default 1920x1080)
    \\  --isolated     private XDG_RUNTIME_DIR for the display
    \\  --gpu          use the real GPU instead of forcing software GL
    \\  --xwayland     require rootless X11 compatibility
    \\  --no-xwayland  disable automatic rootless X11 compatibility
    \\  --ttl SECS     destroy after this long with no viewer or Wayland client
    \\  --json         print machine-readable session, output, and environment
    \\  --socket PATH  talk to a specific daemon instance
    \\
;

const RUN_HELP =
    \\Usage: sketerm-mux display run [options] -- COMMAND [ARG...]
    \\
    \\Creates a native Wayland display, runs COMMAND directly (no shell),
    \\forwards INT/TERM/HUP/QUIT to its process group, returns its status,
    \\and destroys the display. X11 applications use rootless Xwayland when
    \\available; --xwayland requires it and --no-xwayland disables it.
    \\
    \\Options are the same as `display create`; --ttl defaults to 300 seconds
    \\for crash cleanup and only counts while no viewer or Wayland client is
    \\connected. The command itself has no implicit timeout.
    \\
;

const INSPECT_HELP = "Usage: sketerm-mux display inspect NAME [--json] [--socket PATH]\n";
const LIST_HELP = "Usage: sketerm-mux display list [--json] [--socket PATH]\n";
const DESTROY_HELP = "Usage: sketerm-mux display destroy NAME [--json] [--socket PATH]\n";

const Sess = struct {
    name: []const u8 = "",
    rows: u16 = 0,
    cols: u16 = 0,
    clients: u32 = 0,
    exited: bool = false,
    app: bool = false,
    pid: i32 = 0,
    display: bool = false,
    xwayland: bool = false,
    x_display: []const u8 = "",
    xauthority: []const u8 = "",
    gpu: bool = false,
    output_width: u32 = wlcomp.DEFAULT_OUTPUT_WIDTH,
    output_height: u32 = wlcomp.DEFAULT_OUTPUT_HEIGHT,
    wl_display: []const u8 = "",
    pulse_server: []const u8 = "",
    runtime_dir: []const u8 = "",
    ttl_secs: u32 = 0,
    viewers: u32 = 0,
    controller: []const u8 = "",
};

const Listing = struct {
    proto: u32 = 0,
    sessions: []Sess = &.{},
};

const Args = struct {
    cmd: []const u8 = "",
    name: []const u8 = "",
    socket: ?[]const u8 = null,
    isolated: bool = false,
    gpu: bool = false,
    xwayland: enum { auto, required, disabled } = .auto,
    ttl: u32 = 0,
    ttl_set: bool = false,
    json: bool = false,
    help: bool = false,
    size_set: bool = false,
    output_width: u32 = wlcomp.DEFAULT_OUTPUT_WIDTH,
    output_height: u32 = wlcomp.DEFAULT_OUTPUT_HEIGHT,
    command: []const []const u8 = &.{},
};

fn sigNoop(_: c_int) callconv(.c) void {}

fn errPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "sketerm-mux display: " ++ fmt ++ "\n", args) catch return;
    _ = c.write(2, msg.ptr, msg.len);
}

fn outPrint(bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(1, bytes.ptr + off, bytes.len - off);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn parseSize(text: []const u8) ?[2]u32 {
    const split = std.mem.indexOfScalar(u8, text, 'x') orelse
        std.mem.indexOfScalar(u8, text, 'X') orelse return null;
    if (split == 0 or split + 1 >= text.len) return null;
    const width = std.fmt.parseInt(u32, text[0..split], 10) catch return null;
    const height = std.fmt.parseInt(u32, text[split + 1 ..], 10) catch return null;
    if (width == 0 or height == 0 or width > 16_384 or height > 16_384) return null;
    if (@as(u64, width) * height > 64 * 1024 * 1024) return null;
    return .{ width, height };
}

fn parseArgs(argv: []const []const u8) ?Args {
    var a: Args = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const s = argv[i];
        if (std.mem.eql(u8, s, "--")) {
            a.command = argv[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, s, "--name")) {
            if (i + 1 >= argv.len) {
                errPrint("--name needs a value", .{});
                return null;
            }
            i += 1;
            a.name = argv[i];
        } else if (std.mem.eql(u8, s, "--socket")) {
            if (i + 1 >= argv.len) {
                errPrint("--socket needs a path", .{});
                return null;
            }
            i += 1;
            a.socket = argv[i];
        } else if (std.mem.eql(u8, s, "--ttl")) {
            if (i + 1 >= argv.len) {
                errPrint("--ttl needs whole seconds", .{});
                return null;
            }
            i += 1;
            a.ttl = std.fmt.parseInt(u32, argv[i], 10) catch {
                errPrint("bad --ttl '{s}' (want whole seconds)", .{argv[i]});
                return null;
            };
            a.ttl_set = true;
        } else if (std.mem.eql(u8, s, "--size")) {
            if (i + 1 >= argv.len) {
                errPrint("--size needs WxH", .{});
                return null;
            }
            i += 1;
            const size = parseSize(argv[i]) orelse {
                errPrint("bad --size '{s}' (want WxH, max 16384 per side and 64 megapixels)", .{argv[i]});
                return null;
            };
            a.output_width = size[0];
            a.output_height = size[1];
            a.size_set = true;
        } else if (std.mem.eql(u8, s, "--isolated")) {
            a.isolated = true;
        } else if (std.mem.eql(u8, s, "--gpu")) {
            a.gpu = true;
        } else if (std.mem.eql(u8, s, "--xwayland")) {
            a.xwayland = .required;
        } else if (std.mem.eql(u8, s, "--no-xwayland")) {
            a.xwayland = .disabled;
        } else if (std.mem.eql(u8, s, "--json")) {
            a.json = true;
        } else if (std.mem.eql(u8, s, "--help") or std.mem.eql(u8, s, "-h")) {
            a.help = true;
        } else if (std.mem.startsWith(u8, s, "-")) {
            errPrint("unknown option '{s}'", .{s});
            return null;
        } else if (a.cmd.len == 0) {
            a.cmd = s;
        } else if (a.name.len == 0) {
            a.name = s;
        } else {
            errPrint("unexpected argument '{s}'", .{s});
            return null;
        }
    }
    return a;
}

fn commandHelp(cmd: []const u8) []const u8 {
    if (std.mem.eql(u8, cmd, "create")) return CREATE_HELP;
    if (std.mem.eql(u8, cmd, "run")) return RUN_HELP;
    if (std.mem.eql(u8, cmd, "inspect")) return INSPECT_HELP;
    if (std.mem.eql(u8, cmd, "list")) return LIST_HELP;
    if (std.mem.eql(u8, cmd, "destroy")) return DESTROY_HELP;
    return HELP;
}

fn validateArgs(a: Args) bool {
    const create_or_run = std.mem.eql(u8, a.cmd, "create") or std.mem.eql(u8, a.cmd, "run");
    if (!create_or_run and (a.isolated or a.gpu or a.ttl_set or a.size_set or a.xwayland != .auto)) {
        errPrint("{s} does not accept create options", .{a.cmd});
        return false;
    }
    if (std.mem.eql(u8, a.cmd, "list") and a.name.len > 0) {
        errPrint("list takes no session name", .{});
        return false;
    }
    if ((std.mem.eql(u8, a.cmd, "inspect") or std.mem.eql(u8, a.cmd, "destroy")) and a.name.len == 0) {
        errPrint("{s} needs a session name", .{a.cmd});
        return false;
    }
    if (create_or_run and a.name.len > 64) {
        errPrint("--name must be at most 64 bytes", .{});
        return false;
    }
    if (std.mem.eql(u8, a.cmd, "run")) {
        if (a.command.len == 0) {
            errPrint("run needs -- COMMAND [ARG...]", .{});
            return false;
        }
        if (a.json) {
            errPrint("run does not accept --json (the command owns stdout)", .{});
            return false;
        }
    } else if (a.command.len > 0) {
        errPrint("only run accepts arguments after --", .{});
        return false;
    }
    return true;
}

fn connect(allocator: std.mem.Allocator, sock: ?[]const u8) ?client.Conn {
    return client.Conn.connectLocalAutostartAt(allocator, sock) catch |err| {
        errPrint("daemon unreachable: {s}", .{@errorName(err)});
        return null;
    };
}

fn listSessions(allocator: std.mem.Allocator, conn: *client.Conn) ?std.json.Parsed(Listing) {
    conn.sendFrame(.list, "") catch {
        errPrint("list request failed", .{});
        return null;
    };
    const frame = conn.recvExpectFor(&.{.welcome}, 15_000) catch {
        errPrint("list: no answer from the daemon", .{});
        return null;
    };
    defer frame.deinit(allocator);
    return std.json.parseFromSlice(Listing, allocator, frame.payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        errPrint("list: unparseable answer", .{});
        return null;
    };
}

const Env = struct {
    wayland_display: []const u8,
    xdg_runtime_dir: []const u8,
    pulse_socket: []const u8,
    x_display: []const u8,
    xauthority: []const u8,
    software_gl: bool,
};

fn pulseServer(buf: []u8, sock: []const u8) []const u8 {
    if (sock.len == 0) return "";
    return std.fmt.bufPrint(buf, "unix:{s}", .{sock}) catch "";
}

fn envOf(s: Sess) Env {
    return .{
        .wayland_display = s.wl_display,
        .xdg_runtime_dir = if (s.runtime_dir.len > 0) s.runtime_dir else platform.runtimeDir(),
        .pulse_socket = s.pulse_server,
        .x_display = if (s.xwayland) s.x_display else "",
        .xauthority = if (s.xwayland) s.xauthority else "",
        .software_gl = !s.gpu,
    };
}

fn writeEnvJson(w: *std.Io.Writer, env: Env) !void {
    try w.writeAll("{\"WAYLAND_DISPLAY\":");
    try std.json.Stringify.value(env.wayland_display, .{}, w);
    try w.writeAll(",\"XDG_RUNTIME_DIR\":");
    try std.json.Stringify.value(env.xdg_runtime_dir, .{}, w);
    try w.writeAll(",\"XDG_SESSION_TYPE\":\"wayland\"");
    if (env.x_display.len > 0 and env.xauthority.len > 0) {
        try w.writeAll(",\"DISPLAY\":");
        try std.json.Stringify.value(env.x_display, .{}, w);
        try w.writeAll(",\"XAUTHORITY\":");
        try std.json.Stringify.value(env.xauthority, .{}, w);
        try w.writeAll(",\"_JAVA_AWT_WM_NONREPARENTING\":\"1\"");
    }
    if (env.pulse_socket.len > 0) {
        var pbuf: [4200]u8 = undefined;
        try w.writeAll(",\"PULSE_SERVER\":");
        try std.json.Stringify.value(pulseServer(&pbuf, env.pulse_socket), .{}, w);
    }
    if (env.software_gl) try w.writeAll(",\"LIBGL_ALWAYS_SOFTWARE\":\"1\"");
    try w.writeAll("}");
}

const Created = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    wl_display: []u8,
    pulse_server: []u8,
    runtime_dir: []u8,
    x_display: []u8,
    xauthority: []u8,
    xwayland: bool,
    pid: i32,
    gpu: bool,
    isolated: bool,
    output_width: u32,
    output_height: u32,

    fn deinit(self: *Created) void {
        self.allocator.free(self.name);
        self.allocator.free(self.wl_display);
        self.allocator.free(self.pulse_server);
        self.allocator.free(self.runtime_dir);
        self.allocator.free(self.x_display);
        self.allocator.free(self.xauthority);
    }

    fn sess(self: *const Created) Sess {
        return .{
            .name = self.name,
            .display = true,
            .gpu = self.gpu,
            .xwayland = self.xwayland,
            .x_display = self.x_display,
            .xauthority = self.xauthority,
            .output_width = self.output_width,
            .output_height = self.output_height,
            .wl_display = self.wl_display,
            .pulse_server = self.pulse_server,
            .runtime_dir = self.runtime_dir,
        };
    }
};

fn generatedName(buf: *[64]u8) []const u8 {
    var random: [8]u8 = undefined;
    if (c.getentropy(&random, random.len) != 0) {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        std.mem.writeInt(u64, &random, @bitCast(@as(i64, ts.tv_nsec) ^ @as(i64, c.getpid())), .little);
    }
    const nonce = std.mem.readInt(u64, &random, .little);
    return std.fmt.bufPrint(buf, "display-{d}-{x}", .{ c.getpid(), nonce }) catch "display-auto";
}

fn waitSocketGone(path: []const u8) bool {
    if (path.len == 0) return true;
    var zbuf: [4096:0]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return false;
    var tries: u32 = 0;
    while (tries < 100) : (tries += 1) {
        if (c.access(z.ptr, c.F_OK) != 0) return true;
        _ = c.usleep(50_000);
    }
    return c.access(z.ptr, c.F_OK) != 0;
}

fn destroyRaw(allocator: std.mem.Allocator, conn: *client.Conn, name: []const u8, pid: i32, wl_path: []const u8) bool {
    if (!conn.display_v2) {
        errPrint("daemon is too old for safe display destruction; upgrade sketerm-mux", .{});
        return false;
    }
    conn.sendJson(.kill, .{
        .name = name,
        .require_display = true,
        .expected_pid = pid,
        .expected_wl_display = wl_path,
    }) catch {
        errPrint("destroy '{s}': request failed", .{name});
        return false;
    };
    const frame = conn.recvExpectFor(&.{.ok}, 15_000) catch |err| {
        if (err == error.DaemonError)
            errPrint("destroy '{s}' failed: {s}", .{ name, conn.lastErr() })
        else
            errPrint("destroy '{s}' failed: {s}", .{ name, @errorName(err) });
        return false;
    };
    frame.deinit(allocator);
    if (!waitSocketGone(wl_path)) {
        errPrint("destroy '{s}' timed out waiting for its Wayland socket to close", .{name});
        return false;
    }
    return true;
}

fn spawnDisplay(allocator: std.mem.Allocator, conn: *client.Conn, a: Args, name: []const u8) ?Created {
    if (!conn.display_v2) {
        errPrint("daemon is too old for display lifecycle safety; upgrade sketerm-mux", .{});
        return null;
    }
    conn.sendJson(.spawn, .{
        .name = name,
        .app = true,
        .display = true,
        .xwayland = a.xwayland != .disabled,
        .require_xwayland = a.xwayland == .required,
        .isolated = a.isolated,
        .gpu = a.gpu,
        .ttl_secs = a.ttl,
        .output_width = a.output_width,
        .output_height = a.output_height,
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
    }) catch {
        errPrint("create: spawn request failed", .{});
        return null;
    };
    const Reply = struct {
        pid: i32 = 0,
        wl_display: []const u8 = "",
        pulse_server: []const u8 = "",
        runtime_dir: []const u8 = "",
        xwayland: bool = false,
        x_display: []const u8 = "",
        xauthority: []const u8 = "",
        gpu: bool = false,
        output_width: u32 = wlcomp.DEFAULT_OUTPUT_WIDTH,
        output_height: u32 = wlcomp.DEFAULT_OUTPUT_HEIGHT,
    };
    const frame = conn.recvExpectFor(&.{.ok}, 30_000) catch |err| {
        if (err == error.DaemonError)
            errPrint("create '{s}' failed: {s}", .{ name, conn.lastErr() })
        else
            errPrint("create '{s}' failed: {s}", .{ name, @errorName(err) });
        return null;
    };
    var parsed = blk: {
        defer frame.deinit(allocator);
        break :blk std.json.parseFromSlice(Reply, allocator, frame.payload, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch {
            // Without a parsed pid/socket identity, a name-only rollback
            // could kill a replacement display created by another process.
            errPrint("create '{s}': unparseable daemon reply; refusing unsafe name-only rollback", .{name});
            return null;
        };
    };
    defer parsed.deinit();
    const r = parsed.value;
    if (r.wl_display.len == 0) {
        errPrint("session '{s}' came up without a Wayland display", .{name});
        if (r.pid != 0) _ = destroyRaw(allocator, conn, name, r.pid, "");
        return null;
    }
    if (a.size_set and (r.output_width != a.output_width or r.output_height != a.output_height)) {
        errPrint("daemon did not apply requested output size {d}x{d}", .{ a.output_width, a.output_height });
        _ = destroyRaw(allocator, conn, name, r.pid, r.wl_display);
        return null;
    }
    if (a.xwayland == .required and !r.xwayland) {
        errPrint("daemon could not start required rootless Xwayland", .{});
        _ = destroyRaw(allocator, conn, name, r.pid, r.wl_display);
        return null;
    }
    if (r.xwayland and !xwayland.waitReady(r.x_display, r.xauthority, 10_000)) {
        errPrint("rootless Xwayland at {s} did not become ready", .{r.x_display});
        _ = destroyRaw(allocator, conn, name, r.pid, r.wl_display);
        if (a.xwayland == .auto) {
            errPrint("continuing with a Wayland-only display", .{});
            var fallback = a;
            fallback.xwayland = .disabled;
            return spawnDisplay(allocator, conn, fallback, name);
        }
        return null;
    }
    const name_owned = allocator.dupe(u8, name) catch {
        errPrint("create '{s}': out of memory", .{name});
        if (conn.display_v2) _ = destroyRaw(allocator, conn, name, r.pid, r.wl_display);
        return null;
    };
    const wl_owned = allocator.dupe(u8, r.wl_display) catch {
        allocator.free(name_owned);
        if (conn.display_v2) _ = destroyRaw(allocator, conn, name, r.pid, r.wl_display);
        return null;
    };
    const pa_owned = allocator.dupe(u8, r.pulse_server) catch {
        allocator.free(wl_owned);
        allocator.free(name_owned);
        if (conn.display_v2) _ = destroyRaw(allocator, conn, name, r.pid, r.wl_display);
        return null;
    };
    const rt_owned = allocator.dupe(u8, r.runtime_dir) catch {
        allocator.free(pa_owned);
        allocator.free(wl_owned);
        allocator.free(name_owned);
        if (conn.display_v2) _ = destroyRaw(allocator, conn, name, r.pid, r.wl_display);
        return null;
    };
    const x_owned = allocator.dupe(u8, r.x_display) catch {
        allocator.free(rt_owned);
        allocator.free(pa_owned);
        allocator.free(wl_owned);
        allocator.free(name_owned);
        if (conn.display_v2) _ = destroyRaw(allocator, conn, name, r.pid, r.wl_display);
        return null;
    };
    const xa_owned = allocator.dupe(u8, r.xauthority) catch {
        allocator.free(x_owned);
        allocator.free(rt_owned);
        allocator.free(pa_owned);
        allocator.free(wl_owned);
        allocator.free(name_owned);
        if (conn.display_v2) _ = destroyRaw(allocator, conn, name, r.pid, r.wl_display);
        return null;
    };
    return .{
        .allocator = allocator,
        .name = name_owned,
        .wl_display = wl_owned,
        .pulse_server = pa_owned,
        .runtime_dir = rt_owned,
        .x_display = x_owned,
        .xauthority = xa_owned,
        .xwayland = r.xwayland,
        .pid = r.pid,
        .gpu = r.gpu,
        .isolated = a.isolated,
        .output_width = r.output_width,
        .output_height = r.output_height,
    };
}

fn printCreated(allocator: std.mem.Allocator, created: *const Created, json: bool) !void {
    const env = envOf(created.sess());
    if (!json) {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.writer.print("session {s}\npid={d}\noutput={d}x{d}\nWAYLAND_DISPLAY={s}\nXDG_RUNTIME_DIR={s}\nXDG_SESSION_TYPE=wayland\n", .{
            created.name,
            created.pid,
            created.output_width,
            created.output_height,
            env.wayland_display,
            env.xdg_runtime_dir,
        });
        if (env.pulse_socket.len > 0) {
            var pbuf: [4200]u8 = undefined;
            try aw.writer.print("PULSE_SERVER={s}\n", .{pulseServer(&pbuf, env.pulse_socket)});
        }
        if (env.x_display.len > 0) {
            try aw.writer.print("DISPLAY={s}\nXAUTHORITY={s}\n_JAVA_AWT_WM_NONREPARENTING=1\n", .{ env.x_display, env.xauthority });
        }
        if (env.software_gl) try aw.writer.writeAll("LIBGL_ALWAYS_SOFTWARE=1\n");
        try aw.writer.writeAll("unset WAYLAND_SOCKET");
        if (env.x_display.len == 0) try aw.writer.writeAll(" DISPLAY XAUTHORITY");
        if (created.isolated) try aw.writer.writeAll(" DBUS_SESSION_BUS_ADDRESS");
        if (created.gpu) try aw.writer.writeAll(" LIBGL_ALWAYS_SOFTWARE");
        if (created.pulse_server.len == 0) try aw.writer.writeAll(" PULSE_SERVER");
        try aw.writer.writeAll("\n");
        return outPrint(aw.written());
    }
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"session\":");
    try std.json.Stringify.value(created.name, .{}, w);
    try w.print(",\"pid\":{d},\"output\":{{\"width\":{d},\"height\":{d}}},\"gpu\":{},\"xwayland\":{},\"environment\":", .{
        created.pid, created.output_width, created.output_height, created.gpu, created.xwayland,
    });
    try writeEnvJson(w, env);
    try w.writeAll(",\"unset_environment\":[\"WAYLAND_SOCKET\"");
    if (env.x_display.len == 0) try w.writeAll(",\"DISPLAY\",\"XAUTHORITY\"");
    if (created.isolated) try w.writeAll(",\"DBUS_SESSION_BUS_ADDRESS\"");
    if (created.gpu) try w.writeAll(",\"LIBGL_ALWAYS_SOFTWARE\"");
    if (created.pulse_server.len == 0) try w.writeAll(",\"PULSE_SERVER\"");
    try w.writeAll("]}\n");
    return outPrint(aw.written());
}

fn create(allocator: std.mem.Allocator, a: Args) u8 {
    var name_buf: [64]u8 = undefined;
    const name = if (a.name.len > 0) a.name else generatedName(&name_buf);
    var conn = connect(allocator, a.socket) orelse return 1;
    defer conn.deinit();
    var created = spawnDisplay(allocator, &conn, a, name) orelse return 1;
    defer created.deinit();
    printCreated(allocator, &created, a.json) catch {
        errPrint("could not write create result; rolling session '{s}' back", .{name});
        _ = destroyRaw(allocator, &conn, name, created.pid, created.wl_display);
        return 1;
    };
    return 0;
}

fn writeSessJson(w: *std.Io.Writer, s: Sess) !void {
    const env = envOf(s);
    try w.writeAll("{\"session\":");
    try std.json.Stringify.value(s.name, .{}, w);
    try w.print(",\"display\":{},\"app\":{},\"exited\":{},\"pid\":{d},\"viewers\":{d},\"ttl_secs\":{d},\"gpu\":{},\"xwayland\":{},\"output\":{{\"width\":{d},\"height\":{d}}}", .{
        s.display, s.app, s.exited, s.pid, s.viewers, s.ttl_secs, s.gpu, s.xwayland, s.output_width, s.output_height,
    });
    try w.writeAll(",\"controller\":");
    if (s.controller.len > 0)
        try std.json.Stringify.value(s.controller, .{}, w)
    else
        try w.writeAll("null");
    try w.writeAll(",\"environment\":");
    try writeEnvJson(w, env);
    try w.writeAll(",\"unset_environment\":[\"WAYLAND_SOCKET\"");
    if (env.x_display.len == 0) try w.writeAll(",\"DISPLAY\",\"XAUTHORITY\"");
    if (s.runtime_dir.len > 0) try w.writeAll(",\"DBUS_SESSION_BUS_ADDRESS\"");
    if (s.gpu) try w.writeAll(",\"LIBGL_ALWAYS_SOFTWARE\"");
    if (s.pulse_server.len == 0) try w.writeAll(",\"PULSE_SERVER\"");
    try w.writeAll("]}");
}

fn inspect(allocator: std.mem.Allocator, a: Args) u8 {
    var conn = connect(allocator, a.socket) orelse return 1;
    defer conn.deinit();
    if (!conn.display_v2) {
        errPrint("daemon is too old to report reliable display metadata; upgrade sketerm-mux", .{});
        return 1;
    }
    var listing = listSessions(allocator, &conn) orelse return 1;
    defer listing.deinit();
    for (listing.value.sessions) |s| {
        if (!std.mem.eql(u8, s.name, a.name)) continue;
        if (!s.display) {
            errPrint("session '{s}' is not a display session", .{a.name});
            return 1;
        }
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        if (a.json) {
            writeSessJson(&aw.writer, s) catch return 1;
            aw.writer.writeAll("\n") catch return 1;
        } else {
            const env = envOf(s);
            var pbuf: [4200]u8 = undefined;
            aw.writer.print(
                "session {s}\noutput={d}x{d}\ngpu={}\nxwayland={}\nviewers={d}\ncontroller={s}\nttl_secs={d}\nexited={}\npid={d}\nWAYLAND_DISPLAY={s}\nXDG_RUNTIME_DIR={s}\nPULSE_SERVER={s}\nDISPLAY={s}\nXAUTHORITY={s}\n",
                .{ s.name, s.output_width, s.output_height, s.gpu, s.xwayland, s.viewers, if (s.controller.len > 0) s.controller else "-", s.ttl_secs, s.exited, s.pid, env.wayland_display, env.xdg_runtime_dir, pulseServer(&pbuf, env.pulse_socket), env.x_display, env.xauthority },
            ) catch return 1;
        }
        outPrint(aw.written()) catch return 1;
        return 0;
    }
    errPrint("no such display session '{s}'", .{a.name});
    return 1;
}

fn list(allocator: std.mem.Allocator, a: Args) u8 {
    var conn = connect(allocator, a.socket) orelse return 1;
    defer conn.deinit();
    if (!conn.display_v2) {
        errPrint("daemon is too old to report reliable display metadata; upgrade sketerm-mux", .{});
        return 1;
    }
    var listing = listSessions(allocator, &conn) orelse return 1;
    defer listing.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    if (a.json) {
        w.writeAll("{\"displays\":[") catch return 1;
        var first = true;
        for (listing.value.sessions) |s| {
            if (!s.display) continue;
            if (!first) w.writeAll(",") catch return 1;
            first = false;
            writeSessJson(w, s) catch return 1;
        }
        w.writeAll("]}\n") catch return 1;
    } else {
        for (listing.value.sessions) |s| {
            if (!s.display) continue;
            w.print("{s}\t{d}x{d}\tviewers={d}\tcontroller={s}\tx11={s}\t{s}\n", .{
                s.name, s.output_width, s.output_height, s.viewers, if (s.controller.len > 0) s.controller else "-", if (s.xwayland) s.x_display else "-", s.wl_display,
            }) catch return 1;
        }
    }
    outPrint(aw.written()) catch return 1;
    return 0;
}

fn destroy(allocator: std.mem.Allocator, a: Args) u8 {
    var conn = connect(allocator, a.socket) orelse return 1;
    defer conn.deinit();
    if (!conn.display_v2) {
        errPrint("daemon is too old for safe display destruction; upgrade sketerm-mux", .{});
        return 1;
    }
    var wl_path: []u8 = allocator.dupe(u8, "") catch return 1;
    defer allocator.free(wl_path);
    var expected_pid: i32 = 0;
    {
        var listing = listSessions(allocator, &conn) orelse return 1;
        defer listing.deinit();
        var found = false;
        for (listing.value.sessions) |s| {
            if (!std.mem.eql(u8, s.name, a.name)) continue;
            found = true;
            if (!s.display) {
                errPrint("session '{s}' is not a display session", .{a.name});
                return 1;
            }
            const fresh = allocator.dupe(u8, s.wl_display) catch return 1;
            allocator.free(wl_path);
            wl_path = fresh;
            expected_pid = s.pid;
            break;
        }
        if (!found) {
            errPrint("no such display session '{s}'", .{a.name});
            return 1;
        }
    }
    if (!destroyRaw(allocator, &conn, a.name, expected_pid, wl_path)) return 1;
    if (a.json)
        outPrint("{\"ok\":true}\n") catch return 1
    else
        outPrint("ok\n") catch return 1;
    return 0;
}

var run_child_pid: c.sig_atomic_t = -1;
var run_signal: c.sig_atomic_t = 0;

fn storeRunPid(value: c.sig_atomic_t) void {
    const ptr: *volatile c.sig_atomic_t = &run_child_pid;
    ptr.* = value;
}

fn loadRunPid() c.sig_atomic_t {
    const ptr: *volatile c.sig_atomic_t = &run_child_pid;
    return ptr.*;
}

fn storeRunSignal(value: c.sig_atomic_t) void {
    const ptr: *volatile c.sig_atomic_t = &run_signal;
    ptr.* = value;
}

fn loadRunSignal() c.sig_atomic_t {
    const ptr: *volatile c.sig_atomic_t = &run_signal;
    return ptr.*;
}

fn forwardRunSignal(pid: c.pid_t, sig: c_int) void {
    if (pid > 0 and c.kill(-pid, sig) < 0) _ = c.kill(pid, sig);
}

const Signal = @TypeOf(std.posix.SIG.INT);

fn onRunSignal(sig: Signal) callconv(.c) void {
    const c_sig: c_int = @intCast(@intFromEnum(sig));
    storeRunSignal(c_sig);
    const pid: c.pid_t = @intCast(loadRunPid());
    forwardRunSignal(pid, c_sig);
}

const run_signals = [_]Signal{ std.posix.SIG.INT, std.posix.SIG.TERM, std.posix.SIG.HUP, std.posix.SIG.QUIT };

fn runSignalSet() std.posix.sigset_t {
    var set = std.posix.sigemptyset();
    for (run_signals) |sig| std.posix.sigaddset(&set, sig);
    return set;
}

fn installRunSignals(old: *[run_signals.len]std.posix.Sigaction) void {
    const action = std.posix.Sigaction{
        .handler = .{ .handler = &onRunSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for (run_signals, 0..) |sig, i| std.posix.sigaction(sig, &action, &old[i]);
}

fn restoreRunSignals(old: *const [run_signals.len]std.posix.Sigaction) void {
    for (run_signals, 0..) |sig, i| std.posix.sigaction(sig, &old[i], null);
}

fn holdRunLease(allocator: std.mem.Allocator, sock: ?[]const u8, name: []const u8) ?client.Conn {
    const path = if (sock) |p| allocator.dupe(u8, p) catch return null else daemon.defaultSocketPath(allocator) catch return null;
    defer allocator.free(path);
    // Deliberately skip hello negotiation: the server's legacy default sends
    // the tiny terminal snapshot but no native app channels, so this lease
    // keeps TTL occupancy without accumulating rendered-frame traffic.
    var lease = client.Conn.connect(allocator, path) catch {
        errPrint("run: could not acquire display lifetime lease", .{});
        return null;
    };
    lease.sendJson(.attach, .{ .name = name, .kind = "cli", .read_only = true }) catch {
        lease.deinit();
        return null;
    };
    const frame = lease.recvExpectFor(&.{.snapshot}, 15_000) catch {
        errPrint("run: display lifetime lease was refused", .{});
        lease.deinit();
        return null;
    };
    frame.deinit(allocator);
    return lease;
}

fn commandStatus(status: c_int) u8 {
    if (c.WIFEXITED(status)) return @intCast(c.WEXITSTATUS(status));
    if (c.WIFSIGNALED(status)) return @intCast(@min(255, 128 + c.WTERMSIG(status)));
    return 125;
}

fn runCommand(allocator: std.mem.Allocator, a_in: Args) u8 {
    var a = a_in;
    if (!a.ttl_set) a.ttl = 300;
    var name_buf: [64]u8 = undefined;
    const name = if (a.name.len > 0) a.name else generatedName(&name_buf);
    var conn = connect(allocator, a.socket) orelse return 125;
    defer conn.deinit();
    if (!conn.display_v2) {
        errPrint("daemon is too old for display run; upgrade sketerm-mux", .{});
        return 125;
    }
    var created = spawnDisplay(allocator, &conn, a, name) orelse return 125;
    defer created.deinit();
    var cleanup_display = true;
    defer {
        if (cleanup_display) _ = destroyRaw(allocator, &conn, name, created.pid, created.wl_display);
    }
    var lease = holdRunLease(allocator, a.socket, name) orelse return 125;
    var lease_live = true;
    defer {
        if (lease_live) lease.deinit();
    }

    var argv_z: std.ArrayList([:0]u8) = .empty;
    defer {
        for (argv_z.items) |arg| allocator.free(arg);
        argv_z.deinit(allocator);
    }
    var argv_ptrs: std.ArrayList(?[*:0]const u8) = .empty;
    defer argv_ptrs.deinit(allocator);
    for (a.command) |arg| {
        const z = allocator.dupeZ(u8, arg) catch {
            return 125;
        };
        argv_z.append(allocator, z) catch {
            allocator.free(z);
            return 125;
        };
        argv_ptrs.append(allocator, z.ptr) catch return 125;
    }
    argv_ptrs.append(allocator, null) catch return 125;

    const env = envOf(created.sess());
    const wl_z = allocator.dupeZ(u8, env.wayland_display) catch return 125;
    defer allocator.free(wl_z);
    const rt_z = allocator.dupeZ(u8, env.xdg_runtime_dir) catch return 125;
    defer allocator.free(rt_z);
    var pulse_z: ?[:0]u8 = null;
    defer if (pulse_z) |p| allocator.free(p);
    if (env.pulse_socket.len > 0)
        pulse_z = std.fmt.allocPrintSentinel(allocator, "unix:{s}", .{env.pulse_socket}, 0) catch return 125;
    const display_z: ?[:0]u8 = if (env.x_display.len > 0) allocator.dupeZ(u8, env.x_display) catch return 125 else null;
    defer if (display_z) |p| allocator.free(p);
    const xauth_z: ?[:0]u8 = if (env.xauthority.len > 0) allocator.dupeZ(u8, env.xauthority) catch return 125 else null;
    defer if (xauth_z) |p| allocator.free(p);

    // Block the forwarded signals through handler installation, fork, process
    // group creation, and PID publication. Pending signals are delivered once
    // after the parent restores its old mask; no replay race is needed.
    const blocked_signals = runSignalSet();
    var old_mask: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &blocked_signals, &old_mask);
    var old_actions: [run_signals.len]std.posix.Sigaction = undefined;
    storeRunPid(-1);
    storeRunSignal(0);
    installRunSignals(&old_actions);
    var signals_finished = false;
    defer {
        if (!signals_finished) {
            restoreRunSignals(&old_actions);
            std.posix.sigprocmask(std.posix.SIG.SETMASK, &old_mask, null);
            storeRunPid(-1);
            storeRunSignal(0);
        }
    }

    const pid = c.fork();
    if (pid < 0) {
        errPrint("run: fork failed", .{});
        return 125;
    }
    if (pid == 0) {
        restoreRunSignals(&old_actions);
        std.posix.sigprocmask(std.posix.SIG.SETMASK, &old_mask, null);
        _ = c.setpgid(0, 0);
        _ = c.close(conn.fd);
        _ = c.close(lease.fd);
        _ = c.setenv("WAYLAND_DISPLAY", wl_z.ptr, 1);
        _ = c.setenv("XDG_RUNTIME_DIR", rt_z.ptr, 1);
        _ = c.setenv("XDG_SESSION_TYPE", "wayland", 1);
        if (display_z) |p| _ = c.setenv("DISPLAY", p.ptr, 1) else _ = c.unsetenv("DISPLAY");
        if (xauth_z) |p| _ = c.setenv("XAUTHORITY", p.ptr, 1) else _ = c.unsetenv("XAUTHORITY");
        if (display_z != null) _ = c.setenv("_JAVA_AWT_WM_NONREPARENTING", "1", 1);
        _ = c.unsetenv("WAYLAND_SOCKET");
        if (a.isolated) _ = c.unsetenv("DBUS_SESSION_BUS_ADDRESS");
        if (pulse_z) |p| _ = c.setenv("PULSE_SERVER", p.ptr, 1) else _ = c.unsetenv("PULSE_SERVER");
        if (env.software_gl)
            _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1)
        else
            _ = c.unsetenv("LIBGL_ALWAYS_SOFTWARE");
        _ = c.execvp(argv_ptrs.items[0].?, @ptrCast(@constCast(argv_ptrs.items.ptr)));
        const exec_errno = std.posix.errno(@as(c_int, -1));
        errPrint("cannot execute '{s}': {s}", .{ a.command[0], @tagName(exec_errno) });
        c._exit(if (exec_errno == .NOENT) 127 else 126);
    }
    _ = c.setpgid(pid, pid);
    storeRunPid(@intCast(pid));
    std.posix.sigprocmask(std.posix.SIG.SETMASK, &old_mask, null);

    var status: c_int = 0;
    var signal_deadline: i64 = 0;
    var sent_kill = false;
    while (true) {
        // Poll with forwarded signals blocked so child-reap -> cleanup-phase
        // transition is atomic with respect to the handler. A signal pending
        // at restore is then recorded as a cleanup signal, never erased.
        var poll_mask: std.posix.sigset_t = undefined;
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &blocked_signals, &poll_mask);
        const waited = c.waitpid(pid, &status, c.WNOHANG);
        if (waited == pid) {
            storeRunPid(-1);
            storeRunSignal(0);
            std.posix.sigprocmask(std.posix.SIG.SETMASK, &poll_mask, null);
            break;
        }
        std.posix.sigprocmask(std.posix.SIG.SETMASK, &poll_mask, null);
        if (waited < 0) {
            if (std.posix.errno(waited) == .INTR) continue;
            errPrint("run: waitpid failed", .{});
            status = 125 << 8;
            break;
        }
        if (loadRunSignal() != 0) {
            var ts: c.struct_timespec = undefined;
            _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
            const now = @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
            if (signal_deadline == 0) signal_deadline = now + 5000;
            if (!sent_kill and now >= signal_deadline) {
                if (c.kill(-pid, c.SIGKILL) < 0) _ = c.kill(pid, c.SIGKILL);
                sent_kill = true;
            }
        }
        _ = c.usleep(20_000);
    }
    storeRunPid(-1);
    const result = commandStatus(status);
    lease.deinit();
    lease_live = false;
    cleanup_display = false;
    var final_result = result;
    if (!destroyRaw(allocator, &conn, name, created.pid, created.wl_display) and result == 0) final_result = 125;

    // Restore caller dispositions while these signals are blocked. Anything
    // arriving after this snapshot is delivered under the caller's policy.
    var cleanup_mask: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &blocked_signals, &cleanup_mask);
    const cleanup_signal = loadRunSignal();
    restoreRunSignals(&old_actions);
    signals_finished = true;
    storeRunPid(-1);
    storeRunSignal(0);
    std.posix.sigprocmask(std.posix.SIG.SETMASK, &cleanup_mask, null);
    if (cleanup_signal != 0) return @intCast(@min(255, 128 + cleanup_signal));
    return final_result;
}

/// Entry point: `argv` is everything after the `display` keyword.
pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) u8 {
    _ = c.signal(c.SIGPIPE, &sigNoop);
    const a = parseArgs(argv) orelse return 2;
    if (a.help) {
        outPrint(commandHelp(a.cmd)) catch return 1;
        return 0;
    }
    if (a.cmd.len == 0) {
        outPrint(HELP) catch return 1;
        return 2;
    }
    if (std.mem.eql(u8, a.cmd, "help")) {
        outPrint(commandHelp(a.name)) catch return 1;
        return 0;
    }
    if (!validateArgs(a)) return 2;
    if (std.mem.eql(u8, a.cmd, "create")) return create(allocator, a);
    if (std.mem.eql(u8, a.cmd, "run")) return runCommand(allocator, a);
    if (std.mem.eql(u8, a.cmd, "inspect")) return inspect(allocator, a);
    if (std.mem.eql(u8, a.cmd, "list")) return list(allocator, a);
    if (std.mem.eql(u8, a.cmd, "destroy")) return destroy(allocator, a);
    errPrint("unknown command '{s}' (want create|run|inspect|list|destroy)", .{a.cmd});
    return 2;
}

test "display: argument parsing covers help, size, and run argv" {
    const t = std.testing;
    const a = parseArgs(&.{ "run", "--name", "d1", "--size", "1024x768", "--isolated", "--gpu", "--ttl", "30", "--", "game", "--level", "one" }).?;
    try t.expectEqualStrings("run", a.cmd);
    try t.expectEqualStrings("d1", a.name);
    try t.expect(a.isolated and a.gpu and a.ttl_set and a.size_set);
    try t.expectEqual(@as(u32, 1024), a.output_width);
    try t.expectEqual(@as(u32, 768), a.output_height);
    try t.expectEqual(@as(usize, 3), a.command.len);
    try t.expectEqualStrings("game", a.command[0]);

    const x11 = parseArgs(&.{ "create", "--xwayland" }).?;
    try t.expectEqual(.required, x11.xwayland);
    const no_x11 = parseArgs(&.{ "run", "--no-xwayland", "--", "true" }).?;
    try t.expectEqual(.disabled, no_x11.xwayland);

    const h = parseArgs(&.{ "create", "--help" }).?;
    try t.expect(h.help);
    try t.expectEqualStrings("create", h.cmd);
    try t.expect(parseSize("0x768") == null);
    try t.expect(parseSize("20000x100") == null);
    try t.expect(parseArgs(&.{ "create", "--ttl", "soon" }) == null);
}

test "display: environment reports native Wayland and actual GPU policy" {
    const t = std.testing;
    const software = Sess{
        .name = "d1",
        .wl_display = "/run/user/1000/sketerm/wl-w42",
        .pulse_server = "/run/user/1000/sketerm/pa-w42",
        .runtime_dir = "/run/user/1000/sketerm/rt-w42",
    };
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    try writeEnvJson(&aw.writer, envOf(software));
    try t.expect(std.mem.indexOf(u8, aw.written(), "\"LIBGL_ALWAYS_SOFTWARE\":\"1\"") != null);
    try t.expect(std.mem.indexOf(u8, aw.written(), "\"XDG_SESSION_TYPE\":\"wayland\"") != null);
    try t.expect(std.mem.indexOf(u8, aw.written(), "\"PULSE_SERVER\":\"unix:/run/user/1000/sketerm/pa-w42\"") != null);

    var gw: std.Io.Writer.Allocating = .init(t.allocator);
    defer gw.deinit();
    var gpu = software;
    gpu.gpu = true;
    try writeEnvJson(&gw.writer, envOf(gpu));
    try t.expect(std.mem.indexOf(u8, gw.written(), "LIBGL_ALWAYS_SOFTWARE") == null);

    var xw: std.Io.Writer.Allocating = .init(t.allocator);
    defer xw.deinit();
    var x11 = software;
    x11.xwayland = true;
    x11.x_display = ":123";
    x11.xauthority = "/run/user/1000/sketerm/xauth";
    try writeEnvJson(&xw.writer, envOf(x11));
    try t.expect(std.mem.indexOf(u8, xw.written(), "\"DISPLAY\":\":123\"") != null);
    try t.expect(std.mem.indexOf(u8, xw.written(), "\"XAUTHORITY\":\"/run/user/1000/sketerm/xauth\"") != null);
}

test "display: logical output dimensions are bounded" {
    const t = std.testing;
    try t.expectEqual([2]u32{ 1024, 768 }, parseSize("1024X768").?);
    try t.expect(parseSize("8192x8193") == null);
    try t.expect(parseSize("1024x768x24") == null);
}
