//! Browser measurement rig — the harness behind the hover-latency and
//! sharpness numbers in the web-face work.
//!
//! Same shape as `smoke_e2e.zig`: private daemon, display session,
//! viewer attached BEFORE the GUI (the compositor brain is client-side),
//! then `sketerm web <url>` rendered into it. What it adds:
//!
//! - `--scale120 N` sends a `set_scale` intent so the session runs at a
//!   FRACTIONAL display scale (180 = the user's 1.5x desktop) — the
//!   only way to reproduce fractional-scale geometry on a headless box.
//! - `--secs N` pumps that long; the GUI's own `SKETERM_WEB_LAT` /
//!   `SKETERM_WEB_STATS` probes print to stderr meanwhile.
//! - `--shot PATH` writes the LAST composited frame (physical pixels,
//!   exactly what the compositor was handed) as PNG for pixel metrics.
//!
//! Usage: sketerm-web-measure --url file:///... [--scale120 180]
//!        [--secs 20] [--shot /tmp/out.png] [--env K=V]...

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const platform = @import("util/platform.zig");
const display_cli = @import("mux/display.zig");
const appdrive = @import("ipc/appdrive.zig");

const SESSION = "web-measure";

var daemon_pid: c.pid_t = -1;
var gui_pid: c.pid_t = -1;
var drive: ?*appdrive.App = null;
var g_alloc: std.mem.Allocator = undefined;
var g_mux_sock: []const u8 = "";
var display_ready = false;

fn dieWithParent() void {
    if (builtin.os.tag != .linux) return;
    const PR_SET_PDEATHSIG: c_long = 1;
    _ = c.syscall(@intFromEnum(std.os.linux.SYS.prctl), PR_SET_PDEATHSIG, @as(c_long, c.SIGKILL));
}

fn reap(pid: c.pid_t, sig: c_int, grace_ms: u32) void {
    if (pid <= 0) return;
    _ = c.kill(pid, sig);
    var status: c_int = 0;
    var waited: u32 = 0;
    while (waited < grace_ms) : (waited += 20) {
        if (c.waitpid(pid, &status, c.WNOHANG) == pid) return;
        _ = c.usleep(20_000);
    }
    _ = c.kill(pid, c.SIGKILL);
    _ = c.waitpid(pid, &status, 0);
}

fn teardown() void {
    if (drive) |app| {
        app.detach();
        drive = null;
    }
    if (gui_pid > 0) {
        reap(gui_pid, c.SIGKILL, 0);
        gui_pid = -1;
    }
    if (display_ready and g_mux_sock.len > 0) {
        const r = runDisplayCli(g_alloc, &.{ "destroy", SESSION, "--socket", g_mux_sock });
        g_alloc.free(r.out);
        display_ready = false;
    }
    if (daemon_pid > 0) {
        reap(daemon_pid, c.SIGTERM, 3000);
        daemon_pid = -1;
    }
}

fn fail(msg: []const u8) u8 {
    _ = c.fprintf(platform.stderr(), "web-measure FAIL: %.*s\n", @as(c_int, @intCast(msg.len)), msg.ptr);
    teardown();
    return 1;
}

const CliResult = struct { code: u8, out: []u8 };

fn runDisplayCli(allocator: std.mem.Allocator, argv: []const []const u8) CliResult {
    var pfds: [2]c_int = undefined;
    if (c.pipe(&pfds) != 0) return .{ .code = 1, .out = allocator.dupe(u8, "") catch &.{} };
    const saved = c.dup(1);
    _ = c.dup2(pfds[1], 1);
    _ = c.close(pfds[1]);
    const code = display_cli.run(allocator, argv);
    _ = c.fflush(platform.stdout());
    _ = c.dup2(saved, 1);
    _ = c.close(saved);
    var out: std.ArrayList(u8) = .empty;
    while (true) {
        var buf: [4096]u8 = undefined;
        const n = c.read(pfds[0], &buf, buf.len);
        if (n <= 0) break;
        out.appendSlice(allocator, buf[0..@intCast(n)]) catch break;
    }
    _ = c.close(pfds[0]);
    return .{ .code = code, .out = out.toOwnedSlice(allocator) catch &.{} };
}

