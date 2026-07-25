//! `sketerm-mux display …` — external display sessions.
//!
//! A display session is a normal named mux APP session whose child is
//! a trivial keeper process (`sketerm-mux --keep`): sketerm spawns no
//! application at all. The session exists to own a Wayland display
//! socket (and a PulseAudio hub) that an OUTSIDE process — a Playwright
//! browser, a test harness, anything — renders into, while the daemon
//! records the windows so a human operator can attach later with the
//! normal sketerm GUI and take over interactively.
//!
//! The whole point of `create --json` is that callers never DERIVE the
//! socket paths: `wl-w<pid>` is an internal naming detail and changes
//! between monolith and broker mode. The daemon answers with the exact
//! environment to export.
//!
//! Lives in the daemon binary (target servers install only
//! `sketerm-mux`), so: libc + the mux client only, no GTK/GLib.

const std = @import("std");
const c = @import("../c.zig").c;
const client = @import("client.zig");
const platform = @import("../util/platform.zig");

pub const HELP =
    \\Usage: sketerm-mux display <command> [options]
    \\
    \\  create --name <n> [--isolated] [--gpu] [--ttl SECS] [--json]
    \\        Create a display session and print the environment an
    \\        external process must export to render into it. Fails if
    \\        <n> already exists.
    \\  inspect <n> [--json]     one session's state + environment
    \\  list [--json]            every display session on the daemon
    \\  destroy <n>              kill the session (closes its sockets)
    \\
    \\Options: --socket PATH  talk to a specific daemon instance
    \\         --ttl SECS     kill the session after SECS with no
    \\                        attached viewer (0 = never, the default)
    \\
;

/// One session as reported by the daemon's `list` (the fields this CLI
/// cares about). Parsed with alloc_always — the frame payload is freed
/// before the values are used.
const Sess = struct {
    name: []const u8 = "",
    rows: u16 = 0,
    cols: u16 = 0,
    clients: u32 = 0,
    exited: bool = false,
    app: bool = false,
    pid: i32 = 0,
    display: bool = false,
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
    ttl: u32 = 0,
    json: bool = false,
};

fn errPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "sketerm-mux display: " ++ fmt ++ "\n", args) catch return;
    _ = c.write(2, msg.ptr, msg.len);
}

fn outPrint(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(1, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn parseArgs(argv: []const []const u8) ?Args {
    var a: Args = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const s = argv[i];
        if (std.mem.eql(u8, s, "--name") and i + 1 < argv.len) {
            i += 1;
            a.name = argv[i];
        } else if (std.mem.eql(u8, s, "--socket") and i + 1 < argv.len) {
            i += 1;
            a.socket = argv[i];
        } else if (std.mem.eql(u8, s, "--ttl") and i + 1 < argv.len) {
            i += 1;
            a.ttl = std.fmt.parseInt(u32, argv[i], 10) catch {
                errPrint("bad --ttl '{s}' (want whole seconds)", .{argv[i]});
                return null;
            };
        } else if (std.mem.eql(u8, s, "--isolated")) {
            a.isolated = true;
        } else if (std.mem.eql(u8, s, "--gpu")) {
            a.gpu = true;
        } else if (std.mem.eql(u8, s, "--json")) {
            a.json = true;
        } else if (std.mem.startsWith(u8, s, "-")) {
            errPrint("unknown option '{s}'", .{s});
            return null;
        } else if (a.cmd.len == 0) {
            a.cmd = s;
        } else if (a.name.len == 0) {
            // Positional name: `display inspect <n>` / `destroy <n>`.
            a.name = s;
        } else {
            errPrint("unexpected argument '{s}'", .{s});
            return null;
        }
    }
    return a;
}

fn connect(allocator: std.mem.Allocator, sock: ?[]const u8) ?client.Conn {
    return client.Conn.connectLocalAutostartAt(allocator, sock) catch |err| {
        errPrint("daemon unreachable: {s}", .{@errorName(err)});
        return null;
    };
}

/// Fetch the daemon's session list. Caller must `.deinit()`.
fn listSessions(allocator: std.mem.Allocator, conn: *client.Conn) ?std.json.Parsed(Listing) {
    conn.sendFrame(.list, "") catch {
        errPrint("list request failed", .{});
        return null;
    };
    const f = conn.recvExpectFor(&.{.welcome}, 15_000) catch {
        errPrint("list: no answer from the daemon", .{});
        return null;
    };
    defer f.deinit(allocator);
    return std.json.parseFromSlice(Listing, allocator, f.payload, .{
        .ignore_unknown_fields = true,
        // The payload is freed above; every string must be copied.
        .allocate = .alloc_always,
    }) catch {
        errPrint("list: unparseable answer", .{});
        return null;
    };
}

/// The environment an external renderer must export. `runtime_dir` is
/// the session's PRIVATE dir when isolated, otherwise the daemon's own
/// (which the keeper — and thus any process the caller starts against
/// this display — inherits). `pulse_socket` is the bare socket path the
/// daemon reports; the exported value needs libpulse's `unix:` scheme
/// (exactly what the daemon hands its own children).
const Env = struct {
    wayland_display: []const u8,
    xdg_runtime_dir: []const u8,
    pulse_socket: []const u8,
    software_gl: bool,
};

/// PULSE_SERVER for `sock`, into `buf`. "" when the session has no
/// audio hub.
fn pulseServer(buf: []u8, sock: []const u8) []const u8 {
    if (sock.len == 0) return "";
    return std.fmt.bufPrint(buf, "unix:{s}", .{sock}) catch "";
}

fn writeEnvJson(w: *std.Io.Writer, env: Env) !void {
    try w.writeAll("{\"WAYLAND_DISPLAY\":");
    try std.json.Stringify.value(env.wayland_display, .{}, w);
    try w.writeAll(",\"XDG_RUNTIME_DIR\":");
    try std.json.Stringify.value(env.xdg_runtime_dir, .{}, w);
    if (env.pulse_socket.len > 0) {
        var pbuf: [4200]u8 = undefined;
        try w.writeAll(",\"PULSE_SERVER\":");
        try std.json.Stringify.value(pulseServer(&pbuf, env.pulse_socket), .{}, w);
    }
    // --gpu means "keep the real driver", so the software-GL force is
    // exactly what must NOT be exported there.
    if (env.software_gl) try w.writeAll(",\"LIBGL_ALWAYS_SOFTWARE\":\"1\"");
    try w.writeAll("}");
}

fn envOf(s: Sess, gpu: bool) Env {
    return .{
        .wayland_display = s.wl_display,
        .xdg_runtime_dir = if (s.runtime_dir.len > 0) s.runtime_dir else platform.runtimeDir(),
        .pulse_socket = s.pulse_server,
        .software_gl = !gpu,
    };
}

fn printCreated(allocator: std.mem.Allocator, name: []const u8, env: Env, json: bool) void {
    if (!json) {
        var buf: [8192]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf,
            \\session {s}
            \\WAYLAND_DISPLAY={s}
            \\XDG_RUNTIME_DIR={s}
            \\
        , .{ name, env.wayland_display, env.xdg_runtime_dir }) catch return;
        outPrint(txt);
        if (env.pulse_socket.len > 0) {
            var pbuf: [4200]u8 = undefined;
            const extra = std.fmt.bufPrint(&buf, "PULSE_SERVER={s}\n", .{pulseServer(&pbuf, env.pulse_socket)}) catch return;
            outPrint(extra);
        }
        if (env.software_gl) outPrint("LIBGL_ALWAYS_SOFTWARE=1\n");
        return;
    }
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"session\":") catch return;
    std.json.Stringify.value(name, .{}, w) catch return;
    w.writeAll(",\"environment\":") catch return;
    writeEnvJson(w, env) catch return;
    w.writeAll("}\n") catch return;
    outPrint(aw.written());
}