const CreateReply = struct {
    session: []const u8 = "",
    environment: struct {
        WAYLAND_DISPLAY: []const u8 = "",
        XDG_RUNTIME_DIR: []const u8 = "",
        PULSE_SERVER: []const u8 = "",
        LIBGL_ALWAYS_SOFTWARE: []const u8 = "",
    } = .{},
};

pub fn main(init: std.process.Init.Minimal) u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    const allocator = gpa_state.allocator();
    g_alloc = allocator;
    const argv = init.args.vector;

    var url: []const u8 = "about:blank";
    var scale120: u32 = 120;
    var secs: u32 = 20;
    var shot_path: ?[]const u8 = null;
    var extra_env: [16][]const u8 = undefined;
    var n_env: usize = 0;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = std.mem.span(argv[i]);
        if (std.mem.eql(u8, a, "--url") and i + 1 < argv.len) {
            i += 1;
            url = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, a, "--scale120") and i + 1 < argv.len) {
            i += 1;
            scale120 = std.fmt.parseInt(u32, std.mem.span(argv[i]), 10) catch 120;
        } else if (std.mem.eql(u8, a, "--secs") and i + 1 < argv.len) {
            i += 1;
            secs = std.fmt.parseInt(u32, std.mem.span(argv[i]), 10) catch 20;
        } else if (std.mem.eql(u8, a, "--shot") and i + 1 < argv.len) {
            i += 1;
            shot_path = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, a, "--env") and i + 1 < argv.len) {
            i += 1;
            if (n_env < extra_env.len) {
                extra_env[n_env] = std.mem.span(argv[i]);
                n_env += 1;
            }
        }
    }

    // Isolated everything, like smoke-e2e.
    var rt_buf: [128:0]u8 = undefined;
    const rt = std.fmt.bufPrintZ(&rt_buf, "/tmp/sk-webm-{d}", .{c.getpid()}) catch return 1;
    _ = c.mkdir(rt.ptr, 0o700);
    _ = c.setenv("XDG_RUNTIME_DIR", rt.ptr, 1);
    _ = c.setenv("XDG_CONFIG_HOME", rt.ptr, 1);
    _ = c.setenv("XDG_STATE_HOME", rt.ptr, 1);
    _ = c.setenv("XDG_CACHE_HOME", rt.ptr, 1);
    _ = c.unsetenv("SKETERM_SOCKET");
    _ = c.system("fc-cache >/dev/null 2>&1");

    const mux_pid = c.fork();
    if (mux_pid < 0) return fail("mux fork");
    if (mux_pid == 0) {
        dieWithParent();
        const margv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm-mux", "--broker", null };
        _ = c.execv("zig-out/bin/sketerm-mux", @ptrCast(@constCast(&margv)));
        c._exit(127);
    }
    daemon_pid = mux_pid;
    var sock_buf: [256]u8 = undefined;
    const mux_sock = std.fmt.bufPrintZ(&sock_buf, "{s}/sketerm/mux.sock", .{rt}) catch return fail("sock path");
    var waited: u32 = 0;
    while (c.access(mux_sock.ptr, c.F_OK) != 0) {
        _ = c.usleep(50_000);
        waited += 1;
        if (waited > 100) return fail("daemon socket never appeared");
    }
    g_mux_sock = mux_sock;

    const r = runDisplayCli(allocator, &.{ "create", "--name", SESSION, "--ttl", "600", "--json", "--socket", mux_sock });
    defer allocator.free(r.out);
    if (r.code != 0) return fail("display create failed");
    display_ready = true;
    var parsed = std.json.parseFromSlice(CreateReply, allocator, r.out, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return fail("display create JSON");
    defer parsed.deinit();
    var wl_z: [4096:0]u8 = undefined;
    const wl = parsed.value.environment.WAYLAND_DISPLAY;
    if (wl.len == 0 or wl[0] != '/') return fail("no WAYLAND_DISPLAY");
    _ = std.fmt.bufPrintZ(&wl_z, "{s}", .{wl}) catch return fail("WAYLAND_DISPLAY too long");

    drive = appdrive.App.attachExisting(allocator, SESSION, null, mux_sock, null) catch
        return fail("viewer attach failed");
    const app = drive.?;

    // GUI child.
    const pid = c.fork();
    if (pid < 0) return fail("gui fork");
    if (pid == 0) {
        dieWithParent();
        _ = c.setenv("SKETERM_APP_ID", "dev.sker.sketerm.webmeasure", 1);
        _ = c.setenv("WAYLAND_DISPLAY", &wl_z, 1);
        _ = c.setenv("GDK_BACKEND", "wayland", 1);
        _ = c.unsetenv("DISPLAY");
        _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
        _ = c.setenv("GTK_A11Y", "none", 1);
        for (extra_env[0..n_env]) |kv| {
            if (std.mem.indexOfScalar(u8, kv, '=')) |eq| {
                var kb: [128:0]u8 = undefined;
                var vb: [512:0]u8 = undefined;
                const k = std.fmt.bufPrintZ(&kb, "{s}", .{kv[0..eq]}) catch continue;
                const v = std.fmt.bufPrintZ(&vb, "{s}", .{kv[eq + 1 ..]}) catch continue;
                _ = c.setenv(k.ptr, v.ptr, 1);
            }
        }
        var url_z: [4096:0]u8 = undefined;
        const uz = std.fmt.bufPrintZ(&url_z, "{s}", .{url}) catch c._exit(126);
        // `--url exec:<path>` runs an arbitrary binary as the display
        // client instead of the browser GUI (probe experiments).
        if (std.mem.startsWith(u8, std.mem.span(uz.ptr), "exec:")) {
            const bin: [*:0]const u8 = uz.ptr + 5;
            const pargv = [_:null]?[*:0]const u8{ bin, null };
            _ = c.execv(bin, @ptrCast(@constCast(&pargv)));
            c._exit(127);
        }
        const gargv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm", "web", uz.ptr, null };
        _ = c.execv("zig-out/bin/sketerm", @ptrCast(@constCast(&gargv)));
        c._exit(127);
    }
    gui_pid = pid;

    if (!app.waitFirstWindow(60_000)) return fail("GUI never committed a window");
    _ = c.fprintf(platform.stderr(), "web-measure: window up\n");

    if (scale120 != 120) {
        app.setViewerScale120(scale120) catch return fail("set_scale intent failed");
        _ = c.fprintf(platform.stderr(), "web-measure: viewer scale set to %u/120\n", scale120);
    }

    // Pump the viewer for the requested duration; the GUI's env-gated
    // probes do the talking on stderr.
    var elapsed_ms: u64 = 0;
    while (elapsed_ms < @as(u64, secs) * 1000) {
        _ = app.pumpOnce(50);
        elapsed_ms += 50;
    }

    if (shot_path) |sp| {
        const win_id: u32 = if (app.windows.items.len > 0) app.windows.items[0].id else return fail("no window for shot");
        const shot = app.screenshotPng(win_id, 100_000, null, 1) catch return fail("screenshot failed");
        var pz: [1024:0]u8 = undefined;
        const p = std.fmt.bufPrintZ(&pz, "{s}", .{sp}) catch return fail("shot path");
        const f = c.fopen(p.ptr, "wb") orelse return fail("shot open");
        _ = c.fwrite(shot.png.ptr, 1, shot.png.len, f);
        _ = c.fclose(f);
        _ = c.fprintf(platform.stderr(), "web-measure: shot %ux%u frame %llu -> %s\n", shot.img_w, shot.img_h, @as(c_ulonglong, shot.frame), p.ptr);
    }

    teardown();
    return 0;
}