fn create(allocator: std.mem.Allocator, a: Args) u8 {
    if (a.name.len == 0 or a.name.len > 64) {
        errPrint("create needs --name <1-64 chars>", .{});
        return 2;
    }
    var conn = connect(allocator, a.socket) orelse return 1;
    defer conn.deinit();

    // Duplicate names are refused by the daemon, but check first so the
    // caller gets a precise message instead of a generic spawn error
    // (and so a name held by an EXITED corpse is still reported).
    {
        var lst = listSessions(allocator, &conn) orelse return 1;
        defer lst.deinit();
        for (lst.value.sessions) |s| {
            if (std.mem.eql(u8, s.name, a.name)) {
                errPrint("session '{s}' already exists", .{a.name});
                return 1;
            }
        }
    }

    conn.sendJson(.spawn, .{
        .name = a.name,
        // No argv: the daemon substitutes its own `--keep` keeper.
        .app = true,
        .display = true,
        .isolated = a.isolated,
        .gpu = a.gpu,
        .ttl_secs = a.ttl,
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
    }) catch {
        errPrint("spawn request failed", .{});
        return 1;
    };
    const Ok = struct {
        name: []const u8 = "",
        pid: i32 = 0,
        wl_display: []const u8 = "",
        pulse_server: []const u8 = "",
        runtime_dir: []const u8 = "",
    };
    const f = conn.recvExpectFor(&.{.ok}, 30_000) catch |err| {
        if (err == error.DaemonError)
            errPrint("create failed: {s}", .{conn.lastErr()})
        else
            errPrint("create failed: {s}", .{@errorName(err)});
        return 1;
    };
    var parsed = blk: {
        defer f.deinit(allocator);
        break :blk std.json.parseFromSlice(Ok, allocator, f.payload, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch {
            errPrint("create: unparseable daemon reply", .{});
            return 1;
        };
    };
    defer parsed.deinit();
    if (parsed.value.wl_display.len == 0) {
        // No hub = nothing to render into; a caller must never be
        // handed a half-usable environment.
        errPrint("session '{s}' came up WITHOUT a Wayland display (forwarding disabled on the daemon?)", .{a.name});
        return 1;
    }
    printCreated(allocator, a.name, envOf(.{
        .name = a.name,
        .wl_display = parsed.value.wl_display,
        .pulse_server = parsed.value.pulse_server,
        .runtime_dir = parsed.value.runtime_dir,
    }, a.gpu), a.json);
    return 0;
}

fn writeSessJson(w: *std.Io.Writer, s: Sess) !void {
    try w.writeAll("{\"session\":");
    try std.json.Stringify.value(s.name, .{}, w);
    try w.print(",\"display\":{},\"app\":{},\"exited\":{},\"pid\":{d},\"viewers\":{d},\"ttl_secs\":{d}", .{
        s.display, s.app, s.exited, s.pid, s.viewers, s.ttl_secs,
    });
    try w.writeAll(",\"controller\":");
    if (s.controller.len > 0)
        try std.json.Stringify.value(s.controller, .{}, w)
    else
        try w.writeAll("null");
    try w.writeAll(",\"environment\":");
    // Report the environment as it IS: a session spawned without --gpu
    // runs software GL, and that is derivable from nothing else here,
    // so inspect states it explicitly.
    try writeEnvJson(w, envOf(s, false));
    try w.writeAll("}");
}

fn inspect(allocator: std.mem.Allocator, a: Args) u8 {
    if (a.name.len == 0) {
        errPrint("inspect needs a session name", .{});
        return 2;
    }
    var conn = connect(allocator, a.socket) orelse return 1;
    defer conn.deinit();
    var lst = listSessions(allocator, &conn) orelse return 1;
    defer lst.deinit();
    for (lst.value.sessions) |s| {
        if (!std.mem.eql(u8, s.name, a.name)) continue;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        if (a.json) {
            writeSessJson(&aw.writer, s) catch return 1;
            aw.writer.writeAll("\n") catch return 1;
        } else {
            const env = envOf(s, false);
            var pbuf: [4200]u8 = undefined;
            aw.writer.print(
                "session {s}\ndisplay={}\nviewers={d}\ncontroller={s}\nttl_secs={d}\nexited={}\npid={d}\nWAYLAND_DISPLAY={s}\nXDG_RUNTIME_DIR={s}\nPULSE_SERVER={s}\n",
                .{
                    s.name,
                    s.display,
                    s.viewers,
                    if (s.controller.len > 0) s.controller else "-",
                    s.ttl_secs,
                    s.exited,
                    s.pid,
                    env.wayland_display,
                    env.xdg_runtime_dir,
                    pulseServer(&pbuf, env.pulse_socket),
                },
            ) catch return 1;
        }
        outPrint(aw.written());
        return 0;
    }
    errPrint("no such session '{s}'", .{a.name});
    return 1;
}

fn list(allocator: std.mem.Allocator, a: Args) u8 {
    var conn = connect(allocator, a.socket) orelse return 1;
    defer conn.deinit();
    var lst = listSessions(allocator, &conn) orelse return 1;
    defer lst.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    if (a.json) {
        w.writeAll("{\"displays\":[") catch return 1;
        var first = true;
        for (lst.value.sessions) |s| {
            if (!s.display) continue;
            if (!first) w.writeAll(",") catch return 1;
            first = false;
            writeSessJson(w, s) catch return 1;
        }
        w.writeAll("]}\n") catch return 1;
    } else {
        for (lst.value.sessions) |s| {
            if (!s.display) continue;
            w.print("{s}\tviewers={d}\tcontroller={s}\t{s}\n", .{
                s.name,
                s.viewers,
                if (s.controller.len > 0) s.controller else "-",
                s.wl_display,
            }) catch return 1;
        }
    }
    outPrint(aw.written());
    return 0;
}

fn destroy(allocator: std.mem.Allocator, a: Args) u8 {
    if (a.name.len == 0) {
        errPrint("destroy needs a session name", .{});
        return 2;
    }
    var conn = connect(allocator, a.socket) orelse return 1;
    defer conn.deinit();
    conn.sendJson(.kill, .{ .name = a.name }) catch {
        errPrint("kill request failed", .{});
        return 1;
    };
    const f = conn.recvExpectFor(&.{.ok}, 15_000) catch |err| {
        if (err == error.DaemonError)
            errPrint("destroy failed: {s}", .{conn.lastErr()})
        else
            errPrint("destroy failed: {s}", .{@errorName(err)});
        return 1;
    };
    f.deinit(allocator);
    if (a.json) outPrint("{\"ok\":true}\n") else outPrint("ok\n");
    return 0;
}

/// Entry point: `argv` is everything AFTER the `display` keyword.
/// Exposed so the smoke rig drives the real CLI against its own daemon
/// (`--socket`) instead of re-implementing the flow.
pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) u8 {
    const a = parseArgs(argv) orelse return 2;
    if (a.cmd.len == 0 or std.mem.eql(u8, a.cmd, "help")) {
        outPrint(HELP);
        return if (a.cmd.len == 0) 2 else 0;
    }
    if (std.mem.eql(u8, a.cmd, "create")) return create(allocator, a);
    if (std.mem.eql(u8, a.cmd, "inspect")) return inspect(allocator, a);
    if (std.mem.eql(u8, a.cmd, "list")) return list(allocator, a);
    if (std.mem.eql(u8, a.cmd, "destroy")) return destroy(allocator, a);
    errPrint("unknown command '{s}' (want create|inspect|list|destroy)", .{a.cmd});
    return 2;
}

test "display: arg parsing covers flags, positionals and rejections" {
    const t = std.testing;
    const a = parseArgs(&.{ "create", "--name", "d1", "--isolated", "--gpu", "--ttl", "30", "--json" }).?;
    try t.expectEqualStrings("create", a.cmd);
    try t.expectEqualStrings("d1", a.name);
    try t.expect(a.isolated and a.gpu and a.json);
    try t.expectEqual(@as(u32, 30), a.ttl);

    const b = parseArgs(&.{ "inspect", "d2" }).?;
    try t.expectEqualStrings("inspect", b.cmd);
    try t.expectEqualStrings("d2", b.name);

    try t.expectEqual(@as(?Args, null), parseArgs(&.{ "create", "--ttl", "soon" }));
    try t.expectEqual(@as(?Args, null), parseArgs(&.{"--wat"}));
}

test "display: create env json omits software GL under --gpu, keeps it otherwise" {
    const t = std.testing;
    const s = Sess{
        .name = "d1",
        .wl_display = "/run/user/1000/sketerm/wl-w42",
        // The daemon reports the BARE socket path; the exported value
        // must carry libpulse's scheme.
        .pulse_server = "/run/user/1000/sketerm/pa-w42",
        .runtime_dir = "/run/user/1000/sketerm/rt-w42",
    };
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    try writeEnvJson(&aw.writer, envOf(s, false));
    try t.expect(std.mem.indexOf(u8, aw.written(), "\"LIBGL_ALWAYS_SOFTWARE\":\"1\"") != null);
    try t.expect(std.mem.indexOf(u8, aw.written(), "wl-w42") != null);
    try t.expect(std.mem.indexOf(u8, aw.written(), "\"XDG_RUNTIME_DIR\":\"/run/user/1000/sketerm/rt-w42\"") != null);
    try t.expect(std.mem.indexOf(u8, aw.written(), "\"PULSE_SERVER\":\"unix:/run/user/1000/sketerm/pa-w42\"") != null);

    var gw: std.Io.Writer.Allocating = .init(t.allocator);
    defer gw.deinit();
    try writeEnvJson(&gw.writer, envOf(s, true));
    try t.expect(std.mem.indexOf(u8, gw.written(), "LIBGL_ALWAYS_SOFTWARE") == null);
}

test "display: a session with no audio hub exports no PULSE_SERVER" {
    const t = std.testing;
    const env = envOf(.{ .name = "d", .wl_display = "/x/wl-1" }, false);
    // Non-isolated: the child inherits the daemon's runtime dir.
    try t.expectEqualStrings(platform.runtimeDir(), env.xdg_runtime_dir);
    try t.expectEqual(@as(usize, 0), env.pulse_socket.len);
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    try writeEnvJson(&aw.writer, env);
    try t.expect(std.mem.indexOf(u8, aw.written(), "PULSE_SERVER") == null);
    var buf: [8]u8 = undefined;
    try t.expectEqualStrings("", pulseServer(&buf, ""));
}
