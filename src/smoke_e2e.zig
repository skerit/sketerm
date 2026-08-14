//! End-to-end smoke: launch the real app, drive it over the
//! remote-control socket AND over a real seat, assert on what the
//! terminal actually rendered. `zig build smoke-e2e`.
//!
//! **sketerm is its own test display.** The harness starts a private
//! daemon, asks it for an external display session (`sketerm-mux
//! display create`), and runs the GUI as a Wayland client of that
//! session's hub. No Xvfb, no X11, no ambient compositor: a headless
//! host needs nothing installed.
//!
//! X11 is not an acceptable substitute and is deliberately unreachable
//! here (the GUI child gets `GDK_BACKEND=wayland` and no `DISPLAY`).
//! Under X, `GtkIMMulticontext` falls back to `GtkIMContextSimple`, so
//! input-method behaviour under Xvfb is NOT the behaviour on any
//! Wayland compositor advertising `zwp_text_input_manager_v3` — an
//! Xvfb run of this smoke went green while dead keys were broken
//! everywhere real. Every input assertion below is therefore worthless
//! unless it runs on sketerm's own compositor.
//!
//! macOS has no Wayland hub; there the GUI talks to the WindowServer
//! and the real-input stage is skipped (documented gap).

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const platform = @import("util/platform.zig");
const protocol = @import("ipc/protocol.zig");
const version = @import("version.zig");
const display_cli = @import("mux/display.zig");
const appdrive = @import("ipc/appdrive.zig");
const muxclient = @import("mux/client.zig");
const muxwire = @import("mux/wire.zig");
const panel_assets = @import("ui/panel/assets.zig");
const panelhost = @import("ui/panelhost.zig");
const editor_pass = @import("render/editor_pass.zig");
const wlcomp = @import("wlhost/compositor.zig");
const clock = @import("util/clock.zig");

const MARKER = "sketerm-e2e-marker-7423";
/// Typed on a real seat (not over IPC) — a distinct marker so the two
/// input paths can never be confused for one another.
const KEY_MARKER = "sketerm-e2e-keyed-9317";

/// The display session the GUI renders into.
const DISPLAY_SESSION = "e2e-display";
/// A SECOND display session, on a Belgian (AZERTY) keymap, for the
/// dead-key stage. It needs its own session because a session's keymap
/// is fixed at creation, and its own GUI instance because that one must
/// run WITHOUT `GTK_IM_MODULE=wayland` — see `deadKeyStage`.
const DEADKEY_SESSION = "e2e-deadkey";
/// Backstop against orphans: even a SIGKILLed harness leaves nothing
/// behind past this, because the daemon reaps a session with no
/// attached viewer.
const DISPLAY_TTL = "900";
/// The remote daemon alone inherits this descriptor. A panel whose logical
/// image path is `/proc/self/fd/900` therefore cannot render by opening the
/// path in the GUI process; it has to hydrate through the remote mux worker.
const REMOTE_PANEL_ASSET_FD: c_int = 900;
const REMOTE_PANEL_ASSET_PATH = "/proc/self/fd/900";

var child_pid: c.pid_t = 0;
var daemon_pid: c.pid_t = 0;
/// The SECOND private daemon acting as the "remote host" behind the
/// fake ssh (remoteProjectStage). Killed by exact pid, like the rest.
var remote_mux_pid: c.pid_t = 0;
/// Seat/pixel side of the harness: a viewer of the display session the
/// GUI renders into. null on macOS (no hub) — see the module docs.
var drive: ?*appdrive.App = null;
var display_ready = false;
/// Same three, for the Belgian-layout dead-key session.
var dk_pid: c.pid_t = 0;
/// The second GUI started with --restore (restoreStage), killed by
/// EXACT pid — never by name.
var restore_pid: c.pid_t = -1;
/// The standalone image viewer (`sketerm view`) spawned into the same
/// display session by viewerMenuStage. Killed by EXACT pid.
var viewer_pid: c.pid_t = -1;
/// The theme-flip GUI (themeSingletonStage), killed by EXACT pid.
var theme_pid: c.pid_t = -1;
/// The cast-playback GUI (`sketerm play`, castPlaybackStage), killed
/// by EXACT pid.
var cast_pid: c.pid_t = -1;
/// The viewer-cast GUI (`sketerm view` on a mixed image+cast batch,
/// viewerCastStage), killed by EXACT pid.
var vcast_pid: c.pid_t = -1;
/// `sketerm files` window hosting the quick-look stage (its own app
/// identity in the shared display session), killed by EXACT pid.
var qlfiles_pid: c.pid_t = -1;
var dk_drive: ?*appdrive.App = null;
var dk_ready = false;
var g_alloc: std.mem.Allocator = undefined;
var g_mux_sock: []const u8 = "";
/// Exact browser-helper pid captured by the action E2E and checked after
/// the GUI's graceful shutdown.
var web_helper_pid: c.pid_t = -1;
/// This run's isolated `XDG_RUNTIME_DIR`, in a global buffer so the
/// signal handlers and the final sweep can still name it. Empty until
/// `main` has built it.
var g_rt_buf: [256]u8 = undefined;
var g_rt: []const u8 = "";

/// The prefix every run's isolated runtime dir is built from; the
/// harness pid follows. Unique enough that a process whose environment
/// contains it CANNOT be the user's real daemon — which is what makes
/// the by-environ sweeps below safe.
const RT_PREFIX = "/tmp/sketerm-smoke-e2e-";

/// SIGTERM (or `sig`), wait up to `grace_ms`, then SIGKILL — a wedged
/// child must never turn teardown into a hang, and a hung teardown is
/// how a "failed" run used to leave its whole process fleet running.
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

/// Tear down everything this process created, in dependency order and
/// by exact pid — never by name. Idempotent: the success path and
/// every `fail` go through it.
///
/// The ordered part below is not sufficient on its own: a GUI whose
/// daemon connection drops AUTOSTARTS a replacement daemon, and that
/// replacement is double-forked (no `PR_SET_PDEATHSIG`, not our child,
/// not `daemon_pid`) — so it and every session worker it forks outlive
/// the harness. `sweepRuntimeDir` is the fence that makes "everything
/// this run started is gone" true regardless of who started it.
fn teardown() void {
    dkTeardown();
    themeTeardown();
    if (viewer_pid > 0) {
        _ = c.kill(viewer_pid, c.SIGKILL);
        var vst: c_int = 0;
        _ = c.waitpid(viewer_pid, &vst, 0);
        viewer_pid = -1;
    }
    if (restore_pid > 0) {
        reap(restore_pid, c.SIGKILL, 0);
        restore_pid = -1;
    }
    if (cast_pid > 0) {
        reap(cast_pid, c.SIGKILL, 0);
        cast_pid = -1;
    }
    if (vcast_pid > 0) {
        reap(vcast_pid, c.SIGKILL, 0);
        vcast_pid = -1;
    }
    if (qlfiles_pid > 0) {
        reap(qlfiles_pid, c.SIGKILL, 0);
        qlfiles_pid = -1;
    }
    if (drive) |app| {
        // detach, not kill: the session is destroyed by name below, so
        // a half-torn-down client never decides that for us.
        app.detach();
        drive = null;
    }
    if (child_pid > 0) {
        reap(child_pid, c.SIGKILL, 0);
        child_pid = 0;
    }
    if (remote_mux_pid > 0) {
        reap(remote_mux_pid, c.SIGTERM, 2000);
        remote_mux_pid = 0;
    }
    if (display_ready and g_mux_sock.len > 0) {
        const r = runDisplayCli(g_alloc, &.{ "destroy", DISPLAY_SESSION, "--socket", g_mux_sock });
        g_alloc.free(r.out);
        display_ready = false;
    }
    if (daemon_pid > 0) {
        // Let the broker terminate and reap its exact worker children.
        reap(daemon_pid, c.SIGTERM, 3000);
        daemon_pid = 0;
    }
    if (g_rt.len > 0) {
        const left = sweepRuntimeDir(g_rt);
        if (left > 0) {
            _ = c.fprintf(
                platform.stderr(),
                "smoke-e2e: swept %d orphan process(es) still holding %.*s\n",
                @as(c_int, @intCast(left)),
                @as(c_int, @intCast(g_rt.len)),
                g_rt.ptr,
            );
        }
    }
}

/// True when `hay` contains `needle` as a whole path token: the byte
/// after the match must not be a digit, so a sweep for
/// `/tmp/sketerm-smoke-e2e-123` never matches `.../sketerm-smoke-e2e-1234`.
fn hasPathToken(hay: []const u8, needle: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, hay, from, needle)) |at| {
        const end = at + needle.len;
        if (end >= hay.len or !std.ascii.isDigit(hay[end])) return true;
        from = at + 1;
    }
    return false;
}

/// True only when the pid is provably gone (ESRCH). EPERM — someone
/// else's process wearing that number — reads as ALIVE, so a leftover
/// whose ownership we cannot establish is left running.
fn pidGone(pid: c.pid_t) bool {
    const rc = c.kill(pid, 0);
    if (rc == 0) return false;
    return std.posix.errno(rc) == .SRCH;
}

/// Read `/proc/<pid>/environ` into `buf`. Null when it is unreadable —
/// a process we cannot read cannot be ours, so it is never a target.
fn readEnviron(pid: c.pid_t, buf: []u8) ?[]u8 {
    var path_buf: [64:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/environ", .{pid}) catch return null;
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var used: usize = 0;
    while (used < buf.len) {
        const n = c.read(fd, buf.ptr + used, buf.len - used);
        if (n <= 0) break;
        used += @intCast(n);
    }
    if (used == 0) return null;
    return buf[0..used];
}

/// Kill, BY EXACT PID, every live process whose environment names `dir`
/// — the isolated runtime dir of one smoke-e2e run. Nothing is ever
/// matched by process NAME: `dir` embeds the owning harness's pid, so a
/// process carrying it in its environment was started by that run and
/// by nothing else. The user's real daemon can never match.
///
/// Two rounds, because killing a broker can let a worker fork one more
/// child before it dies. Returns how many processes were killed.
fn sweepRuntimeDir(dir: []const u8) usize {
    if (builtin.os.tag != .linux) return 0;
    const self = c.getpid();
    var killed: usize = 0;
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        var hits: usize = 0;
        const d = c.opendir("/proc") orelse return killed;
        while (c.readdir(d)) |ent| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
            const pid = std.fmt.parseInt(c.pid_t, name, 10) catch continue;
            if (pid == self) continue;
            var env_buf: [64 * 1024]u8 = undefined;
            const env = readEnviron(pid, &env_buf) orelse continue;
            if (!hasPathToken(env, dir)) continue;
            _ = c.kill(pid, c.SIGKILL);
            hits += 1;
        }
        _ = c.closedir(d);
        killed += hits;
        if (hits == 0) break;
        // Give the kernel a moment to deliver, then look again: a
        // freshly forked grandchild inherits the same environment.
        _ = c.usleep(150_000);
    }
    // Reap whatever of ours died along the way; orphans belong to init.
    var st: c_int = 0;
    while (c.waitpid(-1, &st, c.WNOHANG) > 0) {}
    return killed;
}

/// Startup self-defence: clean up after a PREVIOUS run that never got
/// to `teardown` (SIGKILL, a panic, a crashed harness). Modelled on
/// `sweepStaleEphemeral` in `src/ipc/mcp.zig`.
///
/// Keyed on the process environment rather than on the leftover
/// directory, because the worst orphan — an autostarted replacement
/// daemon — outlives the directory: the previous run's `removeTreeBestEffort`
/// deletes the tree while the daemon bound to a socket inside it keeps
/// running. A leftover is only swept when its OWNING harness pid is
/// gone, so two concurrent smoke-e2e runs never touch each other.
fn sweepStaleRuns() void {
    if (builtin.os.tag != .linux) return;
    const self = c.getpid();
    const d = c.opendir("/proc") orelse return;
    defer _ = c.closedir(d);
    var swept: usize = 0;
    while (c.readdir(d)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        const pid = std.fmt.parseInt(c.pid_t, name, 10) catch continue;
        if (pid == self) continue;
        var env_buf: [64 * 1024]u8 = undefined;
        const env = readEnviron(pid, &env_buf) orelse continue;
        const at = std.mem.indexOf(u8, env, RT_PREFIX) orelse continue;
        var end = at + RT_PREFIX.len;
        while (end < env.len and std.ascii.isDigit(env[end])) end += 1;
        const owner = std.fmt.parseInt(c.pid_t, env[at + RT_PREFIX.len .. end], 10) catch continue;
        if (owner == self) continue;
        // Owner still alive = a concurrent run; leave it strictly alone.
        if (!pidGone(owner)) continue;
        _ = c.kill(pid, c.SIGKILL);
        swept += 1;
    }
    // Directories whose owner is gone: the tree the crashed run never removed.
    const t = c.opendir("/tmp") orelse {
        if (swept > 0) reportSwept(swept);
        return;
    };
    defer _ = c.closedir(t);
    const dir_prefix = "sketerm-smoke-e2e-";
    while (c.readdir(t)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.startsWith(u8, name, dir_prefix)) continue;
        const owner = std.fmt.parseInt(c.pid_t, name[dir_prefix.len..], 10) catch continue;
        if (owner == self or !pidGone(owner)) continue;
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/tmp/{s}", .{name}) catch continue;
        @import("mux/daemon.zig").removeTreeBestEffort(path);
    }
    if (swept > 0) reportSwept(swept);
}

fn reportSwept(n: usize) void {
    _ = c.fprintf(
        platform.stderr(),
        "smoke-e2e: startup sweep killed %d orphan(s) from a previous run\n",
        @as(c_int, @intCast(n)),
    );
}

/// Teardown must also happen when the harness is interrupted or dies on
/// a fault. `fail`/`failMsg` cover every ordinary exit; these cover the
/// rest, because an un-torn-down run poisons the NEXT one (its GUI
/// autostarts a daemon at a socket a leftover daemon already owns).
/// The handler is not strictly async-signal-safe — it walks /proc — but
/// it runs once, in a process that is exiting either way.
fn onFatalSignal(sig: c_int) callconv(.c) void {
    _ = c.signal(sig, c.SIG_DFL); // never re-enter on a fault inside teardown
    teardown();
    if (g_rt.len > 0) {
        var z: [256:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&z, "{s}", .{g_rt})) |p| {
            @import("mux/daemon.zig").removeTreeBestEffort(p);
        } else |_| {}
    }
    c._exit(1);
}

fn installTeardownSignals() void {
    for ([_]c_int{ c.SIGINT, c.SIGTERM, c.SIGHUP, c.SIGQUIT, c.SIGABRT, c.SIGSEGV }) |sig| {
        _ = c.signal(sig, onFatalSignal);
    }
}

/// Tear down only the dead-key stage's GUI, viewer and session — by
/// exact pid and by name, like `teardown` itself. Idempotent, so the
/// stage's own early returns and the global teardown share it.
fn dkTeardown() void {
    if (dk_drive) |app| {
        app.detach();
        dk_drive = null;
    }
    if (dk_pid > 0) {
        _ = c.kill(dk_pid, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(dk_pid, &status, 0);
        dk_pid = 0;
    }
    if (dk_ready and g_mux_sock.len > 0) {
        const r = runDisplayCli(g_alloc, &.{ "destroy", DEADKEY_SESSION, "--socket", g_mux_sock });
        g_alloc.free(r.out);
        dk_ready = false;
    }
}

/// Tear down only the theme stage's GUI, by exact pid. Idempotent, so
/// the stage's own early returns and the global teardown share it.
fn themeTeardown() void {
    if (theme_pid > 0) {
        _ = c.kill(theme_pid, c.SIGKILL);
        var st: c_int = 0;
        _ = c.waitpid(theme_pid, &st, 0);
        theme_pid = -1;
    }
}

fn fail(comptime msg: []const u8) u8 {
    _ = c.fprintf(platform.stderr(), "smoke-e2e: FAIL: " ++ msg ++ "\n");
    teardown();
    return 1;
}

/// `fail` for runtime-built messages (stage helpers return one).
fn failMsg(msg: []const u8) u8 {
    _ = c.fprintf(platform.stderr(), "smoke-e2e: FAIL: %.*s\n", @as(c_int, @intCast(msg.len)), msg.ptr);
    teardown();
    return 1;
}

/// Die with the harness. `teardown` covers every ordinary exit, but a
/// SIGKILLed harness would otherwise orphan a daemon and a GUI holding
/// an isolated runtime dir — and nothing may ever kill those by name.
/// Linux-only (`prctl(PR_SET_PDEATHSIG)`), called in the forked child.
fn dieWithParent() void {
    if (builtin.os.tag != .linux) return;
    const PR_SET_PDEATHSIG: c_long = 1;
    _ = c.syscall(@intFromEnum(std.os.linux.SYS.prctl), PR_SET_PDEATHSIG, @as(c_long, c.SIGKILL));
}

/// Progress line (the stages are slow; a silent run is unreadable).
fn say(msg: []const u8) void {
    _ = c.fprintf(platform.stdout(), "smoke-e2e: %.*s\n", @as(c_int, @intCast(msg.len)), msg.ptr);
    _ = c.fflush(platform.stdout());
}

const CliResult = struct { code: u8, out: []u8 };

/// Run the real `sketerm-mux display` CLI in-process with stdout
/// captured — the harness parses exactly the bytes an external caller
/// would, instead of re-deriving socket paths (which CLAUDE.md forbids:
/// `wl-*` naming differs between monolith and broker mode).
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

/// Run the real `sketerm cli` in-process with stdout captured — the
/// same bytes a shell would see. The CLI leaks its request payloads on
/// purpose (the real process exits right after), so it runs against an
/// arena the caller drops.
fn runCli(allocator: std.mem.Allocator, argv: []const []const u8) CliResult {
    var pfds: [2]c_int = undefined;
    if (c.pipe(&pfds) != 0) return .{ .code = 1, .out = allocator.dupe(u8, "") catch &.{} };
    const saved = c.dup(1);
    _ = c.dup2(pfds[1], 1);
    _ = c.close(pfds[1]);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    const code = @import("ipc/client.zig").run(arena_state.allocator(), argv);
    arena_state.deinit();
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

pub fn main() u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    g_alloc = allocator;

    // On Linux the harness makes its own display below. macOS always
    // has one (the GDK macOS backend talks to the WindowServer
    // directly; no env var advertises it).

    // Leftovers from a run that never reached `teardown` poison this one:
    // its GUI would autostart a daemon whose socket path a stale daemon
    // still owns, and the failure surfaces stages later as an unrelated
    // regression. Sweep before anything of ours exists.
    sweepStaleRuns();
    installTeardownSignals();

    // Every mutable path and the daemon itself are private to this smoke.
    // A protocol bump must never classify the user's live daemon as stale
    // and shut it down.
    const rt = std.fmt.bufPrintZ(&g_rt_buf, RT_PREFIX ++ "{d}", .{c.getpid()}) catch return fail("runtime path");
    g_rt = rt;
    _ = c.mkdir(rt.ptr, 0o700);
    _ = c.setenv("XDG_RUNTIME_DIR", rt.ptr, 1);
    _ = c.setenv("XDG_CONFIG_HOME", rt.ptr, 1);
    _ = c.setenv("XDG_STATE_HOME", rt.ptr, 1);
    _ = c.setenv("XDG_CACHE_HOME", rt.ptr, 1);
    _ = c.setenv("XDG_DATA_HOME", rt.ptr, 1);
    _ = c.unsetenv("SKETERM_SOCKET");
    defer @import("mux/daemon.zig").removeTreeBestEffort(rt);

    const have_web_action = c.access("zig-out/bin/sketerm-webengine", c.X_OK) == 0;
    if (have_web_action and !prepareWebActionFixture(allocator, rt))
        return fail("could not prepare the browser-action GUI fixture");

    // A fresh XDG_CONFIG_HOME changes fontconfig's cache key, so every
    // isolated GUI launch below would otherwise rebuild the font caches
    // on concurrent threads and race pango into heap corruption (SEGV in
    // pango_glyph_string_extents_range, or "malloc(): unaligned tcache
    // chunk", with no sketerm frame in the faulting stack). Warming it
    // ONCE, single-threaded, before anything else starts is the fix —
    // same as smoke-atspi and smoke-lsp-gui.
    _ = c.system("fc-cache >/dev/null 2>&1");

    const mux_pid = c.fork();
    if (mux_pid < 0) return fail("mux fork");
    if (mux_pid == 0) {
        dieWithParent();
        const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm-mux", "--broker", null };
        _ = c.execv("zig-out/bin/sketerm-mux", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    daemon_pid = mux_pid;
    var mux_sock_buf: [512]u8 = undefined;
    const mux_sock = std.fmt.bufPrintZ(&mux_sock_buf, "{s}/sketerm/mux.sock", .{rt}) catch return fail("mux socket path");
    var waited: u32 = 0;
    while (c.access(mux_sock.ptr, c.F_OK) != 0) {
        _ = c.usleep(50_000);
        waited += 1;
        if (waited > 100) return fail("private mux socket never appeared (5s)");
    }
    g_mux_sock = mux_sock;

    // ── the display: sketerm serving itself ───────────────────────
    //
    // A display session is a keeper-backed app session that owns a
    // Wayland hub. The GUI under test renders into it as an ordinary
    // Wayland client, and this process attaches as the session's viewer
    // — which is BOTH the compositor brain (nothing configures the
    // GUI's toplevel otherwise) and the seat that injects real input.
    var wl_z: [4096:0]u8 = undefined;
    var have_wl = false;
    if (!platform.is_macos) {
        const r = runDisplayCli(allocator, &.{
            "create", "--name", DISPLAY_SESSION, "--ttl", DISPLAY_TTL, "--json", "--socket", mux_sock,
        });
        defer allocator.free(r.out);
        if (r.code != 0) {
            _ = c.fprintf(platform.stderr(), "smoke-e2e: display create said: %.*s\n", @as(c_int, @intCast(r.out.len)), r.out.ptr);
            return fail("could not create a display session (Wayland forwarding disabled on the daemon?)");
        }
        display_ready = true;
        var parsed = std.json.parseFromSlice(CreateReply, allocator, r.out, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return fail("display create did not answer the documented JSON");
        defer parsed.deinit();
        const wl = parsed.value.environment.WAYLAND_DISPLAY;
        if (wl.len == 0 or wl[0] != '/') return fail("display create returned no absolute WAYLAND_DISPLAY");
        _ = std.fmt.bufPrintZ(&wl_z, "{s}", .{wl}) catch return fail("WAYLAND_DISPLAY too long");
        have_wl = true;
        say("display session up (sketerm is its own compositor; no X involved)");

        // Attach BEFORE the GUI starts: the brain lives client-side, so
        // an unattended hub never configures the toplevel it is handed.
        drive = appdrive.App.attachExisting(allocator, DISPLAY_SESSION, null, mux_sock) catch {
            _ = c.fprintf(platform.stderr(), "smoke-e2e: attach said: %s\n", appdrive.lastLaunchErr().ptr);
            return fail("could not attach a viewer to the display session");
        };
    }

    // ── a hermetic "remote" host: fake ssh + a second daemon ──────
    // remoteProjectStage used to run over REAL `ssh localhost`, which
    // reaches whatever daemon the target user happens to be running —
    // a daemon predating a capability (git_diff, say) draws an empty
    // gutter BY DESIGN, so the assertion was about the host machine's
    // installed daemon, not about this build. The remote is now the
    // freshly built sketerm-mux: $SKETERM_SSH points at a script that
    // execs `sketerm-mux --proxy` against a SECOND private daemon
    // under <rt>/r, pre-started here so its pid is owned (an
    // autostarted daemon detaches and could not be killed by exact
    // pid). Setting SKETERM_SSH also disables the deploy/multiplex
    // legs by design (deploy.prepare returns null under it).
    var rrt_buf: [256]u8 = undefined;
    const rrt = std.fmt.bufPrintZ(&rrt_buf, "{s}/r", .{rt}) catch return fail("remote rt path");
    _ = c.mkdir(rrt.ptr, 0o700);
    {
        var mux_abs_buf: [4096]u8 = undefined;
        const mux_abs_raw = c.realpath("zig-out/bin/sketerm-mux", &mux_abs_buf) orelse return fail("realpath sketerm-mux");
        const mux_abs = std.mem.span(@as([*:0]const u8, @ptrCast(mux_abs_raw)));
        var asset_seed_buf: [512]u8 = undefined;
        const asset_seed = std.fmt.bufPrintZ(&asset_seed_buf, "{s}/panel-asset.png", .{rrt}) catch
            return fail("remote panel asset seed path");
        if (!writeSolidPng(allocator, asset_seed.ptr, 0x20, 0x80, 0xff))
            return fail("remote panel asset seed write");
        const asset_fd = c.open(asset_seed.ptr, c.O_RDWR);
        if (asset_fd < 0) return fail("remote panel asset seed open");
        const rmt_pid = c.fork();
        if (rmt_pid < 0) {
            _ = c.close(asset_fd);
            return fail("remote mux fork");
        }
        if (rmt_pid == 0) {
            dieWithParent();
            for (0..5) |i| {
                if (c.dup2(asset_fd, REMOTE_PANEL_ASSET_FD + @as(c_int, @intCast(i))) < 0) c._exit(126);
            }
            if (asset_fd < REMOTE_PANEL_ASSET_FD or asset_fd >= REMOTE_PANEL_ASSET_FD + 5)
                _ = c.close(asset_fd);
            _ = c.setenv("XDG_RUNTIME_DIR", rrt.ptr, 1);
            _ = c.setenv("XDG_STATE_HOME", rrt.ptr, 1);
            _ = c.setenv("XDG_CONFIG_HOME", rrt.ptr, 1);
            const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm-mux", null };
            _ = c.execv("zig-out/bin/sketerm-mux", @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        _ = c.close(asset_fd);
        remote_mux_pid = rmt_pid;
        var rsock_buf: [512]u8 = undefined;
        const rsock = std.fmt.bufPrintZ(&rsock_buf, "{s}/sketerm/mux.sock", .{rrt}) catch return fail("remote sock path");
        var rwaited: u32 = 0;
        while (c.access(rsock.ptr, c.F_OK) != 0) {
            _ = c.usleep(50_000);
            rwaited += 1;
            if (rwaited > 100) return fail("private remote mux socket never appeared (5s)");
        }
        // The daemon and its future session workers retain the inode through
        // fd 900. Removing the name makes the process-relative logical path
        // the only way to read it and prevents a direct local-file fallback.
        if (c.unlink(asset_seed.ptr) != 0) return fail("remote panel asset unlink");

        var ssh_path_buf: [300:0]u8 = undefined;
        const ssh_path = std.fmt.bufPrintZ(&ssh_path_buf, "{s}/fake-ssh", .{rt}) catch return fail("fake ssh path");
        var script_buf: [2048]u8 = undefined;
        const body = std.fmt.bufPrint(&script_buf,
            \\#!/bin/sh
            \\if [ "$1" = "-G" ]; then printf 'hostname 127.0.0.1\n'; exit 0; fi
            \\export XDG_RUNTIME_DIR='{s}'
            \\export XDG_STATE_HOME='{s}'
            \\export XDG_CONFIG_HOME='{s}'
            \\export SKETERM_MUX_BIN='{s}'
            \\exec '{s}' --proxy
            \\
        , .{ rrt, rrt, rrt, mux_abs, mux_abs }) catch return fail("fake ssh body");
        const fp = c.fopen(ssh_path.ptr, "wb") orelse return fail("fake ssh open");
        const wrote = c.fwrite(body.ptr, 1, body.len, fp) == body.len;
        _ = c.fclose(fp);
        if (!wrote) return fail("fake ssh write");
        if (c.chmod(ssh_path.ptr, 0o755) != 0) return fail("fake ssh chmod");
        _ = c.setenv("SKETERM_SSH", ssh_path.ptr, 1);
    }

    // Spawn the freshly-built binary with its own app id so it
    // doesn't join a running user instance via GApplication.
    const pid = c.fork();
    if (pid < 0) return fail("fork");
    if (pid == 0) {
        dieWithParent();
        _ = c.setenv("SKETERM_APP_ID", "dev.sker.sketerm.e2e", 1);
        if (have_wl) {
            // The ONLY display this child can reach is sketerm's own
            // hub. X11 is unreachable on purpose: GtkIMMulticontext
            // silently degrades to GtkIMContextSimple there, which
            // makes every input assertion below a false green.
            _ = c.setenv("WAYLAND_DISPLAY", &wl_z, 1);
            _ = c.setenv("GDK_BACKEND", "wayland", 1);
            _ = c.unsetenv("DISPLAY");
            // The hub has no GPU; the daemon mmaps shm planes.
            _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
            // "The user configured a real IME": makes the editor face
            // take GtkIMMulticontext, so the Wayland text-input path is
            // exercised rather than the always-available Compose
            // fallback. Only meaningful because the display advertises
            // zwp_text_input_manager_v3 (comptime-asserted below).
            _ = c.setenv("GTK_IM_MODULE", "wayland", 1);
        }
        // Cross-check the pane-tree model against the widget tree
        // after every split/close — divergence aborts the app, which
        // fails this harness.
        _ = c.setenv("SKETERM_VERIFY_TREE", "1", 1);
        // Hermeticity: on a dev box with at-spi running, the GUI child
        // would otherwise register its accessibles on the USER'S real
        // a11y bus. This harness isolates every other resource, so it
        // must isolate that too. Nothing here asserts a11y behaviour —
        // if that is ever wanted it needs its own test with its own
        // private bus (src/mux/a11yhub.zig spawns one per app session).
        _ = c.setenv("GTK_A11Y", "none", 1);
        const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm", "--no-save", null };
        _ = c.execv("zig-out/bin/sketerm", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    child_pid = pid;

    // Wait for the socket to appear (app startup + bind).
    const sock_path = std.fmt.allocPrintSentinel(allocator, "{s}/sketerm/{d}.sock", .{ rt, pid }, 0) catch return fail("alloc");
    defer allocator.free(sock_path);
    waited = 0;
    while (c.access(sock_path.ptr, c.F_OK) != 0) {
        _ = c.usleep(100_000);
        waited += 1;
        if (waited > 100) return fail("socket never appeared (10s)");
    }
    // The GUI must actually paint into the session — a GTK window that
    // never commits a buffer means the Wayland path is broken, which
    // the IPC stages alone would happily not notice.
    if (drive) |app| {
        if (!app.waitFirstWindow(60_000))
            return fail("the GUI never committed a window into the display session");
        say("GUI window rendered into the display session");
    }
    // Give the first pane's shell a moment to start.
    _ = c.usleep(700_000);

    if (c.getenv("SKETERM_SMOKE_E2E_WEB_ONLY") != null) {
        if (mcpWebReaderStage(allocator, sock_path, rt)) |why| return failMsg(why);
        say("mcp GUI web adapter: focused reader-ID stage passed");
        teardown();
        return 0;
    }

    // 1. list — exactly one tab with at least one pane.
    const list_resp = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse return fail("list roundtrip");
    defer allocator.free(list_resp);
    if (std.mem.indexOf(u8, list_resp, "\"ok\":true") == null) return fail("list not ok");
    if (std.mem.indexOf(u8, list_resp, "\"panes\":[{") == null) return fail("list has no panes");

    // 2. send-text an echo with a unique marker...
    var req_buf: [256]u8 = undefined;
    const send_req = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"send-text\",\"pane\":1,\"data\":\"echo {s}\\n\"}}\n", .{MARKER}) catch return fail("fmt");
    const send_resp = roundtrip(allocator, sock_path, send_req) orelse return fail("send-text roundtrip");
    defer allocator.free(send_resp);
    if (std.mem.indexOf(u8, send_resp, "\"ok\":true") == null) return fail("send-text not ok");

    // 3. ...and poll get-text until the marker shows up as command
    // OUTPUT (echoed line + result = at least 2 occurrences; a shell
    // that hasn't run it yet shows at most the typed line).
    var tries: u32 = 0;
    var seen = false;
    while (tries < 50) : (tries += 1) {
        _ = c.usleep(200_000);
        const text_resp = roundtrip(allocator, sock_path, "{\"cmd\":\"get-text\",\"pane\":1}\n") orelse return fail("get-text roundtrip");
        defer allocator.free(text_resp);
        if (countMarker(allocator, text_resp, MARKER) >= 2) {
            seen = true;
            break;
        }
        if (tries == 49) {
            // Diagnosability: show what the screen actually held.
            _ = c.fprintf(platform.stderr(), "smoke-e2e: last get-text: %.*s\n", @as(c_int, @intCast(@min(text_resp.len, 2000))), text_resp.ptr);
        }
    }
    if (!seen) return fail("marker output never appeared in get-text");

    // 3b. REAL input, not IPC: evdev keycodes and a pointer click
    // injected on the display session's seat, exactly what a physical
    // keyboard and mouse produce. Proves the whole chain the IPC
    // stages bypass — compositor → GDK/GTK event delivery → pane key
    // handling → daemon PTY → Screen → GL render → committed frame.
    if (drive) |app| {
        if (realInputStage(allocator, app, sock_path)) |why| return failMsg(why);
        say("real seat input reached the shell and repainted the window");

        if (kittyKbdStage(allocator, app, sock_path)) |why| return failMsg(why);
        say("kitty keyboard protocol encodes real key events correctly");

        // The tree-style tab sidebar is the BROWSER's tab surface while
        // it is open: new tabs become pages of the browser, not window
        // tabs. Runs before copy mode so a failure there (a known,
        // unrelated red stage) does not hide this one.
        if (treeSidebarStage(allocator, app, sock_path, rt)) |why| return failMsg(why);
        say("tree sidebar: open, new_tab made a browser PAGE; closed, new_tab made a window tab");

        if (sidebarDragStage(allocator, app, sock_path)) |why| return failMsg(why);
        say("tree sidebar drag: a row nested under another, unnested onto the empty list, and reordered above it");

        if (have_web_action) {
            if (webActionGuiStage(allocator, app, sock_path)) |why| return failMsg(why);
            say("browser action: WebGroup switching refreshed per-tab icons; a trusted click opened, drove, closed and tore down a real extension popup");
        } else {
            say("SKIP browser-action GUI stage (sketerm-webengine is not built; run `zig build web` first)");
        }

        // Run the secondary-window ownership fuse before the known
        // mouse-reporting stage can abort the rest of the full rig.
        if (!platform.is_macos) {
            if (themeSingletonStage(allocator, drive, rt, &wl_z)) |why| return failMsg(why);
            say("secondary window reused one Preferences child, flushed its pending sidebar toggle on close, and survived later global style flips");
        }

        // The palette RANKS rather than filters. Also before copy mode,
        // for the same reason the sidebar stage is.
        if (commandPaletteStage(allocator, app, sock_path)) |why| return failMsg(why);
        say("command palette: typing 'tab' ranked New Tab top, and Enter ran it");
        if (copyModeStage(allocator, app, sock_path)) |why| return failMsg(why);
        say("copy mode selected a word with vi motions and yanked it to the clipboard");
        if (hintsStage(allocator, app, sock_path)) |why| return failMsg(why);
        say("hint labels typed on the real seat, with the copy override");
        if (scrollbarStage(allocator, app, sock_path)) |why| return failMsg(why);
        say("overlay scrollbar dragged and paged on the real seat, mouse mode included");

        // 3c. The pane's context menu, driven by a real right-click and
        // by the keyboard. Contents and per-row sensitivity are
        // asserted in smoke_atspi (this rig runs GTK_A11Y=none).
        if (contextMenuStage(allocator, app, sock_path)) |why| return failMsg(why);
        say("context menu: right-click and Shift+F10 both opened it, Escape closed it, focus returned to the pane");

        // 3d. The standalone image viewer's canvas menu — a second
        // application identity in the same display session.
        if (have_wl) {
            if (viewerMenuStage(allocator, app, rt, &wl_z)) |why| return failMsg(why);
            say("image viewer: right-click and Shift+F10 opened the canvas menu, Escape closed it");
        }
    }

    // 3c. The config file, edited underneath the running GUI, applies
    // itself — including the rename-over that every editor save is.
    if (configReloadStage(allocator, sock_path, rt)) |why| return failMsg(why);
    say("config.conf edited on disk applied live, in-place AND rename-over");

    // 3e. The cursor trail animates and then leaves the pane fully
    // idle — measured in CPU, since "no timer is armed" has no other
    // observable.
    if (cursorTrailStage(allocator, sock_path, rt, pid)) |why| return failMsg(why);
    say("cursor trail animated on cursor jumps and returned the pane to idle");

    // 4. split, then list must show two panes.
    const split_resp = roundtrip(allocator, sock_path, "{\"cmd\":\"split\",\"pane\":1,\"direction\":\"h\"}\n") orelse return fail("split roundtrip");
    defer allocator.free(split_resp);
    if (std.mem.indexOf(u8, split_resp, "\"ok\":true") == null) return fail("split not ok");
    // 1 tab id + 2 pane ids.
    if (!waitIdCount(allocator, sock_path, 3, false, 10_000)) return fail("split did not add a pane");
    const list2 = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse return fail("list2 roundtrip");
    defer allocator.free(list2);

    // 5. nested split (vertical on the new pane), then close it —
    // exercises the tree model's deep split + collapse paths under
    // SKETERM_VERIFY_TREE.
    const new_pane = otherPaneInSelectedTab(list2, 1);
    if (new_pane == 0) return fail("the split's new pane is not in the selected tab");
    var split_buf: [96]u8 = undefined;
    const split2_cmd = std.fmt.bufPrint(&split_buf, "{{\"cmd\":\"split\",\"pane\":{d},\"direction\":\"v\"}}\n", .{new_pane}) catch
        return fail("building the split2 command");
    const split2 = roundtrip(allocator, sock_path, split2_cmd) orelse return fail("split2 roundtrip");
    defer allocator.free(split2);
    if (std.mem.indexOf(u8, split2, "\"ok\":true") == null) return fail("split2 not ok");
    _ = c.usleep(500_000);
    var close_buf: [96]u8 = undefined;
    const close2_cmd = std.fmt.bufPrint(&close_buf, "{{\"cmd\":\"close-pane\",\"pane\":{d}}}\n", .{new_pane}) catch
        return fail("building the close-pane command");
    const close2 = roundtrip(allocator, sock_path, close2_cmd) orelse return fail("close-pane roundtrip");
    defer allocator.free(close2);
    if (std.mem.indexOf(u8, close2, "\"ok\":true") == null) return fail("close-pane not ok");
    // Relative invariant (the instance may have restored a saved
    // default layout, so absolute counts are unknowable): split2
    // added one pane, close-pane removed one — net equal to list2.
    const ids2 = std.mem.count(u8, list2, "\"id\":");
    if (!waitIdCount(allocator, sock_path, ids2, true, 10_000)) return fail("close-pane wrong pane count");

    // 6. Closing a split that wears a browser face must synchronously
    // stop its filesystem mux watch and fence GTK's synchronous model
    // callbacks before their child widgets are destroyed.
    const split_browser = roundtrip(allocator, sock_path, "{\"cmd\":\"split\",\"pane\":1,\"direction\":\"h\"}\n") orelse return fail("browser split roundtrip");
    defer allocator.free(split_browser);
    if (std.mem.indexOf(u8, split_browser, "\"ok\":true") == null) {
        // Show the daemon's own reason — "not ok" alone says nothing
        // about WHICH way it went wrong (missing pane vs failed split).
        _ = c.fprintf(platform.stderr(), "smoke-e2e: browser split reply: %.*s\n", @as(c_int, @intCast(@min(split_browser.len, 500))), split_browser.ptr);
        const l = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n");
        if (l) |ls| {
            defer allocator.free(ls);
            _ = c.fprintf(platform.stderr(), "smoke-e2e: tree at failure: %.*s\n", @as(c_int, @intCast(@min(ls.len, 1500))), ls.ptr);
        }
        return fail("browser split not ok");
    }
    // Same rule as split2: ASK which pane the split made rather than
    // assuming an id.
    const bpane = blk: {
        const l = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse return fail("list before browser-here");
        defer allocator.free(l);
        break :blk otherPaneInSelectedTab(l, 1);
    };
    if (bpane == 0) return fail("the browser split's new pane is not in the selected tab");
    var bh_buf: [128]u8 = undefined;
    const bh_cmd = std.fmt.bufPrint(&bh_buf, "{{\"cmd\":\"browser-here\",\"pane\":{d},\"data\":\"/\"}}\n", .{bpane}) catch
        return fail("building the browser-here command");
    const browser_here = roundtrip(allocator, sock_path, bh_cmd) orelse return fail("browser-here roundtrip");
    defer allocator.free(browser_here);
    if (std.mem.indexOf(u8, browser_here, "\"ok\":true") == null) return fail("browser-here not ok");
    var bc_buf: [96]u8 = undefined;
    const bc_cmd = std.fmt.bufPrint(&bc_buf, "{{\"cmd\":\"close-pane\",\"pane\":{d}}}\n", .{bpane}) catch
        return fail("building the browser close command");
    const close_browser = roundtrip(allocator, sock_path, bc_cmd) orelse return fail("browser close roundtrip");
    defer allocator.free(close_browser);
    if (std.mem.indexOf(u8, close_browser, "\"ok\":true") == null) return fail("browser close not ok");
    // The browser face tears down asynchronously (mux watch stop, model
    // callbacks, widget destroy) — poll rather than guess a delay.
    if (!waitIdCount(allocator, sock_path, ids2, true, 15_000))
        return fail("browser split close did not remove its pane (or the GUI stopped serving)");

    // 6b. Editor face end-to-end: a new editor tab on a (not yet
    // existing) file spec, text typed over IPC, Ctrl+S saved through
    // the daemon, file content asserted, pane closed.
    {
        var efile_buf: [512]u8 = undefined;
        const efile = std.fmt.bufPrintZ(&efile_buf, "{s}/e2e-editor.txt", .{rt}) catch return fail("editor path");
        var ereq_buf: [700]u8 = undefined;
        const ereq = std.fmt.bufPrint(&ereq_buf, "{{\"cmd\":\"new-editor-tab\",\"data\":\"{s}\"}}\n", .{efile}) catch return fail("editor req fmt");
        const eresp = roundtrip(allocator, sock_path, ereq) orelse return fail("new-editor-tab roundtrip");
        defer allocator.free(eresp);
        if (std.mem.indexOf(u8, eresp, "\"ok\":true") == null) return fail("new-editor-tab not ok");
        const epane = parseNumAfter(eresp, "\"pane\":") orelse return fail("new-editor-tab reply has no pane id");
        // Let the tab spawn and the async (missing-file) load resolve.
        _ = c.usleep(1_000_000);

        var treq_buf: [256]u8 = undefined;
        const treq = std.fmt.bufPrint(&treq_buf, "{{\"cmd\":\"send-text\",\"pane\":{d},\"data\":\"hello editor\"}}\n", .{epane}) catch return fail("fmt");
        const tresp = roundtrip(allocator, sock_path, treq) orelse return fail("editor send-text roundtrip");
        defer allocator.free(tresp);
        if (std.mem.indexOf(u8, tresp, "\"ok\":true") == null) return fail("editor send-text not ok");

        const kreq = std.fmt.bufPrint(&treq_buf, "{{\"cmd\":\"send-keys\",\"pane\":{d},\"data\":\"ctrl+s\"}}\n", .{epane}) catch return fail("fmt");
        const kresp = roundtrip(allocator, sock_path, kreq) orelse return fail("editor save roundtrip");
        defer allocator.free(kresp);
        if (std.mem.indexOf(u8, kresp, "\"ok\":true") == null) return fail("editor ctrl+s not ok");

        // The save is a daemon-backed async write: poll the file.
        var saved = false;
        var etries: u32 = 0;
        while (etries < 50) : (etries += 1) {
            _ = c.usleep(200_000);
            const f = c.fopen(efile.ptr, "rb") orelse continue;
            var content: [64]u8 = undefined;
            const n = c.fread(&content, 1, content.len, f);
            _ = c.fclose(f);
            if (std.mem.eql(u8, content[0..n], "hello editor")) {
                saved = true;
                break;
            }
        }
        if (!saved) return fail("editor save never produced the expected file content");

        // Editor V2 chords driven over IPC: newline, soft wrap toggle
        // (Alt+Z), and the document-edge jumps that go through the
        // anchored scroll path. Chords that open GTK widgets (Ctrl+F)
        // need a real seat and are covered by editorInputStage below.
        {
            const chords = [_][]const u8{ "enter", "alt+z", "ctrl+home", "ctrl+end" };
            for (chords) |ch| {
                if (std.mem.eql(u8, ch, "enter")) {
                    const r0 = std.fmt.bufPrint(&treq_buf, "{{\"cmd\":\"send-keys\",\"pane\":{d},\"data\":\"enter\"}}\n", .{epane}) catch return fail("fmt");
                    const p0 = roundtrip(allocator, sock_path, r0) orelse return fail("editor enter roundtrip");
                    defer allocator.free(p0);
                    if (std.mem.indexOf(u8, p0, "\"ok\":true") == null) return fail("editor enter not ok");
                    const r1 = std.fmt.bufPrint(&treq_buf, "{{\"cmd\":\"send-text\",\"pane\":{d},\"data\":\"second line\"}}\n", .{epane}) catch return fail("fmt");
                    const p1 = roundtrip(allocator, sock_path, r1) orelse return fail("editor second-line roundtrip");
                    defer allocator.free(p1);
                    if (std.mem.indexOf(u8, p1, "\"ok\":true") == null) return fail("editor second-line not ok");
                    continue;
                }
                var cbuf: [256]u8 = undefined;
                const rq = std.fmt.bufPrint(&cbuf, "{{\"cmd\":\"send-keys\",\"pane\":{d},\"data\":\"{s}\"}}\n", .{ epane, ch }) catch return fail("fmt");
                const rp = roundtrip(allocator, sock_path, rq) orelse return fail("editor chord roundtrip");
                defer allocator.free(rp);
                if (std.mem.indexOf(u8, rp, "\"ok\":true") == null) return fail("editor chord not ok");
            }
            const kreq2 = std.fmt.bufPrint(&treq_buf, "{{\"cmd\":\"send-keys\",\"pane\":{d},\"data\":\"ctrl+s\"}}\n", .{epane}) catch return fail("fmt");
            const kresp2 = roundtrip(allocator, sock_path, kreq2) orelse return fail("editor second save roundtrip");
            defer allocator.free(kresp2);
            var saved2 = false;
            var t2: u32 = 0;
            while (t2 < 50) : (t2 += 1) {
                _ = c.usleep(200_000);
                const f = c.fopen(efile.ptr, "rb") orelse continue;
                var content: [64]u8 = undefined;
                const n = c.fread(&content, 1, content.len, f);
                _ = c.fclose(f);
                if (std.mem.eql(u8, content[0..n], "hello editor\nsecond line")) {
                    saved2 = true;
                    break;
                }
            }
            if (!saved2) return fail("editor wrap/edge chord sequence did not round-trip through a save");
        }

        // External modification of a CLEAN buffer must reload itself,
        // quietly. The rewrite is an ATOMIC one (temp + rename, so a
        // NEW inode) — the case an mtime-only check misses. The probe
        // is driven by focusing the pane, which is what a user coming
        // back to the editor does.
        {
            var tmp_buf: [600]u8 = undefined;
            const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}/e2e-editor.new", .{rt}) catch return fail("editor tmp path");
            const f = c.fopen(tmp.ptr, "wb") orelse return fail("editor external write open");
            const body = "changed on disk\n";
            _ = c.fwrite(body.ptr, 1, body.len, f);
            _ = c.fclose(f);
            if (c.rename(tmp.ptr, efile.ptr) != 0) return fail("editor external rename");

            const freq = std.fmt.bufPrint(&treq_buf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{epane}) catch return fail("fmt");
            const fresp = roundtrip(allocator, sock_path, freq) orelse return fail("editor focus roundtrip");
            defer allocator.free(fresp);
            if (std.mem.indexOf(u8, fresp, "\"ok\":true") == null) return fail("editor focus not ok");

            var reloaded = false;
            var rt_tries: u32 = 0;
            while (rt_tries < 50) : (rt_tries += 1) {
                _ = c.usleep(200_000);
                const greq = std.fmt.bufPrint(&treq_buf, "{{\"cmd\":\"get-text\",\"pane\":{d}}}\n", .{epane}) catch return fail("fmt");
                const gresp = roundtrip(allocator, sock_path, greq) orelse continue;
                defer allocator.free(gresp);
                if (std.mem.indexOf(u8, gresp, "changed on disk") != null) {
                    reloaded = true;
                    break;
                }
            }
            if (!reloaded) return fail("editor did not auto-reload a clean buffer after an external atomic rewrite");
        }

        // 6c. The editor, driven by a real seat: the GTK-widget chord
        // (Ctrl+F) that no IPC command can reach, plus the proof that
        // this face is on GTK's WAYLAND input-method path.
        if (drive) |app| {
            if (editorInputStage(allocator, app)) |why| return failMsg(why);
            say("editor search bar opened by a real Ctrl+F, on the Wayland IM path");
        }

        // 6c-2. The project layer, on a REAL git repository: root
        // discovery, the change gutter, project-wide search and the
        // outline panel.
        if (projectStage(allocator, drive, sock_path, rt)) |why| return failMsg(why);
        say("project layer: git gutter painted, project search navigated, outline listed symbols");

        // 6c-3. The same layer on a REMOTE document, and the session
        // the layout just recorded, restored by a second GUI.
        if (remoteProjectStage(allocator, drive, sock_path, rt)) |why| return failMsg(why);
        if (restoreStage(allocator, drive, rt, &wl_z)) |why| return failMsg(why);

        const creq = std.fmt.bufPrint(&treq_buf, "{{\"cmd\":\"close-pane\",\"pane\":{d}}}\n", .{epane}) catch return fail("fmt");
        const cresp = roundtrip(allocator, sock_path, creq) orelse return fail("editor close roundtrip");
        defer allocator.free(cresp);
        if (std.mem.indexOf(u8, cresp, "\"ok\":true") == null) return fail("editor close-pane not ok");
        _ = c.usleep(500_000);
        const after_editor = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse return fail("GUI stopped serving after editor close");
        defer allocator.free(after_editor);
        if (std.mem.indexOf(u8, after_editor, "\"ok\":true") == null) return fail("GUI unhealthy after editor close");
    }

    // 6c-4. Declarative UI panels (src/ui/panel + ui/panelhost.zig):
    // a document rendered into a real window, clicked on a real seat,
    // and the interaction read back over the socket.
    if (drive) |app| {
        var gui_session_buf: [64]u8 = undefined;
        const gui_session = std.fmt.bufPrintZ(&gui_session_buf, "s{d}-1", .{pid}) catch return fail("GUI session name");
        if (panelRelayGuiStage(allocator, mux_sock, gui_session, sock_path)) |why| return failMsg(why);
        say("panel relay: the daemon selected the exact GUI terminal, which rendered and answered a correlated native panel request");

        if (mcpMuxPanelStage(allocator, app, mux_sock, gui_session, sock_path)) |why| return failMsg(why);
        say("mux-native MCP: default isolated server rendered in its exact origin pane, returned a real click, and kept app/terminal resources private");

        if (panelStage(allocator, app, sock_path, rt)) |why| return failMsg(why);
        say("panel: document rendered in its own window, a real click and a slider drag came back as events, patch/list/close held");

        // 6c-5. The same panels through a REAL `sketerm mcp` server —
        // the path an assistant actually takes.
        if (mcpPanelStage(allocator, app, sock_path)) |why| return failMsg(why);
        say("mcp: ui_show rendered a panel, ui_wait_event returned a real click, ui_save read the live document back (another process's panel included), save/load/close/delete held");

        if (mcpWebReaderStage(allocator, sock_path, rt)) |why| return failMsg(why);
        say("mcp GUI web adapter: web_read IDs acted through the visible browser and a retargeted entity was refused stale");

        if (remotePanelAssetStage(allocator, app, sock_path, rt)) |why| return failMsg(why);
        say("remote panel asset: fake-SSH panel images hydrated into the GUI cache, repainted after a same-path rewrite, and kept their logical path through panel-get/save/load");

        // 6c-6. The same store, retrieved by the USER: the saved-panel
        // picker the command palette opens, driven by real keystrokes.
        if (panelPickerStage(allocator, app, sock_path, rt)) |why| return failMsg(why);
        say("picker: custom-local store IO stayed responsive and teardown-safe; close cancellation left only a valid shell tab");

        // 6c-7. The pane-face lifetime, with the fuse it needs: a panel
        // put ON an existing pane, closed, and then the GUI kept
        // running long enough for the face's widgets to be finalized.
        if (panePanelLifetimeStage(allocator, app, sock_path)) |why| return failMsg(why);
        say("panel face on a pane: shown and closed three times, and the GUI outlived every deferred widget destroy");
    }

    // 6c-8. Cast playback: `sketerm play` end to end, with the
    // fixed_grid render path and every transport control on a real
    // seat, cross-checked against the daemon's play_state stream.
    if (drive) |app| {
        if (have_wl) {
            if (castPlaybackStage(allocator, app, rt, mux_sock, &wl_z)) |why| return failMsg(why);
            say("cast playback: rendered, paused, seeked to EOF, restarted and closed (session died with the window)");

            // 6c-9. The same recording INSIDE the Sketerm Viewer, in
            // a mixed image+cast batch, navigated both directions.
            if (viewerCastStage(allocator, app, rt, mux_sock, &wl_z)) |why| return failMsg(why);
            say("viewer cast: played in place, paused, batch navigation killed/rebuilt the ephemeral session without a leak, and the text/hex fallback rendered");

            // 6c-10. Files' Quick Look, which now HOSTS the shared
            // Viewer: Space in a real Files window opens a
            // ViewerWindow on the focused entry, arrows step the
            // listing batch, Space closes it again.
            if (quickLookStage(allocator, app, rt, &wl_z)) |why| return failMsg(why);
            say("quick look: Space in a Files window opened the shared viewer on the focused file, Right stepped to the next entry, Space closed it, and the browser stayed healthy");
        }
    }

    // 6d. Dead keys, composed by a real seat on a Belgian keymap, in
    // the terminal AND in the editor. Its own session + GUI — see
    // deadKeyStage for why neither can be shared with the stages above.
    if (!platform.is_macos) {
        if (deadKeyStage(allocator, rt, mux_sock)) |why| return failMsg(why);
        say("dead keys composed on a Belgian seat: '^'+'e' -> 'e-circumflex' in both the terminal and the editor");
    }

    // 7. A stale SKETERM_PANE_ID (the GUI restarted since the pane's
    // shell was spawned, so its baked-in id no longer matches a live
    // pane) must NOT fail an attach with "no such pane" — the takeover
    // falls back to the current pane. Using a bogus session name keeps
    // this non-destructive: attachMux fails at the snapshot step (after
    // the pane resolution we're testing), for a reason that ISN'T
    // "no such pane".
    const stale = roundtrip(allocator, sock_path, "{\"cmd\":\"attach-session\",\"pane\":99999,\"data\":\"no-such-sess-e2e\"}\n") orelse return fail("stale-pane roundtrip");
    defer allocator.free(stale);
    if (std.mem.indexOf(u8, stale, "no such pane") != null) return fail("stale SKETERM_PANE_ID regressed to 'no such pane'");

    // 7b. An attach that cannot proceed must DEGRADE, never abort the
    // process: a crash here takes every attached durable session's viewer
    // with it. Sessions whose names carry a space or a colon ("Traffic
    // Giant", "ST:AFU") travel through the JSON request and the daemon's
    // lookup, so they must fail the same clean way; every shape is followed
    // by a `list` that proves the GUI is still serving.
    const attach_shapes = [_][]const u8{
        "{\"cmd\":\"attach-session\",\"data\":\"no-such-sess-e2e\"}\n",
        "{\"cmd\":\"attach-session\",\"data\":\"no such sess e2e\"}\n",
        "{\"cmd\":\"attach-session\",\"data\":\"NO:SUCH:E2E\",\"session\":\"nope-e2e\"}\n",
        "{\"cmd\":\"attach-session\",\"data\":\"\"}\n",
        "{\"cmd\":\"attach-session\"}\n",
    };
    for (attach_shapes) |shape| {
        const resp = roundtrip(allocator, sock_path, shape) orelse return fail("attach-failure roundtrip");
        defer allocator.free(resp);
        if (std.mem.indexOf(u8, resp, "\"ok\":false") == null)
            return fail("a doomed attach did not report failure");
        const still = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse
            return fail("GUI stopped serving after a failed attach");
        defer allocator.free(still);
        if (std.mem.indexOf(u8, still, "\"ok\":true") == null)
            return fail("GUI unhealthy after a failed attach");
    }

    // 8. unknown command must error.
    const bad = roundtrip(allocator, sock_path, "{\"cmd\":\"nope\"}\n") orelse return fail("bad-cmd roundtrip");
    defer allocator.free(bad);
    if (std.mem.indexOf(u8, bad, "\"ok\":false") == null) return fail("unknown cmd not rejected");

    // Leave one relayed panel tab mounted and a second target:tab setup in
    // the deliberate worker delay. SIGTERM must synchronously sever the first
    // entry, cancel the second job, and ignore its eventual handback without
    // queueing page-detach work against a freed Window.
    var teardown_requester: ?muxclient.Conn = null;
    defer if (teardown_requester) |*requester| requester.deinit();
    if (drive != null) {
        var gui_session_buf: [64]u8 = undefined;
        const gui_session = std.fmt.bufPrintZ(&gui_session_buf, "s{d}-1", .{pid}) catch
            return fail("teardown GUI session name");
        var requester = muxclient.connectPanelRequester(allocator, mux_sock, gui_session, 10_000) catch
            return fail("teardown panel requester attach");
        const mounted = panelRelayCall(
            allocator,
            &requester,
            0x5f01,
            "{\"cmd\":\"panel-show\",\"name\":\"teardown-mounted\",\"target\":\"tab\"," ++
                "\"document\":\"{\\\"root\\\":\\\"t\\\",\\\"components\\\":{\\\"t\\\":{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"mounted\\\"}}}\"}",
        ) orelse return fail("teardown mounted panel did not reply");
        defer allocator.free(mounted);
        if (std.mem.indexOf(u8, mounted, "\"ok\":true") == null)
            return fail("teardown mounted panel was rejected");
        requester.sendPanelRequest(
            0x5f02,
            "{\"cmd\":\"panel-show\",\"name\":\"teardown-pending\",\"target\":\"tab\"," ++
                "\"document\":\"{\\\"root\\\":\\\"t\\\",\\\"components\\\":{\\\"t\\\":{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"pending\\\"}}}\"}",
        ) catch return fail("teardown pending panel send");
        teardown_requester = requester;
        _ = c.usleep(100_000);
    }

    // Shut down via SIGTERM (graceful path) and check socket cleanup.
    _ = c.kill(pid, c.SIGTERM);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    const gui_ok = c.WIFEXITED(status) and c.WEXITSTATUS(status) == 0;
    child_pid = 0;
    if (!gui_ok) return fail("GUI exited abnormally during final teardown");
    if (c.access(sock_path.ptr, c.F_OK) == 0) return fail("socket not unlinked on shutdown");
    if (web_helper_pid > 0) {
        var helper_wait: u32 = 0;
        while (!pidGone(web_helper_pid) and helper_wait < 10_000) : (helper_wait += 50)
            _ = c.usleep(50_000);
        if (!pidGone(web_helper_pid)) return fail("browser helper outlived the GUI's graceful shutdown");
        web_helper_pid = -1;
    }

    // Viewer, display session, daemon — by exact pid and by name.
    teardown();

    _ = c.fputs("smoke-e2e: PASS\n", platform.stdout());
    return 0;
}

/// Occurrences of `marker` in a get-text reply, counted on a de-wrapped
/// copy: a narrow window wraps the typed line mid-marker, so the JSON
/// "\n" escapes are stripped before counting.
/// Run one `/bin/sh -c` line, returning its exit status.
fn sh(cmd: [*:0]const u8) c_int {
    const st = c.system(cmd);
    return if (c.WIFEXITED(st)) c.WEXITSTATUS(st) else -1;
}

/// Count pixels in the GUTTER STRIP that match one of the change
/// colours, so "the gutter painted a mark" is an assertion and not a
/// screenshot somebody has to look at.
fn gutterMarkPixels(allocator: std.mem.Allocator, app: *appdrive.App, win_id: u32) usize {
    const shot = app.snapshotRgba(win_id, null) catch return 0;
    defer allocator.free(shot.px);
    const colors = editor_pass.Colors{};
    var n: usize = 0;
    var y: u32 = 0;
    while (y < shot.h) : (y += 1) {
        // The gutter is at the left edge of the editor canvas, which is
        // itself at the left edge of the window.
        var x: u32 = 0;
        while (x < @min(shot.w, 130)) : (x += 1) {
            const i = (y * shot.w + x) * 4;
            if (i + 2 >= shot.px.len) break;
            const px = [3]u8{ shot.px[i], shot.px[i + 1], shot.px[i + 2] };
            if (nearColor8(px, colors.git_added) or
                nearColor8(px, colors.git_modified) or
                nearColor8(px, colors.git_deleted)) n += 1;
        }
    }
    return n;
}

fn dumpLeftStrip(allocator: std.mem.Allocator, app: *appdrive.App, win_id: u32) void {
    const shot = app.snapshotRgba(win_id, null) catch return;
    defer allocator.free(shot.px);
    var counts: [64]struct { rgb: [3]u8, n: usize } = undefined;
    var used: usize = 0;
    var y: u32 = 0;
    while (y < shot.h) : (y += 1) {
        var x: u32 = 0;
        while (x < @min(shot.w, 130)) : (x += 1) {
            const i = (y * shot.w + x) * 4;
            if (i + 2 >= shot.px.len) break;
            const px = [3]u8{ shot.px[i], shot.px[i + 1], shot.px[i + 2] };
            var found = false;
            for (counts[0..used]) |*e| {
                if (e.rgb[0] == px[0] and e.rgb[1] == px[1] and e.rgb[2] == px[2]) {
                    e.n += 1;
                    found = true;
                    break;
                }
            }
            if (!found and used < counts.len) {
                counts[used] = .{ .rgb = px, .n = 1 };
                used += 1;
            }
        }
    }
    _ = c.fprintf(platform.stderr(), "smoke-e2e: left strip %ux%u distinct=%zu\n", shot.w, shot.h, used);
    for (counts[0..used]) |e| {
        if (e.n < 20) continue;
        _ = c.fprintf(platform.stderr(), "  rgb(%u,%u,%u) x%zu\n", @as(c_uint, e.rgb[0]), @as(c_uint, e.rgb[1]), @as(c_uint, e.rgb[2]), e.n);
    }
}

/// Chrome-coloured pixels in the 200px strip the outline panel claims.
/// The editor canvas there is the dark theme background, so a jump in
/// this count IS the panel.
/// The right-hand CANVAS band, copied out for a before/after compare.
/// Deliberately not a "count the light pixels" heuristic: that assumed a
/// LIGHT outline panel against a dark canvas, and under the dark theme
/// this rig actually runs the panel is dark too — it opened correctly
/// and the assertion still failed (0 -> 278 px against a +20000 bar).
/// What "the panel took a column" really means is that the band STOPPED
/// LOOKING LIKE THE CANVAS, which a diff states without knowing either
/// theme's colours. The window chrome above and the project panel below
/// are excluded because they change for their own reasons.
const Band = struct {
    px: []u8,
    w: u32,
    h: u32,
    fn deinit(self: Band, allocator: std.mem.Allocator) void {
        allocator.free(self.px);
    }
};

fn captureRightBand(allocator: std.mem.Allocator, app: *appdrive.App, win_id: u32) ?Band {
    const shot = app.snapshotRgba(win_id, null) catch return null;
    defer allocator.free(shot.px);
    if (shot.w < 260 or shot.h < 500) return null;
    const x0 = shot.w - 240;
    const x1 = shot.w - 30;
    const y0: u32 = 220;
    const y1: u32 = shot.h - 230;
    if (y1 <= y0) return null;
    const bw = x1 - x0;
    const bh = y1 - y0;
    const out = allocator.alloc(u8, @as(usize, bw) * bh * 4) catch return null;
    var y: u32 = 0;
    while (y < bh) : (y += 1) {
        const src = ((y0 + y) * shot.w + x0) * 4;
        const dst = @as(usize, y) * bw * 4;
        if (src + bw * 4 > shot.px.len) {
            allocator.free(out);
            return null;
        }
        @memcpy(out[dst..][0 .. bw * 4], shot.px[src..][0 .. bw * 4]);
    }
    return .{ .px = out, .w = bw, .h = bh };
}

/// Pixels of `b` that differ from `a` beyond a small tolerance.
fn bandChanged(a: Band, b: Band) usize {
    if (a.w != b.w or a.h != b.h or a.px.len != b.px.len) return 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i + 3 < a.px.len) : (i += 4) {
        const dr = @abs(@as(i32, a.px[i]) - @as(i32, b.px[i]));
        const dg = @abs(@as(i32, a.px[i + 1]) - @as(i32, b.px[i + 1]));
        const db = @abs(@as(i32, a.px[i + 2]) - @as(i32, b.px[i + 2]));
        if (dr + dg + db > 24) n += 1;
    }
    return n;
}

fn nearColor8(px: [3]u8, want: [4]f32) bool {
    inline for (0..3) |i| {
        const w: i32 = @intFromFloat(want[i] * 255.0 + 0.5);
        const got: i32 = px[i];
        if (@abs(got - w) > 12) return false;
    }
    return true;
}

/// The project layer end to end against a REAL repository.
///
/// Everything here is a daemon round trip on the file's own host (root
/// discovery listings, `git diff` through the panelize verb, grep, the
/// candidate reads), so this stage is also the proof that the layer
/// works for a document the GUI never touched the disk for.
fn projectStage(
    allocator: std.mem.Allocator,
    maybe_app: ?*appdrive.App,
    sock_path: [:0]const u8,
    rt: []const u8,
) ?[]const u8 {
    // ── a scratch repository ──────────────────────────────────────
    var cmd_buf: [2048:0]u8 = undefined;
    const setup = std.fmt.bufPrintZ(&cmd_buf,
        \\set -e
        \\rm -rf {s}/proj && mkdir -p {s}/proj/src
        \\printf 'const std = @import("std");\n\npub fn main() void {{\n    hello();\n}}\n\nfn hello() void {{\n    _ = std;\n}}\n' > {s}/proj/src/main.zig
        \\printf 'pub const NEEDLETOKEN = 1;\npub fn use() void {{\n    _ = NEEDLETOKEN;\n}}\n' > {s}/proj/src/other.zig
        \\cd {s}/proj
        \\git init -q -b main .
        \\git config user.email s@e && git config user.name s
        \\git add -A && git commit -q -m init
    , .{ rt, rt, rt, rt, rt }) catch return "project setup command too long";
    if (sh(setup.ptr) != 0) return "could not build the scratch git repository (is git installed?)";

    var main_buf: [512]u8 = undefined;
    const main_path = std.fmt.bufPrintZ(&main_buf, "{s}/proj/src/main.zig", .{rt}) catch return "path";
    var other_buf: [512]u8 = undefined;
    const other_path = std.fmt.bufPrintZ(&other_buf, "{s}/proj/src/other.zig", .{rt}) catch return "path";

    // ── open it in an editor tab ──────────────────────────────────
    var req_buf: [900]u8 = undefined;
    const oreq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"new-editor-tab\",\"data\":\"{s}\"}}\n", .{main_path}) catch return "fmt";
    const oresp = roundtrip(allocator, sock_path, oreq) orelse return "project new-editor-tab roundtrip";
    defer allocator.free(oresp);
    if (std.mem.indexOf(u8, oresp, "\"ok\":true") == null) return "project new-editor-tab not ok";
    const ppane = parseNumAfter(oresp, "\"pane\":") orelse return "project editor tab has no pane id";
    _ = c.usleep(1_500_000);
    // The new tab is not necessarily the VISIBLE one (the rig already
    // owns an editor tab), and every pixel assertion below reads the
    // window, so make it the visible one first.
    {
        const freq0 = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{ppane}) catch return "fmt";
        const fresp0 = roundtrip(allocator, sock_path, freq0) orelse return "project focus roundtrip";
        defer allocator.free(fresp0);
        if (std.mem.indexOf(u8, fresp0, "\"ok\":true") == null) return "project focus not ok";
        _ = c.usleep(700_000);
    }

    // The document really came from the daemon.
    {
        const greq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"get-text\",\"pane\":{d}}}\n", .{ppane}) catch return "fmt";
        const gresp = roundtrip(allocator, sock_path, greq) orelse return "project get-text roundtrip";
        defer allocator.free(gresp);
        if (std.mem.indexOf(u8, gresp, "pub fn main") == null) return "the project file did not load";
    }

    // ── the change gutter ─────────────────────────────────────────
    //
    // The gutter is computed against the file ON DISK, so the mark
    // appears once the edit is SAVED — which is also when the refresh
    // is triggered. Type at the caret (top of file) and save.
    if (maybe_app) |app| {
        _ = app.drainLive(2_000);
        if (app.windows.items.len == 0) return "the display session lost its window";
        const win_id = app.windows.items[0].id;
        const before = gutterMarkPixels(allocator, app, win_id);

        const treq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"send-text\",\"pane\":{d},\"data\":\"// touched\"}}\n", .{ppane}) catch return "fmt";
        const tresp = roundtrip(allocator, sock_path, treq) orelse return "project send-text roundtrip";
        allocator.free(tresp);
        const sreq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"send-keys\",\"pane\":{d},\"data\":\"ctrl+s\"}}\n", .{ppane}) catch return "fmt";
        const sresp = roundtrip(allocator, sock_path, sreq) orelse return "project save roundtrip";
        allocator.free(sresp);

        var after: usize = 0;
        var tries: u32 = 0;
        while (tries < 60) : (tries += 1) {
            // PUMP: `snapshotRgba` reads the last frame this viewer
            // actually received, so a sleep alone would poll a stale
            // window for ever.
            _ = app.pumpOnce(250);
            after = gutterMarkPixels(allocator, app, win_id);
            if (after > before + 8) break;
        }
        if (app.screenshotPng(win_id, 0, null, 0)) |shot| {
            defer allocator.free(shot.png);
            writePng("zig-out/smoke-e2e-git-gutter.png", shot.png);
        } else |_| {}
        if (after <= before + 8) {
            _ = c.fprintf(platform.stderr(), "smoke-e2e: gutter pixels before=%zu after=%zu\n", before, after);
            dumpLeftStrip(allocator, app, win_id);
            return "the git gutter painted no change mark after a save inside a repository";
        }

        // Hunk navigation. Where the caret LANDS is not observable over
        // IPC, so park it at the end of the document, press F7, and type
        // a marker: the text says exactly where the caret was.
        {
            const ereq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"send-keys\",\"pane\":{d},\"data\":\"ctrl+end\"}}\n", .{ppane}) catch return "fmt";
            const eresp2 = roundtrip(allocator, sock_path, ereq) orelse return "ctrl+end roundtrip";
            allocator.free(eresp2);
            _ = app.waitIdle(200, 3_000);
            app.pressKey(null, "F7") catch return "injecting F7 failed";
            _ = app.waitIdle(300, 5_000);
            const mreq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"send-text\",\"pane\":{d},\"data\":\"HUNKMARK\"}}\n", .{ppane}) catch return "fmt";
            const mresp = roundtrip(allocator, sock_path, mreq) orelse return "hunk marker roundtrip";
            allocator.free(mresp);
            const greq2 = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"get-text\",\"pane\":{d}}}\n", .{ppane}) catch return "fmt";
            const gresp2 = roundtrip(allocator, sock_path, greq2) orelse return "hunk get-text roundtrip";
            defer allocator.free(gresp2);
            // The only change against HEAD is on line 1, so F7 must have
            // put the caret at its start.
            if (std.mem.indexOf(u8, gresp2, "HUNKMARK// touched") == null)
                return "F7 did not move the caret to the change hunk";
            // Undo the marker so the search stage sees the file it expects.
            const ureq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"send-keys\",\"pane\":{d},\"data\":\"ctrl+z\"}}\n", .{ppane}) catch return "fmt";
            const uresp = roundtrip(allocator, sock_path, ureq) orelse return "undo roundtrip";
            allocator.free(uresp);
        }
    }

    // ── project-wide search, driven by a real seat ────────────────
    if (maybe_app) |app| {
        const win_id = app.windows.items[0].id;
        // Focus the canvas so the chord reaches the editor face.
        const freq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{ppane}) catch return "fmt";
        const fresp = roundtrip(allocator, sock_path, freq) orelse return "project focus roundtrip";
        allocator.free(fresp);
        _ = app.waitIdle(300, 4_000);

        var ref = app.frameRef(win_id, true) orelse return "no baseline frame for the project search";
        defer ref.deinit(allocator);
        app.pressKey(null, "ctrl+shift+f") catch return "injecting ctrl+shift+f failed";
        if (!app.waitChangeSince(win_id, &ref, 15_000, 0.01, null))
            return "ctrl+shift+f did not open the project search panel";

        app.typeText(null, "NEEDLETOKEN") catch return "typing the project needle failed";
        _ = app.waitIdle(200, 4_000);
        app.pressKey(null, "return") catch return "injecting return failed";

        // The search reads its candidates through the daemon; poll for
        // the panel to fill rather than guessing a delay.
        var ref2 = app.frameRef(win_id, true) orelse return "no post-search frame";
        defer ref2.deinit(allocator);
        _ = app.waitChangeSince(win_id, &ref2, 20_000, 0.005, null);
        _ = app.waitVisualSettle(win_id, 500, 10_000, 0.002, null);
        if (app.screenshotPng(win_id, 0, null, 0)) |shot| {
            defer allocator.free(shot.png);
            writePng("zig-out/smoke-e2e-project-search.png", shot.png);
        } else |_| {}

        // Activate the first hit: it must open other.zig at the match.
        // Rows are at the bottom panel; walk down from the entry with
        // Tab-free navigation by clicking the first hit row.
        const wh: f64 = @floatFromInt(app.windows.items[0].h);
        const ww: f64 = @floatFromInt(app.windows.items[0].w);
        // The results list fills the panel below its two toolbars; the
        // first hit row is the second row from its top.
        var opened = false;
        var row: u32 = 0;
        while (row < 6 and !opened) : (row += 1) {
            const y = wh - 100 + @as(f64, @floatFromInt(row)) * 22;
            if (y >= wh - 4) break;
            app.clickEx(win_id, ww * 0.3, y, 1, 60, 2) catch continue;
            _ = app.waitIdle(300, 4_000);
            const greq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"get-text\",\"pane\":{d}}}\n", .{ppane}) catch return "fmt";
            const gresp = roundtrip(allocator, sock_path, greq) orelse continue;
            defer allocator.free(gresp);
            if (std.mem.indexOf(u8, gresp, "NEEDLETOKEN") != null) opened = true;
        }
        if (!opened) return "activating a project-search hit did not open the file it named";
    }

    // ── the outline panel ─────────────────────────────────────────
    if (maybe_app) |app| {
        const win_id = app.windows.items[0].id;
        const band_before = captureRightBand(allocator, app, win_id) orelse
            return "could not sample the editor canvas band";
        defer band_before.deinit(allocator);
        // Focus is in the search panel after activating a hit; the
        // outline chord belongs to the editor canvas.
        const freq2 = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{ppane}) catch return "fmt";
        const fresp2 = roundtrip(allocator, sock_path, freq2) orelse return "outline focus roundtrip";
        allocator.free(fresp2);
        _ = app.waitIdle(300, 4_000);
        var ref = app.frameRef(win_id, true) orelse return "no baseline frame for the outline";
        defer ref.deinit(allocator);
        app.pressKey(null, "ctrl+shift+o") catch return "injecting ctrl+shift+o failed";
        if (!app.waitChangeSince(win_id, &ref, 15_000, 0.01, null))
            return "ctrl+shift+o did not open the outline panel";
        _ = app.waitVisualSettle(win_id, 400, 8_000, 0.002, null);
        if (app.screenshotPng(win_id, 0, null, 0)) |shot| {
            defer allocator.free(shot.png);
            writePng("zig-out/smoke-e2e-outline.png", shot.png);
        } else |_| {}
        // The panel takes a real column out of the canvas: the strip it
        // occupies must stop being the editor's dark background. The
        // baseline is not zero (the scrollbar and the window edge live
        // there), so the assertion is relative.
        const band_after = captureRightBand(allocator, app, win_id) orelse
            return "could not sample the editor canvas band after the outline opened";
        defer band_after.deinit(allocator);
        const changed = bandChanged(band_before, band_after);
        const band_total = @as(usize, band_before.w) * band_before.h;
        _ = c.fprintf(platform.stderr(), "smoke-e2e: outline column changed %zu of %zu px\n", changed, band_total);
        // A panel that took the column repaints most of the band; a
        // caret blink or a scrollbar nudge cannot reach a third of it.
        if (changed * 3 < band_total)
            return "the outline panel did not take a column from the canvas";
        // Closing it again must restore the canvas width.
        var ref2 = app.frameRef(win_id, true) orelse return "no open-outline frame";
        defer ref2.deinit(allocator);
        app.pressKey(null, "ctrl+shift+o") catch return "injecting ctrl+shift+o failed";
        if (!app.waitChangeSince(win_id, &ref2, 15_000, 0.01, null))
            return "ctrl+shift+o did not close the outline panel";
    }

    // ── previewed, then applied, project-wide replace ─────────────
    if (maybe_app) |app| {
        const win_id = app.windows.items[0].id;
        // Ctrl+Shift+H with the needle already typed opens the replace
        // row AND puts the caret in it.
        app.pressKey(null, "ctrl+shift+h") catch return "injecting ctrl+shift+h failed";
        _ = app.waitIdle(300, 5_000);
        app.typeText(null, "REPLACEDTOKEN") catch return "typing the replacement failed";
        _ = app.waitIdle(200, 4_000);
        // Enter previews: nothing may be written yet.
        app.pressKey(null, "return") catch return "injecting return failed";
        _ = app.waitVisualSettle(win_id, 600, 15_000, 0.002, null);
        if (app.screenshotPng(win_id, 0, null, 0)) |shot| {
            defer allocator.free(shot.png);
            writePng("zig-out/smoke-e2e-replace-preview.png", shot.png);
        } else |_| {}
        if (fileContains(other_path, "REPLACEDTOKEN"))
            return "the replace PREVIEW wrote to disk";
        if (!fileContains(other_path, "NEEDLETOKEN"))
            return "the replace preview changed the file it only previewed";

        // Ctrl+Enter applies.
        app.pressKey(null, "ctrl+return") catch return "injecting ctrl+return failed";
        var wrote = false;
        var w_tries: u32 = 0;
        while (w_tries < 80) : (w_tries += 1) {
            _ = app.pumpOnce(250);
            if (fileContains(other_path, "REPLACEDTOKEN")) {
                wrote = true;
                break;
            }
        }
        if (!wrote) return "the applied project-wide replace never reached the file";
        if (fileContains(other_path, "NEEDLETOKEN"))
            return "the applied replace left the old token behind";
        _ = app.waitVisualSettle(win_id, 600, 15_000, 0.002, null);
        if (app.screenshotPng(win_id, 0, null, 0)) |shot| {
            defer allocator.free(shot.png);
            writePng("zig-out/smoke-e2e-replace-applied.png", shot.png);
        } else |_| {}
        app.pressKey(null, "escape") catch {};
        _ = app.waitIdle(300, 4_000);
    }

    // ── the session the layout persists ───────────────────────────
    {
        const areq = "{\"cmd\":\"action\",\"data\":\"save_layout\"}\n";
        const aresp = roundtrip(allocator, sock_path, areq) orelse return "save_layout roundtrip";
        defer allocator.free(aresp);
        if (std.mem.indexOf(u8, aresp, "\"ok\":true") == null) return "save_layout not ok";
        var lay_buf: [512]u8 = undefined;
        const lay = std.fmt.bufPrintZ(&lay_buf, "{s}/sketerm/last.json", .{rt}) catch return "layout path";
        var ok = false;
        var t: u32 = 0;
        while (t < 40 and !ok) : (t += 1) {
            _ = c.usleep(150_000);
            ok = fileContains(lay, "\"project\":") and fileContains(lay, "src/main.zig");
        }
        if (!ok) return "the saved layout carries no editor session (project association missing)";
        if (!fileContains(lay, "\"top_line\":")) return "the saved layout carries no scroll anchor";
    }
    return null;
}

/// True when `path` exists and contains `needle` (bounded read).
fn fileContains(path: [*:0]const u8, needle: []const u8) bool {
    const f = c.fopen(path, "rb") orelse return false;
    defer _ = c.fclose(f);
    var buf: [256 * 1024]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len, f);
    return std.mem.indexOf(u8, buf[0..n], needle) != null;
}

fn writePng(path: [*:0]const u8, bytes: []const u8) void {
    const f = c.fopen(path, "wb") orelse return;
    _ = c.fwrite(bytes.ptr, 1, bytes.len, f);
    _ = c.fclose(f);
}

/// Rectangle of the ACTIVE tree-sidebar row's chip, in the window's
/// left third. Null when the sidebar is not showing one, which is how
/// the rig reads sidebar visibility.
///
/// Pixels arrive as Wayland ARGB/XRGB8888, little-endian, so the bytes
/// are B,G,R,A. libadwaita's selection blue is far more blue than red;
/// the terminal's own colours in this rig are not.
///
/// A BLOCK, not a bounding box: the focused pane's border is drawn in
/// the same accent colour, so "some accent pixels exist on the left" is
/// true with the sidebar closed too. A chip is instead a solid run at
/// least CHIP_MIN_W wide repeated over at least CHIP_MIN_H rows, which
/// a one-pixel border can never be.
const CHIP_MIN_W: usize = 60;
const CHIP_MIN_H: usize = 8;

fn sidebarChipBounds(app: *appdrive.App, win_id: u32) ?struct { min_x: usize, max_x: usize, min_y: usize, max_y: usize } {
    for (app.windows.items) |w| {
        if (w.id != win_id or w.w <= 0 or w.h <= 0) continue;
        const width: usize = @intCast(w.w);
        const height: usize = @intCast(w.h);
        const px = w.pixels.items;
        if (px.len < width * height * 4) return null;
        const limit = width / 3;
        var min_x = limit;
        var max_x: usize = 0;
        var min_y: usize = 0;
        var run_rows: usize = 0;
        var y: usize = 0;
        while (y < height) : (y += 1) {
            const row = y * width * 4;
            // Longest accent run on this scanline.
            var best_start: usize = 0;
            var best_len: usize = 0;
            var start: usize = 0;
            var len: usize = 0;
            var x: usize = 0;
            while (x < limit) : (x += 1) {
                const i = row + x * 4;
                const b: i32 = px[i];
                const g: i32 = px[i + 1];
                const r: i32 = px[i + 2];
                if (b > 150 and b - r > 70 and g < b) {
                    if (len == 0) start = x;
                    len += 1;
                    if (len > best_len) {
                        best_len = len;
                        best_start = start;
                    }
                } else {
                    len = 0;
                }
            }
            if (best_len >= CHIP_MIN_W) {
                if (run_rows == 0) {
                    min_y = y;
                    min_x = best_start;
                    max_x = best_start + best_len - 1;
                } else {
                    min_x = @min(min_x, best_start);
                    max_x = @max(max_x, best_start + best_len - 1);
                }
                run_rows += 1;
                continue;
            }
            if (run_rows >= CHIP_MIN_H) return .{ .min_x = min_x, .max_x = max_x, .min_y = min_y, .max_y = y - 1 };
            run_rows = 0;
        }
        if (run_rows >= CHIP_MIN_H) return .{ .min_x = min_x, .max_x = max_x, .min_y = min_y, .max_y = height - 1 };
        return null;
    }
    return null;
}

/// Right edge, in window pixels, of the selected row's chip, which
/// spans the sidebar's width. 0 when there is no chip.
fn sidebarChipRight(app: *appdrive.App, win_id: u32) usize {
    const bounds = sidebarChipBounds(app, win_id) orelse return 0;
    return bounds.max_x;
}

/// Wait until `win_id`'s tree sidebar is shown (its active row paints a
/// chip) or hidden (nothing does). Sidebar visibility is PER WINDOW and
/// no longer touches config.conf, so this pixel probe — not a file — is
/// the proof that a toggle reached the window it was aimed at.
fn waitSidebarVisible(app: *appdrive.App, win_id: u32, want: bool, timeout_ms: u32) bool {
    var waited: u32 = 0;
    while (true) {
        if ((sidebarChipRight(app, win_id) != 0) == want) return true;
        if (waited >= timeout_ms) return false;
        _ = app.pumpOnce(100);
        waited += 100;
    }
}

/// True when config.conf currently carries a `show_tab_sidebar` line.
/// A runtime toggle must NEVER write one: that key is the default a new
/// window opens with, and persisting a toggle into it is what flipped
/// the sidebar in every other window on the next reload.
fn configHasSidebarKey(allocator: std.mem.Allocator, rt: []const u8) bool {
    var pbuf: [512:0]u8 = undefined;
    const p = std.fmt.bufPrintZ(&pbuf, "{s}/sketerm/config.conf", .{rt}) catch return false;
    const body = readFileAlloc(allocator, p) orelse return false;
    defer allocator.free(body);
    return std.mem.indexOf(u8, body, "show_tab_sidebar") != null;
}

/// A point on the selected tree-sidebar row's blue chip. Clicking it
/// gives a real GtkListBoxRow keyboard focus without a test-only IPC
/// focus hook.
fn sidebarChipPoint(app: *appdrive.App, win_id: u32) ?struct { x: f64, y: f64 } {
    const bounds = sidebarChipBounds(app, win_id) orelse return null;
    return .{
        .x = @floatFromInt((bounds.min_x + bounds.max_x) / 2),
        .y = @floatFromInt((bounds.min_y + bounds.max_y) / 2),
    };
}

/// Count `"pane":N` occurrences in a `web-list` reply: how many browser
/// PAGES live on that pane. One row per page is the contract.
fn webViewsOnPane(resp: []const u8, pane: u32) usize {
    var needle_buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"pane\":{d},", .{pane}) catch return 0;
    var n: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, resp, from, needle)) |at| : (from = at + needle.len) n += 1;
    return n;
}

/// View ids on `pane`, in `web-list` order (= the browser's page order).
/// `out` is filled up to its length; the count is returned.
fn webViewIds(resp: []const u8, pane: u32, out: []u32) usize {
    var needle_buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"pane\":{d},", .{pane}) catch return 0;
    var n: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, resp, from, needle)) |at| {
        from = at + needle.len;
        if (n >= out.len) break;
        // "view" is the field right after "pane" in WebViewInfo.
        const vat = std.mem.indexOfPos(u8, resp, from, "\"view\":") orelse break;
        const rest = resp[vat + 7 ..];
        const end = std.mem.indexOfAny(u8, rest, ",}") orelse break;
        out[n] = std.fmt.parseInt(u32, rest[0..end], 10) catch continue;
        n += 1;
    }
    return n;
}

/// The view id of the page `pane` is SHOWING — the row that reports
/// `"visible":true`. 0 when the reply names none.
fn activeWebView(resp: []const u8, pane: u32) u32 {
    var needle_buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"pane\":{d},", .{pane}) catch return 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, resp, from, needle)) |at| {
        from = at + needle.len;
        // The row ends where the next one begins (or at the end).
        const next = std.mem.indexOfPos(u8, resp, from, "{\"pane\":") orelse resp.len;
        const row = resp[at..next];
        if (std.mem.indexOf(u8, row, "\"visible\":true") == null) continue;
        const vat = std.mem.indexOf(u8, row, "\"view\":") orelse continue;
        const rest = row[vat + 7 ..];
        const end = std.mem.indexOfAny(u8, rest, ",}") orelse continue;
        return std.fmt.parseInt(u32, rest[0..end], 10) catch 0;
    }
    return 0;
}

/// Which window tab is selected, as its first pane id — enough to tell
/// "the selection moved" from "it did not".
fn selectedTabFirstPane(resp: []const u8) u32 {
    const at = std.mem.indexOf(u8, resp, "\"selected\":true") orelse return 0;
    const panes_at = std.mem.indexOfPos(u8, resp, at, "\"panes\":[") orelse return 0;
    const idat = std.mem.indexOfPos(u8, resp, panes_at, "\"id\":") orelse return 0;
    const rest = resp[idat + 5 ..];
    const end = std.mem.indexOfAny(u8, rest, ",}") orelse return 0;
    return std.fmt.parseInt(u32, rest[0..end], 10) catch 0;
}

fn countTabs(resp: []const u8) usize {
    var n: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, resp, from, "\"panes\":[")) |at| : (from = at + 9) n += 1;
    return n;
}

fn tabCount(allocator: std.mem.Allocator, sock_path: [:0]const u8) ?usize {
    const r = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse return null;
    defer allocator.free(r);
    return countTabs(r);
}

const tree_toggle_key = if (platform.is_macos) "cmd+shift+option+b" else "ctrl+shift+alt+b";
const tree_collapse_key = if (platform.is_macos) "cmd+shift+option+h" else "ctrl+shift+alt+h";
const tree_expand_key = if (platform.is_macos) "cmd+shift+option+e" else "ctrl+shift+alt+e";
const tree_next_key = if (platform.is_macos) "cmd+option+pagedown" else "ctrl+alt+pagedown";
const tree_prev_key = if (platform.is_macos) "cmd+option+pageup" else "ctrl+alt+pageup";

fn selectedTabPane(allocator: std.mem.Allocator, sock_path: [:0]const u8) ?u32 {
    const r = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse return null;
    defer allocator.free(r);
    return selectedTabFirstPane(r);
}

fn expectRealTreeStep(
    allocator: std.mem.Allocator,
    app: *appdrive.App,
    sock_path: [:0]const u8,
    key: []const u8,
    context: []const u8,
) ?[]const u8 {
    const before = selectedTabPane(allocator, sock_path) orelse return "list failed before a real tree shortcut";
    app.pressKey(null, key) catch return "injecting a real tree shortcut failed";
    _ = app.waitIdle(300, 5_000);
    const after = selectedTabPane(allocator, sock_path) orelse return "list failed after a real tree shortcut";
    if (before == after) {
        _ = c.fprintf(platform.stderr(), "smoke-e2e: real tree key did not move from %.*s focus\n", @as(c_int, @intCast(context.len)), context.ptr);
        return "a real tree shortcut did not move the window tab selection";
    }
    return null;
}

/// The command palette RANKS, it does not merely filter.
///
/// Typing "tab" has to select "New Tab". The trap it must avoid is
/// "Keyboard Hints", whose DESCRIPTION mentions Tab and which sits
/// earlier in the catalogue — a filter-only palette (what this was
/// before the shared suggestion framework) hides non-matches while
/// preserving catalogue order, so it would put Keyboard Hints on top.
///
/// Asserted behaviourally rather than by reading pixels, because there
/// is no IPC command that reads a widget's text and OCR cannot say
/// which row is FIRST without a fragile geometry comparison. Enter
/// activates whatever the palette selected, and the two candidates have
/// different observable effects: New Tab adds a window tab, Keyboard
/// Hints does not. The tab count is therefore the ranking assertion and
/// it cannot pass by accident. `commandcat.zig` pins the same
/// expectation as a unit test; this proves the GUI wires it up.
fn commandPaletteStage(allocator: std.mem.Allocator, app: *appdrive.App, sock_path: [:0]const u8) ?[]const u8 {
    _ = app.drainLive(1_000);
    if (app.windows.items.len == 0) return "the display session lost its window";
    const win_id = app.windows.items[0].id;

    const before = tabCount(allocator, sock_path) orelse
        return "list roundtrip failed before the command-palette stage";
    var keep_ids: [64]u32 = undefined;
    var keep_n: usize = 0;
    {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse
            return "list roundtrip failed before the command-palette stage";
        defer allocator.free(r);
        keep_n = listPaneIds(r, &keep_ids);
    }

    // Open it through the same action the keybind dispatches.
    var ref = app.frameRef(win_id, true) orelse return "no baseline frame for the command palette";
    defer ref.deinit(allocator);
    const opened = roundtrip(allocator, sock_path, "{\"cmd\":\"action\",\"data\":\"command_palette\"}\n") orelse
        return "command_palette action roundtrip failed";
    allocator.free(opened);
    if (!app.waitChangeSince(win_id, &ref, 15_000, 0.01, null))
        return "the command palette did not open";
    // Let the present animation finish BEFORE the pre-typing baseline,
    // or the fade-in is still repainting and the "did the entry take
    // the text" check below passes on the animation instead.
    _ = app.waitVisualSettle(win_id, 300, 5_000, 0.002, null);

    // Type the query. The palette filters ~80 rows down to a handful,
    // which is a large visual change; if nothing moves, the entry never
    // took the text and any ranking verdict below would be a lie.
    var ref2 = app.frameRef(win_id, true) orelse return "no pre-typing frame for the command palette";
    defer ref2.deinit(allocator);
    app.typeText(null, "tab") catch {};
    var typed = app.waitChangeSince(win_id, &ref2, 5_000, 0.005, null);
    if (!typed) {
        // GTK's wayland IM module can leave a focused GtkText waiting
        // for the compositor to produce its text, and nothing in this
        // harness plays IME. A paste goes through GtkText's own binding
        // and bypasses the IM entirely.
        app.pasteText(null, "tab") catch return "pasting the palette query failed";
        typed = app.waitChangeSince(win_id, &ref2, 8_000, 0.005, null);
    }
    if (!typed) return "typing 'tab' into the palette changed nothing on screen";
    _ = app.waitVisualSettle(win_id, 300, 5_000, 0.002, null);

    // No screenshot on the happy path, deliberately. AdwDialog presents
    // with a fade, and the frame this rig captures reliably predates the
    // filter being painted — a success artefact would show an
    // UNFILTERED palette and read as though the stage were bogus. The
    // verdict below is behavioural and does not depend on pixels; the
    // failure branch keeps a frame for whoever has to debug a red run.
    app.pressKey(null, "return") catch return "injecting return into the palette failed";
    _ = app.waitIdle(300, 5_000);

    // This check is self-validating, which is why it is the one that
    // matters: with an EMPTY entry the top row is the catalogue's first,
    // "Copy", and copy_selection opens no tab. So a tab appearing proves
    // BOTH that the entry took the text and that ranking chose a
    // tab-opening row over the earlier-in-catalogue decoys.
    var got: usize = before;
    var tries: u32 = 0;
    while (tries < 50) : (tries += 1) {
        got = tabCount(allocator, sock_path) orelse got;
        if (got == before + 1) break;
        _ = app.pumpOnce(100);
    }
    if (got != before + 1) {
        _ = c.fprintf(platform.stderr(), "smoke-e2e: palette tabs %zu -> %zu\n", before, got);
        if (app.screenshotPng(win_id, 1400, null, 0)) |shot| {
            defer allocator.free(shot.png);
            writePng("/tmp/sketerm-e2e-command-palette-fail.png", shot.png);
        } else |_| {}
        // Leave nothing armed if the WRONG row won: hints_open (the
        // decoy) puts the pane into hint mode.
        app.pressKey(null, "escape") catch {};
        return "the palette's top-ranked row for 'tab' did not open a new tab";
    }

    // Put the window back the way the later stages expect it. The
    // count is re-read BEFORE each close, never after one is assumed to
    // have landed, or a slow close closes a tab the next stage wanted.
    closeAddedPanes(allocator, sock_path, app, keep_ids[0..keep_n]);
    // ...and focused where they expect it. Closing a tab lands the
    // selection wherever libadwaita chooses, which is not necessarily
    // the tab holding pane 1 — and every later stage that types into
    // "the shell" then asserts on pane 1.
    if (roundtrip(allocator, sock_path, "{\"cmd\":\"focus\",\"pane\":1}\n")) |r| allocator.free(r);
    _ = app.waitIdle(300, 5_000);
    return null;
}

/// Tree-style tabs, browser scope: while the sidebar is open it is the
/// browser's OWN tab surface, so "new tab" inside a browser opens a
/// PAGE in that browser rather than another window tab; with the
/// sidebar closed the same action opens a window tab as it always did.
///
/// The browser helper is deliberately not needed: a web face exists (and
/// groups) whether or not CEF ever connects, so this rig — which links
/// no CEF — still covers the whole grouping and routing path.
fn treeSidebarStage(allocator: std.mem.Allocator, app: *appdrive.App, sock_path: [:0]const u8, rt: []const u8) ?[]const u8 {
    _ = app.drainLive(1_000);

    var keep_ids: [64]u32 = undefined;
    var keep_n: usize = 0;
    const tabs_before = blk: {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse
            return "list roundtrip failed before the tree-sidebar stage";
        defer allocator.free(r);
        keep_n = listPaneIds(r, &keep_ids);
        break :blk countTabs(r);
    };
    const had_config = blk: {
        var pbuf: [512:0]u8 = undefined;
        const p = std.fmt.bufPrintZ(&pbuf, "{s}/sketerm/config.conf", .{rt}) catch break :blk true;
        break :blk c.access(p.ptr, c.F_OK) == 0;
    };

    // Real seat events from every face that owns local key handling.
    // IPC only selects/setup states; the product behavior under test is
    // the physical chord flowing through GTK's focused widget.
    const seed_tab = roundtrip(allocator, sock_path, "{\"cmd\":\"new-tab\"}\n") orelse
        return "creating a second tab for real tree-key coverage failed";
    allocator.free(seed_tab);
    _ = app.waitIdle(300, 5_000);
    if (roundtrip(allocator, sock_path, "{\"cmd\":\"focus\",\"pane\":1}\n")) |r| allocator.free(r) else
        return "terminal focus failed before real tree-key coverage";
    _ = app.waitIdle(200, 4_000);
    if (expectRealTreeStep(allocator, app, sock_path, tree_prev_key, "terminal")) |err| return err;
    if (roundtrip(allocator, sock_path, "{\"cmd\":\"focus\",\"pane\":1}\n")) |r| allocator.free(r);

    var req_buf: [768]u8 = undefined;
    const browser_req = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"new-browser-tab\",\"pane\":1,\"data\":\"{s}\"}}\n", .{rt}) catch
        return "building the browser-face setup request failed";
    const browser_resp = roundtrip(allocator, sock_path, browser_req) orelse return "new-browser-tab setup failed";
    const browser_pane = parseNumAfter(browser_resp, "\"pane\":") orelse {
        allocator.free(browser_resp);
        return "new-browser-tab setup returned no pane";
    };
    allocator.free(browser_resp);
    var browser_focus_buf: [96]u8 = undefined;
    const browser_focus = std.fmt.bufPrint(&browser_focus_buf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{browser_pane}) catch
        return "building the file-browser focus request failed";
    if (roundtrip(allocator, sock_path, browser_focus)) |r| allocator.free(r) else
        return "file-browser focus failed before real tree-key coverage";
    _ = app.waitIdle(400, 8_000);
    if (app.windows.items.len == 0) return "the display session lost its window";
    const win_id = app.windows.items[0].id;
    if (expectRealTreeStep(allocator, app, sock_path, tree_prev_key, "file browser")) |err| return err;

    const editor_resp = roundtrip(allocator, sock_path, "{\"cmd\":\"new-editor-tab\",\"pane\":1}\n") orelse
        return "new-editor-tab setup failed";
    const editor_pane = parseNumAfter(editor_resp, "\"pane\":") orelse {
        allocator.free(editor_resp);
        return "new-editor-tab setup returned no pane";
    };
    allocator.free(editor_resp);
    var focus_buf: [96]u8 = undefined;
    const editor_focus = std.fmt.bufPrint(&focus_buf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{editor_pane}) catch
        return "building the editor focus request failed";
    if (roundtrip(allocator, sock_path, editor_focus)) |r| allocator.free(r) else
        return "editor focus failed before real tree-key coverage";
    _ = app.waitIdle(300, 5_000);
    if (expectRealTreeStep(allocator, app, sock_path, tree_prev_key, "editor")) |err| return err;

    closeAddedPanes(allocator, sock_path, app, keep_ids[0..keep_n]);
    if (roundtrip(allocator, sock_path, "{\"cmd\":\"focus\",\"pane\":1}\n")) |r| allocator.free(r);
    _ = app.waitIdle(300, 5_000);

    // The terminal shortcut toggles THIS window's sidebar and leaves
    // config.conf alone: visibility is per-window state, not a
    // preference a reload may push into every other window.
    app.pressKey(null, tree_toggle_key) catch return "injecting the sidebar toggle shortcut failed";
    _ = app.waitIdle(400, 5_000);
    if (!waitSidebarVisible(app, win_id, true, 6_000))
        return "the real sidebar toggle shortcut did not show the sidebar";
    if (configHasSidebarKey(allocator, rt))
        return "showing the sidebar at runtime wrote show_tab_sidebar into config.conf";
    if (roundtrip(allocator, sock_path, "{\"cmd\":\"focus\",\"pane\":1}\n")) |r| allocator.free(r) else
        return "terminal focus failed before the sidebar hide shortcut";
    _ = app.waitIdle(200, 4_000);
    app.pressKey(null, tree_toggle_key) catch return "injecting the sidebar hide shortcut failed";
    _ = app.waitIdle(400, 5_000);
    // A stale replica frame can still carry the old blue row, so the
    // chip has to go AWAY rather than merely be absent from one sample.
    if (!waitSidebarVisible(app, win_id, false, 6_000))
        return "the real sidebar hide shortcut did not hide the sidebar";
    if (configHasSidebarKey(allocator, rt))
        return "hiding the sidebar at runtime wrote show_tab_sidebar into config.conf";

    // A browser tab, then find the pane its web face landed on.
    const open = roundtrip(allocator, sock_path, "{\"cmd\":\"action\",\"data\":\"new_web_tab\"}\n") orelse
        return "new_web_tab action roundtrip failed";
    allocator.free(open);
    _ = app.waitIdle(300, 5_000);

    var web_pane: u32 = 0;
    var tries: u32 = 0;
    while (tries < 50) : (tries += 1) {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"web-list\"}\n") orelse continue;
        defer allocator.free(r);
        if (std.mem.indexOf(u8, r, "\"pane\":")) |at| {
            const rest = r[at + 7 ..];
            const end = std.mem.indexOfScalar(u8, rest, ',') orelse continue;
            web_pane = std.fmt.parseInt(u32, rest[0..end], 10) catch continue;
            break;
        }
        _ = app.pumpOnce(100);
    } else return "no web view appeared after new_web_tab";
    if (web_pane == 0) return "web-list reported no pane id for the new browser";
    var web_nav_buf: [192]u8 = undefined;
    const web_nav = std.fmt.bufPrint(&web_nav_buf, "{{\"cmd\":\"web-navigate\",\"pane\":{d},\"data\":\"data:text/html,tree-key-smoke\"}}\n", .{web_pane}) catch
        return "building the initial web navigation command failed";
    if (roundtrip(allocator, sock_path, web_nav)) |r| allocator.free(r) else
        return "initial web navigation roundtrip failed";
    var initial_web_focus_buf: [96]u8 = undefined;
    const initial_web_focus = std.fmt.bufPrint(&initial_web_focus_buf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{web_pane}) catch
        return "building the initial web focus command failed";
    if (roundtrip(allocator, sock_path, initial_web_focus)) |r| allocator.free(r) else
        return "initial web focus roundtrip failed";
    _ = app.waitIdle(200, 4_000);

    // ── sidebar CLOSED: new_tab is a WINDOW tab ────────────────
    // The tree actions follow the visible WINDOW tree too; a focused
    // browser's hidden page forest must not steal them.
    const closed_page = blk: {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"web-list\"}\n") orelse
            return "web-list roundtrip failed before the closed-sidebar tree check";
        defer allocator.free(r);
        break :blk activeWebView(r, web_pane);
    };
    const closed_tab = blk: {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse
            return "list roundtrip failed before the closed-sidebar tree check";
        defer allocator.free(r);
        break :blk selectedTabFirstPane(r);
    };
    if (roundtrip(allocator, sock_path, initial_web_focus)) |r| allocator.free(r) else
        return "web focus roundtrip failed before the closed-sidebar tree check";
    _ = app.waitIdle(200, 4_000);
    app.pressKey(null, tree_prev_key) catch return "injecting tab_tree_prev failed with the sidebar closed";
    _ = app.waitIdle(300, 5_000);
    {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse
            return "list roundtrip failed after the closed-sidebar tree step";
        defer allocator.free(r);
        if (selectedTabFirstPane(r) == closed_tab)
            return "with the sidebar closed, tab_tree_prev did not step through WINDOW tabs";
    }
    {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"web-list\"}\n") orelse
            return "web-list roundtrip failed after the closed-sidebar tree step";
        defer allocator.free(r);
        if (activeWebView(r, web_pane) != closed_page)
            return "with the sidebar closed, tab_tree_prev stepped through hidden browser pages";
    }
    var closed_focus_buf: [96]u8 = undefined;
    const closed_focus = std.fmt.bufPrint(&closed_focus_buf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{web_pane}) catch
        return "building the closed-sidebar focus command failed";
    if (roundtrip(allocator, sock_path, closed_focus)) |r| allocator.free(r) else return "closed-sidebar focus roundtrip failed";
    _ = app.waitIdle(300, 5_000);

    const before_closed = blk: {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse
            return "list roundtrip failed";
        defer allocator.free(r);
        break :blk countTabs(r);
    };
    const nt1 = roundtrip(allocator, sock_path, "{\"cmd\":\"action\",\"data\":\"new_tab\"}\n") orelse
        return "new_tab action roundtrip failed";
    allocator.free(nt1);
    _ = app.waitIdle(300, 5_000);
    {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse
            return "list roundtrip failed after new_tab";
        defer allocator.free(r);
        if (countTabs(r) != before_closed + 1)
            return "with the tree sidebar closed, new_tab did not open a window tab";
    }
    {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"web-list\"}\n") orelse
            return "web-list roundtrip failed";
        defer allocator.free(r);
        if (webViewsOnPane(r, web_pane) != 1)
            return "with the tree sidebar closed, new_tab added a page to the browser";
    }

    // ── sidebar OPEN: new_tab is a PAGE of the browser ─────────
    // Focus has to be back on the browser pane: the sidebar lists the
    // FOCUSED pane's browser, and the window tab opened above stole it.
    var fbuf: [96]u8 = undefined;
    const focus_cmd = std.fmt.bufPrint(&fbuf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{web_pane}) catch
        return "building the focus command failed";
    if (roundtrip(allocator, sock_path, focus_cmd)) |r| allocator.free(r) else return "focus roundtrip failed";
    _ = app.waitIdle(300, 5_000);
    app.pressKey(null, tree_toggle_key) catch return "injecting toggle_tab_sidebar failed";
    _ = app.waitIdle(400, 5_000);
    if (sidebarChipRight(app, win_id) == 0)
        return "the real web-face sidebar toggle did not show the sidebar";

    const tabs_with_sidebar = blk: {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse
            return "list roundtrip failed with the sidebar open";
        defer allocator.free(r);
        break :blk countTabs(r);
    };

    const nt2 = roundtrip(allocator, sock_path, "{\"cmd\":\"action\",\"data\":\"new_tab\"}\n") orelse
        return "new_tab action roundtrip failed with the sidebar open";
    allocator.free(nt2);
    _ = app.waitIdle(400, 8_000);

    {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"web-list\"}\n") orelse
            return "web-list roundtrip failed with the sidebar open";
        defer allocator.free(r);
        const n = webViewsOnPane(r, web_pane);
        if (n != 2) {
            _ = c.fprintf(platform.stderr(), "smoke-e2e: web-list was: %.*s\n", @as(c_int, @intCast(@min(r.len, 1500))), r.ptr);
            return "with the tree sidebar open, new_tab did not open a second PAGE in the browser";
        }
    }
    {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse
            return "list roundtrip failed after the in-browser new tab";
        defer allocator.free(r);
        if (countTabs(r) != tabs_with_sidebar)
            return "with the tree sidebar open, new_tab ALSO opened a window tab";
    }
    if (roundtrip(allocator, sock_path, web_nav)) |r| allocator.free(r) else
        return "child web navigation roundtrip failed";
    if (roundtrip(allocator, sock_path, focus_cmd)) |r| allocator.free(r) else
        return "child web focus roundtrip failed";
    _ = app.waitIdle(300, 5_000);

    // ── the tree ACTIONS follow the sidebar, not the window ────
    // tab_tree_next/tab_collapse used to walk the window's tab forest
    // unconditionally, so in a browser they moved something invisible.
    var ids: [8]u32 = undefined;
    var parent_view: u32 = 0;
    var child_view: u32 = 0;
    {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"web-list\"}\n") orelse
            return "web-list roundtrip failed before the tree-action checks";
        defer allocator.free(r);
        if (webViewIds(r, web_pane, &ids) < 2) return "the browser did not report two pages";
        parent_view = ids[0];
        child_view = ids[1];
        if (activeWebView(r, web_pane) != child_view)
            return "the newly opened page did not become the visible one";
    }
    const tab_before = blk: {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse
            return "list roundtrip failed";
        defer allocator.free(r);
        break :blk selectedTabFirstPane(r);
    };

    // Stepping the tree must move the PAGE...
    app.pressKey(null, tree_prev_key) catch return "injecting tab_tree_prev failed";
    _ = app.waitIdle(300, 5_000);
    {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"web-list\"}\n") orelse
            return "web-list roundtrip failed after tab_tree_prev";
        defer allocator.free(r);
        if (activeWebView(r, web_pane) != parent_view)
            return "tab_tree_prev did not step to the other PAGE of the browser";
    }
    // ...and must NOT have moved the window's tab selection.
    {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse
            return "list roundtrip failed after tab_tree_prev";
        defer allocator.free(r);
        if (selectedTabFirstPane(r) != tab_before)
            return "tab_tree_prev moved the WINDOW tab selection instead of the browser's pages";
    }

    // Collapsing the parent hides its child, so a step can no longer
    // reach it and the active page stays put.
    app.pressKey(null, tree_collapse_key) catch return "injecting tab_collapse failed";
    _ = app.waitIdle(300, 5_000);
    app.pressKey(null, tree_next_key) catch return "injecting tab_tree_next failed";
    _ = app.waitIdle(300, 5_000);
    {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"web-list\"}\n") orelse
            return "web-list roundtrip failed after collapse";
        defer allocator.free(r);
        if (activeWebView(r, web_pane) != parent_view)
            return "a collapsed page subtree was still reachable by tab_tree_next";
    }
    app.pressKey(null, tree_expand_key) catch return "injecting tab_expand failed";
    _ = app.waitIdle(300, 5_000);
    {
        const chip = sidebarChipPoint(app, win_id) orelse return "no selected sidebar row was visible to focus";
        app.click(win_id, chip.x, chip.y, 1) catch return "clicking the selected sidebar row failed";
        _ = app.waitIdle(200, 4_000);
        app.pressKey(null, tree_next_key) catch return "injecting tab_tree_next from a focused sidebar row failed";
        _ = app.waitIdle(300, 5_000);
        const r2 = roundtrip(allocator, sock_path, "{\"cmd\":\"web-list\"}\n") orelse
            return "web-list roundtrip failed after expand";
        defer allocator.free(r2);
        if (activeWebView(r2, web_pane) != child_view)
            return "expanding did not make the child page reachable again";
    }

    // A PNG of the window with the sidebar showing its rows — the
    // artefact a human reviews for the styling and the indent.
    if (app.windows.items.len == 0) return "the display session lost its window";
    _ = app.waitVisualSettle(win_id, 300, 5_000, 0.002, null);
    if (app.screenshotPng(win_id, 1400, null, 0)) |shot| {
        defer allocator.free(shot.png);
        writePng("/tmp/sketerm-e2e-tab-sidebar.png", shot.png);
    } else |_| {}

    // ── the divider resizes, and the width is remembered ───────
    // The sidebar is measured from its selected row's chip rather than
    // guessed at, so the drag starts on the divider by construction.
    const width_before = sidebarChipRight(app, win_id);
    if (width_before == 0) return "no selected sidebar row was visible to measure";
    const grab_x = @as(f64, @floatFromInt(width_before + 8));
    const mid_y = @as(f64, @floatFromInt(app.windows.items[0].h)) * 0.6;
    app.drag(win_id, grab_x, mid_y, grab_x + 90, mid_y, 1) catch
        return "dragging the sidebar divider failed";
    _ = app.waitIdle(300, 5_000);

    var width_after: usize = 0;
    var wtries: u32 = 0;
    while (wtries < 40) : (wtries += 1) {
        width_after = sidebarChipRight(app, win_id);
        if (width_after >= width_before + 60) break;
        _ = app.pumpOnce(100);
    }
    if (width_after < width_before + 60) {
        _ = c.fprintf(platform.stderr(), "smoke-e2e: sidebar chip right %zu -> %zu\n", width_before, width_after);
        return "dragging the divider did not widen the tree sidebar";
    }

    // The drag is debounced into ONE config write; the key must land.
    var saw_width = false;
    var ctries: u32 = 0;
    while (ctries < 60) : (ctries += 1) {
        _ = app.pumpOnce(100);
        var pbuf: [512:0]u8 = undefined;
        const p = std.fmt.bufPrintZ(&pbuf, "{s}/sketerm/config.conf", .{rt}) catch break;
        if (readFileAlloc(allocator, p)) |body| {
            defer allocator.free(body);
            if (std.mem.indexOf(u8, body, "tab_sidebar_width = ") != null) {
                saw_width = true;
                break;
            }
        }
    }
    if (!saw_width) return "the dragged sidebar width was never written to config.conf";
    // Put the window back the way the later stages expect it.
    if (roundtrip(allocator, sock_path, "{\"cmd\":\"focus\",\"pane\":1}\n")) |r| allocator.free(r) else
        return "terminal focus failed before the final sidebar hide";
    _ = app.waitIdle(200, 4_000);
    app.pressKey(null, tree_toggle_key) catch return "injecting toggle_tab_sidebar (off) failed";
    if (!waitSidebarVisible(app, win_id, false, 6_000))
        return "the final toggle_tab_sidebar did not hide the sidebar";
    // The hide itself writes nothing now, but the WIDTH drag above went
    // through a 400ms debounce: let any last scheduled save land before
    // the unlink, or it recreates config.conf behind the next stage.
    // (`onSidebarPosition` ignores a hidden sidebar, so the hide cannot
    // schedule a fresh one.)
    _ = app.waitIdle(700, 6_000);
    // Put the config directory back the way the later config stages
    // expect it (step 1 of configReloadStage is the CREATE path).
    if (!had_config) {
        var pbuf: [512:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&pbuf, "{s}/sketerm/config.conf", .{rt}) catch null) |p|
            _ = c.unlink(p.ptr);
    }
    _ = tabs_before;
    closeAddedPanes(allocator, sock_path, app, keep_ids[0..keep_n]);
    // Same contract as the palette stage: hand the window back focused
    // on pane 1, which is what the stages after this one assume.
    if (roundtrip(allocator, sock_path, "{\"cmd\":\"focus\",\"pane\":1}\n")) |r| allocator.free(r);
    _ = app.waitIdle(200, 4_000);
    return null;
}

/// Sidebar rows drag like real tabs: onto a row to NEST under it,
/// between rows to REORDER, and out onto the empty list to unnest.
///
/// Everything is read off the one pixel probe the rig already has —
/// the active row's chip. Its left edge IS the row's indent (a nested
/// row starts one INDENT_PX in) and its top edge IS the row's slot, and
/// a dropped tab becomes the active one, so the chip lands on exactly
/// the row whose new place is under test.
fn sidebarDragStage(allocator: std.mem.Allocator, app: *appdrive.App, sock_path: [:0]const u8) ?[]const u8 {
    var keep_ids: [64]u32 = undefined;
    var keep_n: usize = 0;
    {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse
            return "list roundtrip failed before the sidebar drag stage";
        defer allocator.free(r);
        keep_n = listPaneIds(r, &keep_ids);
    }
    if (app.windows.items.len == 0) return "the display session lost its window";
    const win_id = app.windows.items[0].id;

    // Two more tabs: enough for a three-row tree with a stable first row.
    var extra: [2]u32 = .{ 0, 0 };
    for (&extra) |*slot| {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"new-tab\"}\n") orelse
            return "creating a tab for the sidebar drag stage failed";
        defer allocator.free(r);
        slot.* = parseNumAfter(r, "\"pane\":") orelse return "a new tab for the drag stage reported no pane";
    }
    _ = app.waitIdle(300, 5_000);
    if (roundtrip(allocator, sock_path, "{\"cmd\":\"focus\",\"pane\":1}\n")) |r| allocator.free(r) else
        return "terminal focus failed before opening the sidebar for the drag stage";
    _ = app.waitIdle(200, 4_000);
    app.pressKey(null, tree_toggle_key) catch return "injecting toggle_tab_sidebar for the drag stage failed";
    if (!waitSidebarVisible(app, win_id, true, 6_000))
        return "the sidebar never opened for the drag stage";

    // Learn both rows' rectangles by making each tab current in turn.
    const first_row = sidebarChipBounds(app, win_id) orelse return "the first tab's sidebar row was not visible";
    var focus_buf: [96]u8 = undefined;
    const focus_last = std.fmt.bufPrint(&focus_buf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{extra[1]}) catch
        return "building the drag-stage focus command failed";
    if (roundtrip(allocator, sock_path, focus_last)) |r| allocator.free(r) else
        return "focusing the last tab for the drag stage failed";
    _ = app.waitIdle(300, 5_000);
    const last_row = sidebarChipBounds(app, win_id) orelse return "the last tab's sidebar row was not visible";
    if (last_row.min_x != first_row.min_x) return "two root sidebar rows started at different indents";
    if (last_row.min_y <= first_row.min_y) return "the last tab's row is not below the first tab's";
    const mid = struct {
        fn of(b: anytype) struct { x: f64, y: f64 } {
            return .{
                .x = @floatFromInt((b.min_x + b.max_x) / 2),
                .y = @floatFromInt((b.min_y + b.max_y) / 2),
            };
        }
    };
    const from = mid.of(last_row);
    const onto = mid.of(first_row);

    // 1. Drop ON the first row -> the dragged tab becomes its child.
    app.drag(win_id, from.x, from.y, onto.x, onto.y, 1) catch return "dragging a sidebar row onto another failed";
    _ = app.waitIdle(300, 6_000);
    const nested = blk: {
        var waited: u32 = 0;
        while (waited < 6_000) : (waited += 100) {
            if (sidebarChipBounds(app, win_id)) |b| {
                if (b.min_x > first_row.min_x) break :blk b;
            }
            _ = app.pumpOnce(100);
        }
        break :blk sidebarChipBounds(app, win_id) orelse
            return "the dragged sidebar row disappeared";
    };
    if (nested.min_x <= first_row.min_x)
        return "dropping a sidebar row onto another did not nest it under that row";
    if (nested.min_y <= first_row.min_y)
        return "a nested sidebar row did not follow its new parent";

    // 2. Drop on the empty list below the rows -> back to the root level.
    const empty_y = @as(f64, @floatFromInt(app.windows.items[0].h)) * 0.75;
    app.drag(win_id, mid.of(nested).x, mid.of(nested).y, onto.x, empty_y, 1) catch
        return "dragging a sidebar row onto the empty list failed";
    _ = app.waitIdle(300, 6_000);
    const unnested = blk: {
        var waited: u32 = 0;
        while (waited < 6_000) : (waited += 100) {
            if (sidebarChipBounds(app, win_id)) |b| {
                if (b.min_x == first_row.min_x) break :blk b;
            }
            _ = app.pumpOnce(100);
        }
        break :blk sidebarChipBounds(app, win_id) orelse
            return "the unnested sidebar row disappeared";
    };
    if (unnested.min_x != first_row.min_x)
        return "dropping a sidebar row on the empty list did not return it to the root level";

    // 3. Drop on the TOP of the first row -> reorder above it, still a
    //    root. This is the gesture the old drag had no notion of: it
    //    could only ever make the dropped-on row a parent.
    const above_y = @as(f64, @floatFromInt(first_row.min_y)) + 2.0;
    app.drag(win_id, mid.of(unnested).x, mid.of(unnested).y, onto.x, above_y, 1) catch
        return "dragging a sidebar row above another failed";
    _ = app.waitIdle(300, 6_000);
    const reordered = blk: {
        var waited: u32 = 0;
        while (waited < 6_000) : (waited += 100) {
            if (sidebarChipBounds(app, win_id)) |b| {
                if (b.min_y <= first_row.min_y) break :blk b;
            }
            _ = app.pumpOnce(100);
        }
        break :blk sidebarChipBounds(app, win_id) orelse
            return "the reordered sidebar row disappeared";
    };
    if (reordered.min_y > first_row.min_y) {
        _ = c.fprintf(platform.stderr(), "smoke-e2e: reorder target y %zu, landed at %zu\n", first_row.min_y, reordered.min_y);
        return "dropping a sidebar row above another did not move it to the top";
    }
    if (reordered.min_x != first_row.min_x)
        return "a row dropped BETWEEN rows was nested instead of reordered";

    if (app.screenshotPng(win_id, 1400, null, 0)) |shot| {
        defer allocator.free(shot.png);
        writePng("/tmp/sketerm-e2e-tab-sidebar-drag.png", shot.png);
    } else |_| {}

    app.pressKey(null, tree_toggle_key) catch return "hiding the sidebar after the drag stage failed";
    if (!waitSidebarVisible(app, win_id, false, 6_000))
        return "the sidebar never closed after the drag stage";
    closeAddedPanes(allocator, sock_path, app, keep_ids[0..keep_n]);
    if (roundtrip(allocator, sock_path, "{\"cmd\":\"focus\",\"pane\":1}\n")) |r| allocator.free(r);
    _ = app.waitIdle(200, 4_000);
    return null;
}

const web_action_id = "gui-action@sketerm.test";

const web_action_manifest =
    \\{"manifest_version":2,"name":"GUI action fixture","version":"1",
    \\ "browser_specific_settings":{"gecko":{"id":"gui-action@sketerm.test"}},
    \\ "permissions":["tabs"],"background":{"scripts":["bg.js"],"persistent":true},
    \\ "browser_action":{"default_title":"GUI Action","default_icon":"blue.png","default_popup":"popup.html"}}
;

const web_action_bg =
    \\browser.tabs.onCreated.addListener(function(tab){
    \\  browser.browserAction.setIcon({tabId:tab.id,path:tab.url.includes("action-two")?"orange.png":"blue.png"});
    \\});
    \\browser.tabs.onUpdated.addListener(function(id,change,tab){
    \\  browser.browserAction.setIcon({tabId:id,path:tab.url.includes("action-two")?"orange.png":"blue.png"});
    \\});
    \\browser.browserAction.onClicked.addListener(function(tab){
    \\  browser.browserAction.setBadgeText({tabId:tab.id,text:String(tab.id)});
    \\});
;

const web_action_popup =
    \\<!doctype html><style>html,body{margin:0;width:100%;height:100%;background:#004400;color:white}button{margin:80px;width:220px;height:100px}</style>
    \\<button id=b>popup:loading</button><script>
    \\b.textContent="popup:"+browser.runtime.getManifest().name;
    \\if(b.textContent==="popup:GUI action fixture")document.body.style.background="#00aa00";
    \\b.onclick=()=>{document.body.style.background="#ff8800";b.textContent="clicked"};
    \\</script>
;

fn prepareWebActionFixture(allocator: std.mem.Allocator, rt: [:0]const u8) bool {
    var base_buf: [512:0]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "{s}/sketerm/webext", .{rt}) catch return false;
    mkdirAllPath(base);
    var ext_buf: [640:0]u8 = undefined;
    const ext = std.fmt.bufPrintZ(&ext_buf, "{s}/fixture", .{base}) catch return false;
    mkdirAllPath(ext);
    var path_buf: [768:0]u8 = undefined;
    const manifest_path = std.fmt.bufPrintZ(&path_buf, "{s}/manifest.json", .{ext}) catch return false;
    if (!writeFile(manifest_path, web_action_manifest)) return false;
    const bg_path = std.fmt.bufPrintZ(&path_buf, "{s}/bg.js", .{ext}) catch return false;
    if (!writeFile(bg_path, web_action_bg)) return false;
    const popup_path = std.fmt.bufPrintZ(&path_buf, "{s}/popup.html", .{ext}) catch return false;
    if (!writeFile(popup_path, web_action_popup)) return false;
    const blue_path = std.fmt.bufPrintZ(&path_buf, "{s}/blue.png", .{ext}) catch return false;
    if (!writeSolidPng(allocator, blue_path.ptr, 0x20, 0x60, 0xff)) return false;
    const orange_path = std.fmt.bufPrintZ(&path_buf, "{s}/orange.png", .{ext}) catch return false;
    if (!writeSolidPng(allocator, orange_path.ptr, 0xff, 0x70, 0x10)) return false;
    const registry_path = std.fmt.bufPrintZ(&path_buf, "{s}/registry.json", .{base}) catch return false;
    var registry_buf: [1024]u8 = undefined;
    const registry = std.fmt.bufPrint(&registry_buf,
        "[{{\"id\":\"{s}\",\"dir\":\"{s}\",\"enabled\":true,\"owned\":false}}]",
        .{ web_action_id, ext }) catch return false;
    return writeFile(registry_path, registry);
}

fn mkdirAllPath(path: [:0]const u8) void {
    var copy: [768:0]u8 = @splat(0);
    if (path.len >= copy.len) return;
    @memcpy(copy[0..path.len], path);
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and copy[i] != '/') continue;
        const saved = copy[i];
        copy[i] = 0;
        _ = c.mkdir(&copy, 0o700);
        copy[i] = saved;
    }
}

fn webActionGuiStage(allocator: std.mem.Allocator, app: *appdrive.App, sock: [:0]const u8) ?[]const u8 {
    _ = app.drainLive(1_000);
    if (app.windows.items.len == 0) return "the display session lost its window before the browser-action stage";
    const win_id = app.windows.items[0].id;
    if (openPopup(app) != null) return "a popup was already open before the browser-action stage";
    var keep_ids: [64]u32 = undefined;
    const keep_n = blk: {
        const before = roundtrip(allocator, sock, "{\"cmd\":\"list\"}\n") orelse return "listing panes before the browser-action stage failed";
        defer allocator.free(before);
        break :blk listPaneIds(before, &keep_ids);
    };

    const open = roundtrip(allocator, sock,
        "{\"cmd\":\"web-open\",\"target\":\"tab\",\"data\":\"data:text/html,<title>action-one</title><body style='margin:0;background:%23eee'>one</body>\"}\n") orelse
        return "opening the browser-action page failed";
    defer allocator.free(open);
    if (std.mem.indexOf(u8, open, "\"ok\":true") == null) return "the browser-action page was rejected";
    const pane = parseNumAfter(open, "\"pane\":") orelse return "the browser-action page reply had no pane";

    var views: [4]u32 = undefined;
    var first_view: u32 = 0;
    var tries: u32 = 0;
    while (tries < 150) : (tries += 1) {
        const list = roundtrip(allocator, sock, "{\"cmd\":\"web-list\"}\n") orelse continue;
        defer allocator.free(list);
        if (std.mem.indexOf(u8, list, "\"helper\":\"ready\"") != null and webViewIds(list, pane, &views) >= 1) {
            first_view = views[0];
            if (findToolbarColor(app, win_id, .blue) != null) break;
        }
        _ = app.pumpOnce(100);
    } else return "the browser action never appeared in the real GTK toolbar";

    web_helper_pid = helperPidOf(child_pid) orelse return "the browser helper pid could not be identified exactly";
    const blue = findToolbarColor(app, win_id, .blue) orelse return "the first page did not show its blue per-tab action icon";

    // Open another PAGE in the same WebGroup, then navigate it to the
    // URL that gives it the orange per-tab override.
    if (roundtrip(allocator, sock, "{\"cmd\":\"action\",\"data\":\"toggle_tab_sidebar\"}\n")) |r| allocator.free(r) else
        return "opening the tree sidebar for the browser-action stage failed";
    if (roundtrip(allocator, sock, "{\"cmd\":\"action\",\"data\":\"new_tab\"}\n")) |r| allocator.free(r) else
        return "opening the second WebGroup page failed";
    var nav_buf: [512]u8 = undefined;
    const nav = std.fmt.bufPrint(&nav_buf,
        "{{\"cmd\":\"web-navigate\",\"pane\":{d},\"data\":\"data:text/html,<title>action-two</title><body style='margin:0;background:%23ddd'>two</body>\"}}\n",
        .{pane}) catch return "building the second-page navigation failed";
    if (roundtrip(allocator, sock, nav)) |r| allocator.free(r) else return "navigating the second WebGroup page failed";
    _ = app.waitIdle(300, 8_000);
    var second_view: u32 = 0;
    tries = 0;
    while (tries < 100) : (tries += 1) {
        const list = roundtrip(allocator, sock, "{\"cmd\":\"web-list\"}\n") orelse continue;
        defer allocator.free(list);
        if (webViewIds(list, pane, &views) >= 2) {
            second_view = activeWebView(list, pane);
            if (second_view != 0 and second_view != first_view and findToolbarColor(app, win_id, .orange) != null) break;
        }
        _ = app.pumpOnce(100);
    } else return "switching the WebGroup to its second page did not refresh the orange per-tab action icon";

    // Switch back and require the blue icon to return before clicking it.
    if (roundtrip(allocator, sock, "{\"cmd\":\"action\",\"data\":\"tab_tree_prev\"}\n")) |r| allocator.free(r) else
        return "switching back to the first WebGroup page failed";
    tries = 0;
    var action = blue;
    while (tries < 100) : (tries += 1) {
        const list = roundtrip(allocator, sock, "{\"cmd\":\"web-list\"}\n") orelse continue;
        defer allocator.free(list);
        if (activeWebView(list, pane) == first_view) {
            if (findToolbarColor(app, win_id, .blue)) |p| {
                action = p;
                break;
            }
        }
        _ = app.pumpOnce(100);
    } else return "switching back did not restore the first page's blue action icon";

    app.clickEx(win_id, action.x, action.y, 1, 100, 1) catch return "the trusted action-button click could not be injected";
    const popup = waitPopup(app, true, 20_000) orelse return "the trusted GTK action click opened no native popup surface";
    if (waitPopupColor(app, popup, .green, 20_000) == null)
        return "the extension popup never painted the runtime.getManifest success state";
    app.clickEx(popup, 190, 130, 1, 100, 1) catch
        return "clicking inside the extension popup failed";
    if (waitPopupColor(app, popup, .orange, 10_000) == null)
        return "trusted popup input did not repaint the extension document";
    if (app.screenshotPng(popup, 1024, null, 0)) |shot| {
        defer allocator.free(shot.png);
        writePng("/tmp/sketerm-e2e-webaction-popup.png", shot.png);
    } else |_| return "screenshotting the extension popup failed";
    app.pressKey(popup, "Escape") catch return "injecting Escape into the extension popup failed";
    if (waitPopup(app, false, 10_000) == null) return "the extension popup did not close on Escape";

    // A split has two visible browser toolbars, but only its focused pane
    // is the active MV2 tab. The inactive face must receive the empty
    // replace-all snapshot rather than keeping its old clickable action.
    const split_open = roundtrip(allocator, sock,
        "{\"cmd\":\"web-open\",\"target\":\"split\",\"data\":\"data:text/html,<title>action-two</title><body style='margin:0;background:%23ddd'>split</body>\"}\n") orelse
        return "opening the browser-action split failed";
    defer allocator.free(split_open);
    const split_pane = parseNumAfter(split_open, "\"pane\":") orelse {
        _ = c.fprintf(platform.stderr(), "smoke-e2e: web-open split reply: %.*s\n", @as(c_int, @intCast(@min(split_open.len, 800))), split_open.ptr);
        return "the browser-action split returned no pane";
    };
    if (waitSplitToolbarExclusive(app, win_id, .orange, false, .blue, 15_000) == null)
        return "split focus did not move the only live action to the orange pane";
    var focus_buf: [96]u8 = undefined;
    const focus_first = std.fmt.bufPrint(&focus_buf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{pane}) catch
        return "building the first browser-pane focus request failed";
    if (roundtrip(allocator, sock, focus_first)) |r| allocator.free(r) else return "focusing the first browser pane failed";
    if (waitSplitToolbarExclusive(app, win_id, .blue, true, .orange, 15_000) == null)
        return "split focus did not clear the old orange action and restore the blue one";

    // Repeat across real GTK toplevels. The new focused window gets the
    // action and its trusted click must open a real popup there; returning
    // focus to the primary clears the secondary's stale action.
    const window_open = roundtrip(allocator, sock,
        "{\"cmd\":\"web-open\",\"target\":\"window\",\"data\":\"data:text/html,<title>action-two</title><body style='margin:0;background:%23ddd'>window</body>\"}\n") orelse
        return "opening the browser-action window failed";
    defer allocator.free(window_open);
    const window_pane = parseNumAfter(window_open, "\"pane\":") orelse return "the browser-action window returned no pane";
    const second_win = blk: {
        var waited: u32 = 0;
        while (waited < 20_000) : (waited += 100) {
            if (hasToplevelOtherThan(app, &.{win_id})) |id| break :blk id;
            _ = app.pumpOnce(100);
        }
        return "the browser-action second window never mapped";
    };
    const second_action = waitToolbarExclusive(app, second_win, .orange, .blue, 15_000) orelse
        return "the focused second window did not own the orange action";
    if (waitSplitToolbarAbsent(app, win_id, .blue, 15_000) == null)
        return "the unfocused primary window kept a stale blue action";
    app.clickEx(second_win, second_action.x, second_action.y, 1, 100, 1) catch
        return "clicking the second window's action failed";
    const second_popup = waitPopup(app, true, 20_000) orelse return "the second window action opened no popup";
    if (waitPopupColor(app, second_popup, .green, 20_000) == null)
        return "the second window popup never painted its extension state";
    app.pressKey(second_popup, "Escape") catch return "closing the second window popup failed";
    if (waitPopup(app, false, 10_000) == null) return "the second window popup did not close";
    app.closeWindow(second_win) catch return "closing the browser-action second window failed";

    const focus_primary = std.fmt.bufPrint(&focus_buf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{pane}) catch
        return "building the primary-window focus request failed";
    if (roundtrip(allocator, sock, focus_primary)) |r| allocator.free(r) else return "returning focus to the primary window failed";
    const primary_win = app.winById(win_id) orelse return "the primary browser-action window disappeared";
    app.clickEx(win_id, @floatFromInt(@divTrunc(primary_win.w * 3, 8)), @floatFromInt(@divTrunc(primary_win.h, 2)), 1, 100, 1) catch
        return "injecting a real focus click into the primary window failed";
    if (waitSplitToolbarExclusive(app, win_id, .blue, true, .orange, 15_000) == null)
        return "returning window focus did not restore the primary action";
    _ = window_pane;

    // Reopen, then close the OWNER page. The popup must disappear and
    // the surviving second page must remain driveable.
    const restored_action = findToolbarColorRange(app, win_id, .blue, true) orelse
        return "the restored primary action could not be located";
    app.clickEx(win_id, restored_action.x, restored_action.y, 1, 100, 1) catch return "reopening the extension popup failed";
    _ = waitPopup(app, true, 20_000) orelse return "the extension popup did not reopen";
    // The popup owns the Wayland keyboard grab, so a seat chord would
    // correctly reach its document rather than the toplevel shortcut.
    // Close the known owner pane directly: with another split alive,
    // global close_tab focus routing is not the behavior under test.
    var owner_close_buf: [96]u8 = undefined;
    const owner_close = std.fmt.bufPrint(&owner_close_buf, "{{\"cmd\":\"close-pane\",\"pane\":{d}}}\n", .{pane}) catch
        return "building the popup owner close request failed";
    if (roundtrip(allocator, sock, owner_close)) |r| {
        defer allocator.free(r);
        if (std.mem.indexOf(u8, r, "\"ok\":true") == null)
            return "closing the popup owner pane was rejected";
    } else return "closing the popup owner pane failed";
    if (waitPopup(app, false, 15_000) == null) return "closing the owner pane did not close its extension popup";
    const alive = roundtrip(allocator, sock, "{\"cmd\":\"web-list\"}\n") orelse return "the GUI stopped serving after popup-owner teardown";
    defer allocator.free(alive);
    if (std.mem.indexOf(u8, alive, "\"ok\":true") == null or std.mem.indexOf(u8, alive, "\"helper\":\"ready\"") == null)
        return "the GUI/helper was unhealthy after popup-owner teardown";

    var close_split_buf: [96]u8 = undefined;
    const close_split = std.fmt.bufPrint(&close_split_buf, "{{\"cmd\":\"close-pane\",\"pane\":{d}}}\n", .{split_pane}) catch
        return "building the browser-action split close failed";
    if (roundtrip(allocator, sock, close_split)) |r| allocator.free(r) else return "closing the browser-action split failed";

    if (roundtrip(allocator, sock, "{\"cmd\":\"action\",\"data\":\"toggle_tab_sidebar\"}\n")) |r| allocator.free(r);
    closeAddedPanes(allocator, sock, app, keep_ids[0..keep_n]);
    if (roundtrip(allocator, sock, "{\"cmd\":\"focus\",\"pane\":1}\n")) |r| allocator.free(r) else
        return "restoring terminal focus after the browser-action stage failed";
    _ = app.waitIdle(200, 4_000);
    return null;
}

const ToolbarColor = enum { blue, orange, green };
const Point = struct { x: f64, y: f64 };

fn findToolbarColor(app: *appdrive.App, win_id: u32, color: ToolbarColor) ?Point {
    return findToolbarColorRange(app, win_id, color, false);
}

fn findToolbarColorRange(app: *appdrive.App, win_id: u32, color: ToolbarColor, left_half: bool) ?Point {
    const win = app.winById(win_id) orelse return null;
    if (win.w <= 0 or win.h <= 0) return null;
    const w: usize = @intCast(win.w);
    const h: usize = @intCast(win.h);
    const limit_y = @min(h, 180);
    var y: usize = 0;
    while (y < limit_y) : (y += 1) {
        var x: usize = if (left_half) 0 else w / 2;
        const limit_x = if (left_half) w / 2 else w;
        while (x < limit_x) : (x += 1) {
            if (x + 3 >= limit_x or y + 3 >= limit_y) continue;
            var solid = true;
            var by: usize = 0;
            while (by < 4 and solid) : (by += 1) {
                var bx: usize = 0;
                while (bx < 4) : (bx += 1) {
                    const i = ((y + by) * w + x + bx) * 4;
                    if (i + 3 >= win.pixels.items.len or !toolbarColorMatches(win.pixels.items[i..][0..4], color)) {
                        solid = false;
                        break;
                    }
                }
            }
            if (solid) return .{ .x = @floatFromInt(x + 2), .y = @floatFromInt(y + 2) };
        }
    }
    return null;
}

fn toolbarColorMatches(pixel: []const u8, color: ToolbarColor) bool {
    const b = pixel[0];
    const g = pixel[1];
    const r = pixel[2];
    return switch (color) {
        .blue => b > 180 and b > r +| 80 and b > g +| 40,
        .orange => r > 180 and g > 50 and g < 170 and b < 80,
        .green => g > 120 and g > r +| 70 and g > b +| 70,
    };
}

fn waitPopupColor(app: *appdrive.App, popup: u32, color: ToolbarColor, timeout_ms: u32) ?Point {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 100) {
        if (findToolbarColor(app, popup, color)) |p| return p;
        _ = app.pumpOnce(100);
    }
    return null;
}

fn waitToolbarExclusive(app: *appdrive.App, win: u32, wanted: ToolbarColor, absent: ToolbarColor, timeout_ms: u32) ?Point {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 100) {
        if (findToolbarColor(app, win, wanted)) |point| {
            if (findToolbarColor(app, win, absent) == null) return point;
        }
        _ = app.pumpOnce(100);
    }
    return null;
}

fn waitSplitToolbarExclusive(app: *appdrive.App, win: u32, wanted: ToolbarColor, wanted_left: bool, absent: ToolbarColor, timeout_ms: u32) ?Point {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 100) {
        if (findToolbarColorRange(app, win, wanted, wanted_left)) |point| {
            if (findToolbarColorRange(app, win, absent, true) == null and
                findToolbarColorRange(app, win, absent, false) == null) return point;
        }
        _ = app.pumpOnce(100);
    }
    return null;
}

fn waitSplitToolbarAbsent(app: *appdrive.App, win: u32, color: ToolbarColor, timeout_ms: u32) ?void {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 100) {
        if (findToolbarColorRange(app, win, color, true) == null and
            findToolbarColorRange(app, win, color, false) == null) return {};
        _ = app.pumpOnce(100);
    }
    return null;
}

fn helperPidOf(gui_pid: c.pid_t) ?c.pid_t {
    if (builtin.os.tag != .linux) return null;
    const d = c.opendir("/proc") orelse return null;
    defer _ = c.closedir(d);
    while (c.readdir(d)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        const pid = std.fmt.parseInt(c.pid_t, name, 10) catch continue;
        var path_buf: [96:0]u8 = undefined;
        const status_path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/status", .{pid}) catch continue;
        const status = readFileAlloc(g_alloc, status_path) orelse continue;
        defer g_alloc.free(status);
        var needle_buf: [32]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "PPid:\t{d}\n", .{gui_pid}) catch continue;
        if (std.mem.indexOf(u8, status, needle) == null) continue;
        const cmd_path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/cmdline", .{pid}) catch continue;
        const cmd = readFileAlloc(g_alloc, cmd_path) orelse continue;
        defer g_alloc.free(cmd);
        if (std.mem.indexOf(u8, cmd, "sketerm-webengine") != null) return pid;
    }
    return null;
}

/// The project layer on a document served over `ssh localhost` — the
/// proof that root discovery, the gutter's `git diff` and the search's
/// grep all run on the FILE'S host and not on the GUI's.
///
/// Skipped (loudly) when passwordless ssh to localhost is not
/// available; a rig that cannot reach the transport must not turn that
/// into a product failure.
/// True when a `list` reply shows pane `pane` inside a tab with
/// "selected":true — i.e. the pane's tab is what its window is
/// actually showing. With several windows this accepts any window's
/// selected tab; the e2e runs a single window at this stage.
fn selectedTabHasPane(resp: []const u8, pane: u32) bool {
    var needle_buf: [48]u8 = undefined;
    // PaneInfo serializes as {"id":N,"title":...} — anchor on the pair
    // so a tab id or a stray number in a title cannot match.
    const needle = std.fmt.bufPrint(&needle_buf, "\"id\":{d},\"title\"", .{pane}) catch return false;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, resp, from, "\"selected\":true")) |at| {
        const panes_at = std.mem.indexOfPos(u8, resp, at, "\"panes\":[") orelse return false;
        const end = std.mem.indexOfScalarPos(u8, resp, panes_at, ']') orelse return false;
        if (std.mem.indexOf(u8, resp[panes_at..end], needle) != null) return true;
        from = end;
    }
    return false;
}

fn remoteProjectStage(
    allocator: std.mem.Allocator,
    maybe_app: ?*appdrive.App,
    sock_path: [:0]const u8,
    rt: []const u8,
) ?[]const u8 {
    // "localhost" resolves through $SKETERM_SSH (set at GUI launch) to
    // the harness's second private daemon — the freshly built
    // sketerm-mux, not whatever the machine's installed one is. No
    // passwordless ssh needed, and the gutter assertion below is about
    // THIS build's remote project layer.
    const app = maybe_app orelse return null;

    var req_buf: [900]u8 = undefined;
    const oreq = std.fmt.bufPrint(
        &req_buf,
        "{{\"cmd\":\"new-editor-tab\",\"data\":\"localhost:{s}/proj/src/main.zig\"}}\n",
        .{rt},
    ) catch return "fmt";
    const oresp = roundtrip(allocator, sock_path, oreq) orelse return "remote new-editor-tab roundtrip";
    defer allocator.free(oresp);
    if (std.mem.indexOf(u8, oresp, "\"ok\":true") == null) return "remote new-editor-tab not ok";
    const rpane = parseNumAfter(oresp, "\"pane\":") orelse return "remote editor tab has no pane id";

    // The load is an ssh bootstrap plus a daemon read; give it room.
    var loaded = false;
    var t: u32 = 0;
    while (t < 80 and !loaded) : (t += 1) {
        _ = c.usleep(250_000);
        const greq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"get-text\",\"pane\":{d}}}\n", .{rpane}) catch return "fmt";
        const gresp = roundtrip(allocator, sock_path, greq) orelse continue;
        defer allocator.free(gresp);
        if (std.mem.indexOf(u8, gresp, "// touched") != null) loaded = true;
    }
    if (!loaded) return "a remote (ssh) document never loaded into the editor";

    const freq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{rpane}) catch return "fmt";
    const fresp = roundtrip(allocator, sock_path, freq) orelse return "remote focus roundtrip";
    defer allocator.free(fresp);
    if (std.mem.indexOf(u8, fresp, "\"ok\":true") == null) return "remote focus was refused";

    // The gutter scan below reads WINDOW pixels, so it is evidence
    // about the remote document only while the remote tab is the one
    // on screen — the LOCAL editor tab from the previous stage is
    // still open with its own marks, and a run once went green off
    // those. Assert the selected tab actually holds the remote pane,
    // and fail the stage if the focus never took.
    const win_id = app.windows.items[0].id;
    {
        var selected = false;
        var st: u32 = 0;
        while (st < 40 and !selected) : (st += 1) {
            _ = c.usleep(250_000);
            const lresp = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse continue;
            defer allocator.free(lresp);
            selected = selectedTabHasPane(lresp, rpane);
        }
        if (!selected) return "focus did not take: the remote editor tab never became the selected tab";
        // Flush any frame committed before the tab switch, so the scan
        // cannot count the local tab's final frame.
        _ = app.waitVisualSettle(win_id, 600, 10_000, 0.003, null);
    }

    // The gutter is the whole layer in one assertion: it needs the
    // project resolved (directory listings on the remote), the diff
    // produced by a remote `git`, and the result read back.
    var marks: usize = 0;
    var g: u32 = 0;
    while (g < 80) : (g += 1) {
        _ = app.pumpOnce(250);
        marks = gutterMarkPixels(allocator, app, win_id);
        if (marks > 8) break;
    }
    if (marks <= 8) {
        // Evidence for the postmortem: what the (confirmed-selected)
        // remote tab actually shows.
        dumpLeftStrip(allocator, app, win_id);
        if (app.screenshotPng(win_id, 0, null, 0)) |shot| {
            defer allocator.free(shot.png);
            writePng("zig-out/smoke-e2e-remote-gutter-FAIL.png", shot.png);
        } else |_| {}
        return "the git gutter never painted for a document served over ssh";
    }
    if (app.screenshotPng(win_id, 0, null, 0)) |shot| {
        defer allocator.free(shot.png);
        writePng("zig-out/smoke-e2e-remote-gutter.png", shot.png);
    } else |_| {}
    say("remote (ssh localhost) document: project resolved and the gutter painted on the remote host");

    const creq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"close-pane\",\"pane\":{d}}}\n", .{rpane}) catch return "fmt";
    const cresp = roundtrip(allocator, sock_path, creq) orelse return "remote close roundtrip";
    allocator.free(cresp);
    _ = c.usleep(500_000);
    return null;
}

/// A real restart: a SECOND GUI process started with `--restore` must
/// bring the editor session back — the files, not just the window.
fn restoreStage(
    allocator: std.mem.Allocator,
    maybe_app: ?*appdrive.App,
    rt: []const u8,
    wl: [*:0]const u8,
) ?[]const u8 {
    const app = maybe_app orelse return null;

    const pid = c.fork();
    if (pid < 0) return "fork for the restore GUI failed";
    if (pid == 0) {
        dieWithParent();
        _ = c.setenv("SKETERM_APP_ID", "dev.sker.sketerm.e2e.restore", 1);
        _ = c.setenv("WAYLAND_DISPLAY", wl, 1);
        _ = c.setenv("GDK_BACKEND", "wayland", 1);
        _ = c.unsetenv("DISPLAY");
        _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
        _ = c.setenv("GTK_A11Y", "none", 1);
        _ = c.setenv("SKETERM_VERIFY_TREE", "1", 1);
        const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm", "--restore", "--no-save", null };
        _ = c.execv("zig-out/bin/sketerm", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    restore_pid = pid;
    defer {
        if (restore_pid > 0) {
            _ = c.kill(restore_pid, c.SIGTERM);
            var st: c_int = 0;
            _ = c.waitpid(restore_pid, &st, 0);
            restore_pid = -1;
        }
    }

    const sock = std.fmt.allocPrintSentinel(allocator, "{s}/sketerm/{d}.sock", .{ rt, pid }, 0) catch return "alloc";
    defer allocator.free(sock);
    var waited: u32 = 0;
    while (c.access(sock.ptr, c.F_OK) != 0) {
        _ = c.usleep(100_000);
        waited += 1;
        if (waited > 200) return "the restoring GUI never opened its control socket";
    }

    // The restored editor pane must hold the file the layout named,
    // with the content it has on disk.
    var found = false;
    var pane: u32 = 1;
    var tries: u32 = 0;
    outer: while (tries < 60) : (tries += 1) {
        _ = c.usleep(300_000);
        pane = 1;
        while (pane < 30) : (pane += 1) {
            var req_buf: [128]u8 = undefined;
            const greq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"get-text\",\"pane\":{d}}}\n", .{pane}) catch return "fmt";
            const gresp = roundtrip(allocator, sock, greq) orelse continue;
            defer allocator.free(gresp);
            // The layout's ACTIVE tab is the file the replace rewrote,
            // so finding its token proves both the file set and the
            // active index came back.
            if (std.mem.indexOf(u8, gresp, "REPLACEDTOKEN") != null) {
                found = true;
                break :outer;
            }
        }
    }
    if (!found) {
        var lay_buf: [512]u8 = undefined;
        const lay = std.fmt.bufPrintZ(&lay_buf, "{s}/sketerm/last.json", .{rt}) catch return "layout path";
        const f = c.fopen(lay.ptr, "rb");
        if (f) |fp| {
            var buf: [8192]u8 = undefined;
            const n = c.fread(&buf, 1, buf.len, fp);
            _ = c.fclose(fp);
            _ = c.fprintf(platform.stderr(), "smoke-e2e: last.json = %.*s\n", @as(c_int, @intCast(n)), &buf);
        }
        const lst = roundtrip(allocator, sock, "{\"cmd\":\"list\"}\n");
        if (lst) |l| {
            defer allocator.free(l);
            _ = c.fprintf(platform.stderr(), "smoke-e2e: restored list = %.*s\n", @as(c_int, @intCast(l.len)), l.ptr);
        }
        return "the restored session did not bring the editor's document back";
    }

    {
        // Bring the restored EDITOR tab forward, so the screenshot
        // shows what was restored rather than the first terminal tab.
        var req_buf: [128]u8 = undefined;
        const freq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{pane}) catch return "fmt";
        if (roundtrip(allocator, sock, freq)) |r| allocator.free(r);
        _ = c.usleep(800_000);
    }
    _ = app.drainLive(3_000);
    if (app.windows.items.len > 0) {
        // The restored instance owns the newest toplevel.
        const win_id = app.windows.items[app.windows.items.len - 1].id;
        _ = app.waitVisualSettle(win_id, 600, 10_000, 0.003, null);
        if (app.screenshotPng(win_id, 0, null, 0)) |shot| {
            defer allocator.free(shot.png);
            writePng("zig-out/smoke-e2e-restored-session.png", shot.png);
        } else |_| {}
    }
    say("session restored by a second GUI started with --restore");
    return null;
}

fn countMarker(allocator: std.mem.Allocator, text: []const u8, marker: []const u8) usize {
    const flat = allocator.alloc(u8, text.len) catch return 0;
    defer allocator.free(flat);
    var w: usize = 0;
    var r: usize = 0;
    while (r < text.len) {
        if (r + 1 < text.len and text[r] == '\\' and text[r + 1] == 'n') {
            r += 2;
            continue;
        }
        flat[w] = text[r];
        w += 1;
        r += 1;
    }
    return std.mem.count(u8, flat[0..w], marker);
}

/// zwp_text_input_v3 objects the GUI created on the session's seat.
/// Non-zero is the structural proof that GTK took its WAYLAND
/// input-method path — the one X11 silently replaces with
/// GtkIMContextSimple, which is how an Xvfb run of this smoke passed
/// while dead keys were broken on every real compositor.
fn textInputCount(app: *appdrive.App) usize {
    var n: usize = 0;
    for (app.chans.values()) |ch| n += ch.comp.text_inputs.count();
    return n;
}

// The test display must be as demanding as a production compositor on
// the one axis that made X11 lie: `zwp_text_input_manager_v3`. Drop it
// from the advertised set and GTK falls back to GtkIMContextSimple
// here too, and this harness becomes exactly as misleading as Xvfb was.
comptime {
    var advertises_text_input = false;
    for (wlcomp.globals) |g| {
        if (std.mem.eql(u8, g.iface.name, "zwp_text_input_manager_v3"))
            advertises_text_input = true;
    }
    if (!advertises_text_input)
        @compileError("the test display no longer advertises zwp_text_input_manager_v3 — GUI input tests would go false-green");
}

/// Drive the GUI through the compositor's seat instead of the IPC
/// socket. Returns null on success, else the failure message.
fn realInputStage(allocator: std.mem.Allocator, app: *appdrive.App, sock_path: [:0]const u8) ?[]const u8 {
    _ = app.drainLive(3_000);
    if (app.windows.items.len == 0) return "the display session has no window to drive";
    const win_id = app.windows.items[0].id;
    const win_w = app.windows.items[0].w;
    const win_h = app.windows.items[0].h;
    if (win_w <= 0 or win_h <= 0) return "the GUI's window has no size";

    // A real click in the middle of the window: pointer routing, and
    // what hands the pane keyboard focus.
    app.clickEx(
        win_id,
        @as(f64, @floatFromInt(win_w)) / 2,
        @as(f64, @floatFromInt(win_h)) / 2,
        1,
        100,
        1,
    ) catch return "injecting a pointer click failed";
    _ = app.waitIdle(300, 5_000);

    var ref = app.frameRef(win_id, true) orelse return "no baseline frame to diff against";
    defer ref.deinit(allocator);

    app.typeText(null, "echo " ++ KEY_MARKER ++ "\n") catch return "injecting keystrokes failed";

    // Pixels, not protocol: the window must genuinely repaint.
    if (!app.waitChangeSince(win_id, &ref, 20_000, 0.02, null))
        return "the window never repainted after real key input";

    // ...and the bytes must have reached the shell, which only happens
    // if GTK delivered the key events to the focused pane.
    var tries: u32 = 0;
    while (tries < 75) : (tries += 1) {
        const resp = roundtrip(allocator, sock_path, "{\"cmd\":\"get-text\",\"pane\":1}\n") orelse continue;
        defer allocator.free(resp);
        if (countMarker(allocator, resp, KEY_MARKER) >= 2) break;
        _ = app.pumpOnce(200);
    } else return "keys typed on the real seat never reached the pane's shell";

    // A PNG of the live window: the encode path callers rely on, and a
    // final check that the composited buffer is real.
    const shot = app.screenshotPng(win_id, 1024, null, 0) catch return "screenshotting the GUI window failed";
    defer allocator.free(shot.png);
    if (shot.png.len < 1024 or shot.img_w == 0 or shot.img_h == 0)
        return "the GUI window screenshot is empty";
    return null;
}

const MENU_MARKER = "CTXMENU_OK";

/// A GTK4 popover is its OWN xdg_popup surface, not part of the
/// toplevel's buffer — screenshotting the toplevel never shows it,
/// and a toplevel pixel-diff "proving" a menu opened is really just
/// the cursor blinking. So the menu is counted as a popup surface
/// with committed frames.
fn openPopup(app: *appdrive.App) ?u32 {
    _ = app.pumpOnce(120);
    for (app.windows.items) |w| {
        if (w.popup and w.frames > 0) return w.id;
    }
    return null;
}

fn waitPopup(app: *appdrive.App, want_open: bool, ms: u32) ?u32 {
    var waited: u32 = 0;
    while (true) {
        const id = openPopup(app);
        if ((id != null) == want_open) return id orelse 0;
        if (waited >= ms) return null;
        _ = app.pumpOnce(200);
        waited += 200;
    }
}

/// The pane's context menu on the REAL seat: a right-click and
/// Shift+F10 must both open it, Escape must close it, and focus must
/// come back to the pane afterwards.
///
/// Asserted on the popup surface and on shell bytes, because this
/// harness runs with GTK_A11Y=none (see the GUI spawn above). The
/// menu's CONTENTS, per-row sensitivity and row activation are
/// asserted in `smoke_atspi.zig`, which has a private a11y bus.
fn contextMenuStage(allocator: std.mem.Allocator, app: *appdrive.App, sock_path: [:0]const u8) ?[]const u8 {
    _ = app.drainLive(3_000);
    if (app.windows.items.len == 0) return "the display session lost its window";
    const win_id = app.windows.items[0].id;
    const cx = @as(f64, @floatFromInt(app.windows.items[0].w)) / 2;
    const cy = @as(f64, @floatFromInt(app.windows.items[0].h)) / 2;
    if (openPopup(app) != null) return "a popup was already open before the context-menu stage";

    // ── pointer path ────────────────────────────────────────────
    app.clickEx(win_id, cx, cy, 3, 100, 1) catch return "injecting a right-click failed";
    const menu_id = waitPopup(app, true, 15_000) orelse
        return "a right-click on the pane opened no menu popup";
    _ = app.waitVisualSettle(menu_id, 300, 5_000, 0.002, null);

    // A PNG of the menu surface itself — the artefact a human reviews.
    if (app.screenshotPng(menu_id, 1024, null, 0)) |shot| {
        defer allocator.free(shot.png);
        writePng("/tmp/sketerm-e2e-context-menu.png", shot.png);
        if (shot.img_w < 40 or shot.img_h < 40) return "the context menu popup has no real size";
    } else |_| return "screenshotting the open context menu failed";

    app.pressKey(null, "Escape") catch return "injecting Escape failed";
    if (waitPopup(app, false, 10_000) == null)
        return "the right-click menu never closed on Escape";

    // ── keyboard path ───────────────────────────────────────────
    // Shift+F10 must open the same menu with no pointer involved.
    app.pressKey(null, "shift+F10") catch return "injecting Shift+F10 failed";
    const kb_id = waitPopup(app, true, 15_000) orelse
        return "Shift+F10 did not open the context menu";
    _ = app.waitVisualSettle(kb_id, 300, 5_000, 0.002, null);
    if (app.screenshotPng(kb_id, 1024, null, 0)) |shot| {
        defer allocator.free(shot.png);
        writePng("/tmp/sketerm-e2e-context-menu-keyboard.png", shot.png);
    } else |_| return "screenshotting the keyboard-opened context menu failed";

    app.pressKey(null, "Escape") catch return "injecting Escape failed";
    if (waitPopup(app, false, 10_000) == null)
        return "the keyboard-opened menu never closed on Escape";
    _ = app.waitIdle(300, 5_000);

    // ── focus return ────────────────────────────────────────────
    // Focus is only genuinely back on the pane if typed bytes reach
    // its shell again — a popover that keeps the keyboard grab, or a
    // pane that never regains focus, dies here.
    app.typeText(null, "echo " ++ MENU_MARKER ++ "\n") catch
        return "injecting keystrokes after the menu closed failed";
    var tries: u32 = 0;
    while (tries < 75) : (tries += 1) {
        const resp = roundtrip(allocator, sock_path, "{\"cmd\":\"get-text\",\"pane\":1}\n") orelse continue;
        defer allocator.free(resp);
        if (countMarker(allocator, resp, MENU_MARKER) >= 2) break;
        _ = app.pumpOnce(200);
    } else return "focus never returned to the pane after the context menu closed";
    return null;
}

/// One line per known surface on stderr — failure forensics only.
fn dumpWindowRoster(app: *appdrive.App, why: []const u8) void {
    _ = c.fprintf(platform.stderr(), "smoke-e2e: %.*s; window roster:\n", @as(c_int, @intCast(why.len)), why.ptr);
    for (app.windows.items) |w| {
        const title: []const u8 = w.title orelse "-";
        const app_id: []const u8 = w.app_id orelse "-";
        _ = c.fprintf(
            platform.stderr(),
            "  id=%u popup=%d frames=%llu size=%dx%d title='%.*s' app_id='%.*s'\n",
            w.id,
            @as(c_int, @intFromBool(w.popup)),
            @as(c_ulonglong, w.frames),
            w.w,
            w.h,
            @as(c_int, @intCast(title.len)),
            title.ptr,
            @as(c_int, @intCast(app_id.len)),
            app_id.ptr,
        );
    }
}

/// Ids of every non-popup surface currently known, so a newly mapped
/// toplevel can be told from the ones already on screen.
fn hasToplevelOtherThan(app: *appdrive.App, known: []const u32) ?u32 {
    _ = app.pumpOnce(120);
    outer: for (app.windows.items) |w| {
        if (w.popup or w.frames == 0) continue;
        for (known) |k| {
            if (w.id == k) continue :outer;
        }
        return w.id;
    }
    return null;
}

/// The standalone image viewer's canvas context menu, in the same
/// display session. `sketerm view` is its own application identity, so
/// it is spawned as a second child and killed by exact pid.
fn viewerMenuStage(allocator: std.mem.Allocator, app: *appdrive.App, rt: []const u8, wl: [*:0]const u8) ?[]const u8 {
    _ = app.drainLive(2_000);
    if (app.windows.items.len == 0) return "the display session lost its window";
    const term_win = app.windows.items[0].id;

    // An image to open: a PNG of the terminal window itself, which is
    // guaranteed to exist and to decode.
    const img_path = std.fmt.allocPrintSentinel(allocator, "{s}/viewer-sample.png", .{rt}, 0) catch
        return "allocating the sample image path failed";
    defer allocator.free(img_path);
    if (app.screenshotPng(term_win, 512, null, 0)) |shot| {
        defer allocator.free(shot.png);
        writePng(img_path, shot.png);
    } else |_| return "could not produce a sample image for the viewer";

    var known: [8]u32 = undefined;
    var n_known: usize = 0;
    for (app.windows.items) |w| {
        if (w.popup or n_known >= known.len) continue;
        known[n_known] = w.id;
        n_known += 1;
    }

    const pid = c.fork();
    if (pid < 0) return "fork for the viewer failed";
    if (pid == 0) {
        dieWithParent();
        // Its own app id: `sketerm view` registers a viewer identity,
        // and it must not join the terminal instance already running.
        _ = c.setenv("SKETERM_APP_ID", "dev.sker.sketerm.e2eview", 1);
        _ = c.setenv("WAYLAND_DISPLAY", wl, 1);
        _ = c.setenv("GDK_BACKEND", "wayland", 1);
        _ = c.unsetenv("DISPLAY");
        _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
        _ = c.setenv("GTK_A11Y", "none", 1);
        const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm", "view", img_path.ptr, null };
        _ = c.execv("zig-out/bin/sketerm", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    viewer_pid = pid;

    var waited: u32 = 0;
    const viewer_win = while (waited < 25_000) : (waited += 200) {
        if (hasToplevelOtherThan(app, known[0..n_known])) |id| break id;
        _ = app.pumpOnce(200);
    } else return "the image viewer never mapped a window";
    _ = app.waitVisualSettle(viewer_win, 400, 10_000, 0.002, null);

    const vw = app.winById(viewer_win) orelse return "the viewer window vanished";
    const cx = @as(f64, @floatFromInt(vw.w)) / 2;
    const cy = @as(f64, @floatFromInt(vw.h)) / 2;
    if (openPopup(app) != null) return "a popup was already open before the viewer menu";

    // Right-click on the image canvas.
    app.clickEx(viewer_win, cx, cy, 3, 100, 1) catch return "right-clicking the viewer canvas failed";
    const menu_id = waitPopup(app, true, 15_000) orelse
        return "a right-click on the image canvas opened no menu";
    _ = app.waitVisualSettle(menu_id, 300, 5_000, 0.002, null);
    if (app.screenshotPng(menu_id, 1024, null, 0)) |shot| {
        defer allocator.free(shot.png);
        writePng("/tmp/sketerm-e2e-viewer-menu.png", shot.png);
        if (shot.img_w < 40 or shot.img_h < 40) return "the viewer's menu popup has no real size";
    } else |_| return "screenshotting the viewer's context menu failed";

    app.pressKey(viewer_win, "Escape") catch return "injecting Escape failed";
    if (waitPopup(app, false, 10_000) == null)
        return "the viewer's context menu never closed on Escape";

    // Keyboard path: the viewer routes Menu / Shift+F10 through its
    // own window-level key handler.
    app.pressKey(viewer_win, "shift+F10") catch return "injecting Shift+F10 failed";
    if (waitPopup(app, true, 15_000) == null)
        return "Shift+F10 did not open the viewer's context menu";
    app.pressKey(viewer_win, "Escape") catch return "injecting Escape failed";
    if (waitPopup(app, false, 10_000) == null)
        return "the viewer's keyboard-opened menu never closed on Escape";

    _ = c.kill(viewer_pid, c.SIGKILL);
    var vst: c_int = 0;
    _ = c.waitpid(viewer_pid, &vst, 0);
    viewer_pid = -1;
    _ = app.drainLive(2_000);
    return null;
}

/// One play_state frame's JSON, as the daemon ships it.
const CastMsg = struct {
    state: []const u8 = "",
    position_ms: u64 = 0,
    duration_ms: ?u64 = null,
    speed: f64 = 1,
    markers: []const struct { u64, []const u8 } = &.{},
};

/// Scalars of the LAST play_state castWaitState saw (marker labels are
/// frame-scoped, so only the first marker's time is kept).
const CastObserved = struct {
    position_ms: u64 = 0,
    duration_ms: ?u64 = null,
    n_markers: usize = 0,
    first_marker_ms: u64 = 0,
};

/// Consume frames on an attached side connection until a play_state
/// with `want` arrives (other frames are ignored). Every play_state
/// seen updates `out`, so the caller reads the winning frame's fields.
fn castWaitState(
    allocator: std.mem.Allocator,
    conn: *@import("mux/client.zig").Conn,
    want: []const u8,
    timeout_ms: i64,
    out: *CastObserved,
) bool {
    const deadline = clock.nowMs() + timeout_ms;
    while (clock.nowMs() < deadline) {
        const f = conn.recvFrameFor(500) catch |err| switch (err) {
            error.Timeout => continue,
            else => return false,
        };
        defer f.deinit(conn.allocator);
        if (f.ftype != .play_state) continue;
        const parsed = std.json.parseFromSlice(CastMsg, allocator, f.payload, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();
        const m = parsed.value;
        out.* = .{
            .position_ms = m.position_ms,
            .duration_ms = m.duration_ms,
            .n_markers = m.markers.len,
            .first_marker_ms = if (m.markers.len > 0) m.markers[0][0] else 0,
        };
        if (std.mem.eql(u8, m.state, want)) return true;
    }
    return false;
}

/// One-shot daemon session list into `buf` (the raw .ok JSON), over a
/// fresh connection. Empty slice on any failure.
fn castListSessions(allocator: std.mem.Allocator, mux_sock: []const u8, buf: []u8) []const u8 {
    var conn = muxclient.Conn.connectProbed(allocator, mux_sock) catch return buf[0..0];
    defer conn.deinit();
    conn.sendFrame(.list, "") catch return buf[0..0];
    // Monolith answers .ok; a broker answers with a refreshed .welcome
    // carrying the aggregated worker roster.
    const f = conn.recvExpectFor(&.{ .ok, .welcome }, 5_000) catch return buf[0..0];
    defer f.deinit(allocator);
    const n = @min(f.payload.len, buf.len);
    @memcpy(buf[0..n], f.payload[0..n]);
    return buf[0..n];
}

/// Pixels in `win_id` within tolerance of `rgb`.
fn castCountRgb(allocator: std.mem.Allocator, app: *appdrive.App, win_id: u32, rgb: [3]u8) usize {
    const shot = app.snapshotRgba(win_id, null) catch return 0;
    defer allocator.free(shot.px);
    var n: usize = 0;
    var i: usize = 0;
    while (i + 3 < shot.px.len) : (i += 4) {
        const dr = @abs(@as(i32, shot.px[i]) - @as(i32, rgb[0]));
        const dg = @abs(@as(i32, shot.px[i + 1]) - @as(i32, rgb[1]));
        const db = @abs(@as(i32, shot.px[i + 2]) - @as(i32, rgb[2]));
        if (dr <= 40 and dg <= 40 and db <= 40) n += 1;
    }
    return n;
}

/// Poll until `win_id` shows (or stops showing) at least `min` pixels
/// of `rgb`.
fn castWaitRgb(allocator: std.mem.Allocator, app: *appdrive.App, win_id: u32, rgb: [3]u8, min: usize, present: bool, timeout_ms: i64) bool {
    const deadline = clock.nowMs() + timeout_ms;
    while (clock.nowMs() < deadline) {
        _ = app.pumpOnce(200);
        const n = castCountRgb(allocator, app, win_id, rgb);
        if (present and n >= min) return true;
        if (!present and n < min) return true;
    }
    return false;
}

/// Cast playback end to end: `sketerm play` on a hand-written v2 cast,
/// rendered through the fixed_grid TerminalSurface (its first-ever
/// runtime exercise), every transport control driven by REAL
/// keystrokes, and the daemon's play_state transitions asserted over a
/// read-only side attachment. The recording's only late event sits at
/// 30s so pause/seek behaviour is deterministic — normal playback
/// never reaches it inside this stage.
fn castPlaybackStage(
    allocator: std.mem.Allocator,
    app: *appdrive.App,
    rt: []const u8,
    mux_sock: []const u8,
    wl: [*:0]const u8,
) ?[]const u8 {
    // The recording: red at 0.1s, a recorded RESIZE (40x10 -> 30x8), a
    // green block only printable on the post-resize grid, a marker,
    // and a blue block at 30s.
    var cast_path_buf: [512:0]u8 = undefined;
    const cast_path = std.fmt.bufPrintZ(&cast_path_buf, "{s}/e2e.cast", .{rt}) catch return "cast path too long";
    {
        const body =
            "{\"version\": 2, \"width\": 40, \"height\": 10}\n" ++
            "[0.1, \"o\", \"\\u001b[48;2;255;0;0m  RED BLOCK  \\u001b[0m cast-e2e\"]\n" ++
            "[0.6, \"r\", \"30x8\"]\n" ++
            "[0.9, \"o\", \"\\r\\n\\u001b[48;2;0;255;0m  GREEN BLOCK  \\u001b[0m\"]\n" ++
            "[1.4, \"m\", \"half\"]\n" ++
            "[30.0, \"o\", \"\\r\\n\\u001b[48;2;0;0;255m  BLUE BLOCK  \\u001b[0m\"]\n";
        const f = c.fopen(cast_path.ptr, "wb") orelse return "could not write the cast file";
        const ok = c.fwrite(body.ptr, 1, body.len, f) == body.len;
        _ = c.fclose(f);
        if (!ok) return "short write on the cast file";
    }

    _ = app.drainLive(2_000);
    var known: [16]u32 = undefined;
    var n_known: usize = 0;
    for (app.windows.items) |w| {
        if (w.popup or n_known >= known.len) continue;
        known[n_known] = w.id;
        n_known += 1;
    }

    const pid = c.fork();
    if (pid < 0) return "fork for sketerm play failed";
    if (pid == 0) {
        dieWithParent();
        // Its own app id: it must not join the terminal instance
        // already running in this display session.
        _ = c.setenv("SKETERM_APP_ID", "dev.sker.sketerm.e2ecast", 1);
        _ = c.setenv("WAYLAND_DISPLAY", wl, 1);
        _ = c.setenv("GDK_BACKEND", "wayland", 1);
        _ = c.unsetenv("DISPLAY");
        _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
        _ = c.setenv("GTK_A11Y", "none", 1);
        const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm", "play", cast_path.ptr, null };
        _ = c.execv("zig-out/bin/sketerm", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    cast_pid = pid;

    var waited: u32 = 0;
    const cast_win = while (waited < 25_000) : (waited += 200) {
        if (hasToplevelOtherThan(app, known[0..n_known])) |id| break id;
        _ = app.pumpOnce(200);
    } else return "sketerm play never mapped a window";
    _ = app.waitVisualSettle(cast_win, 400, 10_000, 0.002, null);

    // Side attachment: find the GUI-minted session (name prefix
    // "cast") and follow its play_state stream read-only.
    var name_buf: [64]u8 = undefined;
    var name: []const u8 = &.{};
    var name_tries: u32 = 0;
    while (name_tries < 50) : (name_tries += 1) {
        var list_buf: [16384]u8 = undefined;
        const listing = castListSessions(allocator, mux_sock, &list_buf);
        if (std.mem.indexOf(u8, listing, "\"name\":\"cast")) |at| {
            const start = at + "\"name\":\"".len;
            const end = std.mem.indexOfScalarPos(u8, listing, start, '"') orelse break;
            const found = listing[start..end];
            if (found.len <= name_buf.len) {
                @memcpy(name_buf[0..found.len], found);
                name = name_buf[0..found.len];
                break;
            }
        }
        _ = c.usleep(200_000);
    }
    if (name.len == 0) return "the cast session never appeared in the daemon's list";

    var side = muxclient.Conn.connectProbed(allocator, mux_sock) catch return "side connect failed";
    defer side.deinit();
    side.sendJson(.attach, .{ .name = name, .kind = "cli", .read_only = true }) catch return "side attach send failed";
    {
        const snap = side.recvExpectFor(&.{.snapshot}, 10_000) catch return "side attach got no snapshot";
        snap.deinit(allocator);
    }
    var st: CastObserved = .{};
    if (!castWaitState(allocator, &side, "playing", 10_000, &st))
        return "the cast never reported state playing (auto-play on first attach)";

    // Playback rendered through fixed_grid: the green block only
    // exists AFTER the recorded resize applied.
    if (!castWaitRgb(allocator, app, cast_win, .{ 0, 255, 0 }, 40, true, 20_000))
        return "the green block never rendered (playback or fixed_grid broken)";
    if (castCountRgb(allocator, app, cast_win, .{ 255, 0, 0 }) < 40)
        return "the red block is missing from the rendered frame";

    // Space pauses (keyboard -> play_control -> daemon).
    app.pressKey(cast_win, "space") catch return "injecting space failed";
    if (!castWaitState(allocator, &side, "paused", 8_000, &st))
        return "space did not pause the cast";
    if (st.position_ms >= 30_000)
        return "playback passed the 30s guard event before the pause (host too slow for this stage's timing)";

    // Space resumes.
    app.pressKey(cast_win, "space") catch return "injecting space failed";
    if (!castWaitState(allocator, &side, "playing", 8_000, &st))
        return "space did not resume the cast";

    // Shift+Right seeks +30s -> past EOF -> finished, with the final
    // frame (blue block) materialized by the seek replay.
    app.pressKey(cast_win, "shift+right") catch return "injecting shift+right failed";
    if (!castWaitState(allocator, &side, "finished", 15_000, &st))
        return "the +30s seek never reported finished";
    if (st.duration_ms != 30_000) return "finished state carries the wrong duration";
    if (st.position_ms != 30_000) return "finished state carries the wrong position";
    if (st.n_markers < 1 or st.first_marker_ms != 1400)
        return "the recorded marker is missing from play_state";
    if (!castWaitRgb(allocator, app, cast_win, .{ 0, 0, 255 }, 40, true, 10_000))
        return "the blue block never rendered after the seek";

    // EOF retains the final screen and the session stays alive.
    _ = app.drainLive(1_500);
    if (castCountRgb(allocator, app, cast_win, .{ 0, 0, 255 }) < 40)
        return "the final frame was not retained after playback finished";
    {
        var list_buf: [16384]u8 = undefined;
        const listing = castListSessions(allocator, mux_sock, &list_buf);
        if (std.mem.indexOf(u8, listing, name) == null)
            return "the finished cast session vanished from the daemon";
    }

    // R restarts: back to the top (blue gone), playing again.
    app.pressKey(cast_win, "r") catch return "injecting r failed";
    if (!castWaitState(allocator, &side, "playing", 10_000, &st))
        return "restart never reported playing";
    if (!castWaitRgb(allocator, app, cast_win, .{ 0, 0, 255 }, 40, false, 10_000))
        return "restart did not reset the screen (blue block still visible)";

    // Q closes the window; the ephemeral session must die with it.
    app.pressKey(cast_win, "q") catch return "injecting q failed";
    {
        var status: c_int = 0;
        var reaped = false;
        var t: u32 = 0;
        while (t < 15_000) : (t += 100) {
            if (c.waitpid(cast_pid, &status, c.WNOHANG) == cast_pid) {
                reaped = true;
                break;
            }
            _ = c.usleep(100_000);
        }
        if (!reaped) return "sketerm play did not exit on q";
        cast_pid = -1;
        if (!(c.WIFEXITED(status) and c.WEXITSTATUS(status) == 0))
            return "sketerm play exited abnormally on q";
    }
    var gone = false;
    var t2: u32 = 0;
    while (t2 < 10_000) : (t2 += 250) {
        var list_buf: [16384]u8 = undefined;
        const listing = castListSessions(allocator, mux_sock, &list_buf);
        if (std.mem.indexOf(u8, listing, name) == null) {
            gone = true;
            break;
        }
        _ = c.usleep(250_000);
    }
    if (!gone) return "closing the window did not kill the ephemeral cast session";
    _ = app.drainLive(2_000);
    return null;
}

/// OCR the window and wait until `needle` appears in the recognized
/// text. Also true (with a note) when tesseract is not installed, so
/// hosts without OCR still run the stage's structural checks.
fn viewerWaitOcr(allocator: std.mem.Allocator, app: *appdrive.App, win_id: u32, needle: []const u8, timeout_ms: i64) bool {
    const ocr = @import("util/ocr.zig");
    const png_util = @import("util/png.zig");
    if (!ocr.available()) {
        say("viewer text: tesseract unavailable; skipping the OCR content check");
        return true;
    }
    const deadline = clock.nowMs() + timeout_ms;
    while (clock.nowMs() < deadline) {
        _ = app.pumpOnce(250);
        const shot = app.snapshotRgba(win_id, null) catch continue;
        defer allocator.free(shot.px);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        // NATIVE scale first. A blanket 2x nearest-neighbour upscale
        // measurably DESTROYS recognition of ordinary UI text: the same
        // frame that reads "Approve remote" at 1:1 reads as nothing at
        // 2x. Upscaling is the repair for tiny fonts, not a default.
        // psm 6 reads a uniform BLOCK of text; a window that is almost
        // entirely empty with one centred label is not one, and psm 6
        // returns nothing at all for it (ocr.zig's own Options doc names
        // 11 for scattered UI labels). Try the block mode first, since
        // it is better on the viewer's paragraphs, then sparse.
        var found = false;
        var recognized: []const u8 = "";
        outer: for ([_]u32{ 1, 2 }) |scale| {
            const px = if (scale == 1)
                shot.px
            else
                png_util.upscaleRgba(arena.allocator(), shot.px, shot.w, shot.h, scale) catch continue;
            for ([_]i32{ 6, 11 }) |psm| {
                const res = ocr.recognize(arena.allocator(), px, shot.w * scale, shot.h * scale, .{ .psm = psm }) catch continue;
                if (res.text.len > recognized.len) recognized = res.text;
                if (std.mem.indexOf(u8, res.text, needle) != null) {
                    found = true;
                    break :outer;
                }
            }
        }
        if (found) return true;
        const res = .{ .text = recognized };
        // Failure forensics: the last round before the deadline keeps
        // what was actually on screen, so "the OCR never saw X" can be
        // told apart from "the window showed something else".
        if (clock.nowMs() + 300 >= deadline) {
            const n = @min(res.text.len, 400);
            _ = c.fprintf(platform.stderr(), "smoke-e2e: OCR timed out on '%.*s'; recognized: [%.*s]\n", @as(c_int, @intCast(needle.len)), needle.ptr, @as(c_int, @intCast(n)), res.text.ptr);
            // Dump the EXACT buffer handed to tesseract. Comparing it
            // against the screenshot PNG is what separates "our pixels
            // are wrong" from "tesseract cannot read this frame".
            if (png_util.encodeRgba(arena.allocator(), shot.px, shot.w, shot.h)) |raw| {
                writePng("/tmp/sketerm-e2e-ocr-input.png", raw);
            } else |_| {}
            if (app.screenshotPng(win_id, 1024, null, 0)) |dbgshot| {
                defer allocator.free(dbgshot.png);
                writePng("/tmp/sketerm-e2e-ocr-fail.png", dbgshot.png);
            } else |_| {}
        }
    }
    return false;
}

const OcrPoint = struct { x: f64, y: f64 };

fn waitOcrWordCenter(
    allocator: std.mem.Allocator,
    app: *appdrive.App,
    win_id: u32,
    word: []const u8,
    timeout_ms: i64,
) ?OcrPoint {
    const ocr = @import("util/ocr.zig");
    const png_util = @import("util/png.zig");
    if (!ocr.available()) return null;
    const deadline = clock.nowMs() + timeout_ms;
    while (clock.nowMs() < deadline) {
        _ = app.pumpOnce(200);
        const shot = app.snapshotRgba(win_id, null) catch continue;
        defer allocator.free(shot.px);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scale: u32 = 2;
        const px = png_util.upscaleRgba(arena.allocator(), shot.px, shot.w, shot.h, scale) catch continue;
        const result = ocr.recognize(arena.allocator(), px, shot.w * scale, shot.h * scale, .{ .psm = 11 }) catch continue;
        for (result.words) |found| {
            if (!std.ascii.eqlIgnoreCase(found.text, word)) continue;
            return .{
                .x = @as(f64, @floatFromInt(found.x * 2 + found.w)) / (2 * scale),
                .y = @as(f64, @floatFromInt(found.y * 2 + found.h)) / (2 * scale),
            };
        }
    }
    return null;
}

/// Cast playback INSIDE the Sketerm Viewer: `sketerm view` on a mixed
/// batch (image + cast + text + binary), navigated both directions on
/// a real seat. What only a live run can prove: the shared
/// CastPlayerBox renders through the viewer's content slot, Space
/// reaches the daemon as a pause, BATCH NAVIGATION tears the ephemeral
/// cast session down completely (no leaked session) and can rebuild a
/// fresh one, and the universal text fallback renders a .txt as text
/// and an arbitrary binary as a hex dump.
fn viewerCastStage(
    allocator: std.mem.Allocator,
    app: *appdrive.App,
    rt: []const u8,
    mux_sock: []const u8,
    wl: [*:0]const u8,
) ?[]const u8 {
    _ = app.drainLive(2_000);
    if (app.windows.items.len == 0) return "the display session lost its window";
    const term_win = app.windows.items[0].id;

    // The image half of the batch: a screenshot of the terminal
    // window, guaranteed to exist and to decode.
    const img_path = std.fmt.allocPrintSentinel(allocator, "{s}/viewer-cast-img.png", .{rt}, 0) catch
        return "allocating the sample image path failed";
    defer allocator.free(img_path);
    if (app.screenshotPng(term_win, 512, null, 0)) |shot| {
        defer allocator.free(shot.png);
        writePng(img_path, shot.png);
    } else |_| return "could not produce a sample image for the viewer";

    // The cast half: red+green early, a blue guard event at 30s so
    // normal playback never changes the asserted pixels mid-stage.
    var cast_path_buf: [512:0]u8 = undefined;
    const cast_path = std.fmt.bufPrintZ(&cast_path_buf, "{s}/viewer-e2e.cast", .{rt}) catch return "cast path too long";
    {
        const body =
            "{\"version\": 2, \"width\": 40, \"height\": 10}\n" ++
            "[0.1, \"o\", \"\\u001b[48;2;255;0;0m  RED BLOCK  \\u001b[0m viewer-cast-e2e\"]\n" ++
            "[0.5, \"o\", \"\\r\\n\\u001b[48;2;0;255;0m  GREEN BLOCK  \\u001b[0m\"]\n" ++
            "[30.0, \"o\", \"\\r\\n\\u001b[48;2;0;0;255m  BLUE BLOCK  \\u001b[0m\"]\n";
        const f = c.fopen(cast_path.ptr, "wb") orelse return "could not write the cast file";
        const ok = c.fwrite(body.ptr, 1, body.len, f) == body.len;
        _ = c.fclose(f);
        if (!ok) return "short write on the cast file";
    }

    // The text and binary halves: the viewer's universal fallback.
    // Distinct tokens (QUILL vs HEXPROOF) so one item's screen can
    // never satisfy the other's OCR assertion.
    var txt_path_buf: [512:0]u8 = undefined;
    const txt_path = std.fmt.bufPrintZ(&txt_path_buf, "{s}/viewer-e2e-note.txt", .{rt}) catch return "text path too long";
    {
        const body = "SKETERM VIEWER TEXTMODE QUILL\n" ** 12;
        const f = c.fopen(txt_path.ptr, "wb") orelse return "could not write the text file";
        const ok = c.fwrite(body.ptr, 1, body.len, f) == body.len;
        _ = c.fclose(f);
        if (!ok) return "short write on the text file";
    }
    var bin_path_buf: [512:0]u8 = undefined;
    const bin_path = std.fmt.bufPrintZ(&bin_path_buf, "{s}/viewer-e2e-data.bin", .{rt}) catch return "binary path too long";
    {
        // NULs trip the binary classifier; HEXPROOF lands in the hex
        // dump's ASCII gutter.
        const body = "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x0b\x0c\x0e\x0f\x10\x11\x12" ++
            "HEXPROOF" ++ "\x00\x01\x02\x03\x04\x05\x06\x07";
        const f = c.fopen(bin_path.ptr, "wb") orelse return "could not write the binary file";
        const ok = c.fwrite(body.ptr, 1, body.len, f) == body.len;
        _ = c.fclose(f);
        if (!ok) return "short write on the binary file";
    }

    var known: [16]u32 = undefined;
    var n_known: usize = 0;
    for (app.windows.items) |w| {
        if (w.popup or n_known >= known.len) continue;
        known[n_known] = w.id;
        n_known += 1;
    }

    const pid = c.fork();
    if (pid < 0) return "fork for the viewer failed";
    if (pid == 0) {
        dieWithParent();
        // Its own app id: it must not join any instance already
        // running in this display session.
        _ = c.setenv("SKETERM_APP_ID", "dev.sker.sketerm.e2evcast", 1);
        _ = c.setenv("WAYLAND_DISPLAY", wl, 1);
        _ = c.setenv("GDK_BACKEND", "wayland", 1);
        _ = c.unsetenv("DISPLAY");
        _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
        _ = c.setenv("GTK_A11Y", "none", 1);
        const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm", "view", img_path.ptr, cast_path.ptr, txt_path.ptr, bin_path.ptr, null };
        _ = c.execv("zig-out/bin/sketerm", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    vcast_pid = pid;

    var waited: u32 = 0;
    const vwin = while (waited < 25_000) : (waited += 200) {
        if (hasToplevelOtherThan(app, known[0..n_known])) |id| break id;
        _ = app.pumpOnce(200);
    } else return "sketerm view never mapped a window";
    _ = app.waitVisualSettle(vwin, 400, 10_000, 0.002, null);

    // The batch starts on the image, so no cast session may exist yet.
    {
        var list_buf: [16384]u8 = undefined;
        const listing = castListSessions(allocator, mux_sock, &list_buf);
        if (std.mem.indexOf(u8, listing, "\"name\":\"cast") != null)
            return "a cast session existed before navigating to the cast item";
    }

    // Right -> the cast item: playback renders in place.
    app.pressKey(vwin, "Right") catch return "injecting Right failed";
    if (!castWaitRgb(allocator, app, vwin, .{ 255, 0, 0 }, 40, true, 20_000))
        return "the red block never rendered inside the viewer";
    if (!castWaitRgb(allocator, app, vwin, .{ 0, 255, 0 }, 40, true, 20_000))
        return "the green block never rendered inside the viewer";

    // The GUI-minted ephemeral session (name prefix "cast").
    var name_buf: [64]u8 = undefined;
    var name: []const u8 = &.{};
    var name_tries: u32 = 0;
    while (name_tries < 50) : (name_tries += 1) {
        var list_buf: [16384]u8 = undefined;
        const listing = castListSessions(allocator, mux_sock, &list_buf);
        if (std.mem.indexOf(u8, listing, "\"name\":\"cast")) |at| {
            const start = at + "\"name\":\"".len;
            const end = std.mem.indexOfScalarPos(u8, listing, start, '"') orelse break;
            const found = listing[start..end];
            if (found.len <= name_buf.len) {
                @memcpy(name_buf[0..found.len], found);
                name = name_buf[0..found.len];
                break;
            }
        }
        _ = c.usleep(200_000);
    }
    if (name.len == 0) return "the viewer's cast session never appeared in the daemon's list";

    // Space pauses, cross-checked on a read-only side attachment.
    {
        var side = muxclient.Conn.connectProbed(allocator, mux_sock) catch return "side connect failed";
        defer side.deinit();
        side.sendJson(.attach, .{ .name = name, .kind = "cli", .read_only = true }) catch return "side attach send failed";
        const snap = side.recvExpectFor(&.{.snapshot}, 10_000) catch return "side attach got no snapshot";
        snap.deinit(allocator);
        var st: CastObserved = .{};
        app.pressKey(vwin, "space") catch return "injecting space failed";
        if (!castWaitState(allocator, &side, "paused", 8_000, &st))
            return "space did not pause the cast inside the viewer";
        // Resume so the teardown below kills a RUNNING playback. This
        // second press deliberately lands the instant the daemon
        // reports "paused" — before the GUI has necessarily read that
        // push — so it also covers the toggle's stale-state race.
        app.pressKey(vwin, "space") catch return "injecting space failed";
        if (!castWaitState(allocator, &side, "playing", 8_000, &st))
            return "space did not resume the cast inside the viewer";
    }

    // Left -> back to the image: the outgoing controller must kill
    // its ephemeral session (this is the no-leak invariant).
    app.pressKey(vwin, "Left") catch return "injecting Left failed";
    if (!castWaitRgb(allocator, app, vwin, .{ 255, 0, 0 }, 40, false, 15_000))
        return "navigating back to the image did not clear the cast frame";
    {
        var gone = false;
        var t: u32 = 0;
        while (t < 10_000) : (t += 250) {
            var list_buf: [16384]u8 = undefined;
            const listing = castListSessions(allocator, mux_sock, &list_buf);
            if (std.mem.indexOf(u8, listing, name) == null) {
                gone = true;
                break;
            }
            _ = c.usleep(250_000);
        }
        if (!gone) return "navigating away leaked the ephemeral cast session";
    }

    // Right again -> a FRESH controller and session (rebuild path).
    app.pressKey(vwin, "Right") catch return "injecting Right failed";
    if (!castWaitRgb(allocator, app, vwin, .{ 255, 0, 0 }, 40, true, 20_000))
        return "re-navigating to the cast never rendered again";

    // Right -> the TEXT item: the universal fallback renders the
    // file's bytes, and the outgoing controller dies here too (the
    // cast -> text teardown direction).
    app.pressKey(vwin, "Right") catch return "injecting Right failed";
    if (!castWaitRgb(allocator, app, vwin, .{ 255, 0, 0 }, 40, false, 15_000))
        return "navigating to the text item did not clear the cast frame";
    {
        var gone = false;
        var t: u32 = 0;
        while (t < 10_000) : (t += 250) {
            var list_buf: [16384]u8 = undefined;
            const listing = castListSessions(allocator, mux_sock, &list_buf);
            if (std.mem.indexOf(u8, listing, "\"name\":\"cast") == null) {
                gone = true;
                break;
            }
            _ = c.usleep(250_000);
        }
        if (!gone) return "navigating cast -> text leaked the ephemeral cast session";
    }
    if (!viewerWaitOcr(allocator, app, vwin, "QUILL", 25_000))
        return "the text item's content never rendered (no QUILL in the OCR text)";

    // Right -> the BINARY item: classic hexdump, ASCII gutter included.
    app.pressKey(vwin, "Right") catch return "injecting Right failed";
    if (!viewerWaitOcr(allocator, app, vwin, "HEXPROOF", 25_000))
        return "the binary item's hex dump never rendered (no HEXPROOF in the OCR text)";

    // Left -> text again (the backwards direction into text).
    app.pressKey(vwin, "Left") catch return "injecting Left failed";
    if (!viewerWaitOcr(allocator, app, vwin, "QUILL", 25_000))
        return "navigating back to the text item did not restore its content";

    // Left -> the cast: a fresh controller in the backwards direction.
    app.pressKey(vwin, "Left") catch return "injecting Left failed";
    if (!castWaitRgb(allocator, app, vwin, .{ 255, 0, 0 }, 40, true, 20_000))
        return "navigating text -> cast never rendered the recording";

    // WM close -> clean exit, and the second session dies too.
    app.closeWindow(vwin) catch return "closing the viewer window failed";
    {
        var status: c_int = 0;
        var reaped = false;
        var t: u32 = 0;
        while (t < 15_000) : (t += 100) {
            if (c.waitpid(vcast_pid, &status, c.WNOHANG) == vcast_pid) {
                reaped = true;
                break;
            }
            _ = c.usleep(100_000);
        }
        if (!reaped) return "the viewer did not exit on window close";
        vcast_pid = -1;
        if (!(c.WIFEXITED(status) and c.WEXITSTATUS(status) == 0))
            return "the viewer exited abnormally on window close";
    }
    {
        var gone = false;
        var t: u32 = 0;
        while (t < 10_000) : (t += 250) {
            var list_buf: [16384]u8 = undefined;
            const listing = castListSessions(allocator, mux_sock, &list_buf);
            if (std.mem.indexOf(u8, listing, "\"name\":\"cast") == null) {
                gone = true;
                break;
            }
            _ = c.usleep(250_000);
        }
        if (!gone) return "closing the viewer did not kill the ephemeral cast session";
    }
    _ = app.drainLive(2_000);
    return null;
}

/// Wait until `win_id` is gone from the compositor roster.
///
/// Two things make this a WALL-CLOCK wait with `drainLive` in it
/// rather than a `pumpOnce` loop counted in iterations. A destroyed
/// toplevel usually reaches the driver only through a daemon RESYNC:
/// while an app streams pixels faster than this process consumes them
/// the daemon withholds its frames (`native_gap`) — the surface-destroy
/// request among them — and replays the live mirror later, where the
/// dead window simply no longer appears. And `pumpOnce` returns
/// immediately whenever a frame is queued, so a loop that adds its
/// timeout in fixed steps burns a nominal 10s in under a second
/// exactly when frames ARE flowing, i.e. exactly when the resync has
/// not landed yet.
fn waitWindowGone(app: *appdrive.App, win_id: u32, timeout_ms: i64) bool {
    const deadline = clock.nowMs() + timeout_ms;
    while (clock.nowMs() < deadline) {
        if (app.winById(win_id) == null) return true;
        _ = app.drainLive(500);
        if (app.winById(win_id) == null) return true;
        _ = app.pumpOnce(200);
    }
    return app.winById(win_id) == null;
}

/// Files' Quick Look, hosted by the shared Viewer. What only a live
/// run can prove: Space in a real `sketerm files` window opens a
/// ViewerWindow on the FOCUSED entry, the batch follows the rendered
/// listing (Right lands on the next file), Space closes the window
/// through the viewer's own quick-look key handling, and the tracked
/// pointer on the BrowserView really clears (a second Space reopens).
fn quickLookStage(allocator: std.mem.Allocator, app: *appdrive.App, rt: []const u8, wl: [*:0]const u8) ?[]const u8 {
    _ = app.drainLive(2_000);

    // Two text files with distinct OCR tokens, in a directory of their
    // own so the display order is exactly known (aaa before bbb).
    var dir_buf: [512:0]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/qlfiles", .{rt}) catch return "quick look dir path too long";
    _ = c.mkdir(dir.ptr, 0o700);
    var path_buf: [560:0]u8 = undefined;
    {
        const first = std.fmt.bufPrintZ(&path_buf, "{s}/aaa-first.txt", .{dir}) catch return "quick look path too long";
        const body = "SKETERM QUICKLOOK QLALPHA\n" ** 10;
        const f = c.fopen(first.ptr, "wb") orelse return "could not write the first quick-look file";
        const ok = c.fwrite(body.ptr, 1, body.len, f) == body.len;
        _ = c.fclose(f);
        if (!ok) return "short write on the first quick-look file";
    }
    {
        const second = std.fmt.bufPrintZ(&path_buf, "{s}/bbb-second.txt", .{dir}) catch return "quick look path too long";
        const body = "SKETERM QUICKLOOK QLBRAVO\n" ** 10;
        const f = c.fopen(second.ptr, "wb") orelse return "could not write the second quick-look file";
        const ok = c.fwrite(body.ptr, 1, body.len, f) == body.len;
        _ = c.fclose(f);
        if (!ok) return "short write on the second quick-look file";
    }

    var known: [16]u32 = undefined;
    var n_known: usize = 0;
    for (app.windows.items) |w| {
        if (w.popup or n_known >= known.len) continue;
        known[n_known] = w.id;
        n_known += 1;
    }

    const pid = c.fork();
    if (pid < 0) return "fork for the files window failed";
    if (pid == 0) {
        dieWithParent();
        // Its own app id (files mode appends its .files suffix), so it
        // never joins the terminal instance in this session.
        _ = c.setenv("SKETERM_APP_ID", "dev.sker.sketerm.e2eql", 1);
        _ = c.setenv("WAYLAND_DISPLAY", wl, 1);
        _ = c.setenv("GDK_BACKEND", "wayland", 1);
        _ = c.unsetenv("DISPLAY");
        _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
        _ = c.setenv("GTK_A11Y", "none", 1);
        const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm", "files", dir.ptr, null };
        _ = c.execv("zig-out/bin/sketerm", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    qlfiles_pid = pid;

    var waited: u32 = 0;
    const files_win = while (waited < 25_000) : (waited += 200) {
        if (hasToplevelOtherThan(app, known[0..n_known])) |id| break id;
        _ = app.pumpOnce(200);
    } else return "sketerm files never mapped a window";
    _ = app.waitVisualSettle(files_win, 400, 15_000, 0.002, null);
    if (n_known < known.len) {
        known[n_known] = files_win;
        n_known += 1;
    }

    // Focus the listing (a click on its empty lower half), then focus
    // the first row via type-ahead. Escape clears the prefix so the
    // Space that follows is a Quick Look toggle, not type-ahead input.
    const fw = app.winById(files_win) orelse return "the files window vanished";
    app.clickEx(files_win, @as(f64, @floatFromInt(fw.w)) * 0.55, @as(f64, @floatFromInt(fw.h)) * 0.6, 1, 60, 1) catch return "clicking the listing failed";
    _ = app.pumpOnce(300);
    app.pressKey(files_win, "a") catch return "injecting the type-ahead key failed";
    _ = app.pumpOnce(300);
    app.pressKey(files_win, "Escape") catch return "injecting Escape failed";
    _ = app.pumpOnce(200);
    app.pressKey(files_win, "space") catch return "injecting Space failed";

    waited = 0;
    const ql_win = while (waited < 25_000) : (waited += 200) {
        if (hasToplevelOtherThan(app, known[0..n_known])) |id| break id;
        _ = app.pumpOnce(200);
    } else return "Space did not open a quick-look viewer window";
    _ = app.waitVisualSettle(ql_win, 400, 10_000, 0.002, null);
    if (!viewerWaitOcr(allocator, app, ql_win, "QLALPHA", 25_000))
        return "the quick-look viewer never showed the focused file's content";

    // Right steps to the NEXT listing entry inside the viewer.
    app.pressKey(ql_win, "Right") catch return "injecting Right failed";
    if (!viewerWaitOcr(allocator, app, ql_win, "QLBRAVO", 25_000))
        return "Right did not step the quick-look batch to the next file";

    // Space closes (quick-look semantics inside the shared viewer).
    app.pressKey(ql_win, "space") catch return "injecting the closing Space failed";
    if (!waitWindowGone(app, ql_win, 15_000))
        return "Space did not close the quick-look viewer";

    // The browser survived AND its tracked pointer cleared: a second
    // Space must open a FRESH viewer (a stale pointer would make the
    // toggle a silent no-op close instead).
    if (app.winById(files_win) == null) return "the files window died with its quick-look viewer";
    app.pressKey(files_win, "space") catch return "injecting the reopening Space failed";
    waited = 0;
    const ql2 = while (waited < 25_000) : (waited += 200) {
        if (hasToplevelOtherThan(app, known[0..n_known])) |id| break id;
        _ = app.pumpOnce(200);
    } else return "a second Space did not reopen the quick-look viewer";
    // Let the fresh window finish mapping before keying into it.
    _ = app.waitVisualSettle(ql2, 300, 8_000, 0.002, null);
    app.pressKey(ql2, "space") catch return "injecting the second closing Space failed";
    if (!waitWindowGone(app, ql2, 15_000)) {
        dumpWindowRoster(app, "quick look: reopened viewer did not close");
        if (app.screenshotPng(ql2, 1024, null, 0)) |shot| {
            defer allocator.free(shot.png);
            writePng("/tmp/sketerm-e2e-ql2-fail.png", shot.png);
        } else |_| {}
        return "the reopened quick-look viewer did not close";
    }

    _ = c.kill(qlfiles_pid, c.SIGKILL);
    var qst: c_int = 0;
    _ = c.waitpid(qlfiles_pid, &qst, 0);
    qlfiles_pid = -1;
    _ = app.drainLive(2_000);
    return null;
}

fn panelRelayCall(
    allocator: std.mem.Allocator,
    conn: *muxclient.Conn,
    id: u64,
    request: []const u8,
) ?[]u8 {
    conn.sendPanelRequest(id, request) catch return null;
    const frame = conn.recvExpectFor(&.{.panel_reply}, 45_000) catch return null;
    defer frame.deinit(allocator);
    const envelope = muxwire.decodePanelEnvelope(frame.payload) catch return null;
    if (envelope.id != id) return null;
    return allocator.dupe(u8, envelope.json) catch null;
}

/// A control-socket request whose reply is read LATER, on a connection of its
/// own, so a liveness probe on a SECOND connection can overlap the work the
/// request kicked off. `roundtrip` cannot express that: it blocks until the
/// reply lands, and by then nothing is in flight for a probe to trip over.
const PendingCall = struct {
    client: [*c]c.GSocketClient,
    conn: [*c]c.GSocketConnection,
    din: [*c]c.GDataInputStream,

    /// Connect and write the request line; the reply is deliberately unread.
    fn start(sock_path: [:0]const u8, line: []const u8) ?PendingCall {
        if (drive) |app| app.drain();
        const client = c.g_socket_client_new();
        const addr = c.g_unix_socket_address_new(sock_path.ptr);
        defer c.g_object_unref(addr);
        var gerr: [*c]c.GError = null;
        const conn = c.g_socket_client_connect(client, @ptrCast(@alignCast(addr)), null, &gerr);
        if (conn == null) {
            if (gerr != null) c.g_error_free(gerr);
            c.g_object_unref(client);
            return null;
        }
        const out_stream = c.g_io_stream_get_output_stream(@ptrCast(conn));
        var written: c.gsize = 0;
        if (c.g_output_stream_write_all(out_stream, line.ptr, line.len, &written, null, &gerr) == 0) {
            if (gerr != null) c.g_error_free(gerr);
            c.g_object_unref(conn);
            c.g_object_unref(client);
            return null;
        }
        return .{
            .client = client,
            .conn = conn,
            .din = c.g_data_input_stream_new(c.g_io_stream_get_input_stream(@ptrCast(conn))),
        };
    }

    /// Read the reply line. Caller frees; the call is consumed either way.
    fn finish(self: *PendingCall, allocator: std.mem.Allocator) ?[]u8 {
        defer {
            c.g_object_unref(self.din);
            c.g_object_unref(self.conn);
            c.g_object_unref(self.client);
        }
        var gerr: [*c]c.GError = null;
        var rlen: c.gsize = 0;
        const resp = c.g_data_input_stream_read_line(self.din, &rlen, null, &gerr);
        if (resp == null) {
            if (gerr != null) c.g_error_free(gerr);
            return null;
        }
        defer c.g_free(resp);
        return allocator.dupe(u8, resp[0..rlen]) catch null;
    }
};

/// One GTK-liveness probe: is the GUI still serving control requests, and
/// promptly? Only evidence while work is IN FLIGHT, so callers either overlap
/// it with a `PendingCall` or repeat it across the whole transition; a single
/// probe issued after the work completed cannot fail.
fn guiResponsive(allocator: std.mem.Allocator, sock_path: [:0]const u8) bool {
    const started = clock.nowMs();
    const resp = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse return false;
    defer allocator.free(resp);
    if (clock.nowMs() - started > 600) return false;
    return std.mem.indexOf(u8, resp, "\"ok\":true") != null;
}

/// Poll `panel-list` over a relay requester until EVERY needle is present, or
/// the deadline passes. Registry metadata (a session rename, for one) reaches
/// the GUI asynchronously, and this file's timings are load-bearing: a fixed
/// settle sleep is either flaky or needlessly slow, a bounded poll is neither.
fn waitPanelListMatch(
    allocator: std.mem.Allocator,
    conn: *muxclient.Conn,
    base_id: u64,
    needles: []const []const u8,
    timeout_ms: i64,
) bool {
    const deadline = clock.nowMs() + timeout_ms;
    var id = base_id;
    while (true) : (id += 1) {
        const list = panelRelayCall(allocator, conn, id, "{\"cmd\":\"panel-list\"}") orelse return false;
        defer allocator.free(list);
        var all = true;
        for (needles) |needle| {
            if (std.mem.indexOf(u8, list, needle) == null) all = false;
        }
        if (all) return true;
        if (clock.nowMs() >= deadline) return false;
        _ = c.usleep(100_000);
    }
}

fn listedPaneIds(allocator: std.mem.Allocator, gui_sock: [:0]const u8) ?[]u32 {
    const response = roundtrip(allocator, gui_sock, "{\"cmd\":\"list\"}\n") orelse return null;
    defer allocator.free(response);
    const PaneInfo = struct { id: u32 = 0 };
    const TabInfo = struct { panes: []const PaneInfo = &.{} };
    const Listing = struct {
        ok: bool = false,
        tabs: []const TabInfo = &.{},
    };
    var parsed = std.json.parseFromSlice(Listing, allocator, response, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    if (!parsed.value.ok) return null;
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(allocator);
    for (parsed.value.tabs) |tab| for (tab.panes) |pane| ids.append(allocator, pane.id) catch return null;
    return ids.toOwnedSlice(allocator) catch null;
}

/// The id of the first pane that appeared since `before`, polled to a
/// deadline. Several IPC commands create a pane without answering with its id;
/// this is how a later teardown can still be fenced on that exact pane.
fn newPaneId(allocator: std.mem.Allocator, gui_sock: [:0]const u8, before: []const u32, ms: u32) ?u32 {
    var waited: u32 = 0;
    while (true) {
        if (listedPaneIds(allocator, gui_sock)) |now| {
            defer allocator.free(now);
            for (now) |id| {
                var seen = false;
                for (before) |old| {
                    if (old == id) seen = true;
                }
                if (!seen) return id;
            }
        }
        if (waited >= ms) return null;
        _ = c.usleep(100_000);
        waited += 100;
    }
}

fn attachDuplicateGuiPane(
    allocator: std.mem.Allocator,
    gui_sock: [:0]const u8,
    mux_sock: []const u8,
    session: []const u8,
) ?u32 {
    const before = listedPaneIds(allocator, gui_sock) orelse return null;
    defer allocator.free(before);
    var request_buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(
        &request_buf,
        "{{\"cmd\":\"attach-session\",\"data\":\"{s}\",\"host\":\"sock:{s}\"}}\n",
        .{ session, mux_sock },
    ) catch return null;
    const attached = roundtrip(allocator, gui_sock, request) orelse return null;
    defer allocator.free(attached);
    if (std.mem.indexOf(u8, attached, "\"ok\":true") == null) return null;

    var waited: u32 = 0;
    while (waited <= 10_000) : (waited += 100) {
        const after = listedPaneIds(allocator, gui_sock) orelse return null;
        defer allocator.free(after);
        for (after) |candidate| {
            var existed = false;
            for (before) |old| if (candidate == old) {
                existed = true;
                break;
            };
            if (!existed) return candidate;
        }
        _ = c.usleep(100_000);
    }
    return null;
}

fn closeGuiPaneAndWait(allocator: std.mem.Allocator, gui_sock: [:0]const u8, pane: u32) bool {
    var request_buf: [128]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "{{\"cmd\":\"close-pane\",\"pane\":{d}}}\n", .{pane}) catch return false;
    const closed = roundtrip(allocator, gui_sock, request) orelse return false;
    defer allocator.free(closed);
    return std.mem.indexOf(u8, closed, "\"ok\":true") != null and
        waitPaneGone(allocator, gui_sock, pane, 10_000);
}

/// Real daemon -> real GUI Terminal -> native panelhost -> correlated daemon
/// reply, without involving MCP routing.
fn panelRelayGuiStage(
    allocator: std.mem.Allocator,
    mux_sock: []const u8,
    session: []const u8,
    gui_sock: [:0]const u8,
) ?[]const u8 {
    var requester = muxclient.connectPanelRequester(allocator, mux_sock, session, 10_000) catch
        return "could not attach a panel-only requester to the GUI's terminal session";
    defer requester.deinit();

    const shown = panelRelayCall(
        allocator,
        &requester,
        0x501,
        "{\"cmd\":\"panel-show\",\"name\":\"relay-native\",\"session\":\"forged\"," ++
            "\"pane\":4294967295,\"target\":\"pane\"," ++
            "\"document\":\"{\\\"title\\\":\\\"Relay Native\\\",\\\"root\\\":\\\"r\\\"," ++
            "\\\"components\\\":{\\\"r\\\":{\\\"type\\\":\\\"heading\\\",\\\"text\\\":\\\"Relayed\\\",\\\"level\\\":1}}}\"}",
    ) orelse return "the GUI did not return the correlated panel-show reply";
    defer allocator.free(shown);
    if (std.mem.indexOf(u8, shown, "\"ok\":true") == null)
        return "the GUI rejected a valid relayed panel document";
    const panel_id = parseNumAfter(shown, "\"panel_id\":") orelse
        return "the relayed panel-show reply had no panel_id";
    var session_needle_buf: [96]u8 = undefined;
    const session_needle = std.fmt.bufPrint(&session_needle_buf, "\"session\":\"{s}\"", .{session}) catch
        return "the GUI session name was too long";
    if (std.mem.indexOf(u8, shown, session_needle) == null)
        return "relay dispatch trusted the request's forged session instead of the receiving Terminal";

    // Direct GUI IPC is a separate namespace: neither a guessed relay id nor
    // an unfiltered list may cross into the mux-origin registry.
    var direct_get_buf: [96]u8 = undefined;
    const direct_get_req = std.fmt.bufPrint(&direct_get_buf, "{{\"cmd\":\"panel-get\",\"panel_id\":{d}}}\n", .{panel_id}) catch
        return "formatting direct namespace probe failed";
    const direct_get = roundtrip(allocator, gui_sock, direct_get_req) orelse
        return "direct namespace panel-get did not answer";
    defer allocator.free(direct_get);
    if (std.mem.indexOf(u8, direct_get, "\"ok\":false") == null)
        return "direct GUI IPC reached a mux-origin panel id";
    const direct_list = roundtrip(allocator, gui_sock, "{\"cmd\":\"panel-list\"}\n") orelse
        return "direct namespace panel-list did not answer";
    defer allocator.free(direct_list);
    if (std.mem.indexOf(u8, direct_list, "relay-native") != null)
        return "direct GUI IPC listed a mux-origin panel";

    // Rename through the daemon. The panel remains keyed by immutable origin,
    // while list/get metadata deliberately follows the mutable display name.
    var admin = muxclient.Conn.connectProbed(allocator, mux_sock) catch
        return "could not connect for relay rename regression";
    defer admin.deinit();
    const renamed_session = "relay-renamed";
    admin.sendJson(.rename, .{ .name = session, .new_name = renamed_session }) catch
        return "could not send relay session rename";
    (admin.recvExpectFor(&.{.ok}, 5_000) catch return "relay session rename was not acknowledged").deinit(allocator);
    if (!waitPanelListMatch(
        allocator,
        &requester,
        0x5011,
        &.{ "relay-native", "\"session\":\"relay-renamed\"" },
        10_000,
    )) return "session rename orphaned the relay panel or left stale metadata";
    admin.sendJson(.rename, .{ .name = renamed_session, .new_name = session }) catch
        return "could not restore relay session name";
    (admin.recvExpectFor(&.{.ok}, 5_000) catch return "restoring relay session name was not acknowledged").deinit(allocator);
    if (!waitPanelListMatch(allocator, &requester, 0x5100, &.{ "relay-native", session_needle }, 10_000))
        return "restoring the relay session name left stale panel metadata";

    var patch_buf: [256]u8 = undefined;
    const patch = std.fmt.bufPrint(
        &patch_buf,
        "{{\"cmd\":\"panel-patch\",\"panel_id\":{d},\"patch\":\"[{{\\\"op\\\":\\\"title\\\",\\\"value\\\":\\\"Relayed 2\\\"}}]\"}}",
        .{panel_id},
    ) catch return "relay patch request formatting failed";
    const patched = panelRelayCall(allocator, &requester, 0x502, patch) orelse
        return "the GUI did not return the correlated panel-patch reply";
    defer allocator.free(patched);
    if (std.mem.indexOf(u8, patched, "\"ok\":true") == null)
        return "relayed panel-patch failed";

    var close_buf: [96]u8 = undefined;
    const close = std.fmt.bufPrint(&close_buf, "{{\"cmd\":\"panel-close\",\"panel_id\":{d}}}", .{panel_id}) catch
        return "relay close request formatting failed";
    const closed = panelRelayCall(allocator, &requester, 0x503, close) orelse
        return "the GUI did not return the correlated panel-close reply";
    defer allocator.free(closed);
    if (std.mem.indexOf(u8, closed, "\"ok\":true") == null)
        return "relayed panel-close failed";

    // One relay scope hosts many panels at once across all three targets,
    // same-name replacement reuses the panel in place rather than adding
    // another, and every one of them closes cleanly.
    var many_ids: [12]u32 = undefined;
    for (&many_ids, 0..) |*id, i| {
        const target = if (i == 0) "pane" else if (i % 2 == 0) "tab" else "window";
        var request_buf: [640]u8 = undefined;
        const request = std.fmt.bufPrint(
            &request_buf,
            "{{\"cmd\":\"panel-show\",\"name\":\"many-{d}\",\"target\":\"{s}\"," ++
                "\"document\":\"{{\\\"root\\\":\\\"t\\\",\\\"components\\\":{{\\\"t\\\":{{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"panel {d}\\\"}}}}}}\"}}",
            .{ i, target, i },
        ) catch return "formatting a multi-panel show failed";
        const response = panelRelayCall(allocator, &requester, 0x800 + i, request) orelse
            return "multi-panel show timed out";
        defer allocator.free(response);
        if (std.mem.indexOf(u8, response, "\"ok\":true") == null)
            return "one of many concurrent panels in a single relay scope was rejected";
        id.* = parseNumAfter(response, "\"panel_id\":") orelse
            return "multi-panel show returned no panel id";
    }
    const replaced = panelRelayCall(
        allocator,
        &requester,
        0x821,
        "{\"cmd\":\"panel-show\",\"name\":\"many-0\",\"target\":\"pane\"," ++
            "\"document\":\"{\\\"root\\\":\\\"t\\\",\\\"components\\\":{\\\"t\\\":{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"replacement\\\"}}}\"}",
    ) orelse return "same-name replacement timed out";
    defer allocator.free(replaced);
    if (std.mem.indexOf(u8, replaced, "\"ok\":true") == null or
        parseNumAfter(replaced, "\"panel_id\":") != many_ids[0])
        return "same-name panel replacement did not reuse the live panel";

    for (many_ids, 0..) |id, i| {
        var close_buf_many: [96]u8 = undefined;
        const close_many = std.fmt.bufPrint(&close_buf_many, "{{\"cmd\":\"panel-close\",\"panel_id\":{d}}}", .{id}) catch
            return "formatting multi-panel cleanup failed";
        const response = panelRelayCall(allocator, &requester, 0x830 + i, close_many) orelse
            return "multi-panel cleanup timed out";
        defer allocator.free(response);
        if (std.mem.indexOf(u8, response, "\"ok\":true") == null)
            return "multi-panel cleanup failed";
    }

    const close_order_base = panelRelayCall(
        allocator,
        &requester,
        0x850,
        "{\"cmd\":\"panel-show\",\"name\":\"close-ordered\",\"target\":\"pane\"," ++
            "\"document\":\"{\\\"root\\\":\\\"t\\\",\\\"components\\\":{\\\"t\\\":{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"base\\\"}}}\"}",
    ) orelse return "ordered-close base panel timed out";
    defer allocator.free(close_order_base);
    const close_order_id = parseNumAfter(close_order_base, "\"panel_id\":") orelse
        return "ordered-close base panel returned no id";
    requester.sendPanelRequest(
        0x851,
        "{\"cmd\":\"panel-show\",\"name\":\"close-ordered\",\"target\":\"pane\"," ++
            "\"document\":\"{\\\"root\\\":\\\"img\\\",\\\"components\\\":{\\\"img\\\":{\\\"type\\\":\\\"image\\\",\\\"src\\\":\\\"/proc/self/exe\\\"}}}\"}",
    ) catch return "could not send older hydrated show before close";
    var close_order_buf: [96]u8 = undefined;
    const close_order_req = std.fmt.bufPrint(
        &close_order_buf,
        "{{\"cmd\":\"panel-close\",\"panel_id\":{d}}}",
        .{close_order_id},
    ) catch return "formatting ordered close failed";
    requester.sendPanelRequest(0x852, close_order_req) catch
        return "could not send close behind older hydrated show";

    const close_order_first = requester.recvExpectFor(&.{.panel_reply}, 45_000) catch
        return "older hydrated show did not resolve before close";
    defer close_order_first.deinit(allocator);
    const close_order_first_env = muxwire.decodePanelEnvelope(close_order_first.payload) catch
        return "older hydrated show returned a malformed reply";
    if (close_order_first_env.id != 0x851 or
        std.mem.indexOf(u8, close_order_first_env.json, "\"ok\":true") == null or
        parseNumAfter(close_order_first_env.json, "\"panel_id\":") != close_order_id)
        return "panel-close overtook the older hydrated show";
    const close_order_second = requester.recvExpectFor(&.{.panel_reply}, 45_000) catch
        return "queued panel-close never resolved";
    defer close_order_second.deinit(allocator);
    const close_order_second_env = muxwire.decodePanelEnvelope(close_order_second.payload) catch
        return "queued panel-close returned a malformed reply";
    if (close_order_second_env.id != 0x852 or
        std.mem.indexOf(u8, close_order_second_env.json, "\"ok\":true") == null)
        return "queued panel-close failed after the older show";
    const after_ordered_close = panelRelayCall(allocator, &requester, 0x853, "{\"cmd\":\"panel-list\"}") orelse
        return "panel-list after ordered close timed out";
    defer allocator.free(after_ordered_close);
    if (std.mem.indexOf(u8, after_ordered_close, "close-ordered") != null)
        return "an older hydrated show recreated its panel after close success";

    // The default target is a fresh tab. Send without waiting, then prove the
    // GUI socket remains serviceable while daemon connect/spawn/attach runs on
    // the worker; finally consume the correlated reply and close the tab.
    requester.sendPanelRequest(
        0x504,
        "{\"cmd\":\"panel-show\",\"name\":\"relay-tab\",\"document\":\"{\\\"root\\\":\\\"t\\\",\\\"components\\\":{\\\"t\\\":{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"async tab\\\"}}}\"}",
    ) catch return "could not send relayed tab panel";
    const responsive = roundtrip(allocator, gui_sock, "{\"cmd\":\"screen-info\",\"pane\":1}\n") orelse
        return "GTK stopped serving while the relayed tab transport was prepared";
    defer allocator.free(responsive);
    if (std.mem.indexOf(u8, responsive, "\"ok\":true") == null)
        return "GUI health probe failed during relayed tab setup";
    const tab_frame = requester.recvExpectFor(&.{.panel_reply}, 45_000) catch
        return "the asynchronous relayed tab never replied";
    defer tab_frame.deinit(allocator);
    const tab_envelope = muxwire.decodePanelEnvelope(tab_frame.payload) catch
        return "the asynchronous relayed tab returned a malformed envelope";
    if (tab_envelope.id != 0x504 or std.mem.indexOf(u8, tab_envelope.json, "\"ok\":true") == null)
        return "the asynchronous relayed tab returned the wrong correlated result";
    const tab_id = parseNumAfter(tab_envelope.json, "\"panel_id\":") orelse
        return "the asynchronous relayed tab returned no panel id";
    var tab_close_buf: [96]u8 = undefined;
    const tab_close_req = std.fmt.bufPrint(&tab_close_buf, "{{\"cmd\":\"panel-close\",\"panel_id\":{d}}}", .{tab_id}) catch
        return "formatting asynchronous tab close failed";
    const tab_closed = panelRelayCall(allocator, &requester, 0x505, tab_close_req) orelse
        return "closing the asynchronous relayed tab timed out";
    defer allocator.free(tab_closed);
    if (std.mem.indexOf(u8, tab_closed, "\"ok\":true") == null)
        return "closing the asynchronous relayed tab failed";

    // A deferred older show and an immediate newer show for the same name must
    // commit in request order. Before tab jobs occupied the origin slot, the
    // newer pane show replied first and the old worker later overwrote it.
    requester.sendPanelRequest(
        0x506,
        "{\"cmd\":\"panel-show\",\"name\":\"relay-ordered\",\"target\":\"tab\"," ++
            "\"document\":\"{\\\"root\\\":\\\"t\\\",\\\"components\\\":{\\\"t\\\":{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"older deferred\\\"}}}\"}",
    ) catch return "could not send the older ordered panel show";
    requester.sendPanelRequest(
        0x507,
        "{\"cmd\":\"panel-show\",\"name\":\"relay-ordered\",\"target\":\"pane\"," ++
            "\"document\":\"{\\\"root\\\":\\\"t\\\",\\\"components\\\":{\\\"t\\\":{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"newest committed\\\"}}}\"}",
    ) catch return "could not send the newer ordered panel show";
    const ordered_first = requester.recvExpectFor(&.{.panel_reply}, 45_000) catch
        return "the older ordered panel show never replied";
    defer ordered_first.deinit(allocator);
    const ordered_first_env = muxwire.decodePanelEnvelope(ordered_first.payload) catch
        return "the older ordered panel show returned a malformed envelope";
    if (ordered_first_env.id != 0x506 or std.mem.indexOf(u8, ordered_first_env.json, "\"ok\":true") == null)
        return "a newer panel show committed before the older deferred show";
    const ordered_id = parseNumAfter(ordered_first_env.json, "\"panel_id\":") orelse
        return "the older ordered panel show returned no panel id";
    const ordered_second = requester.recvExpectFor(&.{.panel_reply}, 45_000) catch
        return "the newer ordered panel show never replied";
    defer ordered_second.deinit(allocator);
    const ordered_second_env = muxwire.decodePanelEnvelope(ordered_second.payload) catch
        return "the newer ordered panel show returned a malformed envelope";
    if (ordered_second_env.id != 0x507 or std.mem.indexOf(u8, ordered_second_env.json, "\"ok\":true") == null or
        parseNumAfter(ordered_second_env.json, "\"panel_id\":") != ordered_id)
        return "the queued newer panel show did not replace the older panel deterministically";
    var ordered_get_buf: [96]u8 = undefined;
    const ordered_get_req = std.fmt.bufPrint(&ordered_get_buf, "{{\"cmd\":\"panel-get\",\"panel_id\":{d}}}", .{ordered_id}) catch
        return "formatting ordered panel-get failed";
    const ordered_live = panelRelayCall(allocator, &requester, 0x508, ordered_get_req) orelse
        return "ordered panel-get timed out";
    defer allocator.free(ordered_live);
    if (std.mem.indexOf(u8, ordered_live, "newest committed") == null or
        std.mem.indexOf(u8, ordered_live, "older deferred") != null)
        return "the older deferred show overwrote the newer panel document";
    var ordered_close_buf: [96]u8 = undefined;
    const ordered_close_req = std.fmt.bufPrint(&ordered_close_buf, "{{\"cmd\":\"panel-close\",\"panel_id\":{d}}}", .{ordered_id}) catch
        return "formatting ordered panel close failed";
    const ordered_closed = panelRelayCall(allocator, &requester, 0x509, ordered_close_req) orelse
        return "closing the ordered panel timed out";
    defer allocator.free(ordered_closed);
    if (std.mem.indexOf(u8, ordered_closed, "\"ok\":true") == null)
        return "closing the ordered panel failed";

    // Destroy a GUI-attached session and immediately reuse its name. The
    // recorded origin_id must fence the replacement: it may exist, but it must
    // have no GUI presenter and therefore cannot inherit the old pane.
    const reuse_session = "relay-reconnect-reuse";
    admin.sendJson(.spawn, .{
        .name = reuse_session,
        .argv = [_][]const u8{ "sh", "-c", "while :; do sleep 30; done" },
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
        .ttl_secs = @as(u32, 120),
    }) catch return "could not spawn reconnect identity fixture";
    (admin.recvExpectFor(&.{.ok}, 10_000) catch return "reconnect identity fixture spawn was not acknowledged").deinit(allocator);
    var attach_buf: [1024]u8 = undefined;
    const attach_req = std.fmt.bufPrint(
        &attach_buf,
        "{{\"cmd\":\"attach-session\",\"data\":\"{s}\",\"host\":\"sock:{s}\"}}\n",
        .{ reuse_session, mux_sock },
    ) catch return "formatting reconnect identity attach failed";
    const attached = roundtrip(allocator, gui_sock, attach_req) orelse
        return "reconnect identity GUI attach timed out";
    defer allocator.free(attached);
    if (std.mem.indexOf(u8, attached, "\"ok\":true") == null)
        return "GUI refused the reconnect identity fixture";
    _ = c.usleep(250_000);

    var old_lifetime = muxclient.connectPanelRequester(allocator, mux_sock, reuse_session, 10_000) catch
        return "could not attach to the old reconnect fixture lifetime";
    defer old_lifetime.deinit();
    const old_ready = panelRelayCall(allocator, &old_lifetime, 0x570, "{\"cmd\":\"panel-list\"}") orelse
        return "old reconnect fixture had no GUI presenter";
    defer allocator.free(old_ready);
    if (std.mem.indexOf(u8, old_ready, "\"ok\":true") == null)
        return "old reconnect fixture presenter was not ready";
    admin.sendJson(.kill, .{ .name = reuse_session }) catch return "could not kill old reconnect fixture";
    (admin.recvExpectFor(&.{.ok}, 10_000) catch return "old reconnect fixture kill was not acknowledged").deinit(allocator);
    admin.sendJson(.spawn, .{
        .name = reuse_session,
        .argv = [_][]const u8{ "sh", "-c", "while :; do sleep 30; done" },
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
        .ttl_secs = @as(u32, 120),
    }) catch return "could not spawn same-name reconnect replacement";
    (admin.recvExpectFor(&.{.ok}, 10_000) catch return "same-name reconnect replacement spawn was not acknowledged").deinit(allocator);

    // Positive fence first: the OLD lifetime must be provably gone before its
    // absence can mean anything. Our requester on that lifetime stops
    // answering at the same moment the GUI's own connection to it dies, which
    // is what starts the GUI's reconnect-by-name cycle.
    {
        const gone_deadline = clock.nowMs() + 10_000;
        var id: u64 = 0x571;
        while (true) : (id += 1) {
            const still = panelRelayCall(allocator, &old_lifetime, id, "{\"cmd\":\"panel-list\"}");
            if (still == null) break;
            allocator.free(still.?);
            if (clock.nowMs() >= gone_deadline)
                return "the killed reconnect fixture lifetime kept answering panel calls";
            _ = c.usleep(100_000);
        }
    }

    // Then hold the refusal across a window several GUI reconnect cycles long
    // (the retry backoff starts at 1s), re-attaching a fresh requester every
    // round so no cached connection can carry the verdict, and requiring the
    // refusal at EVERY sample including the last one. Residual weakness,
    // stated plainly: refusing adoption produces no daemon- or socket-visible
    // event of its own (the GUI simply declines to register as a presenter),
    // so this samples an absence rather than fencing on a positive
    // transition. The bounded window, not a single sleep, is what makes a
    // late adoption fail the stage.
    {
        const hold_deadline = clock.nowMs() + 6_000;
        var id: u64 = 0x5720;
        while (true) : (id += 1) {
            var replacement = muxclient.connectPanelRequester(allocator, mux_sock, reuse_session, 10_000) catch
                return "could not inspect same-name reconnect replacement";
            defer replacement.deinit();
            const replacement_list = panelRelayCall(allocator, &replacement, id, "{\"cmd\":\"panel-list\"}") orelse
                return "same-name reconnect replacement panel probe timed out";
            defer allocator.free(replacement_list);
            if (std.mem.indexOf(u8, replacement_list, "no compatible GUI") == null)
                return "GUI Terminal adopted a same-name session replacement with a different origin_id";
            if (clock.nowMs() >= hold_deadline) break;
            _ = c.usleep(500_000);
        }
    }

    var close_reuse_buf: [128]u8 = undefined;
    const close_reuse_req = std.fmt.bufPrint(&close_reuse_buf, "{{\"cmd\":\"close-pane\",\"session\":\"{s}\"}}\n", .{reuse_session}) catch
        return "formatting reconnect fixture pane close failed";
    const reuse_closed = roundtrip(allocator, gui_sock, close_reuse_req) orelse
        return "closing reconnect fixture pane timed out";
    defer allocator.free(reuse_closed);
    if (std.mem.indexOf(u8, reuse_closed, "\"ok\":true") == null)
        return "closing the unavailable reconnect fixture pane failed";
    admin.sendJson(.kill, .{ .name = reuse_session }) catch return "could not clean up reconnect replacement";
    (admin.recvExpectFor(&.{.ok}, 10_000) catch return "reconnect replacement cleanup was not acknowledged").deinit(allocator);

    // Two GUI attachments of one session in this process share one
    // origin_id-keyed panel scope. The oldest receives the first route; after
    // it closes, its target:pane face must move to the surviving duplicate
    // without changing the pane tree or panel id. Closing the survivor is the
    // permanent last-viewer boundary and must remove that shared scope.
    const duplicate_session = "relay-duplicate-scope";
    admin.sendJson(.spawn, .{
        .name = duplicate_session,
        .argv = [_][]const u8{ "sh", "-c", "while :; do sleep 30; done" },
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
        .ttl_secs = @as(u32, 120),
    }) catch return "could not spawn duplicate panel-scope fixture";
    (admin.recvExpectFor(&.{.ok}, 10_000) catch return "duplicate panel-scope spawn was not acknowledged").deinit(allocator);
    const first_duplicate = attachDuplicateGuiPane(allocator, gui_sock, mux_sock, duplicate_session) orelse
        return "could not attach the first duplicate GUI pane";
    const second_duplicate = attachDuplicateGuiPane(allocator, gui_sock, mux_sock, duplicate_session) orelse
        return "could not attach the second duplicate GUI pane";
    if (first_duplicate == second_duplicate) return "duplicate GUI attachments reused one pane identity";

    var duplicate_requester = muxclient.connectPanelRequester(allocator, mux_sock, duplicate_session, 10_000) catch
        return "could not attach the duplicate-scope panel requester";
    defer duplicate_requester.deinit();
    const duplicate_shown = panelRelayCall(
        allocator,
        &duplicate_requester,
        0x580,
        "{\"cmd\":\"panel-show\",\"name\":\"duplicate-shared\",\"target\":\"pane\"," ++
            "\"document\":\"{\\\"root\\\":\\\"t\\\",\\\"components\\\":{\\\"t\\\":{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"shared session panel\\\"}}}\"}",
    ) orelse return "duplicate-scope panel show timed out";
    defer allocator.free(duplicate_shown);
    if (std.mem.indexOf(u8, duplicate_shown, "\"ok\":true") == null)
        return "duplicate-scope panel show failed";
    const duplicate_panel_id = parseNumAfter(duplicate_shown, "\"panel_id\":") orelse
        return "duplicate-scope panel show returned no id";

    if (!closeGuiPaneAndWait(allocator, gui_sock, first_duplicate))
        return "closing the oldest duplicate GUI pane did not finish";
    var duplicate_get_buf: [128]u8 = undefined;
    const duplicate_get_req = std.fmt.bufPrint(
        &duplicate_get_buf,
        "{{\"cmd\":\"panel-get\",\"panel_id\":{d}}}",
        .{duplicate_panel_id},
    ) catch return "formatting duplicate-scope panel-get failed";
    var duplicate_rehosted = false;
    var duplicate_get_try: u64 = 0;
    while (duplicate_get_try < 100) : (duplicate_get_try += 1) {
        const duplicate_state = panelRelayCall(
            allocator,
            &duplicate_requester,
            0x581 + duplicate_get_try,
            duplicate_get_req,
        ) orelse return "surviving duplicate GUI pane could not read the shared panel";
        defer allocator.free(duplicate_state);
        if (std.mem.indexOf(u8, duplicate_state, "shared session panel") != null) {
            duplicate_rehosted = true;
            break;
        }
        // Teardown/rehost is asynchronous: a probe may land in the window
        // where the departing attachment's route fails. Any non-ok reply is
        // a transient; a success without the document is a real regression.
        if (std.mem.indexOf(u8, duplicate_state, "\"ok\":true") != null)
            return "first duplicate teardown did not rehost the shared pane panel";
        _ = c.usleep(100_000);
    }
    if (!duplicate_rehosted)
        return "surviving duplicate presenter did not recover after pane rehost";
    const duplicate_list = panelRelayCall(allocator, &duplicate_requester, 0x5811, "{\"cmd\":\"panel-list\"}") orelse
        return "surviving duplicate GUI pane could not list the rehosted panel";
    defer allocator.free(duplicate_list);
    if (std.mem.indexOf(u8, duplicate_list, "\"target\":\"pane\"") == null)
        return "rehosted duplicate panel changed its target shape";

    if (!closeGuiPaneAndWait(allocator, gui_sock, second_duplicate))
        return "closing the last duplicate GUI pane did not finish";
    // With the last panel-capable attachment of this session gone, the next
    // request fails the route pre-delivery as `no_compatible_gui`.
    var presenter_gone = false;
    var presenter_try: u64 = 0;
    while (presenter_try < 100) : (presenter_try += 1) {
        const presenter_absent = panelRelayCall(
            allocator,
            &duplicate_requester,
            0x582 + presenter_try,
            "{\"cmd\":\"panel-list\"}",
        ) orelse return "last duplicate teardown did not resolve presenter absence";
        defer allocator.free(presenter_absent);
        if (std.mem.indexOf(u8, presenter_absent, "no_compatible_gui") != null) {
            presenter_gone = true;
            break;
        }
        _ = c.usleep(100_000);
    }
    if (!presenter_gone) return "last duplicate teardown left a compatible presenter attached";

    const replacement_duplicate = attachDuplicateGuiPane(allocator, gui_sock, mux_sock, duplicate_session) orelse
        return "could not reattach a duplicate GUI pane after last-viewer teardown";
    const after_last = panelRelayCall(allocator, &duplicate_requester, 0x600, "{\"cmd\":\"panel-list\"}") orelse
        return "reattached duplicate GUI pane did not answer panel-list";
    defer allocator.free(after_last);
    if (std.mem.indexOf(u8, after_last, "\"ok\":true") == null or
        std.mem.indexOf(u8, after_last, "duplicate-shared") != null)
        return "last-viewer teardown did not remove the shared panel registry";

    // Rehosting must never evict an unrelated panel already mounted on the
    // only survivor. In that shape there is no empty pane host: the panel on
    // the departing viewer closes, while the occupied survivor stays intact.
    const occupied_duplicate = attachDuplicateGuiPane(allocator, gui_sock, mux_sock, duplicate_session) orelse
        return "could not attach the occupied duplicate GUI pane";
    var occupied_show_buf: [640]u8 = undefined;
    const occupied_show_req = std.fmt.bufPrint(
        &occupied_show_buf,
        "{{\"cmd\":\"panel-show\",\"pane\":{d},\"name\":\"occupied-survivor\",\"target\":\"pane\"," ++
            "\"document\":\"{{\\\"root\\\":\\\"t\\\",\\\"components\\\":{{\\\"t\\\":{{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"survivor stays\\\"}}}}}}\"}}\n",
        .{occupied_duplicate},
    ) catch return "formatting occupied-survivor panel show failed";
    const occupied_shown = roundtrip(allocator, gui_sock, occupied_show_req) orelse
        return "occupied-survivor panel show timed out";
    defer allocator.free(occupied_shown);
    if (std.mem.indexOf(u8, occupied_shown, "\"ok\":true") == null)
        return "could not occupy the surviving duplicate pane";
    const occupied_panel_id = parseNumAfter(occupied_shown, "\"panel_id\":") orelse
        return "occupied-survivor panel show returned no id";

    const no_host_shown = panelRelayCall(
        allocator,
        &duplicate_requester,
        0x601,
        "{\"cmd\":\"panel-show\",\"name\":\"no-empty-survivor\",\"target\":\"pane\"," ++
            "\"document\":\"{\\\"root\\\":\\\"t\\\",\\\"components\\\":{\\\"t\\\":{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"departing panel\\\"}}}\"}",
    ) orelse return "occupied-survivor relay panel show timed out";
    defer allocator.free(no_host_shown);
    if (std.mem.indexOf(u8, no_host_shown, "\"ok\":true") == null)
        return "occupied-survivor relay panel show failed";
    const no_host_panel_id = parseNumAfter(no_host_shown, "\"panel_id\":") orelse
        return "occupied-survivor relay panel show returned no id";

    if (!closeGuiPaneAndWait(allocator, gui_sock, replacement_duplicate))
        return "closing the occupied-survivor source pane did not finish";
    var no_host_get_buf: [128]u8 = undefined;
    const no_host_get_req = std.fmt.bufPrint(
        &no_host_get_buf,
        "{{\"cmd\":\"panel-get\",\"panel_id\":{d}}}",
        .{no_host_panel_id},
    ) catch return "formatting occupied-survivor relay panel-get failed";
    var no_host_removed = false;
    var no_host_try: u64 = 0;
    while (no_host_try < 100) : (no_host_try += 1) {
        const no_host_state = panelRelayCall(
            allocator,
            &duplicate_requester,
            0x602 + no_host_try,
            no_host_get_req,
        ) orelse return "occupied-survivor relay panel-get timed out";
        defer allocator.free(no_host_state);
        if (std.mem.indexOf(u8, no_host_state, "no such panel") != null) {
            no_host_removed = true;
            break;
        }
        if (std.mem.indexOf(u8, no_host_state, "\"ok\":true") != null)
            return "a departing panel displaced the occupied surviving pane";
        // Any other non-ok reply is a transient from the teardown window.
        _ = c.usleep(100_000);
    }
    if (!no_host_removed)
        return "occupied-survivor presenter did not recover after source teardown";

    var occupied_get_buf: [160]u8 = undefined;
    const occupied_get_req = std.fmt.bufPrint(
        &occupied_get_buf,
        "{{\"cmd\":\"panel-get\",\"pane\":{d},\"panel_id\":{d}}}\n",
        .{ occupied_duplicate, occupied_panel_id },
    ) catch return "formatting occupied-survivor direct panel-get failed";
    const occupied_live = roundtrip(allocator, gui_sock, occupied_get_req) orelse
        return "occupied-survivor direct panel-get timed out";
    defer allocator.free(occupied_live);
    if (std.mem.indexOf(u8, occupied_live, "survivor stays") == null)
        return "rehosting evicted the panel on an occupied surviving pane";

    var occupied_close_buf: [160]u8 = undefined;
    const occupied_close_req = std.fmt.bufPrint(
        &occupied_close_buf,
        "{{\"cmd\":\"panel-close\",\"pane\":{d},\"panel_id\":{d}}}\n",
        .{ occupied_duplicate, occupied_panel_id },
    ) catch return "formatting occupied-survivor cleanup failed";
    const occupied_closed = roundtrip(allocator, gui_sock, occupied_close_req) orelse
        return "occupied-survivor cleanup timed out";
    defer allocator.free(occupied_closed);
    if (std.mem.indexOf(u8, occupied_closed, "\"ok\":true") == null)
        return "occupied-survivor panel cleanup failed";
    if (!closeGuiPaneAndWait(allocator, gui_sock, occupied_duplicate))
        return "closing the occupied duplicate GUI pane did not finish";
    admin.sendJson(.kill, .{ .name = duplicate_session }) catch return "could not clean up duplicate panel-scope fixture";
    (admin.recvExpectFor(&.{.ok}, 10_000) catch return "duplicate panel-scope cleanup was not acknowledged").deinit(allocator);
    return null;
}

/// Declarative UI panels, end to end. What only a live run can prove:
/// the renderer builds real widgets from a document, GTK gestures
/// reach the event queue (the button click and the slider drag are
/// injected on the session's seat, not synthesized), a patch updates
/// the live tree, and the image_compare's own drag handling actually
/// moves pixels. Every assertion goes through the SAME control-socket
/// commands an assistant uses.
fn panelStage(
    allocator: std.mem.Allocator,
    app: *appdrive.App,
    sock_path: [:0]const u8,
    rt: []const u8,
) ?[]const u8 {
    _ = app.drainLive(2_000);
    var known: [16]u32 = undefined;
    var n_known: usize = 0;
    for (app.windows.items) |w| {
        if (w.popup or n_known >= known.len) continue;
        known[n_known] = w.id;
        n_known += 1;
    }

    // 1. A panel in its own window whose ROOT is the button: the whole
    // client area is then the click target, so the coordinate cannot
    // drift with theme metrics.
    const show_req =
        "{\"cmd\":\"panel-show\",\"name\":\"e2e\",\"session\":\"e2e-scope\",\"target\":\"window\"," ++
        "\"document\":\"{\\\"version\\\":1,\\\"title\\\":\\\"Epoch 41\\\",\\\"root\\\":\\\"ok\\\"," ++
        "\\\"components\\\":{\\\"ok\\\":{\\\"type\\\":\\\"button\\\",\\\"text\\\":\\\"Approve\\\"," ++
        "\\\"action\\\":\\\"approve\\\",\\\"class\\\":[\\\"expand\\\"]}}}\"}\n";
    const show = roundtrip(allocator, sock_path, show_req) orelse return "panel-show roundtrip";
    defer allocator.free(show);
    if (std.mem.indexOf(u8, show, "\"ok\":true") == null) return "panel-show not ok";
    const panel_id = parseNumAfter(show, "\"panel_id\":") orelse return "panel-show reply has no panel_id";
    if (std.mem.indexOf(u8, show, "\"session\":\"e2e-scope\"") == null)
        return "panel-show did not echo the session it scoped the panel to";
    var guessed_buf: [160]u8 = undefined;
    const guessed_req = std.fmt.bufPrint(
        &guessed_buf,
        "{{\"cmd\":\"panel-get\",\"panel_id\":{d},\"session\":\"e2e-other\"}}\n",
        .{panel_id},
    ) catch return "cross-session panel id probe did not fit";
    const guessed = roundtrip(allocator, sock_path, guessed_req) orelse
        return "cross-session panel id probe timed out";
    defer allocator.free(guessed);
    if (std.mem.indexOf(u8, guessed, "\"ok\":false") == null)
        return "a direct caller reached another session's guessed panel id";

    // A malformed document must be REFUSED with the parser's own
    // message (the assistant fixes its document from that text).
    const bad = roundtrip(
        allocator,
        sock_path,
        "{\"cmd\":\"panel-show\",\"name\":\"e2e-bad\",\"session\":\"e2e-scope\",\"target\":\"window\"," ++
            "\"document\":\"{\\\"root\\\":\\\"r\\\",\\\"components\\\":{\\\"r\\\":{\\\"type\\\":\\\"webview\\\"}}}\"}\n",
    ) orelse return "panel-show(bad) roundtrip";
    defer allocator.free(bad);
    if (std.mem.indexOf(u8, bad, "\"ok\":false") == null) return "a webview component was accepted";
    if (std.mem.indexOf(u8, bad, "webview") == null)
        return "the rejection did not name the offending component type";

    var waited: u32 = 0;
    const win_id = while (waited < 25_000) : (waited += 200) {
        if (hasToplevelOtherThan(app, known[0..n_known])) |id| break id;
        _ = app.pumpOnce(200);
    } else return "the panel never mapped a window";
    _ = app.waitVisualSettle(win_id, 400, 10_000, 0.002, null);

    const pw = app.winById(win_id) orelse return "the panel window vanished";
    const cx = @as(f64, @floatFromInt(pw.w)) / 2;
    const cy = @as(f64, @floatFromInt(pw.h)) / 2;

    // 2. A real click on the real seat, and the event read back.
    app.clickEx(win_id, cx, cy, 1, 100, 1) catch return "clicking the panel button failed";
    var got_click = false;
    var tries: u32 = 0;
    while (tries < 40 and !got_click) : (tries += 1) {
        _ = app.pumpOnce(150);
        var ev_buf: [128]u8 = undefined;
        const ev_req = std.fmt.bufPrint(&ev_buf, "{{\"cmd\":\"panel-events\",\"panel_id\":{d},\"session\":\"e2e-scope\"}}\n", .{panel_id}) catch
            return "panel-events fmt";
        const evs = roundtrip(allocator, sock_path, ev_req) orelse return "panel-events roundtrip";
        defer allocator.free(evs);
        if (std.mem.indexOf(u8, evs, "\"ok\":true") == null) return "panel-events not ok";
        if (std.mem.indexOf(u8, evs, "\"dropped\":") == null) return "panel-events reply has no dropped count";
        if (std.mem.indexOf(u8, evs, "\"component\":\"ok\"") != null and
            std.mem.indexOf(u8, evs, "\"kind\":\"click\"") != null)
        {
            if (std.mem.indexOf(u8, evs, "\"value\":\"approve\"") == null)
                return "the click event carried no action value";
            got_click = true;
        }
    }
    if (!got_click) return "a real click on the panel button produced no event";

    // 3. panel-patch updates the live document (and the window title
    // follows it), and panel-list reports the panel in its session.
    var patch_buf: [512]u8 = undefined;
    const patch_req = std.fmt.bufPrint(
        &patch_buf,
        "{{\"cmd\":\"panel-patch\",\"panel_id\":{d},\"session\":\"e2e-scope\",\"patch\":\"[{{\\\"op\\\":\\\"title\\\",\\\"value\\\":\\\"Epoch 42\\\"}}]\"}}\n",
        .{panel_id},
    ) catch return "panel-patch fmt";
    const patched = roundtrip(allocator, sock_path, patch_req) orelse return "panel-patch roundtrip";
    defer allocator.free(patched);
    if (std.mem.indexOf(u8, patched, "\"ok\":true") == null) return "panel-patch not ok";

    // A patch naming a component that does not exist must fail with the
    // parser's message and leave the panel alone.
    const bad_patch_req = std.fmt.bufPrint(
        &patch_buf,
        "{{\"cmd\":\"panel-patch\",\"panel_id\":{d},\"session\":\"e2e-scope\",\"patch\":\"[{{\\\"op\\\":\\\"remove\\\",\\\"id\\\":\\\"ghost\\\"}}]\"}}\n",
        .{panel_id},
    ) catch return "panel-patch fmt";
    const bad_patch = roundtrip(allocator, sock_path, bad_patch_req) orelse return "bad panel-patch roundtrip";
    defer allocator.free(bad_patch);
    if (std.mem.indexOf(u8, bad_patch, "\"ok\":false") == null) return "removing a missing component was accepted";
    if (std.mem.indexOf(u8, bad_patch, "ghost") == null) return "the patch rejection did not name the component";

    const listed = roundtrip(allocator, sock_path, "{\"cmd\":\"panel-list\",\"session\":\"e2e-scope\"}\n") orelse
        return "panel-list roundtrip";
    defer allocator.free(listed);
    if (std.mem.indexOf(u8, listed, "\"name\":\"e2e\"") == null) return "panel-list does not report the panel";
    if (std.mem.indexOf(u8, listed, "\"title\":\"Epoch 42\"") == null)
        return "the patched title never reached the live document";
    if (std.mem.indexOf(u8, listed, "\"target\":\"window\"") == null) return "panel-list lost the target";

    // Session scoping: another assistant's session must not see it.
    const other = roundtrip(allocator, sock_path, "{\"cmd\":\"panel-list\",\"session\":\"e2e-other\"}\n") orelse
        return "panel-list(other) roundtrip";
    defer allocator.free(other);
    if (std.mem.indexOf(u8, other, "\"name\":\"e2e\"") != null)
        return "a panel leaked into another session's list";

    // 4. Re-showing the SAME name replaces the document in place: same
    // panel_id, no second window. The new root is a slider, which the
    // next step drags.
    const again_req =
        "{\"cmd\":\"panel-show\",\"name\":\"e2e\",\"session\":\"e2e-scope\",\"target\":\"window\"," ++
        "\"document\":\"{\\\"version\\\":1,\\\"title\\\":\\\"Threshold\\\",\\\"root\\\":\\\"thr\\\"," ++
        "\\\"components\\\":{\\\"thr\\\":{\\\"type\\\":\\\"slider\\\",\\\"min\\\":0,\\\"max\\\":100," ++
        "\\\"step\\\":1,\\\"value\\\":0,\\\"class\\\":[\\\"expand\\\"]}}}\"}\n";
    const again = roundtrip(allocator, sock_path, again_req) orelse return "panel-show(again) roundtrip";
    defer allocator.free(again);
    if (std.mem.indexOf(u8, again, "\"ok\":true") == null) return "panel-show(again) not ok";
    const again_id = parseNumAfter(again, "\"panel_id\":") orelse return "panel-show(again) has no panel_id";
    if (again_id != panel_id) return "re-showing a name opened a SECOND panel instead of replacing it";
    if (hasToplevelOtherThan(app, known[0..n_known])) |id| {
        if (id != win_id) return "re-showing a name opened a second window";
    }
    _ = app.waitVisualSettle(win_id, 400, 10_000, 0.002, null);

    // 5. A real drag across the slider: gesture -> value-changed ->
    // queue, with a number payload.
    const w_f = @as(f64, @floatFromInt(pw.w));
    app.drag(win_id, w_f * 0.15, cy, w_f * 0.85, cy, 1) catch return "dragging the slider failed";
    var got_change = false;
    tries = 0;
    while (tries < 40 and !got_change) : (tries += 1) {
        _ = app.pumpOnce(150);
        var ev_buf: [128]u8 = undefined;
        const ev_req = std.fmt.bufPrint(&ev_buf, "{{\"cmd\":\"panel-events\",\"panel_id\":{d},\"session\":\"e2e-scope\"}}\n", .{panel_id}) catch
            return "panel-events fmt";
        const evs = roundtrip(allocator, sock_path, ev_req) orelse return "panel-events roundtrip";
        defer allocator.free(evs);
        if (std.mem.indexOf(u8, evs, "\"component\":\"thr\"") != null and
            std.mem.indexOf(u8, evs, "\"kind\":\"change\"") != null) got_change = true;
    }
    if (!got_change) return "dragging the slider produced no change event";

    // 6. The image_compare, on a PANE face this time: two generated
    // images, then a drag that must move the split (i.e. repaint).
    const left_png = std.fmt.allocPrintSentinel(allocator, "{s}/panel-left.png", .{rt}, 0) catch return "alloc";
    defer allocator.free(left_png);
    const right_png = std.fmt.allocPrintSentinel(allocator, "{s}/panel-right.png", .{rt}, 0) catch return "alloc";
    defer allocator.free(right_png);
    if (!writeSolidPng(allocator, left_png, 0x20, 0x80, 0xff)) return "could not write the left compare image";
    if (!writeSolidPng(allocator, right_png, 0xff, 0x90, 0x20)) return "could not write the right compare image";

    var cmp_buf: [1400]u8 = undefined;
    const cmp_req = std.fmt.bufPrint(
        &cmp_buf,
        "{{\"cmd\":\"panel-show\",\"name\":\"e2e-cmp\",\"session\":\"e2e-scope\",\"target\":\"pane\",\"pane\":1," ++
            "\"document\":\"{{\\\"root\\\":\\\"c\\\",\\\"components\\\":{{\\\"c\\\":{{\\\"type\\\":\\\"image_compare\\\"," ++
            "\\\"left\\\":{{\\\"src\\\":\\\"{s}\\\",\\\"label\\\":\\\"before\\\"}}," ++
            "\\\"right\\\":{{\\\"src\\\":\\\"{s}\\\",\\\"label\\\":\\\"after\\\"}}}}}}}}\"}}\n",
        .{ left_png, right_png },
    ) catch return "compare req fmt";
    // Issue the show WITHOUT reading its reply. The local image read, the
    // cache-namespace init and the decode all run on detached workers between
    // the request and the reply, so the liveness probe has to overlap THAT
    // window: a probe taken after the reply cannot fail, because by then there
    // is no image work left in flight.
    var cmp_call = PendingCall.start(sock_path, cmp_req) orelse
        return "could not send panel-show(compare)";
    _ = c.usleep(250_000);
    if (!guiResponsive(allocator, sock_path))
        return "local image read/cache-init/decode blocked the GTK main thread";
    const cmp = cmp_call.finish(allocator) orelse return "panel-show(compare) roundtrip";
    defer allocator.free(cmp);
    if (std.mem.indexOf(u8, cmp, "\"ok\":true") == null) return "panel-show(compare) not ok";
    const cmp_id = parseNumAfter(cmp, "\"panel_id\":") orelse return "compare panel has no panel_id";

    const term_win = known[0];
    if (!waitForPanelColor(allocator, app, term_win, .{ 0x20, 0x80, 0xff }, 12_000))
        return "the worker-prepared local image never rendered natively";
    _ = app.waitVisualSettle(term_win, 500, 10_000, 0.002, null);
    const before = app.screenshotPng(term_win, 640, null, 0) catch return "screenshotting the compare panel failed";
    defer allocator.free(before.png);
    const tw = app.winById(term_win) orelse return "the terminal window vanished";
    const ty = @as(f64, @floatFromInt(tw.h)) * 0.5;
    // Grab the panel's OWN split, located by its own colours (see
    // compareSplitX) rather than assumed to be at the window midpoint.
    const split_x = compareSplitX(allocator, app, term_win, @intFromFloat(ty)) orelse
        return "could not find the compare panel's split in the frame";
    app.drag(term_win, split_x, ty, split_x - 80, ty, 1) catch
        return "dragging the compare split failed";
    _ = app.waitVisualSettle(term_win, 400, 8_000, 0.002, null);
    const after = app.screenshotPng(term_win, 640, null, 0) catch return "screenshotting after the drag failed";
    defer allocator.free(after.png);
    if (std.mem.eql(u8, before.png, after.png)) {
        writePng("/tmp/sketerm-e2e-compare-before.png", before.png);
        writePng("/tmp/sketerm-e2e-compare-after.png", after.png);
        _ = c.fprintf(platform.stderr(), "smoke-e2e: compare window %dx%d, dragged %.0f -> %.0f at y=%.0f\n", tw.w, tw.h, @as(f64, @floatFromInt(tw.w)) * 0.5, @as(f64, @floatFromInt(tw.w)) * 0.2, ty);
        return "dragging the image_compare split repainted nothing";
    }

    // Refresh the SAME logical path, then immediately apply a title-only
    // patch while the delayed local read is still in flight. Both operations
    // must survive in request order: the title patch must not reread either
    // image, and its revision bump must not discard the healthy older refresh.
    if (!writeSolidPng(allocator, left_png, 0xf0, 0x30, 0x60))
        return "could not rewrite the local same-path image";
    const refresh_req = std.fmt.bufPrint(
        &cmp_buf,
        "{{\"cmd\":\"panel-patch\",\"panel_id\":{d},\"session\":\"e2e-scope\",\"patch\":\"[{{\\\"op\\\":\\\"set\\\",\\\"id\\\":\\\"c\\\",\\\"component\\\":{{\\\"type\\\":\\\"image_compare\\\",\\\"left\\\":{{\\\"src\\\":\\\"{s}\\\",\\\"label\\\":\\\"before\\\"}},\\\"right\\\":{{\\\"src\\\":\\\"{s}\\\",\\\"label\\\":\\\"after\\\"}}}}}}]\"}}\n",
        .{ cmp_id, left_png, right_png },
    ) catch return "formatting local same-path refresh failed";
    const refreshed = roundtrip(allocator, sock_path, refresh_req) orelse
        return "local same-path refresh roundtrip";
    defer allocator.free(refreshed);
    if (std.mem.indexOf(u8, refreshed, "\"ok\":true") == null)
        return "local same-path refresh was rejected";
    const title_started = clock.nowMs();
    const title_req = std.fmt.bufPrint(
        &patch_buf,
        "{{\"cmd\":\"panel-patch\",\"panel_id\":{d},\"session\":\"e2e-scope\",\"patch\":\"[{{\\\"op\\\":\\\"title\\\",\\\"value\\\":\\\"Refresh plus title\\\"}}]\"}}\n",
        .{cmp_id},
    ) catch return "formatting title-during-refresh patch failed";
    const titled = roundtrip(allocator, sock_path, title_req) orelse
        return "title-during-refresh roundtrip";
    defer allocator.free(titled);
    if (std.mem.indexOf(u8, titled, "\"ok\":true") == null or clock.nowMs() - title_started > 600)
        return "a non-image patch waited on or restarted local image IO";
    if (!waitForPanelColor(allocator, app, term_win, .{ 0xf0, 0x30, 0x60 }, 12_000))
        return "a later title patch discarded the in-flight same-path refresh";
    var get_buf: [128]u8 = undefined;
    const get_req = std.fmt.bufPrint(&get_buf, "{{\"cmd\":\"panel-get\",\"panel_id\":{d},\"session\":\"e2e-scope\"}}\n", .{cmp_id}) catch
        return "formatting panel-get after same-path refresh failed";
    const refreshed_doc = roundtrip(allocator, sock_path, get_req) orelse
        return "panel-get after same-path refresh roundtrip";
    defer allocator.free(refreshed_doc);
    if (std.mem.indexOf(u8, refreshed_doc, "Refresh plus title") == null or
        std.mem.indexOf(u8, refreshed_doc, left_png) == null)
        return "same-path refresh and later title did not both commit";

    // Changing the image component to a non-image yields an empty changed-path
    // set. The direct resolver transaction must still remove both prepared
    // image leases immediately and commit the same non-image document.
    const remove_images_req = std.fmt.bufPrint(
        &patch_buf,
        "{{\"cmd\":\"panel-patch\",\"panel_id\":{d},\"session\":\"e2e-scope\",\"patch\":\"[{{\\\"op\\\":\\\"set\\\",\\\"id\\\":\\\"c\\\",\\\"component\\\":{{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"images released\\\"}}}}]\"}}\n",
        .{cmp_id},
    ) catch return "formatting direct image-removal patch failed";
    const images_removed = roundtrip(allocator, sock_path, remove_images_req) orelse
        return "direct image-removal patch roundtrip";
    defer allocator.free(images_removed);
    if (std.mem.indexOf(u8, images_removed, "\"ok\":true") == null)
        return "direct image-removal patch failed";
    const released_doc = roundtrip(allocator, sock_path, get_req) orelse
        return "panel-get after direct image removal roundtrip";
    defer allocator.free(released_doc);
    if (std.mem.indexOf(u8, released_doc, "images released") == null or
        std.mem.indexOf(u8, released_doc, left_png) != null or
        std.mem.indexOf(u8, released_doc, right_png) != null)
        return "direct image removal left the document and resolver transaction divergent";

    // 7. Close both. The compare panel sat ON pane 1, so closing it
    // must give the pane back to its shell rather than close the tab.
    var close_buf: [128]u8 = undefined;
    const close_cmp = std.fmt.bufPrint(&close_buf, "{{\"cmd\":\"panel-close\",\"panel_id\":{d},\"session\":\"e2e-scope\"}}\n", .{cmp_id}) catch
        return "panel-close fmt";
    const closed_cmp = roundtrip(allocator, sock_path, close_cmp) orelse return "panel-close roundtrip";
    defer allocator.free(closed_cmp);
    if (std.mem.indexOf(u8, closed_cmp, "\"ok\":true") == null) return "panel-close(compare) not ok";

    const close_req = std.fmt.bufPrint(&close_buf, "{{\"cmd\":\"panel-close\",\"panel_id\":{d},\"session\":\"e2e-scope\"}}\n", .{panel_id}) catch
        return "panel-close fmt";
    const closed = roundtrip(allocator, sock_path, close_req) orelse return "panel-close roundtrip";
    defer allocator.free(closed);
    if (std.mem.indexOf(u8, closed, "\"ok\":true") == null) return "panel-close not ok";
    _ = app.pumpOnce(500);

    const gone = roundtrip(allocator, sock_path, "{\"cmd\":\"panel-list\",\"session\":\"e2e-scope\"}\n") orelse
        return "panel-list(after close) roundtrip";
    defer allocator.free(gone);
    if (std.mem.indexOf(u8, gone, "\"name\":\"e2e\"") != null) return "a closed panel is still listed";
    if (std.mem.indexOf(u8, gone, "\"name\":\"e2e-cmp\"") != null) return "a closed pane panel is still listed";

    // Addressing a dead panel must be a plain refusal, not a crash.
    const stale = roundtrip(allocator, sock_path, close_req) orelse return "stale panel-close roundtrip";
    defer allocator.free(stale);
    if (std.mem.indexOf(u8, stale, "\"ok\":false") == null) return "closing a dead panel reported success";

    // The pane the compare panel rode on is still a working terminal.
    const alive = roundtrip(allocator, sock_path, "{\"cmd\":\"screen-info\",\"pane\":1}\n") orelse
        return "screen-info after panel close roundtrip";
    defer allocator.free(alive);
    if (std.mem.indexOf(u8, alive, "\"ok\":true") == null) return "the pane did not survive its panel";

    // 7b. The DEFAULT target: a tab of its own. Closing that panel
    // must take its tab with it (the pane exists only for the panel),
    // which is the opposite of the pane-target rule just asserted.
    {
        const before_list = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse return "list roundtrip";
        defer allocator.free(before_list);
        const ids_before = std.mem.count(u8, before_list, "\"id\":");
        const tab_req =
            "{\"cmd\":\"panel-show\",\"name\":\"e2e-tab\",\"session\":\"e2e-scope\",\"pane\":1," ++
            "\"document\":\"{\\\"title\\\":\\\"Tabbed\\\",\\\"root\\\":\\\"t\\\"," ++
            "\\\"components\\\":{\\\"t\\\":{\\\"type\\\":\\\"heading\\\",\\\"text\\\":\\\"In a tab\\\",\\\"level\\\":1}}}\"}\n";
        const tabbed = roundtrip(allocator, sock_path, tab_req) orelse return "panel-show(tab) roundtrip";
        defer allocator.free(tabbed);
        if (std.mem.indexOf(u8, tabbed, "\"ok\":true") == null) return "panel-show(tab) not ok";
        const tab_id = parseNumAfter(tabbed, "\"panel_id\":") orelse return "tab panel has no panel_id";
        const tab_list = roundtrip(allocator, sock_path, "{\"cmd\":\"panel-list\",\"session\":\"e2e-scope\"}\n") orelse
            return "panel-list(tab) roundtrip";
        defer allocator.free(tab_list);
        if (std.mem.indexOf(u8, tab_list, "\"target\":\"tab\"") == null)
            return "omitting target did not default to a tab";
        if (!waitIdCount(allocator, sock_path, ids_before + 2, true, 10_000))
            return "the tab panel did not add a tab and a pane";
        var tclose: [128]u8 = undefined;
        const tclose_req = std.fmt.bufPrint(&tclose, "{{\"cmd\":\"panel-close\",\"panel_id\":{d},\"session\":\"e2e-scope\"}}\n", .{tab_id}) catch
            return "fmt";
        const tclosed = roundtrip(allocator, sock_path, tclose_req) orelse return "panel-close(tab) roundtrip";
        defer allocator.free(tclosed);
        if (std.mem.indexOf(u8, tclosed, "\"ok\":true") == null) return "panel-close(tab) not ok";
        if (!waitIdCount(allocator, sock_path, ids_before, true, 10_000))
            return "closing a tab panel left its tab behind";
    }

    // 7c. A standalone direct panel retains the Terminal that supplied local
    // image bytes as a liveness-fenced asset origin. Destroy that Terminal,
    // then prove a new image source is rejected BEFORE document commit while
    // an unrelated title patch remains usable.
    {
        const opened = roundtrip(allocator, sock_path, "{\"cmd\":\"new-tab\"}\n") orelse
            return "new-tab(dead panel origin) roundtrip";
        defer allocator.free(opened);
        const origin_pane = parseNumAfter(opened, "\"pane\":") orelse
            return "new-tab(dead panel origin) returned no pane id";
        var req_buf: [1600]u8 = undefined;
        const show_origin = std.fmt.bufPrint(
            &req_buf,
            "{{\"cmd\":\"panel-show\",\"name\":\"dead-asset-origin\",\"session\":\"e2e-scope\",\"target\":\"window\",\"pane\":{d}," ++
                "\"document\":\"{{\\\"title\\\":\\\"Origin alive\\\",\\\"root\\\":\\\"t\\\",\\\"components\\\":{{\\\"t\\\":{{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"original document\\\"}}}}}}\"}}\n",
            .{origin_pane},
        ) catch return "formatting dead-origin panel show failed";
        const origin_shown = roundtrip(allocator, sock_path, show_origin) orelse
            return "dead-origin panel show roundtrip";
        defer allocator.free(origin_shown);
        if (std.mem.indexOf(u8, origin_shown, "\"ok\":true") == null)
            return "dead-origin panel show failed";
        const origin_panel_id = parseNumAfter(origin_shown, "\"panel_id\":") orelse
            return "dead-origin panel show returned no panel id";

        const close_origin_pane = std.fmt.bufPrint(
            &req_buf,
            "{{\"cmd\":\"close-pane\",\"pane\":{d}}}\n",
            .{origin_pane},
        ) catch return "formatting dead asset origin close failed";
        const origin_closed = roundtrip(allocator, sock_path, close_origin_pane) orelse
            return "closing dead asset origin pane timed out";
        defer allocator.free(origin_closed);
        if (std.mem.indexOf(u8, origin_closed, "\"ok\":true") == null)
            return "closing dead asset origin pane failed";
        if (!waitPaneGone(allocator, sock_path, origin_pane, 10_000))
            return "dead asset origin pane remained live after close";

        const image_patch = std.fmt.bufPrint(
            &req_buf,
            "{{\"cmd\":\"panel-patch\",\"panel_id\":{d},\"session\":\"e2e-scope\",\"patch\":\"[{{\\\"op\\\":\\\"set\\\",\\\"id\\\":\\\"t\\\",\\\"component\\\":{{\\\"type\\\":\\\"image\\\",\\\"src\\\":\\\"{s}\\\"}}}}]\"}}\n",
            .{ origin_panel_id, left_png },
        ) catch return "formatting dead-origin image patch failed";
        const image_refused = roundtrip(allocator, sock_path, image_patch) orelse
            return "dead-origin image patch roundtrip";
        defer allocator.free(image_refused);
        if (std.mem.indexOf(u8, image_refused, "\"ok\":false") == null or
            std.mem.indexOf(u8, image_refused, "asset origin is no longer available") == null or
            std.mem.indexOf(u8, image_refused, "patch was not committed") == null)
            return "dead-origin image patch was not rejected before commit";

        const get_origin = std.fmt.bufPrint(
            &req_buf,
            "{{\"cmd\":\"panel-get\",\"panel_id\":{d},\"session\":\"e2e-scope\"}}\n",
            .{origin_panel_id},
        ) catch return "formatting dead-origin panel-get failed";
        const unchanged = roundtrip(allocator, sock_path, get_origin) orelse
            return "dead-origin panel-get roundtrip";
        defer allocator.free(unchanged);
        if (std.mem.indexOf(u8, unchanged, "original document") == null or
            std.mem.indexOf(u8, unchanged, left_png) != null)
            return "rejected dead-origin image patch changed the live document";

        const title_patch = std.fmt.bufPrint(
            &req_buf,
            "{{\"cmd\":\"panel-patch\",\"panel_id\":{d},\"session\":\"e2e-scope\",\"patch\":\"[{{\\\"op\\\":\\\"title\\\",\\\"value\\\":\\\"Origin gone but usable\\\"}}]\"}}\n",
            .{origin_panel_id},
        ) catch return "formatting dead-origin title patch failed";
        const title_ok = roundtrip(allocator, sock_path, title_patch) orelse
            return "dead-origin title patch roundtrip";
        defer allocator.free(title_ok);
        if (std.mem.indexOf(u8, title_ok, "\"ok\":true") == null)
            return "non-image patch stopped working after asset-origin teardown";

        const close_origin_panel = std.fmt.bufPrint(
            &req_buf,
            "{{\"cmd\":\"panel-close\",\"panel_id\":{d},\"session\":\"e2e-scope\"}}\n",
            .{origin_panel_id},
        ) catch return "formatting dead-origin panel close failed";
        const origin_panel_closed = roundtrip(allocator, sock_path, close_origin_panel) orelse
            return "dead-origin panel close roundtrip";
        defer allocator.free(origin_panel_closed);
        if (std.mem.indexOf(u8, origin_panel_closed, "\"ok\":true") == null)
            return "dead-origin panel close failed";
    }

    // 8. The same feature through `sketerm cli`, document read from a
    // FILE — the path a human (or a shell script) actually uses, and
    // the one no socket-level assertion above covers.
    const doc_path = std.fmt.allocPrint(allocator, "{s}/panel-doc.json", .{rt}) catch return "alloc";
    defer allocator.free(doc_path);
    {
        const doc_z = allocator.dupeZ(u8, doc_path) catch return "alloc";
        defer allocator.free(doc_z);
        const body =
            "{\"version\":1,\"title\":\"From the CLI\",\"root\":\"t\"," ++
            "\"components\":{\"t\":{\"type\":\"text\",\"text\":\"hello from a file\"}}}";
        const f = c.fopen(doc_z.ptr, "wb") orelse return "could not write the panel document";
        _ = c.fwrite(body.ptr, 1, body.len, f);
        _ = c.fclose(f);
    }
    const cli_show = runCli(allocator, &.{
        "--socket",  sock_path,   "panel-show", "--name", "cli-panel",
        "--session", "e2e-scope", "--target",   "window", "--file",
        doc_path,
    });
    defer allocator.free(cli_show.out);
    if (cli_show.code != 0) return "sketerm cli panel-show exited nonzero";
    const cli_id = parseNumAfter(cli_show.out, "\"panel_id\":") orelse
        return "sketerm cli panel-show printed no panel_id";

    const cli_list = runCli(allocator, &.{ "--socket", sock_path, "panel-list", "--session", "e2e-scope" });
    defer allocator.free(cli_list.out);
    if (cli_list.code != 0) return "sketerm cli panel-list exited nonzero";
    if (std.mem.indexOf(u8, cli_list.out, "\"title\":\"From the CLI\"") == null)
        return "the CLI-shown panel is missing from panel-list";

    var idbuf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{cli_id}) catch return "fmt";
    const cli_close = runCli(allocator, &.{ "--socket", sock_path, "panel-close", "--panel-id", id_str, "--session", "e2e-scope" });
    defer allocator.free(cli_close.out);
    if (cli_close.code != 0) return "sketerm cli panel-close exited nonzero";
    _ = app.pumpOnce(300);
    return null;
}

/// A real `sketerm mcp` server on its own stdio pipes.
///
/// Reads PUMP the display session while they wait: this process is the
/// compositor brain for the GUI's toplevel, so a blocking read here
/// (ui_wait_event blocks for as long as the user takes) would starve
/// configure/frame handling and the panel would never paint or receive
/// the click it is waiting for.
const McpChild = struct {
    pid: c.pid_t,
    to_child: c_int,
    from_child: c_int,
    id: u32 = 0,
    rbuf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    line: [1 << 16]u8 = undefined,

    fn spawn(allocator: std.mem.Allocator, sock_path: [:0]const u8) ?McpChild {
        return spawnForPanelOrigin(allocator, sock_path, null, null, null);
    }

    /// Spawn as though it runs inside a daemon-owned terminal.
    fn spawnMuxPanel(
        allocator: std.mem.Allocator,
        mux_sock: [:0]const u8,
        session: [:0]const u8,
        remote_home: ?[:0]const u8,
    ) ?McpChild {
        var identity = muxclient.connectPanelRequester(allocator, mux_sock, session, 5_000) catch return null;
        defer identity.deinit();
        const origin_id = allocator.dupeZ(u8, identity.panelOriginId()) catch return null;
        defer allocator.free(origin_id);
        if (origin_id.len != 32) return null;
        return spawnForPanelOrigin(allocator, mux_sock, session, origin_id, remote_home);
    }

    fn spawnForPanelOrigin(
        allocator: std.mem.Allocator,
        socket: [:0]const u8,
        session: ?[:0]const u8,
        origin_id: ?[:0]const u8,
        remote_home: ?[:0]const u8,
    ) ?McpChild {
        var in_pipe: [2]c_int = undefined;
        var out_pipe: [2]c_int = undefined;
        if (c.pipe(&in_pipe) != 0 or c.pipe(&out_pipe) != 0) return null;
        const pid = c.fork();
        if (pid < 0) return null;
        if (pid == 0) {
            dieWithParent();
            _ = c.dup2(in_pipe[0], 0);
            _ = c.dup2(out_pipe[1], 1);
            _ = c.close(in_pipe[0]);
            _ = c.close(in_pipe[1]);
            _ = c.close(out_pipe[0]);
            _ = c.close(out_pipe[1]);
            if (session) |remote_session| {
                _ = c.setenv("SKETERM_SESSION", remote_session.ptr, 1);
                _ = c.setenv("SKETERM_MUX_SOCKET", socket.ptr, 1);
                _ = c.setenv("SKETERM_SESSION_ORIGIN_ID", origin_id.?.ptr, 1);
                if (remote_home) |home| {
                    _ = c.setenv("XDG_RUNTIME_DIR", home.ptr, 1);
                    _ = c.setenv("XDG_STATE_HOME", home.ptr, 1);
                    _ = c.setenv("XDG_CONFIG_HOME", home.ptr, 1);
                }
                // No --shared and no --socket: panel delivery must use only
                // the inherited origin, while app/term/fs state stays on the
                // MCP server's lazily started private daemon.
                const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm", "mcp", null };
                _ = c.execv("zig-out/bin/sketerm", @ptrCast(@constCast(&argv)));
            } else {
                // The harness may itself have been launched from inside a
                // sketerm pane. This child is explicitly testing legacy direct
                // GUI-socket semantics, not that ambient pane's mux origin.
                _ = c.unsetenv("SKETERM_SESSION");
                _ = c.unsetenv("SKETERM_MUX_SOCKET");
                _ = c.unsetenv("SKETERM_SESSION_ORIGIN_ID");
                // --shared skips the private daemon entirely (no second
                // mux to clean up); --socket points it at THIS GUI.
                const argv = [_:null]?[*:0]const u8{
                    "zig-out/bin/sketerm", "mcp", "--shared", "--socket", socket.ptr, null,
                };
                _ = c.execv("zig-out/bin/sketerm", @ptrCast(@constCast(&argv)));
            }
            c._exit(127);
        }
        _ = c.close(in_pipe[0]);
        _ = c.close(out_pipe[1]);
        return .{ .pid = pid, .to_child = in_pipe[1], .from_child = out_pipe[0], .allocator = allocator };
    }

    fn send(self: *McpChild, text: []const u8) bool {
        var off: usize = 0;
        while (off < text.len) {
            const n = c.write(self.to_child, text.ptr + off, text.len - off);
            if (n <= 0) return false;
            off += @intCast(n);
        }
        return c.write(self.to_child, "\n", 1) == 1;
    }

    /// One reply line, valid until the next call. Pumps while waiting.
    fn recv(self: *McpChild, timeout_ms: i64) ?[]const u8 {
        const deadline = clock.nowMs() + timeout_ms;
        while (true) {
            if (std.mem.indexOfScalar(u8, self.rbuf.items, '\n')) |nl| {
                const n = @min(nl, self.line.len);
                @memcpy(self.line[0..n], self.rbuf.items[0..n]);
                const rest = self.rbuf.items[nl + 1 ..];
                std.mem.copyForwards(u8, self.rbuf.items[0..rest.len], rest);
                self.rbuf.shrinkRetainingCapacity(rest.len);
                return self.line[0..n];
            }
            if (clock.nowMs() > deadline) return null;
            if (drive) |app| _ = app.pumpOnce(20);
            var pfd = c.struct_pollfd{ .fd = self.from_child, .events = c.POLLIN, .revents = 0 };
            if (c.poll(&pfd, 1, 20) <= 0) continue;
            var tmp: [65536]u8 = undefined;
            const n = c.read(self.from_child, &tmp, tmp.len);
            if (n <= 0) return null;
            self.rbuf.appendSlice(self.allocator, tmp[0..@intCast(n)]) catch return null;
        }
    }

    fn startCall(self: *McpChild, name: []const u8, args_json: []const u8) bool {
        self.id += 1;
        var buf: [4096]u8 = undefined;
        const req = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ self.id, name, args_json }) catch return false;
        return self.send(req);
    }

    fn call(self: *McpChild, name: []const u8, args_json: []const u8, timeout_ms: i64) ?[]const u8 {
        if (!self.startCall(name, args_json)) return null;
        return self.recv(timeout_ms);
    }

    fn initialize(self: *McpChild) bool {
        self.id += 1;
        var buf: [512]u8 = undefined;
        const req = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"smoke-e2e\",\"version\":\"0\"}}}}}}", .{ self.id, version.mcp_protocol }) catch return false;
        if (!self.send(req)) return false;
        return self.recv(20_000) != null;
    }

    fn close(self: *McpChild) void {
        _ = c.close(self.to_child);
        var st: c_int = 0;
        var tries: u32 = 0;
        while (tries < 60) : (tries += 1) {
            if (c.waitpid(self.pid, &st, 1) == self.pid) break;
            if (drive) |app| _ = app.pumpOnce(50);
        }
        if (tries >= 60) {
            _ = c.kill(self.pid, c.SIGKILL);
            _ = c.waitpid(self.pid, &st, 0);
        }
        _ = c.close(self.from_child);
        self.rbuf.deinit(self.allocator);
    }
};

fn readerEntityId(text: []const u8, needle: []const u8) ?u32 {
    const at = std.mem.lastIndexOf(u8, text, needle) orelse return null;
    const before = text[0..at];
    const key = "\\\"id\\\":";
    const id_at = std.mem.lastIndexOf(u8, before, key) orelse return null;
    return parseNumAfter(text[id_at..], key);
}

/// Real MCP GUI adapter: control socket -> WebFace token polling -> helper.
fn mcpWebReaderStage(allocator: std.mem.Allocator, sock_path: [:0]const u8, rt: []const u8) ?[]const u8 {
    if (c.access("zig-out/bin/sketerm-webengine", c.X_OK) != 0)
        return null; // Optional CEF build; smoke-mcp reports the explicit skip.
    var web_bin_buf: [4096]u8 = undefined;
    const web_bin = c.realpath("zig-out/bin/sketerm-webengine", &web_bin_buf) orelse
        return "could not resolve sketerm-webengine for the GUI MCP reader stage";

    var page_buf: [512]u8 = undefined;
    const page = std.fmt.bufPrintZ(&page_buf, "{s}/mcp-gui-reader.html", .{rt}) catch
        return "GUI MCP reader page path did not fit";
    const f = c.fopen(page.ptr, "wb") orelse return "could not create the GUI MCP reader page";
    const html =
        "<html><head><title>GUI Reader</title></head><body><article><h1>GUI Reader Target</h1>" ++
        "<p>GUI-READER-MARKER enough article text for extraction. " ++
        "<a id=target href=#fresh onclick=\"document.title='gui:mcp:'+event.isTrusted;return false\">" ++
        "Activate GUI Reader Target</a></p></article></body></html>";
    const wrote = c.fwrite(html.ptr, 1, html.len, f) == html.len;
    _ = c.fclose(f);
    if (!wrote) return "could not write the GUI MCP reader page";

    _ = c.setenv("SKETERM_WEB_BIN", web_bin, 1);
    defer _ = c.unsetenv("SKETERM_WEB_BIN");
    var m = McpChild.spawn(allocator, sock_path) orelse return "could not spawn MCP for the GUI reader stage";
    defer m.close();
    if (!m.initialize()) return "GUI reader MCP did not answer initialize";

    var args: [1024]u8 = undefined;
    const open_args = std.fmt.bufPrint(&args, "{{\"url\":\"file://{s}\",\"timeout_ms\":30000}}", .{page}) catch
        return "GUI reader web_open arguments did not fit";
    const opened = m.call("web_open", open_args, 60_000) orelse return "GUI reader web_open timed out";
    if (std.mem.indexOf(u8, opened, "isError") != null or std.mem.indexOf(u8, opened, "GUI Reader Target") == null)
        return "GUI reader web_open did not settle on the real page";
    const pane = parseNumAfter(opened, "\\\"pane\\\":") orelse return "GUI reader web_open returned no pane handle";

    const read_args = std.fmt.bufPrint(&args, "{{\"pane\":{d},\"timeout_ms\":30000}}", .{pane}) catch
        return "GUI reader web_read arguments did not fit";
    const read = m.call("web_read", read_args, 60_000) orelse return "GUI reader web_read timed out";
    if (std.mem.indexOf(u8, read, "GUI-READER-MARKER") == null or
        std.mem.indexOf(u8, read, "\\\"entities\\\"") == null)
        return "GUI reader web_read did not return its rich entity model";
    const id = readerEntityId(read, "Activate GUI Reader Target") orelse
        return "GUI reader web_read did not expose the target entity id";

    const act_args = std.fmt.bufPrint(&args, "{{\"pane\":{d},\"id\":{d},\"action\":\"click\"}}", .{ pane, id }) catch
        return "GUI reader web_act arguments did not fit";
    const acted = m.call("web_act", act_args, 60_000) orelse return "GUI reader web_act timed out";
    if (std.mem.indexOf(u8, acted, "\\\"acted\\\":true") == null)
        return "GUI reader fresh entity id did not act";
    const title_args = std.fmt.bufPrint(&args, "{{\"pane\":{d},\"code\":\"document.title\"}}", .{pane}) catch
        return "GUI reader title eval arguments did not fit";
    const title = m.call("web_eval", title_args, 30_000) orelse return "GUI reader title eval timed out";
    if (std.mem.indexOf(u8, title, "gui:mcp:true") == null)
        return "GUI reader entity id did not activate its exact trusted link";

    var reread_buf: [128]u8 = undefined;
    const reread_args = std.fmt.bufPrint(&reread_buf, "{{\"pane\":{d},\"timeout_ms\":30000}}", .{pane}) catch
        return "second GUI reader web_read arguments did not fit";
    const guarded_again = m.call("web_read", reread_args, 60_000) orelse
        return "second GUI reader web_read timed out";
    const stale_id = readerEntityId(guarded_again, "Activate GUI Reader Target") orelse
        return "second GUI reader web_read did not restore the action guard";

    const mutate_args = std.fmt.bufPrint(&args, "{{\"pane\":{d},\"code\":\"document.getElementById('target').href='#stale';'retargeted'\"}}", .{pane}) catch
        return "GUI reader mutation eval arguments did not fit";
    const mutated = m.call("web_eval", mutate_args, 30_000) orelse return "GUI reader mutation eval timed out";
    if (std.mem.indexOf(u8, mutated, "retargeted") == null)
        return "GUI reader target could not be retargeted";
    const stale_args = std.fmt.bufPrint(&args, "{{\"pane\":{d},\"id\":{d},\"action\":\"click\"}}", .{ pane, stale_id }) catch
        return "GUI stale reader web_act arguments did not fit";
    const stale = m.call("web_act", stale_args, 60_000) orelse return "GUI stale reader action timed out";
    if (std.mem.indexOf(u8, stale, "stale reader id") == null or
        std.mem.indexOf(u8, stale, "isError") == null)
        return "GUI MCP adapter did not refuse the stale reader entity";
    return null;
}

fn muxHasSession(allocator: std.mem.Allocator, sock_path: []const u8, name: []const u8) ?bool {
    var conn = muxclient.Conn.connectProbed(allocator, sock_path) catch return null;
    defer conn.deinit();
    conn.setNonBlocking();
    conn.sendFrame(.list, "") catch return null;
    const frame = conn.recvExpectFor(&.{.welcome}, 5_000) catch return null;
    defer frame.deinit(allocator);
    const Listing = struct {
        sessions: []const struct { name: []const u8 = "" } = &.{},
    };
    var parsed = std.json.parseFromSlice(Listing, allocator, frame.payload, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    for (parsed.value.sessions) |session| {
        if (std.mem.eql(u8, session.name, name)) return true;
    }
    return false;
}

fn waitMuxSessionGone(allocator: std.mem.Allocator, sock_path: []const u8, name: []const u8) bool {
    var tries: u32 = 0;
    while (tries < 50) : (tries += 1) {
        if (muxHasSession(allocator, sock_path, name)) |present| {
            if (!present) return true;
        }
        if (drive) |app| _ = app.pumpOnce(20);
        _ = c.usleep(20_000);
    }
    return false;
}

/// Default isolated MCP plus the exact local pane origin, on the real
/// external-display/seat path.
fn mcpMuxPanelStage(
    allocator: std.mem.Allocator,
    app: *appdrive.App,
    mux_sock: [:0]const u8,
    session: [:0]const u8,
    gui_sock: [:0]const u8,
) ?[]const u8 {
    _ = app.drainLive(2_000);
    var term_win: u32 = 0;
    var toplevels_before: usize = 0;
    for (app.windows.items) |window| {
        if (window.popup) continue;
        toplevels_before += 1;
        if (term_win == 0) term_win = window.id;
    }
    if (term_win == 0) return "no terminal window for the mux-native MCP panel";

    var m = McpChild.spawnMuxPanel(allocator, mux_sock, session, null) orelse
        return "could not spawn default MCP with the local pane origin";
    defer m.close();
    if (!m.initialize()) return "the local-origin MCP server never answered initialize";

    const caps = m.call("capabilities", "{}", 20_000) orelse
        return "local-origin MCP capabilities timed out";
    if (std.mem.indexOf(u8, caps, "\\\"mode\\\":\\\"isolated\\\"") == null or
        std.mem.indexOf(u8, caps, "\\\"panels\\\":true") == null or
        std.mem.indexOf(u8, caps, "\\\"gui_socket\\\":false") == null or
        std.mem.indexOf(u8, caps, "\\\"selected\\\":\\\"mux_relay\\\"") == null)
        return "local-origin capabilities did not report isolated mux panels without a GUI socket";

    const gui_terms = m.call("list_terminals", "{}", 20_000) orelse
        return "isolated list_terminals timed out";
    if (std.mem.indexOf(u8, gui_terms, "isError") == null or
        std.mem.indexOf(u8, gui_terms, session) != null)
        return "the panel origin exposed its live pane through GUI terminal tools";
    const private_terms = m.call("term_list", "{}", 20_000) orelse
        return "isolated term_list timed out";
    if (std.mem.indexOf(u8, private_terms, session) != null)
        return "the panel origin leaked into the MCP private terminal roster";

    var baseline = app.frameRef(term_win, true) orelse
        return "could not capture the origin pane before ui_show";
    defer baseline.deinit(allocator);
    const shown = m.call("ui_show",
        \\{"name":"origin-pane","target":"pane","document":{"title":"Origin pane","root":"approve","components":{"approve":{"type":"button","text":"Approve local","action":"local-approve","class":["expand"]}}}}
    , 30_000) orelse return "local-origin ui_show timed out";
    if (std.mem.indexOf(u8, shown, "isError") != null) return "local-origin ui_show returned an error";
    const panel_id = parseNumAfter(shown, "\\\"panel_id\\\":") orelse
        return "local-origin ui_show returned no panel_id";
    if (!app.waitChangeSince(term_win, &baseline, 10_000, 0.02, null))
        return "the mux-relayed panel did not visibly replace its exact origin pane";
    var toplevels_after: usize = 0;
    for (app.windows.items) |window| if (!window.popup) {
        toplevels_after += 1;
    };
    if (toplevels_after != toplevels_before)
        return "target:pane opened a different window instead of using the origin pane";

    const button_point = waitOcrWordCenter(allocator, app, term_win, "Approve", 10_000);

    if (!m.startCall("ui_wait_event", "{\"name\":\"origin-pane\",\"timeout_ms\":20000}"))
        return "could not start local-origin ui_wait_event";
    var settle: u32 = 0;
    while (settle < 5) : (settle += 1) _ = app.pumpOnce(100);
    const window = app.winById(term_win) orelse return "the terminal window vanished under its panel";
    if (button_point) |click| {
        app.clickEx(term_win, click.x, click.y, 1, 100, 1) catch
            return "clicking the OCR-located mux panel button failed";
    } else {
        // Earlier stages deliberately leave a split tree alive. Probe the
        // centres of its pane quadrants, never the title/tab bars or edges;
        // only the relayed button can emit the action asserted below.
        const wf = @as(f64, @floatFromInt(window.w));
        const hf = @as(f64, @floatFromInt(window.h));
        for ([_][2]f64{
            .{ 0.25, 0.42 },
            .{ 0.75, 0.42 },
            .{ 0.25, 0.72 },
            .{ 0.75, 0.72 },
        }) |point| {
            app.clickEx(term_win, wf * point[0], hf * point[1], 1, 100, 1) catch
                return "clicking a mux panel pane quadrant failed";
            _ = app.pumpOnce(100);
        }
    }
    const event = m.recv(30_000) orelse return "local-origin ui_wait_event never answered";
    if (std.mem.indexOf(u8, event, "isError") != null or
        std.mem.indexOf(u8, event, "local-approve") == null or
        std.mem.indexOf(u8, event, "\\\"kind\\\":\\\"click\\\"") == null)
    {
        _ = c.fprintf(platform.stderr(), "smoke-e2e: local-origin event reply: %.*s\n", @as(c_int, @intCast(event.len)), event.ptr);
        return "local-origin ui_wait_event did not return the real button click";
    }

    const patched = m.call(
        "ui_patch",
        "{\"name\":\"origin-pane\",\"patch\":[{\"op\":\"title\",\"value\":\"Origin patched\"}]}",
        20_000,
    ) orelse return "local-origin ui_patch timed out";
    if (std.mem.indexOf(u8, patched, "isError") != null) return "local-origin ui_patch failed";
    const listed = m.call("ui_panels", "{}", 20_000) orelse return "local-origin ui_panels timed out";
    if (std.mem.indexOf(u8, listed, "Origin patched") == null)
        return "local-origin ui_panels did not report the patched live document";
    const saved = m.call("ui_save", "{\"name\":\"origin-pane\"}", 20_000) orelse
        return "local-origin ui_save timed out";
    if (std.mem.indexOf(u8, saved, "isError") != null) return "local-origin ui_save failed";
    if (savedRelayPanelMatchesLive(allocator, mux_sock, session, "origin-pane", panel_id)) |why| return why;

    const app_result = m.call(
        "launch_app",
        "{\"command\":[\"/bin/sh\",\"-c\",\"sleep 30\"],\"wait_for\":\"exit\",\"wait_ms\":100,\"stable_ms\":0}",
        20_000,
    ) orelse return "private launch_app timed out in the local-origin stage";
    const private_app_id = parseNumAfter(app_result, "\\\"app\\\":") orelse
        return "private launch_app returned no app id in the local-origin stage";
    if (std.mem.indexOf(u8, app_result, "\\\"exited\\\":true") != null)
        return "private launch_app was not alive during the local-origin isolation check";
    var private_name_buf: [96]u8 = undefined;
    const private_name = std.fmt.bufPrint(&private_name_buf, "mcpapp-{d}-1", .{m.pid}) catch
        return "private app session name did not fit";
    const origin_dir = std.fs.path.dirname(mux_sock) orelse
        return "local origin socket had no parent directory";
    var private_sock_buf: [512]u8 = undefined;
    const private_sock = std.fmt.bufPrint(&private_sock_buf, "{s}/mcp-tmp-{d}/mux.sock", .{ origin_dir, m.pid }) catch
        return "local private MCP socket path did not fit";
    if (!(muxHasSession(allocator, private_sock, private_name) orelse false))
        return "the live uniquely named MCP app was absent from its private daemon";
    if (muxHasSession(allocator, mux_sock, private_name) orelse
        return "could not inspect the local panel origin during the live isolation check")
        return "the live uniquely named MCP app appeared on the panel origin daemon";
    var close_args_buf: [64]u8 = undefined;
    const close_args = std.fmt.bufPrint(&close_args_buf, "{{\"app\":{d}}}", .{private_app_id}) catch
        return "private close_app arguments did not fit";
    const close_result = m.call("close_app", close_args, 20_000) orelse
        return "closing the live private app timed out";
    if (std.mem.indexOf(u8, close_result, "isError") != null)
        return "closing the live private app failed";
    if (!waitMuxSessionGone(allocator, private_sock, private_name))
        return "close_app did not remove the exact private app session";

    const closed = m.call("ui_close", "{\"name\":\"origin-pane\"}", 20_000) orelse
        return "local-origin ui_close timed out";
    if (std.mem.indexOf(u8, closed, "isError") != null) return "local-origin ui_close failed";
    const deleted = m.call("ui_delete", "{\"name\":\"origin-pane\"}", 20_000) orelse
        return "local-origin ui_delete timed out";
    if (std.mem.indexOf(u8, deleted, "isError") != null) {
        _ = c.fprintf(platform.stderr(), "smoke-e2e: local-origin delete reply: %.*s\n", @as(c_int, @intCast(deleted.len)), deleted.ptr);
        return "local-origin ui_delete failed";
    }
    _ = app.pumpOnce(500);
    const alive = roundtrip(allocator, gui_sock, "{\"cmd\":\"screen-info\",\"pane\":1}\n") orelse
        return "the origin pane stopped answering after ui_close";
    defer allocator.free(alive);
    if (std.mem.indexOf(u8, alive, "\"ok\":true") == null)
        return "ui_close did not restore the origin pane";
    return null;
}

/// The panel feature through a REAL `sketerm mcp` server: the exact
/// path an assistant takes. What only this proves is the MCP layer
/// itself — that `ui_show` reaches the GUI, that `ui_wait_event`'s
/// POLL loop returns a real seat click (it must not block the GUI, and
/// the GUI's own panel-events never waits), that `ui_save` with no
/// document persists the GUI's OWN live document (read back over
/// `panel-get` — including for a panel another process showed), and
/// that save/load/close and delete stay distinct operations.
fn mcpPanelStage(allocator: std.mem.Allocator, app: *appdrive.App, sock_path: [:0]const u8) ?[]const u8 {
    _ = app.drainLive(2_000);
    var known: [16]u32 = undefined;
    var n_known: usize = 0;
    for (app.windows.items) |w| {
        if (w.popup or n_known >= known.len) continue;
        known[n_known] = w.id;
        n_known += 1;
    }

    var m = McpChild.spawn(allocator, sock_path) orelse return "could not spawn `sketerm mcp`";
    defer m.close();
    if (!m.initialize()) return "the mcp server never answered initialize";

    // The GUI socket is attached, so panels are available — and the
    // preflight must say so.
    const caps = m.call("capabilities", "{}", 20_000) orelse return "capabilities timed out";
    if (std.mem.indexOf(u8, caps, "\\\"panels\\\":true") == null)
        return "capabilities does not report panels as available with a GUI socket";

    // 1. ui_show, with the document as a JSON OBJECT (the natural shape
    // for an assistant) rather than a pre-stringified document.
    const show = m.call("ui_show",
        \\{"name":"mcp-e2e","session":"","target":"window","document":{"title":"Epoch 41","root":"ok","components":{"ok":{"type":"button","text":"Approve","action":"approve","class":["expand"]}}}}
    , 30_000) orelse return "ui_show timed out";
    if (std.mem.indexOf(u8, show, "isError") != null) return "ui_show returned an error";
    const panel_id = parseNumAfter(show, "\\\"panel_id\\\":") orelse return "ui_show returned no panel_id";

    // A malformed document must come back with the parser's own text.
    const bad = m.call("ui_show",
        \\{"name":"mcp-bad","session":"","document":{"root":"r","components":{"r":{"type":"webview"}}}}
    , 20_000) orelse return "ui_show(bad) timed out";
    if (std.mem.indexOf(u8, bad, "isError") == null) return "a webview component was accepted through MCP";
    if (std.mem.indexOf(u8, bad, "webview") == null) return "the MCP rejection did not name the offending component";

    var waited: u32 = 0;
    const win_id = while (waited < 25_000) : (waited += 200) {
        if (hasToplevelOtherThan(app, known[0..n_known])) |id| break id;
        _ = app.pumpOnce(200);
    } else return "ui_show never mapped a panel window";
    _ = app.waitVisualSettle(win_id, 400, 10_000, 0.002, null);
    const pw = app.winById(win_id) orelse return "the MCP panel window vanished";

    // 2. ui_wait_event BLOCKS in the server while the GUI stays live:
    // start the call, then click the real seat, then read the reply.
    if (!m.startCall("ui_wait_event",
        \\{"name":"mcp-e2e","session":"","timeout_ms":20000}
    )) return "could not start ui_wait_event";
    // Give the server a moment to be inside its poll loop, pumping so
    // the compositor side keeps running.
    var settle: u32 = 0;
    while (settle < 5) : (settle += 1) _ = app.pumpOnce(100);
    app.clickEx(win_id, @as(f64, @floatFromInt(pw.w)) / 2, @as(f64, @floatFromInt(pw.h)) / 2, 1, 100, 1) catch
        return "clicking the MCP panel button failed";
    const ev = m.recv(30_000) orelse return "ui_wait_event never answered";
    if (std.mem.indexOf(u8, ev, "isError") != null) return "ui_wait_event returned an error";
    if (std.mem.indexOf(u8, ev, "timed_out") != null) return "ui_wait_event timed out on a real click";
    if (std.mem.indexOf(u8, ev, "approve") == null) return "ui_wait_event did not return the button's action";
    if (std.mem.indexOf(u8, ev, "\\\"kind\\\":\\\"click\\\"") == null) return "the MCP event was not a click";

    // 3. ui_patch updates the live document, ui_panels sees the new
    // title, and the panel is listed as live rather than saved.
    const patched = m.call("ui_patch",
        \\{"name":"mcp-e2e","session":"","patch":[{"op":"title","value":"Epoch 42"}]}
    , 20_000) orelse return "ui_patch timed out";
    if (std.mem.indexOf(u8, patched, "isError") != null) return "ui_patch returned an error";
    const listed = m.call("ui_panels", "{\"session\":\"\"}", 20_000) orelse return "ui_panels timed out";
    if (std.mem.indexOf(u8, listed, "Epoch 42") == null) return "ui_panels does not show the patched title";
    if (std.mem.indexOf(u8, listed, "\\\"saved\\\":[]") == null) return "ui_panels claims a saved document that was never saved";

    // 4. ui_save with no document persists what is on screen, patch
    // included. The server keeps NO copy of what it showed: it reads
    // the document back over panel-get, so the bytes on disk must equal
    // the live document byte for byte (both are doc.toJson canonical).
    const saved = m.call("ui_save", "{\"name\":\"mcp-e2e\",\"session\":\"\"}", 20_000) orelse
        return "ui_save timed out";
    if (std.mem.indexOf(u8, saved, "isError") != null) return "ui_save (from the live document) returned an error";
    if (savedPanelMatchesLive(allocator, sock_path, "", "mcp-e2e", panel_id)) |why| return why;

    // 4b. The hole a server-side mirror could never cover: a panel THIS
    // server never showed. It was shown over the control socket by this
    // smoke process, so only a read-back from the GUI can save it.
    const foreign_req =
        "{\"cmd\":\"panel-show\",\"name\":\"foreign\",\"session\":\"\",\"target\":\"window\"," ++
        "\"document\":\"{\\\"title\\\":\\\"Not mine\\\",\\\"root\\\":\\\"t\\\"," ++
        "\\\"components\\\":{\\\"t\\\":{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"shown by another process\\\"}}}\"}\n";
    const foreign = roundtrip(allocator, sock_path, foreign_req) orelse return "panel-show(foreign) roundtrip";
    defer allocator.free(foreign);
    if (std.mem.indexOf(u8, foreign, "\"ok\":true") == null) return "panel-show(foreign) not ok";
    const foreign_id = parseNumAfter(foreign, "\"panel_id\":") orelse return "foreign panel has no panel_id";
    _ = app.pumpOnce(300);
    const foreign_saved = m.call("ui_save", "{\"name\":\"foreign\",\"session\":\"\"}", 20_000) orelse
        return "ui_save(foreign) timed out";
    if (std.mem.indexOf(u8, foreign_saved, "isError") != null)
        return "ui_save could not persist a panel shown by another process";
    if (savedPanelMatchesLive(allocator, sock_path, "", "foreign", foreign_id)) |why| return why;
    {
        var fbuf: [128]u8 = undefined;
        const fclose_req = std.fmt.bufPrint(&fbuf, "{{\"cmd\":\"panel-close\",\"panel_id\":{d},\"session\":\"\"}}\n", .{foreign_id}) catch
            return "panel-close fmt";
        const fclosed = roundtrip(allocator, sock_path, fclose_req) orelse return "panel-close(foreign) roundtrip";
        defer allocator.free(fclosed);
        if (std.mem.indexOf(u8, fclosed, "\"ok\":true") == null) return "panel-close(foreign) not ok";
    }
    const dropped = m.call("ui_delete", "{\"name\":\"foreign\",\"session\":\"\"}", 20_000) orelse
        return "ui_delete(foreign) timed out";
    if (std.mem.indexOf(u8, dropped, "isError") != null) return "ui_delete(foreign) returned an error";
    _ = app.pumpOnce(300);

    // ui_save cannot invent a document for a panel that is not on
    // screen: that is a refusal, never a stale save.
    const ghost = m.call("ui_save", "{\"name\":\"never-shown\",\"session\":\"\"}", 20_000) orelse
        return "ui_save(ghost) timed out";
    if (std.mem.indexOf(u8, ghost, "isError") == null)
        return "ui_save claimed to save a panel that was never shown";
    const closed = m.call("ui_close", "{\"name\":\"mcp-e2e\",\"session\":\"\"}", 20_000) orelse
        return "ui_close timed out";
    if (std.mem.indexOf(u8, closed, "isError") != null) return "ui_close returned an error";
    _ = app.pumpOnce(500);
    const after_close = m.call("ui_panels", "{\"session\":\"\"}", 20_000) orelse return "ui_panels timed out";
    if (std.mem.indexOf(u8, after_close, "\\\"live\\\":[]") == null) return "a closed panel is still listed as live";
    if (std.mem.indexOf(u8, after_close, "Epoch 42") == null) return "ui_close destroyed the saved document";

    // 5. The saved document renders again, and ui_delete removes only
    // the stored copy.
    const reshown = m.call("ui_show",
        \\{"name":"mcp-e2e","session":"","target":"window","load":"mcp-e2e"}
    , 30_000) orelse return "ui_show(load) timed out";
    if (std.mem.indexOf(u8, reshown, "isError") != null) return "ui_show could not re-open the saved panel";
    _ = app.pumpOnce(500);
    const deleted = m.call("ui_delete", "{\"name\":\"mcp-e2e\",\"session\":\"\"}", 20_000) orelse
        return "ui_delete timed out";
    if (std.mem.indexOf(u8, deleted, "isError") != null) return "ui_delete returned an error";
    const final = m.call("ui_panels", "{\"session\":\"\"}", 20_000) orelse return "ui_panels timed out";
    if (std.mem.indexOf(u8, final, "\\\"saved\\\":[]") == null) return "ui_delete left the saved document behind";
    if (std.mem.indexOf(u8, final, "\\\"live\\\":[]") != null) return "ui_delete closed the live panel too";

    const gone = m.call("ui_close", "{\"name\":\"mcp-e2e\",\"session\":\"\"}", 20_000) orelse
        return "final ui_close timed out";
    if (std.mem.indexOf(u8, gone, "isError") != null) return "the re-opened panel could not be closed";
    _ = app.pumpOnce(500);
    return null;
}

/// Remote MCP origin -> remote daemon -> fake SSH GUI attachment -> native
/// panel cache. The logical source exists only as fd 900 in the remote daemon
/// and its workers, so GTK cannot accidentally pass by opening it itself.
fn remotePanelAssetStage(
    allocator: std.mem.Allocator,
    app: *appdrive.App,
    gui_sock: [:0]const u8,
    rt: []const u8,
) ?[]const u8 {
    const session = "remote-panel-assets";

    var gui_fd_buf: [64]u8 = undefined;
    const gui_fd_path = std.fmt.bufPrintZ(&gui_fd_buf, "/proc/{d}/fd/{d}", .{ child_pid, REMOTE_PANEL_ASSET_FD }) catch
        return "formatting the GUI asset-fd probe failed";
    if (c.access(gui_fd_path.ptr, c.F_OK) == 0)
        return "the GUI unexpectedly inherited the remote-only panel asset descriptor";

    var owner = muxclient.Conn.connectSsh(allocator, "localhost") catch
        return "could not connect to the fake-SSH daemon for the remote panel stage";
    defer owner.deinit();
    owner.sendJson(.spawn, .{
        .name = session,
        .argv = [_][]const u8{ "sh", "-c", "while :; do sleep 30; done" },
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
    }) catch return "could not send the remote panel session spawn";
    const spawned = owner.recvExpectFor(&.{.ok}, 10_000) catch
        return "the fake-SSH daemon did not spawn the remote panel session";
    spawned.deinit(allocator);

    // Neither `attach-session` nor `close-pane` answers with a pane id, and
    // the `list` reply carries no session field, so the origin pane's id can
    // only be learned by diffing the pane roster across the attach. The
    // teardown assertion at the end of this stage fences on it.
    const panes_before_attach = listedPaneIds(allocator, gui_sock) orelse
        return "could not list panes before the remote panel attach";
    defer allocator.free(panes_before_attach);

    var attach_buf: [192]u8 = undefined;
    const attach_req = std.fmt.bufPrint(
        &attach_buf,
        "{{\"cmd\":\"attach-session\",\"data\":\"{s}\",\"host\":\"localhost\"}}\n",
        .{session},
    ) catch return "formatting the remote panel attach failed";
    const attached = roundtrip(allocator, gui_sock, attach_req) orelse
        return "the GUI did not answer the remote panel attach";
    defer allocator.free(attached);
    if (std.mem.indexOf(u8, attached, "\"ok\":true") == null)
        return "the GUI refused the fake-SSH remote panel session";
    const origin_pane = newPaneId(allocator, gui_sock, panes_before_attach, 10_000) orelse
        return "the remote panel attach never produced a new pane";

    _ = app.drainLive(2_000);
    var known: [24]u32 = undefined;
    var n_known: usize = 0;
    for (app.windows.items) |window| {
        if (window.popup or n_known >= known.len) continue;
        known[n_known] = window.id;
        n_known += 1;
    }

    var remote_home_buf: [256]u8 = undefined;
    const remote_home = std.fmt.bufPrintZ(&remote_home_buf, "{s}/r", .{rt}) catch
        return "formatting the remote MCP home failed";
    var remote_sock_buf: [512]u8 = undefined;
    const remote_sock = std.fmt.bufPrintZ(&remote_sock_buf, "{s}/sketerm/mux.sock", .{remote_home}) catch
        return "formatting the remote MCP socket failed";
    var session_buf: [64]u8 = undefined;
    const session_z = std.fmt.bufPrintZ(&session_buf, "{s}", .{session}) catch
        return "formatting the remote MCP session failed";

    var m = McpChild.spawnMuxPanel(allocator, remote_sock, session_z, remote_home) orelse
        return "could not spawn a remote-origin `sketerm mcp`";
    defer m.close();
    if (!m.initialize()) return "the remote-origin MCP server never answered initialize";

    const caps = m.call("capabilities", "{}", 20_000) orelse
        return "remote-origin MCP capabilities timed out";
    if (std.mem.indexOf(u8, caps, "\\\"mode\\\":\\\"isolated\\\"") == null or
        std.mem.indexOf(u8, caps, "\\\"panels\\\":true") == null or
        std.mem.indexOf(u8, caps, "\\\"gui_socket\\\":false") == null or
        std.mem.indexOf(u8, caps, "\\\"selected\\\":\\\"mux_relay\\\"") == null)
        return "remote-origin capabilities did not report isolated mux panels";
    const gui_terms = m.call("list_terminals", "{}", 20_000) orelse
        return "remote-origin list_terminals timed out";
    if (std.mem.indexOf(u8, gui_terms, "isError") == null or
        std.mem.indexOf(u8, gui_terms, session) != null)
        return "the remote panel origin exposed its live pane through GUI terminal tools";
    const private_terms = m.call("term_list", "{}", 20_000) orelse
        return "remote-origin term_list timed out";
    if (std.mem.indexOf(u8, private_terms, session) != null)
        return "the remote panel origin leaked into the MCP private terminal roster";

    const app_result = m.call(
        "launch_app",
        "{\"command\":[\"/bin/sh\",\"-c\",\"sleep 30\"],\"wait_for\":\"exit\",\"wait_ms\":100,\"stable_ms\":0}",
        20_000,
    ) orelse return "private remote-side launch_app timed out";
    const private_app_id = parseNumAfter(app_result, "\\\"app\\\":") orelse
        return "private remote-side launch_app returned no app id";
    if (std.mem.indexOf(u8, app_result, "\\\"exited\\\":true") != null)
        return "private remote-side app was not alive during isolation proof";
    var private_name_buf: [96]u8 = undefined;
    const private_name = std.fmt.bufPrint(&private_name_buf, "mcpapp-{d}-1", .{m.pid}) catch
        return "remote private app session name did not fit";
    const remote_origin_dir = std.fs.path.dirname(remote_sock) orelse
        return "remote origin socket had no parent directory";
    var private_sock_buf: [512]u8 = undefined;
    const private_sock = std.fmt.bufPrint(&private_sock_buf, "{s}/mcp-tmp-{d}/mux.sock", .{ remote_origin_dir, m.pid }) catch
        return "remote private MCP socket path did not fit";
    if (!(muxHasSession(allocator, private_sock, private_name) orelse false))
        return "the live remote-side MCP app was absent from its private daemon";
    if (muxHasSession(allocator, remote_sock, private_name) orelse
        return "could not inspect the remote panel origin during isolation proof")
        return "the live remote-side MCP app appeared on the panel origin daemon";
    var close_args_buf: [64]u8 = undefined;
    const close_args = std.fmt.bufPrint(&close_args_buf, "{{\"app\":{d}}}", .{private_app_id}) catch
        return "remote close_app arguments did not fit";
    const close_result = m.call("close_app", close_args, 20_000) orelse
        return "closing the live remote-side private app timed out";
    if (std.mem.indexOf(u8, close_result, "isError") != null)
        return "closing the live remote-side private app failed";
    if (!waitMuxSessionGone(allocator, private_sock, private_name))
        return "close_app did not remove the exact remote-side private app session";

    // First prove the non-asset product path: a native GTK control from the
    // remote origin must paint and return a real seat interaction to MCP.
    const control_show = m.call("ui_show",
        \\{"name":"remote-control","session":"remote-panel-assets","target":"window","document":{"title":"Remote controls","root":"approve","components":{"approve":{"type":"button","text":"Approve remote","action":"remote-approve","class":["expand"]}}}}
    , 30_000) orelse return "remote control ui_show timed out";
    if (std.mem.indexOf(u8, control_show, "isError") != null)
        return "remote control ui_show returned an error";
    var waited: u32 = 0;
    const control_win = while (waited < 25_000) : (waited += 200) {
        if (hasToplevelOtherThan(app, known[0..n_known])) |id| break id;
        _ = app.pumpOnce(200);
    } else return "the remote native control never mapped a window";
    _ = app.waitVisualSettle(control_win, 400, 10_000, 0.002, null);
    // OCR is a HEURISTIC and must not be the product verdict here. The
    // real proof is the click below: it requires the button to have
    // painted, to be hittable at its centre, and to route a trusted
    // seat interaction back through MCP — strictly more than reading a
    // label. Measured: this exact frame renders "Approve remote"
    // correctly and tesseract reads it from a FILE, while the in-process
    // recognition of the same window returns nothing, so failing the
    // stage on it reported "the text did not render" about a frame that
    // plainly contained the text. The frame is kept either way.
    if (!viewerWaitOcr(allocator, app, control_win, "Approve remote", 10_000)) {
        if (app.screenshotPng(control_win, 1024, null, 0)) |shot| {
            defer allocator.free(shot.png);
            writePng("/tmp/sketerm-e2e-remote-control.png", shot.png);
        } else |_| {}
        say("remote control: OCR could not read the label; the click assertion below is the verdict");
    }
    if (!m.startCall(
        "ui_wait_event",
        "{\"name\":\"remote-control\",\"session\":\"remote-panel-assets\",\"timeout_ms\":20000}",
    )) return "could not start remote ui_wait_event";
    var settle: u32 = 0;
    while (settle < 5) : (settle += 1) _ = app.pumpOnce(100);
    const control_window = app.winById(control_win) orelse return "the remote control window vanished";
    app.clickEx(
        control_win,
        @as(f64, @floatFromInt(control_window.w)) / 2,
        @as(f64, @floatFromInt(control_window.h)) / 2,
        1,
        100,
        1,
    ) catch return "clicking the remote native control failed";
    const control_event = m.recv(30_000) orelse return "remote ui_wait_event never answered";
    if (std.mem.indexOf(u8, control_event, "isError") != null or
        std.mem.indexOf(u8, control_event, "remote-approve") == null or
        std.mem.indexOf(u8, control_event, "\\\"kind\\\":\\\"click\\\"") == null)
        return "the real remote control interaction did not return to MCP";
    const control_closed = m.call(
        "ui_close",
        "{\"name\":\"remote-control\",\"session\":\"remote-panel-assets\"}",
        20_000,
    ) orelse return "closing the remote control panel timed out";
    if (std.mem.indexOf(u8, control_closed, "isError") != null)
        return "closing the remote control panel failed";
    if (!waitWindowGone(app, control_win, 15_000))
        return "the remote control panel window did not close";

    // Resolver preservation is selective. Once A is hydrated, remove its
    // source: a title-only patch and a reset of B must not consult A again.
    const selective_a = std.fmt.allocPrintSentinel(allocator, "{s}/remote-selective-a.png", .{rt}, 0) catch
        return "allocating remote selective path A failed";
    defer allocator.free(selective_a);
    defer _ = c.unlink(selective_a.ptr);
    const selective_b = std.fmt.allocPrintSentinel(allocator, "{s}/remote-selective-b.png", .{rt}, 0) catch
        return "allocating remote selective path B failed";
    defer allocator.free(selective_b);
    defer _ = c.unlink(selective_b.ptr);
    if (!writeSolidPng(allocator, selective_a.ptr, 0x20, 0x80, 0xff) or
        !writeSolidPng(allocator, selective_b.ptr, 0xff, 0x90, 0x20))
        return "writing remote selective image fixtures failed";
    var selective_buf: [2400]u8 = undefined;
    const selective_show_args = std.fmt.bufPrint(
        &selective_buf,
        "{{\"name\":\"remote-selective\",\"session\":\"remote-panel-assets\",\"target\":\"window\"," ++
            "\"document\":{{\"title\":\"Selective\",\"root\":\"root\",\"components\":{{" ++
            "\"root\":{{\"type\":\"column\",\"children\":[\"a\",\"b\"]}}," ++
            "\"a\":{{\"type\":\"image\",\"src\":\"{s}\"}}," ++
            "\"b\":{{\"type\":\"image\",\"src\":\"{s}\"}}}}}}}}",
        .{ selective_a, selective_b },
    ) catch return "formatting remote selective show failed";
    const selective_show = m.call("ui_show", selective_show_args, 45_000) orelse
        return "remote selective ui_show timed out";
    if (std.mem.indexOf(u8, selective_show, "isError") != null or
        std.mem.indexOf(u8, selective_show, "\\\"asset_failures\\\":0") == null or
        std.mem.count(u8, selective_show, "\\\"sha256\\\"") != 2)
        return "remote selective ui_show did not hydrate both images";
    waited = 0;
    const selective_win = while (waited < 25_000) : (waited += 200) {
        if (hasToplevelOtherThan(app, known[0..n_known])) |id| break id;
        _ = app.pumpOnce(200);
    } else return "the remote selective panel never mapped";
    if (!waitForPanelColor(allocator, app, selective_win, .{ 0x20, 0x80, 0xff }, 12_000))
        return "remote selective image A did not render";
    if (c.unlink(selective_a.ptr) != 0) return "removing untouched remote image A failed";

    const title_only = m.call(
        "ui_patch",
        "{\"name\":\"remote-selective\",\"session\":\"remote-panel-assets\",\"patch\":[{\"op\":\"title\",\"value\":\"Still selective\"}]}",
        20_000,
    ) orelse return "title-only remote patch timed out";
    if (std.mem.indexOf(u8, title_only, "isError") != null or
        std.mem.indexOf(u8, title_only, "\\\"assets\\\":[]") == null or
        std.mem.indexOf(u8, title_only, "\\\"asset_failures\\\":0") == null)
        return "title-only remote patch rehydrated or replaced an untouched image";
    if (!waitForPanelColor(allocator, app, selective_win, .{ 0x20, 0x80, 0xff }, 5_000))
        return "title-only patch lost the prepared image whose source disappeared";

    if (!writeSolidPng(allocator, selective_b.ptr, 0xf0, 0x30, 0x60))
        return "rewriting selective image B failed";
    const selective_patch_args = std.fmt.bufPrint(
        &selective_buf,
        "{{\"name\":\"remote-selective\",\"session\":\"remote-panel-assets\",\"patch\":[" ++
            "{{\"op\":\"set\",\"id\":\"b\",\"component\":{{\"type\":\"image\",\"src\":\"{s}\"}}}}]}}",
        .{selective_b},
    ) catch return "formatting selective image patch failed";
    const selective_patch = m.call("ui_patch", selective_patch_args, 45_000) orelse
        return "selective image patch timed out";
    if (std.mem.indexOf(u8, selective_patch, "isError") != null or
        std.mem.indexOf(u8, selective_patch, "\\\"asset_failures\\\":0") == null or
        std.mem.count(u8, selective_patch, "\\\"sha256\\\"") != 1 or
        std.mem.indexOf(u8, selective_patch, selective_b) == null or
        std.mem.indexOf(u8, selective_patch, selective_a) != null)
        return "selective image patch hydrated more than the reset path";
    if (!waitForPanelColor(allocator, app, selective_win, .{ 0xf0, 0x30, 0x60 }, 12_000) or
        !waitForPanelColor(allocator, app, selective_win, .{ 0x20, 0x80, 0xff }, 5_000))
        return "selective image patch did not preserve A while replacing B";

    const selective_remove = m.call(
        "ui_patch",
        "{\"name\":\"remote-selective\",\"session\":\"remote-panel-assets\",\"patch\":[{\"op\":\"set\",\"id\":\"b\",\"component\":{\"type\":\"text\",\"text\":\"removed\"}}]}",
        20_000,
    ) orelse return "selective image removal timed out";
    if (std.mem.indexOf(u8, selective_remove, "isError") != null or
        std.mem.indexOf(u8, selective_remove, "\\\"assets\\\":[]") == null or
        !waitForPanelColor(allocator, app, selective_win, .{ 0x20, 0x80, 0xff }, 5_000))
        return "removing B disturbed untouched image A";
    const selective_closed = m.call(
        "ui_close",
        "{\"name\":\"remote-selective\",\"session\":\"remote-panel-assets\"}",
        20_000,
    ) orelse return "closing the remote selective panel timed out";
    if (std.mem.indexOf(u8, selective_closed, "isError") != null or
        !waitWindowGone(app, selective_win, 15_000))
        return "closing the remote selective panel failed";

    if (!m.startCall("ui_show",
        \\{"name":"remote-asset","session":"remote-panel-assets","target":"window","document":{"title":"Remote asset","root":"img","components":{"img":{"type":"image","src":"/proc/self/fd/900","caption":"remote blue"}}}}
    )) return "could not start remote asset ui_show";
    _ = c.usleep(250_000);
    const probe_started = clock.nowMs();
    const responsive = roundtrip(allocator, gui_sock, "{\"cmd\":\"list\"}\n") orelse
        return "GTK stopped serving control requests during remote image decode";
    defer allocator.free(responsive);
    if (std.mem.indexOf(u8, responsive, "\"ok\":true") == null or clock.nowMs() - probe_started > 600)
        return "remote image decode blocked the GTK main thread";
    const show = m.recv(45_000) orelse return "remote asset ui_show timed out";
    if (std.mem.indexOf(u8, show, "isError") != null) return "remote asset ui_show returned an error";
    if (std.mem.indexOf(u8, show, "\\\"asset_failures\\\":0") == null or
        std.mem.indexOf(u8, show, REMOTE_PANEL_ASSET_PATH) == null or
        std.mem.indexOf(u8, show, "\\\"sha256\\\"") == null)
        return "remote asset ui_show did not report a successful hydrated logical path";
    const first_sha_slice = escapedAssetSha(show) orelse
        return "remote asset ui_show returned no complete SHA-256 identity";
    var first_sha: [64]u8 = undefined;
    @memcpy(&first_sha, first_sha_slice);
    const panel_id = parseNumAfter(show, "\\\"panel_id\\\":") orelse
        return "remote asset ui_show returned no panel_id";
    var cache_root_buf: [512]u8 = undefined;
    const cache_root = std.fmt.bufPrintZ(
        &cache_root_buf,
        "{s}/sketerm/panel-assets/{d}",
        .{ rt, child_pid },
    ) catch return "formatting the process-isolated panel cache root failed";
    if (c.access(cache_root.ptr, c.R_OK) != 0)
        return "remote image hydration did not use the GUI process cache namespace";
    var wrong_cache_root_buf: [512]u8 = undefined;
    const wrong_cache_root = std.fmt.bufPrintZ(
        &wrong_cache_root_buf,
        "{s}/sketerm/panel-assets/{d}",
        .{ rt, c.getpid() },
    ) catch return "formatting the non-GUI cache root failed";
    if (c.access(wrong_cache_root.ptr, c.F_OK) == 0)
        return "the panel asset cache was shared across GUI and harness processes";

    waited = 0;
    const win_id = while (waited < 25_000) : (waited += 200) {
        if (hasToplevelOtherThan(app, known[0..n_known])) |id| break id;
        _ = app.pumpOnce(200);
    } else return "the hydrated remote image panel never mapped a window";
    if (!waitForPanelColor(allocator, app, win_id, .{ 0x20, 0x80, 0xff }, 12_000))
        return "the remote-only blue image never rendered in the GUI panel";

    if (!rewriteRemotePanelAsset(allocator, 0xf0, 0x30, 0x60))
        return "could not rewrite the remote daemon's panel asset descriptor";
    const patched = m.call("ui_patch",
        \\{"name":"remote-asset","session":"remote-panel-assets","patch":[{"op":"set","id":"img","component":{"type":"image","src":"/proc/self/fd/900","caption":"remote red"}}]}
    , 45_000) orelse return "same-path remote asset ui_patch timed out";
    if (std.mem.indexOf(u8, patched, "isError") != null) return "same-path remote asset ui_patch returned an error";
    if (std.mem.indexOf(u8, patched, "\\\"asset_failures\\\":0") == null or
        std.mem.indexOf(u8, patched, REMOTE_PANEL_ASSET_PATH) == null or
        std.mem.indexOf(u8, patched, "\\\"sha256\\\"") == null)
        return "same-path remote asset ui_patch did not report successful rehydration";
    const second_sha = escapedAssetSha(patched) orelse
        return "same-path remote asset ui_patch returned no complete SHA-256 identity";
    if (std.mem.eql(u8, &first_sha, second_sha))
        return "same-path remote bytes repainted but reused the old cache identity";
    if (!waitForPanelColor(allocator, app, win_id, .{ 0xf0, 0x30, 0x60 }, 12_000))
        return "rewriting the remote image at the same logical path did not repaint the panel";

    var requester = muxclient.connectPanelRequester(allocator, remote_sock, session, 10_000) catch
        return "could not attach a remote panel-get requester";
    defer requester.deinit();
    var get_buf: [96]u8 = undefined;
    const get_req = std.fmt.bufPrint(&get_buf, "{{\"cmd\":\"panel-get\",\"panel_id\":{d}}}", .{panel_id}) catch
        return "formatting remote panel-get failed";
    const live = panelRelayCall(allocator, &requester, 0x701, get_req) orelse
        return "remote panel-get did not return the live document";
    defer allocator.free(live);
    if (std.mem.indexOf(u8, live, REMOTE_PANEL_ASSET_PATH) == null)
        return "remote panel-get replaced the logical path with a cache path";
    if (std.mem.indexOf(u8, live, "/panel-assets/") != null)
        return "remote panel-get exposed the GUI's private asset cache";

    const saved = m.call("ui_save", "{\"name\":\"remote-asset\",\"session\":\"remote-panel-assets\"}", 45_000) orelse
        return "saving the hydrated remote panel timed out";
    if (std.mem.indexOf(u8, saved, "isError") != null) return "saving the hydrated remote panel failed";
    const loaded = m.call("ui_show",
        \\{"name":"remote-asset","session":"remote-panel-assets","target":"window","load":"remote-asset"}
    , 45_000) orelse return "loading the saved remote panel timed out";
    if (std.mem.indexOf(u8, loaded, "isError") != null) return "loading the saved remote panel failed";
    if (std.mem.indexOf(u8, loaded, "\\\"asset_failures\\\":0") == null)
        return "the saved remote panel no longer hydrated its image";
    const loaded_id = parseNumAfter(loaded, "\\\"panel_id\\\":") orelse
        return "loading the saved remote panel returned no panel_id";
    const get_loaded_req = std.fmt.bufPrint(&get_buf, "{{\"cmd\":\"panel-get\",\"panel_id\":{d}}}", .{loaded_id}) catch
        return "formatting loaded remote panel-get failed";
    const loaded_live = panelRelayCall(allocator, &requester, 0x702, get_loaded_req) orelse
        return "panel-get after remote ui_save/load timed out";
    defer allocator.free(loaded_live);
    if (std.mem.indexOf(u8, loaded_live, REMOTE_PANEL_ASSET_PATH) == null or
        std.mem.indexOf(u8, loaded_live, "/panel-assets/") != null)
        return "ui_save/load did not preserve the remote panel's logical image path";

    // Five tiny unique logical paths once failed at the fifth image because
    // four concurrent reads pessimistically reserved 4x16 MiB forever. All
    // descriptors name the same tiny inode, so actual-byte scheduling must let
    // the fifth read proceed after the first completion.
    const five = m.call("ui_show",
        \\{"name":"remote-asset","session":"remote-panel-assets","target":"window","document":{"title":"Five tiny","root":"root","components":{"root":{"type":"column","children":["i0","i1","i2","i3","i4"]},"i0":{"type":"image","src":"/proc/self/fd/900"},"i1":{"type":"image","src":"/proc/self/fd/901"},"i2":{"type":"image","src":"/proc/self/fd/902"},"i3":{"type":"image","src":"/proc/self/fd/903"},"i4":{"type":"image","src":"/proc/self/fd/904"}}}}
    , 45_000) orelse return "five-tiny remote asset ui_show timed out";
    if (std.mem.indexOf(u8, five, "isError") != null or
        std.mem.indexOf(u8, five, "\\\"asset_failures\\\":0") == null or
        std.mem.count(u8, five, "\\\"sha256\\\"") < 5)
        return "five tiny remote images did not all hydrate under the 64 MiB total cap";

    // Patch every image away in one transaction. The explicit empty resolver
    // releases old leases immediately, while panel-get and the widgets commit
    // the same zero-image document.
    const zero = m.call("ui_patch",
        \\{"name":"remote-asset","session":"remote-panel-assets","patch":[{"op":"set","id":"i0","component":{"type":"text","text":"zero"}},{"op":"set","id":"i1","component":{"type":"text","text":"zero"}},{"op":"set","id":"i2","component":{"type":"text","text":"zero"}},{"op":"set","id":"i3","component":{"type":"text","text":"zero"}},{"op":"set","id":"i4","component":{"type":"text","text":"zero"}}]}
    , 45_000) orelse return "zero-image remote patch timed out";
    if (std.mem.indexOf(u8, zero, "isError") != null or
        std.mem.indexOf(u8, zero, "\\\"assets\\\":[]") == null or
        std.mem.indexOf(u8, zero, "\\\"asset_failures\\\":0") == null)
        return "zero-image patch did not commit an explicit empty asset resolver";
    const zero_live = panelRelayCall(allocator, &requester, 0x703, get_loaded_req) orelse
        return "panel-get after zero-image patch timed out";
    defer allocator.free(zero_live);
    if (std.mem.indexOf(u8, zero_live, "/proc/self/fd/") != null)
        return "zero-image patch left image paths in the committed document";

    const restored = m.call("ui_show",
        \\{"name":"remote-asset","session":"remote-panel-assets","target":"window","document":{"title":"Remote asset","root":"img","components":{"img":{"type":"image","src":"/proc/self/fd/900","caption":"restored red"}}}}
    , 45_000) orelse return "restoring the remote image after zero-image patch timed out";
    if (std.mem.indexOf(u8, restored, "isError") != null or
        std.mem.indexOf(u8, restored, "\\\"asset_failures\\\":0") == null)
        return "remote image did not rehydrate after the zero-image transaction";
    if (!waitForPanelColor(allocator, app, win_id, .{ 0xf0, 0x30, 0x60 }, 12_000))
        return "restored remote image did not repaint after the zero-image transaction";

    // A failed patch never commits its candidate document/resolver/widgets.
    const failed_patch = m.call("ui_patch",
        \\{"name":"remote-asset","session":"remote-panel-assets","patch":[{"op":"remove","id":"ghost"}]}
    , 20_000) orelse return "failed remote transaction patch timed out";
    if (std.mem.indexOf(u8, failed_patch, "isError") == null or
        std.mem.indexOf(u8, failed_patch, "ghost") == null)
        return "invalid remote patch was not rejected transactionally";
    const after_failed = panelRelayCall(allocator, &requester, 0x704, get_loaded_req) orelse
        return "panel-get after failed remote patch timed out";
    defer allocator.free(after_failed);
    if (std.mem.indexOf(u8, after_failed, REMOTE_PANEL_ASSET_PATH) == null or
        std.mem.indexOf(u8, after_failed, "ghost") != null)
        return "failed remote patch diverged the live document from its resolver";
    if (!waitForPanelColor(allocator, app, win_id, .{ 0xf0, 0x30, 0x60 }, 5_000))
        return "failed remote patch changed the rendered widget state";

    if (!resizeRemotePanelAsset(panel_assets.MAX_ASSET_BYTES + 1))
        return "could not enlarge the remote panel asset past its byte limit";
    const oversized_started = clock.nowMs();
    const oversized = m.call("ui_patch",
        \\{"name":"remote-asset","session":"remote-panel-assets","patch":[{"op":"set","id":"img","component":{"type":"image","src":"/proc/self/fd/900","caption":"too large"}}]}
    , 45_000) orelse return "oversized remote asset ui_patch timed out";
    if (clock.nowMs() - oversized_started > 15_000)
        return "oversized remote asset refusal exceeded its bounded fast path";
    if (std.mem.indexOf(u8, oversized, "isError") != null or
        std.mem.indexOf(u8, oversized, "\\\"asset_failures\\\":1") == null or
        std.mem.indexOf(u8, oversized, "asset_warning") == null or
        std.mem.indexOf(u8, oversized, "per-file byte limit") == null or
        std.mem.indexOf(u8, oversized, REMOTE_PANEL_ASSET_PATH) == null)
        return "oversized remote asset did not return an explicit per-path warning";

    const missing_path = "/proc/self/fd/901";
    const missing_started = clock.nowMs();
    const missing = m.call("ui_patch",
        \\{"name":"remote-asset","session":"remote-panel-assets","patch":[{"op":"set","id":"img","component":{"type":"image","src":"/proc/self/fd/901","caption":"missing remote"}}]}
    , 45_000) orelse return "missing remote asset ui_patch timed out";
    if (clock.nowMs() - missing_started > 10_000)
        return "missing remote asset warning exceeded its bounded fast path";
    if (std.mem.indexOf(u8, missing, "isError") != null or
        std.mem.indexOf(u8, missing, "\\\"asset_failures\\\":1") == null or
        std.mem.indexOf(u8, missing, "asset_warning") == null or
        std.mem.indexOf(u8, missing, missing_path) == null or
        std.mem.indexOf(u8, missing, "\\\"error\\\":") == null)
        return "remote asset read failure did not return an explicit per-path warning";

    // Both sides fail independently. Their logical paths and reasons must be
    // painted in their own halves rather than collapsed to one generic error.
    const compare_failed = m.call("ui_show",
        \\{"name":"remote-asset","session":"remote-panel-assets","target":"window","document":{"title":"Both failed","root":"cmp","components":{"cmp":{"type":"image_compare","left":{"src":"/LEFTFAILURE"},"right":{"src":"/RIGHTFAILURE"}}}}}
    , 45_000) orelse return "both-failed image compare timed out";
    if (std.mem.indexOf(u8, compare_failed, "isError") != null or
        std.mem.indexOf(u8, compare_failed, "\\\"asset_failures\\\":2") == null or
        std.mem.indexOf(u8, compare_failed, "/LEFTFAILURE") == null or
        std.mem.indexOf(u8, compare_failed, "/RIGHTFAILURE") == null)
        return "both-failed image compare did not retain two path-specific errors";
    if (!viewerWaitOcr(allocator, app, win_id, "LEFTFAILURE", 10_000) or
        !viewerWaitOcr(allocator, app, win_id, "RIGHTFAILURE", 10_000))
        return "both image-compare path errors were not rendered explicitly";

    const deleted = m.call("ui_delete", "{\"name\":\"remote-asset\",\"session\":\"remote-panel-assets\"}", 20_000) orelse
        return "deleting the saved remote asset panel timed out";
    if (std.mem.indexOf(u8, deleted, "isError") != null) return "deleting the saved remote asset panel failed";

    // Hydrate one more valid image, then retire the Terminal origin. Its
    // panels go with it, later calls into the dead origin are refused, and the
    // GUI stays healthy through the teardown.
    if (!rewriteRemotePanelAsset(allocator, 0x10, 0xd0, 0x70))
        return "could not restore a valid image for origin-teardown coverage";
    const repatched = m.call("ui_patch",
        \\{"name":"remote-asset","session":"remote-panel-assets","patch":[{"op":"set","id":"cmp","component":{"type":"image","src":"/proc/self/fd/900","caption":"before teardown"}}]}
    , 30_000) orelse return "the pre-teardown patch timed out";
    if (std.mem.indexOf(u8, repatched, "isError") != null)
        return "the pre-teardown patch failed";
    const origin_closed = roundtrip(
        allocator,
        gui_sock,
        "{\"cmd\":\"close-pane\",\"session\":\"remote-panel-assets\"}\n",
    ) orelse return "closing the remote panel origin timed out";
    defer allocator.free(origin_closed);
    if (std.mem.indexOf(u8, origin_closed, "\"ok\":true") == null)
        return "the remote panel origin could not be closed";
    // Fence on the pane actually being gone, not on a fixed pump: the refusal
    // below is only meaningful once the origin has really been retired.
    if (!waitPaneGone(allocator, gui_sock, origin_pane, 15_000))
        return "the remote panel origin pane never went away";
    const after_teardown_patch = m.call("ui_patch",
        \\{"name":"remote-asset","session":"remote-panel-assets","patch":[{"op":"title","value":"after teardown"}]}
    , 20_000) orelse return "the post-teardown patch never resolved";
    // Any isError would also accept a document validation error, which would
    // say nothing about the dead origin. With no panel-capable attachment of
    // the session left, the route fails pre-delivery as `no compatible GUI`.
    if (std.mem.indexOf(u8, after_teardown_patch, "isError") == null)
        return "a patch into a torn-down panel origin reported success";
    if (std.mem.indexOf(u8, after_teardown_patch, "no compatible GUI is attached") == null)
        return "a patch into a torn-down panel origin failed for the wrong reason";
    const after_decode_teardown = roundtrip(allocator, gui_sock, "{\"cmd\":\"list\"}\n") orelse
        return "the GUI stopped serving after origin teardown";
    defer allocator.free(after_decode_teardown);
    if (std.mem.indexOf(u8, after_decode_teardown, "\"ok\":true") == null)
        return "the GUI became unhealthy after origin teardown";

    owner.sendJson(.kill, .{ .name = session }) catch return "could not send remote panel session cleanup";
    const killed = owner.recvExpectFor(&.{.ok}, 10_000) catch return "remote panel session cleanup was not acknowledged";
    killed.deinit(allocator);
    _ = app.pumpOnce(500);
    return null;
}

/// The bytes `ui_save` wrote must BE the panel's live document.
///
/// Both sides are `doc.Document.toJson` canonical output, so this is a
/// byte-for-byte comparison rather than a fuzzy one: a server-side
/// mirror that had drifted from the screen, or a save that stored
/// anything other than what the GUI holds, cannot pass it.
/// @return null when they match, else why they do not.
fn savedPanelMatchesLive(
    allocator: std.mem.Allocator,
    sock_path: [:0]const u8,
    session: []const u8,
    name: []const u8,
    panel_id: u32,
) ?[]const u8 {
    var req_buf: [128]u8 = undefined;
    const req = std.fmt.bufPrint(
        &req_buf,
        "{{\"cmd\":\"panel-get\",\"panel_id\":{d},\"session\":\"{s}\"}}\n",
        .{ panel_id, session },
    ) catch
        return "panel-get fmt";
    const resp = roundtrip(allocator, sock_path, req) orelse return "panel-get roundtrip";
    defer allocator.free(resp);
    if (std.mem.indexOf(u8, resp, "\"ok\":true") == null) return "panel-get not ok";

    return savedPanelResponseMatches(
        allocator,
        resp,
        @import("ipc/panelstore.zig").sessionScope(session),
        name,
    );
}

fn savedRelayPanelMatchesLive(
    allocator: std.mem.Allocator,
    mux_sock: [:0]const u8,
    session: []const u8,
    name: []const u8,
    panel_id: u32,
) ?[]const u8 {
    var requester = muxclient.connectPanelRequester(allocator, mux_sock, session, 10_000) catch
        return "relayed panel-get requester attach";
    defer requester.deinit();
    var req_buf: [128]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"panel-get\",\"panel_id\":{d}}}", .{panel_id}) catch
        return "relayed panel-get fmt";
    const resp = panelRelayCall(allocator, &requester, 0x5a9e, req) orelse
        return "relayed panel-get roundtrip";
    defer allocator.free(resp);
    if (std.mem.indexOf(u8, resp, "\"ok\":true") == null) return "relayed panel-get not ok";

    return savedPanelResponseMatches(
        allocator,
        resp,
        .{ .origin = .{
            .daemon_origin = mux_sock,
            .origin_id = requester.panelOriginId(),
            .label = session,
        } },
        name,
    );
}

fn savedPanelResponseMatches(
    allocator: std.mem.Allocator,
    response: []const u8,
    scope: @import("ipc/panelstore.zig").Scope,
    name: []const u8,
) ?[]const u8 {
    const panelstore = @import("ipc/panelstore.zig");

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch
        return "panel-get did not answer JSON";
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return "panel-get did not answer a JSON object",
    };
    const live = switch (obj.get("document") orelse return "panel-get carries no document") {
        .string => |str| str,
        else => return "panel-get's document is not a JSON string",
    };

    // This process shares XDG_STATE_HOME with the GUI and the MCP
    // server, so the store read here IS the one ui_save wrote.
    const stored = panelstore.loadJsonScoped(allocator, scope, name, null) catch
        return "ui_save wrote no document a store read can find";
    defer allocator.free(stored);
    if (!std.mem.eql(u8, stored, live))
        return "the saved bytes are not the panel's live document";
    return null;
}

/// Row count of pane 1's grid — the cheapest socket-visible proof that
/// a config change (font size) actually landed.
fn paneRows(allocator: std.mem.Allocator, sock_path: [:0]const u8) ?u32 {
    const resp = roundtrip(allocator, sock_path, "{\"cmd\":\"screen-info\",\"pane\":1}\n") orelse return null;
    defer allocator.free(resp);
    if (std.mem.indexOf(u8, resp, "\"ok\":true") == null) return null;
    return parseNumAfter(resp, "\"rows\":");
}

fn maxPaneId(allocator: std.mem.Allocator, response: []const u8) ?u32 {
    const Listing = struct {
        tabs: []const struct {
            panes: []const struct { id: u32 = 0 } = &.{},
        } = &.{},
    };
    var parsed = std.json.parseFromSlice(Listing, allocator, response, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    var maximum: ?u32 = null;
    for (parsed.value.tabs) |tab| for (tab.panes) |pane| {
        if (pane.id == 0) continue;
        if (maximum == null or pane.id > maximum.?) maximum = pane.id;
    };
    return maximum;
}

/// Retrieval WITHOUT an assistant: the user reopens his own saved
/// panel from the GUI, through the saved-panel picker the command
/// palette's "Open Saved Panel..." row opens.
///
/// Only a live run proves this. The picker dialog, the store read and
/// the mount all happen inside one GTK process, driven here by real
/// keystrokes on the session's seat. Two halves matter equally: a
/// stored document that still parses must come back on screen keyed
/// exactly as `panel-show` would key it, and a stored document that no
/// longer parses must be listed-but-unopenable rather than crash or
/// silently vanish. "Close Panel" then takes it down again.
///
/// The action is reached by a CONFIG KEYBIND rather than by typing its
/// name into the palette's search entry, because a GtkText cannot be
/// typed into on this display: the GUI child runs with
/// `GTK_IM_MODULE=wayland` and the session advertises
/// `zwp_text_input_manager_v3` (both deliberate — see
/// `editorInputStage`), so an entry that takes focus enables a
/// text-input and GTK then expects the compositor, not raw key events,
/// to produce its text. Nothing in this harness plays IME, so the
/// palette's entry stays empty. Everything AFTER the action is
/// dispatched is identical either way — `dispatchAction` is the one
/// path — and the picker itself takes plain key events because it has
/// no text entry at all.
fn panelPickerStage(
    allocator: std.mem.Allocator,
    app: *appdrive.App,
    sock_path: [:0]const u8,
    rt: []const u8,
) ?[]const u8 {
    const panelstore = @import("ipc/panelstore.zig");

    _ = app.drainLive(2_000);
    var term_win: u32 = 0;
    for (app.windows.items) |w| {
        if (w.popup) continue;
        term_win = w.id;
        break;
    }
    if (term_win == 0) return "no GUI window to drive the picker on";

    // The picker scopes to the FOCUSED pane's session, so pin the focus
    // first and learn that pane's session the way the subsystem itself
    // reports it (a panel-show with no explicit session echoes the
    // session it resolved to).
    const focused = roundtrip(allocator, sock_path, "{\"cmd\":\"focus\",\"pane\":1}\n") orelse
        return "focus roundtrip";
    defer allocator.free(focused);
    if (std.mem.indexOf(u8, focused, "\"ok\":true") == null) return "focusing pane 1 failed";

    const probe = roundtrip(
        allocator,
        sock_path,
        "{\"cmd\":\"panel-show\",\"name\":\"e2e-probe\",\"pane\":1,\"target\":\"window\"," ++
            "\"document\":\"{\\\"root\\\":\\\"r\\\",\\\"components\\\":{\\\"r\\\":{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"probe\\\"}}}\"}\n",
    ) orelse return "panel-show(probe) roundtrip";
    defer allocator.free(probe);
    if (std.mem.indexOf(u8, probe, "\"ok\":true") == null) return "panel-show(probe) not ok";
    const probe_id = parseNumAfter(probe, "\"panel_id\":") orelse return "probe has no panel_id";
    var daemon_origin_buf: [512]u8 = undefined;
    const daemon_origin = std.fmt.bufPrint(&daemon_origin_buf, "{s}/sketerm/mux.sock", .{rt}) catch
        return "formatting the picker daemon origin failed";
    var close_buf: [128]u8 = undefined;
    const close_probe = std.fmt.bufPrint(&close_buf, "{{\"cmd\":\"panel-close\",\"panel_id\":{d}}}\n", .{probe_id}) catch
        return "panel-close fmt";
    const probe_closed = roundtrip(allocator, sock_path, close_probe) orelse return "panel-close(probe) roundtrip";
    defer allocator.free(probe_closed);
    if (std.mem.indexOf(u8, probe_closed, "\"ok\":true") == null) return "panel-close(probe) not ok";
    _ = app.pumpOnce(500);

    // Attach that same local lifetime through an explicit `sock:/path` host.
    // The picker must classify the CONNECTED Unix transport as local and use
    // this exact daemon identity rather than rejecting any non-null host.
    var picker_session_buf: [64]u8 = undefined;
    const picker_session = std.fmt.bufPrint(&picker_session_buf, "picker-local-{d}", .{c.getpid()}) catch
        return "formatting custom-socket picker session failed";
    var picker_admin = muxclient.Conn.connectProbed(allocator, daemon_origin) catch
        return "connecting to spawn the custom-socket picker session failed";
    defer picker_admin.deinit();
    picker_admin.sendJson(.spawn, .{
        .name = picker_session,
        .argv = [_][]const u8{ "sh", "-c", "while :; do sleep 30; done" },
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
        .ttl_secs = @as(u32, 120),
    }) catch return "spawning the custom-socket picker session failed";
    (picker_admin.recvExpectFor(&.{.ok}, 10_000) catch
        return "custom-socket picker session spawn was not acknowledged").deinit(allocator);
    defer {
        picker_admin.sendJson(.kill, .{ .name = picker_session }) catch {};
        if (picker_admin.recvExpectFor(&.{.ok}, 5_000)) |reply| reply.deinit(allocator) else |_| {}
    }
    const before_custom = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse
        return "list before custom-socket picker attach";
    defer allocator.free(before_custom);
    const max_before_custom = maxPaneId(allocator, before_custom) orelse
        return "could not parse panes before custom-socket picker attach";
    var custom_attach_buf: [1024]u8 = undefined;
    const custom_attach_req = std.fmt.bufPrint(
        &custom_attach_buf,
        "{{\"cmd\":\"attach-session\",\"data\":\"{s}\",\"host\":\"sock:{s}\"}}\n",
        .{ picker_session, daemon_origin },
    ) catch return "formatting custom-socket picker attach failed";
    const custom_attached = roundtrip(allocator, sock_path, custom_attach_req) orelse
        return "custom-socket picker attach roundtrip";
    defer allocator.free(custom_attached);
    if (std.mem.indexOf(u8, custom_attached, "\"ok\":true") == null)
        return "the GUI refused a custom local sock: attachment";
    const after_custom = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse
        return "list after custom-socket picker attach";
    defer allocator.free(after_custom);
    const custom_pane = maxPaneId(allocator, after_custom) orelse
        return "the custom local sock: attachment created no pane";
    if (custom_pane <= max_before_custom)
        return "the custom local sock: attachment did not add a pane";
    var custom_focus_buf: [96]u8 = undefined;
    const custom_focus_req = std.fmt.bufPrint(&custom_focus_buf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{custom_pane}) catch
        return "formatting custom local pane focus failed";
    const custom_focused = roundtrip(allocator, sock_path, custom_focus_req) orelse
        return "custom local pane focus roundtrip";
    defer allocator.free(custom_focused);
    if (std.mem.indexOf(u8, custom_focused, "\"ok\":true") == null)
        return "the custom local pane could not be focused";

    var identity_probe = muxclient.connectPanelRequester(allocator, daemon_origin, picker_session, 5_000) catch
        return "reading the custom-socket picker session identity failed";
    defer identity_probe.deinit();
    if (identity_probe.panelOriginId().len != 32)
        return "custom-socket picker session attach carried no valid origin_id";
    const store_scope: panelstore.Scope = .{ .origin = .{
        .daemon_origin = daemon_origin,
        .origin_id = identity_probe.panelOriginId(),
        .label = picker_session,
    } };

    // The fixture: one document that parses, one that does not. This
    // process shares XDG_STATE_HOME with the GUI, so the store it
    // writes IS the store the GUI reads.
    const SAVED_DOC =
        "{\"version\":1,\"title\":\"Saved By Hand\",\"root\":\"r\",\"components\":" ++
        "{\"r\":{\"type\":\"heading\",\"text\":\"Reopened from the palette\",\"level\":2}}}";
    _ = panelstore.saveJsonScoped(allocator, store_scope, "e2e-saved", SAVED_DOC, null) catch
        return "saving the panel document failed";
    {
        const dir = panelstore.scopeDir(allocator, store_scope) catch return "resolving the session dir failed";
        defer allocator.free(dir);
        const broken = std.fmt.allocPrintSentinel(allocator, "{s}/e2e-broken.json", .{dir}, 0) catch return "alloc";
        defer allocator.free(broken);
        // Valid JSON, invalid document: the root names a component that
        // is not there, which is what `panelstore` calls Corrupt.
        if (!writeFile(broken, "{\"root\":\"gone\",\"components\":{}}"))
            return "could not stage the corrupt panel document";
    }
    {
        const listed = panelstore.listScoped(allocator, store_scope) catch return "listing the fixture failed";
        defer panelstore.freeList(allocator, listed);
        if (listed.len != 2) return "the panel fixture is not what the store reports";
        if (!std.mem.eql(u8, listed[0].name, "e2e-broken") or listed[0].ok)
            return "the corrupt fixture is not listed as unopenable";
        if (!std.mem.eql(u8, listed[1].name, "e2e-saved") or !listed[1].ok)
            return "the good fixture is not listed as openable";
    }

    // Bind the two palette actions to chords, and let the config
    // watcher pick the file up (the same live-apply this smoke already
    // proves in `configWatchStage`). The font size rides along purely
    // as an ACK: it changes the pane's cell grid, so `screen-info`
    // tells us when the new config is live — pressing the chord before
    // that would prove nothing.
    const rows_before = paneRows(allocator, sock_path) orelse return "screen-info before the config write";
    var cfg_buf: [4096]u8 = undefined;
    const cfg_path = std.fmt.bufPrintZ(&cfg_buf, "{s}/sketerm/config.conf", .{rt}) catch return "config path";
    if (!writeFile(cfg_path,
        \\# smoke: panel picker
        \\font_size = 13
        \\confirm_close = always
        \\keybind.panel_open = <Control><Shift>F9
        \\keybind.panel_close = <Control><Shift>F10
        \\
    )) return "could not write the keybind config";
    {
        var waited: u32 = 0;
        while (waited < 20_000) : (waited += 200) {
            _ = app.pumpOnce(200);
            const now = paneRows(allocator, sock_path) orelse continue;
            if (now != rows_before) break;
        } else return "the keybind config was written but never applied";
    }

    var list_buf: [256]u8 = undefined;
    const list_req = std.fmt.bufPrint(&list_buf, "{{\"cmd\":\"panel-list\",\"session\":\"{s}\"}}\n", .{picker_session}) catch
        return "panel-list fmt";

    const tabs_before = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse
        return "list before opening the saved panel";
    defer allocator.free(tabs_before);
    const ids_before = std.mem.count(u8, tabs_before, "\"id\":");
    const max_pane_before = maxPaneId(allocator, tabs_before) orelse
        return "could not parse panes before opening the saved panel";

    // The chord now opens the picker: the dialog covers a good part of
    // the window, so its arrival is a pixel fact rather than a guess.
    {
        _ = app.waitVisualSettle(term_win, 500, 8_000, 0.002, null);
        var ref = app.frameRef(term_win, true) orelse return "no baseline frame for the picker";
        defer ref.deinit(allocator);
        app.pressKey(term_win, "ctrl+shift+F9") catch return "injecting the panel_open chord failed";
        // The saved-panel list/parse worker only runs BETWEEN the chord and
        // the dialog's first paint, so probe repeatedly across that whole
        // transition instead of once after it: a single post-arrival probe
        // has no in-flight work left to trip over and cannot fail. Two
        // CONSECUTIVE slow samples are the failure, not one: a blocked main
        // loop keeps every probe waiting, while one 600ms sample on a loaded
        // box is scheduling noise.
        var picker_open = false;
        var picker_slow: u32 = 0;
        const picker_deadline = clock.nowMs() + 10_000;
        while (clock.nowMs() < picker_deadline) {
            if (guiResponsive(allocator, sock_path)) picker_slow = 0 else {
                picker_slow += 1;
                if (picker_slow >= 2) return "saved-panel list/parsing blocked GTK";
            }
            if (app.waitChangeSince(term_win, &ref, 250, 0.02, null)) {
                picker_open = true;
                break;
            }
        }
        if (!picker_open)
            return "the panel_open action never opened the saved-panel picker";
        _ = app.waitVisualSettle(term_win, 400, 8_000, 0.002, null);
    }

    var tries: u32 = 0;

    // The picker lists broken-then-good (sorted by name) and focuses the
    // first row. Activating the BROKEN one must mount nothing at all.
    app.pressKey(term_win, "Return") catch return "activating the broken row failed";
    _ = app.pumpOnce(900);
    {
        const after_broken = roundtrip(allocator, sock_path, list_req) orelse
            return "panel-list(after the broken row) roundtrip";
        defer allocator.free(after_broken);
        if (std.mem.indexOf(u8, after_broken, "\"name\":\"e2e-broken\"") != null)
            return "a corrupt stored document was mounted anyway";
    }

    // Down to the good row, Enter: it must mount, keyed (session, name),
    // in a tab of its own.
    app.pressKey(term_win, "Down") catch return "moving to the saved row failed";
    app.pressKey(term_win, "Down") catch return "moving to the final saved row failed";
    _ = app.pumpOnce(400);
    app.pressKey(term_win, "Return") catch return "opening the saved panel failed";

    var saved_panel_id: u32 = 0;
    var load_slow: u32 = 0;
    const open_deadline = clock.nowMs() + 10_000;
    while (clock.nowMs() < open_deadline) {
        _ = app.pumpOnce(50);
        _ = c.usleep(50_000);
        // The saved-document read/parse worker runs between the Return and the
        // panel showing up in panel-list, so the liveness probe belongs INSIDE
        // this poll: once the panel is up there is nothing left to block on.
        // Two consecutive slow samples are the failure, for the same reason as
        // the picker-open loop above.
        if (guiResponsive(allocator, sock_path)) load_slow = 0 else {
            load_slow += 1;
            if (load_slow >= 2) return "saved-panel load/parsing blocked GTK";
        }
        const live = roundtrip(allocator, sock_path, list_req) orelse continue;
        defer allocator.free(live);
        if (std.mem.indexOf(u8, live, "\"name\":\"e2e-saved\"") == null) continue;
        if (std.mem.indexOf(u8, live, "\"title\":\"Saved By Hand\"") == null)
            return "the reopened panel is not the saved document";
        if (std.mem.indexOf(u8, live, "\"target\":\"tab\"") == null)
            return "the picker opened the panel somewhere other than its own tab";
        saved_panel_id = parseNumAfter(live, "\"panel_id\":") orelse
            return "the reopened saved panel has no id";
        break;
    } else return "the picker never opened the saved panel";

    if (!waitIdCount(allocator, sock_path, ids_before + 2, true, 10_000))
        return "the saved panel did not create its tab and pane";
    const tabs_with_panel = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse
        return "list with the saved panel";
    defer allocator.free(tabs_with_panel);
    const panel_pane = maxPaneId(allocator, tabs_with_panel) orelse
        return "could not identify the saved panel pane";
    if (panel_pane <= max_pane_before) return "the saved panel pane identity did not advance";

    // This is the exact GUI command `ui_close` reaches. It must answer only
    // after detaching the face, even though closing the tab remains pending.
    var ui_close_buf: [128]u8 = undefined;
    const ui_close_req = std.fmt.bufPrint(&ui_close_buf, "{{\"cmd\":\"panel-close\",\"panel_id\":{d},\"session\":\"{s}\"}}\n", .{ saved_panel_id, picker_session }) catch
        return "formatting ui_close cancellation request failed";
    const ui_closed = roundtrip(allocator, sock_path, ui_close_req) orelse
        return "ui_close cancellation roundtrip";
    defer allocator.free(ui_closed);
    if (std.mem.indexOf(u8, ui_closed, "\"ok\":true") == null)
        return "ui_close did not report a detached panel";
    var closed = false;
    tries = 0;
    while (tries < 50 and !closed) : (tries += 1) {
        _ = app.pumpOnce(200);
        const live = roundtrip(allocator, sock_path, list_req) orelse continue;
        defer allocator.free(live);
        closed = std.mem.indexOf(u8, live, "\"name\":\"e2e-saved\"") == null;
    }
    if (!closed) return "Close Panel left the panel live";

    // confirm_close=always leaves the close-page request pending. The panel
    // must already be unregistered and detached before this cancellation.
    var stale_get_buf: [128]u8 = undefined;
    const stale_get_req = std.fmt.bufPrint(&stale_get_buf, "{{\"cmd\":\"panel-get\",\"panel_id\":{d},\"session\":\"{s}\"}}\n", .{ saved_panel_id, picker_session }) catch
        return "formatting panel-get after ui_close failed";
    const stale_get = roundtrip(allocator, sock_path, stale_get_req) orelse
        return "panel-get after ui_close roundtrip";
    defer allocator.free(stale_get);
    if (std.mem.indexOf(u8, stale_get, "\"ok\":false") == null)
        return "ui_close left the detached panel id addressable";
    // The confirm dialog maps asynchronously; an Escape that races it lands
    // in the terminal instead and the ORPHANED MODAL then dims the window
    // for every later pixel probe (found 2026-08-10 via a failure
    // screenshot: the pane-face stage's exact-color check failed under the
    // scrim while the panel had rendered perfectly). Settle until the
    // dialog is up, then require the visual change of it closing.
    _ = app.waitVisualSettle(term_win, 800, 10_000, 0.002, null);
    var escapes: u32 = 0;
    while (escapes < 3) : (escapes += 1) {
        var dlg_ref = app.frameRef(term_win, true) orelse
            return "no baseline frame for the close-confirm cancel";
        defer dlg_ref.deinit(allocator);
        app.pressKey(term_win, "Escape") catch return "canceling the panel tab close failed";
        if (app.waitChangeSince(term_win, &dlg_ref, 3_000, 0.02, null)) break;
    }
    if (escapes == 3) return "the close-confirm dialog never visibly closed";
    if (!waitIdCount(allocator, sock_path, ids_before + 2, true, 3_000))
        return "canceling panel tab closure did not leave the shell tab mounted";
    var panel_screen_buf: [96]u8 = undefined;
    const panel_screen_req = std.fmt.bufPrint(&panel_screen_buf, "{{\"cmd\":\"screen-info\",\"pane\":{d}}}\n", .{panel_pane}) catch
        return "formatting canceled panel-tab screen probe failed";
    const panel_screen = roundtrip(allocator, sock_path, panel_screen_req) orelse
        return "canceled panel-tab screen probe roundtrip";
    defer allocator.free(panel_screen);
    if (std.mem.indexOf(u8, panel_screen, "\"ok\":true") == null)
        return "canceling panel tab closure left no valid shell pane";

    // Closing is not deleting: both stored documents are still there.
    const still = panelstore.listScoped(allocator, store_scope) catch return "re-listing the store failed";
    defer panelstore.freeList(allocator, still);
    if (still.len != 2) return "closing a panel disturbed the stored documents";

    // Close a second picker while its delayed list worker is still running;
    // the handle must fence the eventual handback from every dead widget.
    const teardown_focus = roundtrip(allocator, sock_path, custom_focus_req) orelse
        return "focusing custom local pane before picker teardown failed";
    defer allocator.free(teardown_focus);
    // Same race class as the close-confirm above: an Escape fired before
    // the picker maps leaves the ORPHANED MODAL dimming every later pixel
    // probe. Wait for the picker to visibly appear, close it, and require
    // the visual change of it going away.
    var picker_ref = app.frameRef(term_win, true) orelse
        return "no baseline frame for the picker teardown";
    defer picker_ref.deinit(allocator);
    app.pressKey(term_win, "ctrl+shift+F9") catch return "reopening picker for teardown failed";
    if (!app.waitChangeSince(term_win, &picker_ref, 10_000, 0.02, null))
        return "the teardown picker never appeared";
    // Settle the open animation BEFORE taking the reference frame: a ref
    // captured mid-animation lets the animation itself satisfy the "it
    // closed" check below while Escape lands before the dialog takes input.
    _ = app.waitVisualSettle(term_win, 600, 8_000, 0.002, null);
    var picker_up = app.frameRef(term_win, true) orelse
        return "no mapped-picker frame for the teardown";
    defer picker_up.deinit(allocator);
    var picker_escapes: u32 = 0;
    while (picker_escapes < 3) : (picker_escapes += 1) {
        app.pressKey(term_win, "Escape") catch return "closing the teardown picker failed";
        if (app.waitChangeSince(term_win, &picker_up, 3_000, 0.02, null)) break;
    }
    if (picker_escapes == 3) return "the teardown picker never visibly closed";
    var teardown_waited: u32 = 0;
    while (teardown_waited < 1_400) : (teardown_waited += 100) _ = app.pumpOnce(100);
    const after_teardown = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse
        return "GUI stopped serving after picker worker teardown";
    defer allocator.free(after_teardown);
    if (std.mem.indexOf(u8, after_teardown, "\"ok\":true") == null)
        return "picker worker handback corrupted GUI state after teardown";

    // The cancellation assertion needs `always`; later window-lifecycle stages
    // use the normal policy and must not inherit an unrelated confirmation.
    if (!writeFile(cfg_path,
        \\# smoke: panel picker restored
        \\font_size = 13
        \\confirm_close = multiple
        \\keybind.panel_open = <Control><Shift>F9
        \\keybind.panel_close = <Control><Shift>F10
        \\
    )) return "could not restore confirm_close after the picker cancellation";
    var restore_waited: u32 = 0;
    while (restore_waited < 1_500) : (restore_waited += 100) _ = app.pumpOnce(100);

    // The pane the picker was driven from is still a working terminal.
    const alive = roundtrip(allocator, sock_path, "{\"cmd\":\"screen-info\",\"pane\":1}\n") orelse
        return "screen-info after the picker stage roundtrip";
    defer allocator.free(alive);
    if (std.mem.indexOf(u8, alive, "\"ok\":true") == null) return "the pane did not survive the picker stage";
    return null;
}

/// Show a panel ON an existing pane and close it again — the one
/// hosting shape whose teardown has a FUSE on it.
///
/// A pane face is unparented by `Pane.detachPanel` and then unref'd by
/// `PanelView.deinit`, but the pane's widget tree is not the only thing
/// holding a reference to it: GTK (and, with an accessibility bus up,
/// the AT context) can hold the last one for frames after the close
/// answered "ok". The view's ::destroy handler therefore runs LATER
/// than the free of the struct it points at — the use-after-free this
/// stage exists to catch, which killed the GUI a second or two after a
/// perfectly successful `panel-close`.
///
/// So the assertion is not that the close reports success (every
/// earlier stage already covers that) but that the GUI is still
/// SERVING seconds afterwards, with the display session pumping so the
/// deferred destroy actually gets a chance to fire. Three rounds,
/// because "whoever held the last reference" varies with what the
/// compositor did in between. A unit test cannot reach any of this: it
/// needs a real widget lifecycle on a real frame clock.
fn panePanelLifetimeStage(
    allocator: std.mem.Allocator,
    app: *appdrive.App,
    sock_path: [:0]const u8,
) ?[]const u8 {
    _ = app.drainLive(1_000);
    var term_win: u32 = 0;
    for (app.windows.items) |w| {
        if (w.popup) continue;
        term_win = w.id;
        break;
    }
    if (term_win == 0) return "no GUI window to host a pane panel on";

    const image_path = std.fmt.allocPrintSentinel(
        allocator,
        "/tmp/sketerm-panel-deferred-widget-{d}.png",
        .{c.getpid()},
        0,
    ) catch return "allocating deferred-widget image path failed";
    defer allocator.free(image_path);
    defer _ = c.unlink(image_path.ptr);
    if (!writeSolidPng(allocator, image_path.ptr, 0x35, 0xa0, 0xe0))
        return "writing deferred-widget image fixture failed";

    // Interactive components on purpose: a button and a slider each
    // carry their own heap signal context, so this also exercises the
    // per-component teardown alongside the view's own.
    var show_buf: [1800]u8 = undefined;
    const show_req = std.fmt.bufPrint(
        &show_buf,
        "{{\"cmd\":\"panel-show\",\"name\":\"e2e-life\",\"session\":\"e2e-scope\"," ++
            "\"target\":\"pane\",\"pane\":1,\"document\":\"{{\\\"title\\\":\\\"Lifetime\\\"," ++
            "\\\"root\\\":\\\"c\\\",\\\"components\\\":{{\\\"c\\\":{{\\\"type\\\":\\\"column\\\"," ++
            "\\\"children\\\":[\\\"h\\\",\\\"b\\\",\\\"s\\\",\\\"img\\\"]}}," ++
            "\\\"h\\\":{{\\\"type\\\":\\\"heading\\\",\\\"text\\\":\\\"On the pane\\\",\\\"level\\\":2}}," ++
            "\\\"b\\\":{{\\\"type\\\":\\\"button\\\",\\\"text\\\":\\\"Press\\\",\\\"action\\\":\\\"go\\\"}}," ++
            "\\\"s\\\":{{\\\"type\\\":\\\"slider\\\",\\\"min\\\":0,\\\"max\\\":10,\\\"value\\\":3}}," ++
            "\\\"img\\\":{{\\\"type\\\":\\\"image\\\",\\\"src\\\":\\\"{s}\\\"}}}}}}\"}}\n",
        .{image_path},
    ) catch return "formatting deferred-widget panel failed";

    var round: u32 = 0;
    while (round < 3) : (round += 1) {
        const shown = roundtrip(allocator, sock_path, show_req) orelse
            return "panel-show(pane face) roundtrip";
        defer allocator.free(shown);
        if (std.mem.indexOf(u8, shown, "\"ok\":true") == null) return "panel-show(pane face) not ok";
        const id = parseNumAfter(shown, "\"panel_id\":") orelse
            return "panel-show(pane face) reply has no panel_id";

        // Let the face realize and paint: an unrealized widget tree
        // hands out none of the extra references that make the destroy
        // deferred in the first place.
        _ = app.waitVisualSettle(term_win, 400, 8_000, 0.002, null);
        if (!waitForPanelColorAny(allocator, app, .{ 0x35, 0xa0, 0xe0 }, 12_000)) {
            // Dump every window before failing: an exact-color probe can
            // fail for reasons no assertion message can name (a leaked
            // modal's scrim shifting every pixel was found this way).
            for (app.windows.items, 0..) |window, wi| {
                if (window.popup) continue;
                const shot = app.screenshotPng(window.id, 0, null, 0) catch continue;
                defer allocator.free(shot.png);
                var name_buf: [96]u8 = undefined;
                const name = std.fmt.bufPrintZ(&name_buf, "/tmp/e2e-paneface-fail-w{d}.png", .{wi}) catch continue;
                const f = c.fopen(name.ptr, "wb") orelse continue;
                _ = c.fwrite(shot.png.ptr, 1, shot.png.len, f);
                _ = c.fclose(f);
                std.debug.print("smoke-e2e: DIAG dumped {s}\n", .{name});
            }
            return "pane panel image did not decode before deferred-finalization close";
        }

        var buf: [128]u8 = undefined;
        const close_req = std.fmt.bufPrint(&buf, "{{\"cmd\":\"panel-close\",\"panel_id\":{d},\"session\":\"e2e-scope\"}}\n", .{id}) catch
            return "panel-close fmt";
        const closed = roundtrip(allocator, sock_path, close_req) orelse
            return "panel-close(pane face) roundtrip";
        defer allocator.free(closed);
        if (std.mem.indexOf(u8, closed, "\"ok\":true") == null) return "panel-close(pane face) not ok";

        // The fuse. Keep the display session pumping and keep asking:
        // a GUI that faulted on the deferred destroy stops answering,
        // and `screen-info` is the cheapest round-trip that proves it
        // is both alive and still owning pane 1.
        var waited: u32 = 0;
        while (waited < 3_000) : (waited += 250) {
            _ = app.pumpOnce(250);
            const alive = roundtrip(allocator, sock_path, "{\"cmd\":\"screen-info\",\"pane\":1}\n") orelse
                return "the GUI stopped serving after a pane panel was closed";
            defer allocator.free(alive);
            if (std.mem.indexOf(u8, alive, "\"ok\":true") == null)
                return "the GUI went unhealthy after a pane panel was closed";
        }

        // And the panel really is gone, so the next round mounts a
        // fresh face rather than replacing a live one in place.
        const listed = roundtrip(allocator, sock_path, "{\"cmd\":\"panel-list\",\"session\":\"e2e-scope\"}\n") orelse
            return "panel-list(after the pane face closed) roundtrip";
        defer allocator.free(listed);
        if (std.mem.indexOf(u8, listed, "\"name\":\"e2e-life\"") != null)
            return "a closed pane panel is still listed";
    }
    return null;
}

/// A secondary window's `Window` struct is freed by
/// `deferredWindowFree` while GTK can still be finalizing its widgets.
/// Exercise all three owners that have regressed here: one Preferences
/// child per Window, sidebar callbacks retained by disposing widgets,
/// and the process-global `AdwStyleManager` singleton.
///
/// Its OWN GUI instance, for two reasons: the flip hook has to be set
/// in the environment at exec time, and a colour scheme changing every
/// 200ms would repaint the window under every pixel assertion the
/// other stages make. It shares the display session — a second viewer
/// is not needed, the same hub sees both instances' windows.
fn themeSingletonStage(
    allocator: std.mem.Allocator,
    maybe_app: ?*appdrive.App,
    rt: []const u8,
    wl: [*:0]const u8,
) ?[]const u8 {
    const app = maybe_app orelse return null;

    var theme_cfg_buf: [512:0]u8 = undefined;
    const theme_cfg = std.fmt.bufPrintZ(&theme_cfg_buf, "{s}/theme-config", .{rt}) catch
        return "allocating the theme config directory failed";
    if (c.mkdir(theme_cfg.ptr, 0o700) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST)
        return "creating the theme config directory failed";
    var theme_cfg_dir_buf: [512:0]u8 = undefined;
    const theme_cfg_dir = std.fmt.bufPrintZ(&theme_cfg_dir_buf, "{s}/sketerm", .{theme_cfg}) catch
        return "allocating the theme config parent failed";
    if (c.mkdir(theme_cfg_dir.ptr, 0o700) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST)
        return "creating the theme config parent failed";
    var cfg_path_buf: [512:0]u8 = undefined;
    const cfg_path = std.fmt.bufPrintZ(&cfg_path_buf, "{s}/config.conf", .{theme_cfg_dir}) catch
        return "theme config path";
    if (!writeFile(cfg_path, "# secondary-window lifetime smoke\nconfirm_close = never\n"))
        return "writing the theme config failed";

    // This GUI's windows are found by app_id below, not by diffing a
    // snapshot: its control socket appears before its toplevel reaches
    // the hub, so no pre-fork baseline can be trusted here.
    _ = app.drainLive(500);

    const pid = c.fork();
    if (pid < 0) return "fork for the theme GUI failed";
    if (pid == 0) {
        dieWithParent();
        _ = c.setenv("SKETERM_APP_ID", "dev.sker.sketerm.e2e.theme", 1);
        _ = c.setenv("WAYLAND_DISPLAY", wl, 1);
        _ = c.setenv("GDK_BACKEND", "wayland", 1);
        _ = c.unsetenv("DISPLAY");
        _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
        _ = c.setenv("GTK_A11Y", "none", 1);
        _ = c.setenv("SKETERM_VERIFY_TREE", "1", 1);
        _ = c.setenv("XDG_CONFIG_HOME", theme_cfg.ptr, 1);
        // The hook this stage exists for: nothing outside the process
        // can emit notify::dark (libadwaita takes the system preference
        // from the desktop portal only).
        _ = c.setenv("SKETERM_THEME_FLIP_MS", "200", 1);
        const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm", "--no-save", null };
        _ = c.execv("zig-out/bin/sketerm", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    theme_pid = pid;
    defer themeTeardown();

    const sock = std.fmt.allocPrintSentinel(allocator, "{s}/sketerm/{d}.sock", .{ rt, pid }, 0) catch
        return "alloc";
    defer allocator.free(sock);
    var waited: u32 = 0;
    while (c.access(sock.ptr, c.F_OK) != 0) {
        _ = c.usleep(100_000);
        waited += 1;
        if (waited > 200) return "the theme GUI never opened its control socket";
    }
    _ = app.drainLive(3_000);

    // Identify this GUI's windows by app_id, never by "appeared after a
    // snapshot": the control socket exists BEFORE the toplevel reaches the
    // hub, so a time-based baseline can miss the theme GUI's own primary
    // and then pick it as the "secondary". Closing that primary quits the
    // application (onWindowDestroyed -> g_application_quit) — a clean exit,
    // no core, no panic, which is exactly what the rare red here was.
    const theme_app_id = "dev.sker.sketerm.e2e.theme";
    var primary_id: u32 = 0;
    var primary_waited: u32 = 0;
    while (primary_waited < 15_000) : (primary_waited += 100) {
        _ = app.pumpOnce(100);
        var count: u32 = 0;
        for (app.windows.items) |w| {
            if (w.popup) continue;
            const id = w.app_id orelse continue;
            if (!std.mem.eql(u8, id, theme_app_id)) continue;
            count += 1;
            primary_id = w.id;
        }
        if (count == 1) break;
    }
    if (primary_id == 0) return "the theme GUI's own window never reached the display session";

    // A second tab, selected, so `detach_tab` moves a SINGLE-pane tab:
    // one pane means the confirm-close policy lets the window go
    // without putting a dialog up. A tab created over IPC is not
    // necessarily the selected one, hence the explicit focus.
    const opened = roundtrip(allocator, sock, "{\"cmd\":\"new-tab\"}\n") orelse
        return "new-tab(for detach) roundtrip";
    defer allocator.free(opened);
    if (std.mem.indexOf(u8, opened, "\"ok\":true") == null) return "new-tab(for detach) not ok";
    const pane = parseNumAfter(opened, "\"pane\":") orelse
        return "new-tab(for detach) reply has no pane id";

    var buf: [128]u8 = undefined;
    const focus_req = std.fmt.bufPrint(&buf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{pane}) catch
        return "focus fmt";
    const focused = roundtrip(allocator, sock, focus_req) orelse return "focus roundtrip";
    defer allocator.free(focused);
    if (std.mem.indexOf(u8, focused, "\"ok\":true") == null) return "focus not ok";

    const detached = roundtrip(allocator, sock, "{\"cmd\":\"action\",\"data\":\"detach_tab\"}\n") orelse
        return "detach_tab roundtrip";
    defer allocator.free(detached);
    if (std.mem.indexOf(u8, detached, "\"ok\":true") == null) return "detach_tab not ok";

    // Let the new toplevel map and paint: an unrealized window has not
    // handed out the references that make its teardown deferred.
    _ = app.drainLive(2_000);
    // The detached window is the theme GUI's OTHER window: same app_id,
    // different id from the primary we pinned above. Poll for it instead
    // of assuming it has been announced by now.
    var secondary: u32 = 0;
    var detach_waited: u32 = 0;
    while (detach_waited < 15_000) : (detach_waited += 100) {
        _ = app.pumpOnce(100);
        var found: u32 = 0;
        var candidate: u32 = 0;
        for (app.windows.items) |w| {
            if (w.popup) continue;
            const id = w.app_id orelse continue;
            if (!std.mem.eql(u8, id, theme_app_id)) continue;
            if (w.id == primary_id) continue;
            found += 1;
            candidate = w.id;
        }
        if (found == 1) {
            secondary = candidate;
            break;
        }
        if (found > 1) return "detach_tab produced more than one new theme window";
    }
    if (secondary == 0) return "detach_tab produced no new window on the display session";

    // A transferred pane's keyboard sink must target its NEW Window.
    // This catches stale shortcut_ctx directly: the source primary's
    // sidebar changing cannot produce a selected chip in `secondary`.
    app.pressKey(secondary, tree_toggle_key) catch return "injecting the transferred-pane sidebar shortcut failed";
    if (!waitSidebarVisible(app, secondary, true, 6_000))
        return "a transferred pane's shortcut still targeted its source Window";

    // THE per-window regression. Toggling one window's sidebar used to
    // write show_tab_sidebar to config.conf, and the reload watcher then
    // pushed that value into every other window — the user-visible bug.
    // The primary is a SEPARATE window of the same process, so if that
    // ever comes back it shows up right here.
    if (sidebarChipRight(app, primary_id) != 0)
        return "showing one window's sidebar also opened it in the other window";
    if (readFileAlloc(allocator, cfg_path)) |body| {
        defer allocator.free(body);
        if (std.mem.indexOf(u8, body, "show_tab_sidebar") != null)
            return "toggling a window's sidebar wrote show_tab_sidebar into config.conf";
    }
    // And the other direction: the primary takes its own sidebar, and
    // hiding the secondary's leaves the primary's alone.
    app.pressKey(primary_id, tree_toggle_key) catch return "injecting the primary window's sidebar shortcut failed";
    if (!waitSidebarVisible(app, primary_id, true, 6_000))
        return "the primary window's own sidebar shortcut did nothing";
    app.pressKey(secondary, tree_toggle_key) catch return "hiding the transferred-pane sidebar failed";
    if (!waitSidebarVisible(app, secondary, false, 6_000))
        return "hiding the transferred-pane sidebar did not hide it";
    if (sidebarChipRight(app, primary_id) == 0)
        return "hiding one window's sidebar also closed it in the other window";
    app.pressKey(primary_id, tree_toggle_key) catch return "hiding the primary window's sidebar failed";
    if (!waitSidebarVisible(app, primary_id, false, 6_000))
        return "the primary window's sidebar never went away again";

    // The dragged WIDTH is still a global preference, and a secondary
    // window must be able to write it. Done here rather than next to
    // the detach below because a Preferences child of this window is
    // open by then and the pointer no longer reaches its divider.
    app.pressKey(secondary, tree_toggle_key) catch return "reopening the transferred pane's sidebar failed";
    if (!waitSidebarVisible(app, secondary, true, 6_000))
        return "the transferred pane's sidebar did not reopen";
    // The divider sits a few pixels right of the row chips; which few
    // depends on the theme's list padding, so probe outwards rather
    // than guess.
    const before_w = sidebarChipRight(app, secondary);
    const divider_y = blk: {
        for (app.windows.items) |w| {
            if (w.id == secondary) break :blk @as(f64, @floatFromInt(w.h)) * 0.6;
        }
        break :blk 300.0;
    };
    var widened = false;
    for ([_]usize{ 8, 4, 12, 2, 16 }) |off| {
        const grab: f64 = @floatFromInt(before_w + off);
        app.drag(secondary, grab, divider_y, grab + 70, divider_y, 1) catch
            return "dragging the secondary window's sidebar divider failed";
        var wtries: u32 = 0;
        while (wtries < 10) : (wtries += 1) {
            if (sidebarChipRight(app, secondary) >= before_w + 40) {
                widened = true;
                break;
            }
            _ = app.pumpOnce(50);
        }
        if (widened) break;
    }
    if (!widened) return "the secondary window's sidebar divider never moved";
    var width_saved = false;
    var width_waited: u32 = 0;
    while (width_waited < 6_000) : (width_waited += 100) {
        _ = app.pumpOnce(100);
        if (readFileAlloc(allocator, cfg_path)) |body| {
            defer allocator.free(body);
            if (std.mem.indexOf(u8, body, "tab_sidebar_width = ") != null) {
                width_saved = true;
                break;
            }
        }
    }
    if (!width_saved) return "a secondary window's dragged sidebar width was never persisted";

    // Target by pane so the second request still resolves to the same
    // Window after its first Preferences child becomes GTK's active
    // toplevel. Opening twice must present, not duplicate, that child.
    var prefs_req_buf: [128]u8 = undefined;
    const prefs_req = std.fmt.bufPrint(&prefs_req_buf, "{{\"cmd\":\"action\",\"pane\":{d},\"data\":\"prefs_open\"}}\n", .{pane}) catch
        return "preferences request fmt";
    const prefs_first = roundtrip(allocator, sock, prefs_req) orelse return "opening secondary Preferences failed";
    defer allocator.free(prefs_first);
    if (std.mem.indexOf(u8, prefs_first, "\"ok\":true") == null) return "opening secondary Preferences was not ok";

    var prefs_id: u32 = 0;
    var prefs_waited: u32 = 0;
    while (prefs_waited < 15_000) : (prefs_waited += 100) {
        _ = app.pumpOnce(100);
        var count: u32 = 0;
        for (app.windows.items) |w| {
            if (w.popup) continue;
            const id = w.app_id orelse continue;
            const title = w.title orelse continue;
            if (!std.mem.eql(u8, id, theme_app_id) or !std.mem.eql(u8, title, "Preferences")) continue;
            count += 1;
            prefs_id = w.id;
        }
        if (count == 1) break;
        if (count > 1) return "opening Preferences once produced more than one window";
    }
    if (prefs_id == 0) return "the secondary Preferences window never reached the display session";

    const prefs_second = roundtrip(allocator, sock, prefs_req) orelse return "reopening secondary Preferences failed";
    defer allocator.free(prefs_second);
    if (std.mem.indexOf(u8, prefs_second, "\"ok\":true") == null) return "reopening secondary Preferences was not ok";
    var reuse_waited: u32 = 0;
    while (reuse_waited < 2_000) : (reuse_waited += 100) {
        _ = app.pumpOnce(100);
        var count: u32 = 0;
        for (app.windows.items) |w| {
            if (w.popup) continue;
            const id = w.app_id orelse continue;
            const title = w.title orelse continue;
            if (std.mem.eql(u8, id, theme_app_id) and std.mem.eql(u8, title, "Preferences")) count += 1;
        }
        if (count != 1) return "reopening Preferences did not reuse exactly one window";
    }

    // The same toggle over IPC, which reaches the window Preferences is
    // attached to. Sequential IPC requests are dispatched on the same
    // GLib main loop, so the toggle is applied before the detach that
    // follows. Detaching the secondary's only tab destroys its
    // now-empty source while Preferences is still open.
    var toggle_buf: [128]u8 = undefined;
    const toggle_req = std.fmt.bufPrint(&toggle_buf, "{{\"cmd\":\"action\",\"pane\":{d},\"data\":\"toggle_tab_sidebar\"}}\n", .{pane}) catch
        return "sidebar toggle request fmt";
    const toggled = roundtrip(allocator, sock, toggle_req) orelse
        return "toggling the secondary sidebar over IPC failed";
    defer allocator.free(toggled);
    if (std.mem.indexOf(u8, toggled, "\"ok\":true") == null) return "toggling the secondary sidebar over IPC was not ok";
    if (!waitSidebarVisible(app, secondary, false, 6_000))
        return "the IPC sidebar toggle did not hide the secondary's sidebar";
    var detach_again_buf: [128]u8 = undefined;
    const detach_again = std.fmt.bufPrint(&detach_again_buf, "{{\"cmd\":\"action\",\"pane\":{d},\"data\":\"detach_tab\"}}\n", .{pane}) catch
        return "second detach request fmt";
    const moved = roundtrip(allocator, sock, detach_again) orelse return "detaching from the secondary failed";
    defer allocator.free(moved);
    if (std.mem.indexOf(u8, moved, "\"ok\":true") == null) return "detaching from the secondary was not ok";
    var gone: u32 = 0;
    while (gone < 20_000) : (gone += 250) {
        _ = app.pumpOnce(250);
        if (app.windowGone(secondary) and app.windowGone(prefs_id)) break;
    }
    if (!app.windowGone(secondary)) return "the detached window never closed";
    if (!app.windowGone(prefs_id)) return "Preferences outlived its destroyed secondary parent";
    const saved = readFileAlloc(allocator, cfg_path) orelse return "closing the secondary lost its pending sidebar config write";
    defer allocator.free(saved);
    if (std.mem.indexOf(u8, saved, "tab_sidebar_width = ") == null)
        return "closing the secondary dropped the sidebar width it had persisted";
    if (std.mem.indexOf(u8, saved, "show_tab_sidebar") != null)
        return "the close-time config flush persisted a per-window sidebar toggle";

    // The fuse. `deferredWindowFree` runs on an idle after the destroy
    // chain unwinds, and the flip timer fires five times a second, so
    // by the end of this loop a handler left on the style manager has
    // dispatched into the freed Window many times over.
    var alive_waited: u32 = 0;
    while (alive_waited < 5_000) : (alive_waited += 250) {
        _ = app.pumpOnce(250);
        // A single failed connect is NOT proof the GUI died: this rig runs
        // on a loaded box and the control socket can refuse a connection
        // while the main loop is mid-frame. Only a REAPED child (or a
        // sustained refusal) is the crash this stage is a fuse for.
        var attempt: u32 = 0;
        const alive = while (attempt < 4) : (attempt += 1) {
            if (roundtrip(allocator, sock, "{\"cmd\":\"screen-info\",\"pane\":1}\n")) |resp| break resp;
            var status: c_int = 0;
            if (c.waitpid(theme_pid, &status, c.WNOHANG) == theme_pid) {
                theme_pid = 0;
                return "the GUI EXITED after a secondary window was closed under a theme flip";
            }
            _ = app.pumpOnce(250);
        } else return "the GUI stopped serving after a secondary window was closed under a theme flip";
        defer allocator.free(alive);
        if (std.mem.indexOf(u8, alive, "\"ok\":true") == null)
            return "the GUI went unhealthy after a secondary window was closed under a theme flip";
    }

    // This App viewer is shared with the main e2e GUI. Remove the
    // isolated process's windows and put keyboard focus back before
    // returning, or the next real-seat stage may target a stale id.
    themeTeardown();
    _ = app.drainLive(2_000);
    for (app.windows.items) |w| {
        if (w.popup) continue;
        const id = w.app_id orelse continue;
        if (!std.mem.eql(u8, id, "dev.sker.sketerm.e2e")) continue;
        app.pressKey(w.id, "escape") catch return "restoring main GUI keyboard focus failed";
        _ = app.waitIdle(200, 2_000);
        break;
    } else return "the main GUI disappeared during the secondary-window lifetime stage";
    return null;
}

/// A solid-colour PNG for the image_compare sides. Two visibly
/// different images make "the split moved" a real pixel assertion.
fn writeSolidPng(allocator: std.mem.Allocator, path: [*:0]const u8, r: u8, g: u8, b: u8) bool {
    const w: u32 = 160;
    const h: u32 = 120;
    const rgba = allocator.alloc(u8, w * h * 4) catch return false;
    defer allocator.free(rgba);
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        rgba[i] = r;
        rgba[i + 1] = g;
        rgba[i + 2] = b;
        rgba[i + 3] = 0xff;
    }
    const png = @import("util/png.zig").encodeRgba(allocator, rgba, w, h) catch return false;
    defer allocator.free(png);
    writePng(path, png);
    return true;
}

/// Rewrite the unlinked PNG inherited by the fake remote daemon. Opening the
/// broker's concrete proc path reaches the same inode every worker inherited,
/// while the panel's logical `/proc/self/fd/900` remains process-relative.
fn rewriteRemotePanelAsset(allocator: std.mem.Allocator, r: u8, g: u8, b: u8) bool {
    const w: u32 = 160;
    const h: u32 = 120;
    const rgba = allocator.alloc(u8, w * h * 4) catch return false;
    defer allocator.free(rgba);
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        rgba[i] = r;
        rgba[i + 1] = g;
        rgba[i + 2] = b;
        rgba[i + 3] = 0xff;
    }
    const png = @import("util/png.zig").encodeRgba(allocator, rgba, w, h) catch return false;
    defer allocator.free(png);

    var path_buf: [96]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/fd/{d}", .{ remote_mux_pid, REMOTE_PANEL_ASSET_FD }) catch
        return false;
    const file = c.fopen(path.ptr, "wb") orelse return false;
    const written = c.fwrite(png.ptr, 1, png.len, file) == png.len;
    const flushed = c.fflush(file) == 0;
    const synced = c.fsync(c.fileno(file)) == 0;
    const closed = c.fclose(file) == 0;
    return written and flushed and synced and closed;
}

fn resizeRemotePanelAsset(size: usize) bool {
    var path_buf: [96]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/fd/{d}", .{ remote_mux_pid, REMOTE_PANEL_ASSET_FD }) catch
        return false;
    const fd = c.open(path.ptr, c.O_WRONLY | c.O_CLOEXEC);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    return c.ftruncate(fd, @intCast(size)) == 0 and c.fsync(fd) == 0;
}

fn escapedAssetSha(reply: []const u8) ?[]const u8 {
    const key = "\\\"sha256\\\":\\\"";
    const at = std.mem.indexOf(u8, reply, key) orelse return null;
    const rest = reply[at + key.len ..];
    if (rest.len < 64) return null;
    for (rest[0..64]) |ch| switch (ch) {
        '0'...'9', 'a'...'f' => {},
        else => return null,
    };
    return rest[0..64];
}

fn panelColorPixels(rgba: []const u8, want: [3]u8) usize {
    var hits: usize = 0;
    var i: usize = 0;
    while (i + 3 < rgba.len) : (i += 4) {
        var matches = true;
        inline for (0..3) |channel| {
            const delta = @as(i32, rgba[i + channel]) - @as(i32, want[channel]);
            if (delta < -8 or delta > 8) matches = false;
        }
        if (matches) hits += 1;
    }
    return hits;
}

fn waitForPanelColor(
    allocator: std.mem.Allocator,
    app: *appdrive.App,
    win_id: u32,
    want: [3]u8,
    timeout_ms: u32,
) bool {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 200) {
        _ = app.pumpOnce(200);
        const shot = app.snapshotRgba(win_id, null) catch continue;
        defer allocator.free(shot.px);
        if (panelColorPixels(shot.px, want) >= 400) return true;
    }
    return false;
}

fn waitForPanelColorAny(
    allocator: std.mem.Allocator,
    app: *appdrive.App,
    want: [3]u8,
    timeout_ms: u32,
) bool {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 200) {
        _ = app.pumpOnce(200);
        for (app.windows.items) |window| {
            if (window.popup) continue;
            const shot = app.snapshotRgba(window.id, null) catch continue;
            defer allocator.free(shot.px);
            if (panelColorPixels(shot.px, want) >= 400) return true;
        }
    }
    return false;
}

/// The kitty keyboard protocol, end to end on a real seat. The
/// encoder itself is unit-tested; what only a live run can prove is
/// the layer between GDK and it — that the flags an application set
/// reach the encoder, that a hardware keycode translates to the right
/// unmodified key, and that a chord which produces no character at
/// all still arrives.
///
/// `cat -v` renders the control bytes as text, so the assertions read
/// the pane's own grid: no separate capture channel to get wrong.
fn kittyKbdStage(allocator: std.mem.Allocator, app: *appdrive.App, sock_path: [:0]const u8) ?[]const u8 {
    // One command line does the whole stage: `CSI > 1 u` pushes the
    // disambiguate flag the way a real application would, and the
    // tail pops it back off. `cat` gets a timeout because with the
    // flag on there is no longer any such thing as a Ctrl+D byte —
    // which is the point, and would otherwise wedge the pane.
    app.typeText(
        null,
        "printf '\\033[>1u'; echo KBDON; timeout 6 cat -v; printf '\\033[<1u'; echo KBDOFF\n",
    ) catch return "injecting the protocol-enable command failed";
    // Twice: once as the echoed command line, once as its output.
    if (!waitMarkerCount(allocator, sock_path, "KBDON", 2, 15_000))
        return "the shell never ran the protocol-enable command";

    // Ctrl+A: a chord with no character of its own. Under
    // disambiguate it must arrive as a full key report rather than
    // the legacy 0x01 byte — and the key number must be the 'a' key
    // itself, which only the keycode translation can supply.
    app.pressKey(null, "ctrl+a") catch return "injecting ctrl+a failed";
    // Up: a key that HAS a legacy encoding, which the protocol keeps.
    // Reporting a Private Use Area codepoint here instead would leave
    // the arrow keys dead in every application that does not
    // implement kitty's optional alias table.
    app.pressKey(null, "up") catch return "injecting up failed";
    app.typeText(null, "\n") catch return "injecting newline failed";

    if (!waitPaneText(allocator, sock_path, 1, "^[[97;5u", 10_000))
        return "ctrl+a did not arrive as a kitty key report";
    if (!waitPaneText(allocator, sock_path, 1, "^[[A", 10_000))
        return "the up arrow lost its legacy encoding under the protocol";

    // The tail of the command line pops the flags again, so the pane
    // is an ordinary shell for every stage after this one.
    if (!waitMarkerCount(allocator, sock_path, "KBDOFF", 2, 20_000))
        return "the pane never returned to a plain shell";
    return null;
}

/// Copy mode, driven from the seat and closed through the real system
/// clipboard: the yanked text is pasted back into the shell, so the
/// assertion is on the pane's own grid and covers the whole loop
/// (key sink → motions → selection → GTK clipboard → paste).
///
/// The word motions are what make this worth a live stage: `w` and
/// `e` have to agree about where a word begins and ends, and only the
/// round trip proves the selection they produced was the right one.
/// X of the image_compare panel's own split, found by its own pixels:
/// the rightmost BLUE pixel on row `y` before the orange half begins.
///
/// The drag used to start at the window's horizontal midpoint, on the
/// theory that "a drag anywhere on the surface moves the split". That
/// is false whenever the panel shares the window with another pane —
/// which it does here — because the midpoint is then the PANE divider,
/// and dragging it moves the split between panes while the panel sits
/// untouched and repaints nothing.
fn compareSplitX(allocator: std.mem.Allocator, app: *appdrive.App, win_id: u32, y: u32) ?f64 {
    const shot = app.snapshotRgba(win_id, null) catch return null;
    defer allocator.free(shot.px);
    if (y >= shot.h) return null;
    var last_blue: ?u32 = null;
    var x: u32 = 0;
    while (x < shot.w) : (x += 1) {
        const i = (y * shot.w + x) * 4;
        if (i + 2 >= shot.px.len) break;
        const r = shot.px[i];
        const g = shot.px[i + 1];
        const b = shot.px[i + 2];
        // The panel paints 0x2080ff; accept a wide band so a compositor
        // colour tweak does not silently stop finding it.
        if (b > 180 and r < 120 and g > 90 and g < 190) last_blue = x;
    }
    const lb = last_blue orelse return null;
    return @floatFromInt(lb);
}

/// Every pane id in a `list` reply, in order. Cleanup that closes "the
/// current tab" is not safe: after a few closes the selection can land
/// on the tab the rig started with, and closing THAT takes pane 1 with
/// it — every later stage then asserts against a pane that no longer
/// exists. Stages therefore record the ids they started with and close
/// only what they added.
fn listPaneIds(resp: []const u8, out: []u32) usize {
    var n: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, resp, from, "\"id\":")) |at| {
        from = at + 5;
        // A tab object also carries "id"; only pane objects are
        // followed by "title" then "cwd".
        const rest = resp[from..];
        const stop = std.mem.indexOfAny(u8, rest, ",}") orelse break;
        const id = std.fmt.parseInt(u32, rest[0..stop], 10) catch continue;
        const tail = rest[stop..];
        if (!std.mem.startsWith(u8, tail, ",\"title\"")) continue;
        if (std.mem.indexOf(u8, tail[0..@min(tail.len, 80)], "\"cwd\"") == null) continue;
        if (n < out.len) {
            out[n] = id;
            n += 1;
        }
    }
    return n;
}

fn contains(ids: []const u32, id: u32) bool {
    for (ids) |x| {
        if (x == id) return true;
    }
    return false;
}

/// Close every pane the stage added, leaving the ones it found alone.
fn closeAddedPanes(allocator: std.mem.Allocator, sock_path: [:0]const u8, app: *appdrive.App, keep: []const u32) void {
    var round: u32 = 0;
    while (round < 12) : (round += 1) {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse return;
        defer allocator.free(r);
        var now: [64]u32 = undefined;
        const n = listPaneIds(r, &now);
        var closed_any = false;
        for (now[0..n]) |id| {
            if (contains(keep, id)) continue;
            var buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrint(&buf, "{{\"cmd\":\"close-pane\",\"pane\":{d}}}\n", .{id}) catch continue;
            if (roundtrip(allocator, sock_path, cmd)) |cr| allocator.free(cr);
            closed_any = true;
            _ = app.waitIdle(200, 4_000);
            break;
        }
        if (!closed_any) return;
    }
}

/// A pane id in the SELECTED tab other than `not` — i.e. the pane a
/// split just created. Pane ids are monotonic and every earlier stage
/// that opened a tab consumes some, so the rig must never assume the
/// new pane is id 2; it was, until a stage was inserted ahead of this
/// one, and the assumption then failed a dozen stages downstream.
fn otherPaneInSelectedTab(resp: []const u8, not: u32) u32 {
    const at = std.mem.indexOf(u8, resp, "\"selected\":true") orelse return 0;
    const panes_at = std.mem.indexOfPos(u8, resp, at, "\"panes\":[") orelse return 0;
    const end = std.mem.indexOfScalarPos(u8, resp, panes_at, ']') orelse return 0;
    var from = panes_at;
    while (std.mem.indexOfPos(u8, resp, from, "\"id\":")) |idat| {
        if (idat >= end) break;
        from = idat + 5;
        const rest = resp[from..end];
        const stop = std.mem.indexOfAny(u8, rest, ",}") orelse break;
        const id = std.fmt.parseInt(u32, rest[0..stop], 10) catch continue;
        if (id != not) return id;
    }
    return 0;
}

/// Screen row of the LAST line containing `needle`, from a `get-text`
/// reply. `extractScreen` emits exactly one line per screen row, so
/// counting the escaped newlines before the hit gives the row.
fn screenRowOfLast(resp: []const u8, needle: []const u8) ?usize {
    const text_at = std.mem.indexOf(u8, resp, "\"text\":\"") orelse return null;
    const body = resp[text_at + 8 ..];
    const hit = std.mem.lastIndexOf(u8, body, needle) orelse return null;
    var row: usize = 0;
    var i: usize = 0;
    while (i + 1 < hit) : (i += 1) {
        if (body[i] == '\\' and body[i + 1] == 'n') {
            row += 1;
            i += 1;
        }
    }
    return row;
}

fn cursorRow(allocator: std.mem.Allocator, sock_path: [:0]const u8) ?usize {
    const resp = roundtrip(allocator, sock_path, "{\"cmd\":\"screen-info\",\"pane\":1}\n") orelse return null;
    defer allocator.free(resp);
    const at = std.mem.indexOf(u8, resp, "\"cursor_row\":") orelse return null;
    const rest = resp[at + 13 ..];
    const end = std.mem.indexOfAny(u8, rest, ",}") orelse return null;
    return std.fmt.parseInt(usize, rest[0..end], 10) catch null;
}

fn copyModeStage(allocator: std.mem.Allocator, app: *appdrive.App, sock_path: [:0]const u8) ?[]const u8 {
    // Three words sharing a prefix, so a motion that stops one word
    // early or late yanks something visibly different.
    app.typeText(null, "echo ZQalpha ZQbeta ZQgamma\n") catch return "injecting the sample line failed";
    // Twice: the echoed command line, and its output.
    if (!waitMarkerCount(allocator, sock_path, "ZQbeta", 2, 15_000)) {
        // Say WHICH way it went wrong: a pane that no longer exists, a
        // pane that is not focused, and a shell that is busy all look
        // identical from the marker count alone.
        if (roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n")) |l| {
            defer allocator.free(l);
            _ = c.fprintf(platform.stderr(), "smoke-e2e: tabs at copy-mode entry: %.*s\n", @as(c_int, @intCast(@min(l.len, 1200))), l.ptr);
        }
        if (roundtrip(allocator, sock_path, "{\"cmd\":\"get-text\",\"pane\":1}\n")) |t| {
            defer allocator.free(t);
            _ = c.fprintf(platform.stderr(), "smoke-e2e: pane 1 text: %.*s\n", @as(c_int, @intCast(@min(t.len, 1200))), t.ptr);
        }
        return "the sample line never reached the shell";
    }
    _ = app.waitIdle(300, 5_000);

    // WHERE the output line sits relative to the cursor is the user's
    // shell's business, not ours: a two-line prompt (and a prompt that
    // swaps itself for a taller one once the shell finishes starting,
    // which powerlevel10k-style themes do) puts it several rows up.
    // A fixed "k" once landed on the prompt and yanked from it, so the
    // row is measured instead of assumed.
    const out_row = blk: {
        const r = roundtrip(allocator, sock_path, "{\"cmd\":\"get-text\",\"pane\":1}\n") orelse
            return "get-text roundtrip failed before copy mode";
        defer allocator.free(r);
        break :blk screenRowOfLast(r, "ZQalpha") orelse
            return "the sample line is not on screen";
    };
    const cur_row = cursorRow(allocator, sock_path) orelse
        return "screen-info reported no cursor row";

    app.pressKey(null, "ctrl+shift+x") catch return "entering copy mode failed";
    _ = app.waitIdle(300, 5_000);
    // Onto the output line, to its start, then select the MIDDLE word:
    // w to its first character, e to its last.
    var steps: usize = 0;
    while (steps < 64 and cur_row > out_row + steps) : (steps += 1) {
        app.pressKey(null, "k") catch return "injecting a copy-mode motion failed";
        _ = app.waitIdle(120, 2_000);
    }
    while (steps < 64 and out_row > cur_row + steps) : (steps += 1) {
        app.pressKey(null, "j") catch return "injecting a copy-mode motion failed";
        _ = app.waitIdle(120, 2_000);
    }
    const motions = [_][]const u8{ "0", "w", "v", "e", "y" };
    for (motions) |key| {
        app.pressKey(null, key) catch return "injecting a copy-mode motion failed";
        _ = app.waitIdle(120, 2_000);
    }

    // Paste it back. A third occurrence can only come from the yank.
    app.pressKey(null, "ctrl+shift+v") catch return "pasting the yanked text failed";
    if (!waitMarkerCount(allocator, sock_path, "ZQbeta", 3, 10_000)) {
        if (roundtrip(allocator, sock_path, "{\"cmd\":\"get-text\",\"pane\":1}\n")) |resp| {
            defer allocator.free(resp);
            _ = c.fprintf(platform.stderr(), "smoke-e2e: copy-mode pane text: %.*s\n", @as(c_int, @intCast(@min(resp.len, 2000))), resp.ptr);
        }
        return "copy mode did not yank the word the motions selected";
    }
    // The word boundaries have to be exact: a selection that ran on
    // into the next word would have brought ZQgamma with it.
    if (waitMarkerCount(allocator, sock_path, "ZQgamma", 3, 1_000))
        return "the copy-mode selection overshot the word it was on";

    // Clear the pasted line so the pane is left at a clean prompt.
    app.pressKey(null, "ctrl+u") catch return "clearing the pasted line failed";
    _ = app.waitIdle(300, 5_000);
    return null;
}

/// Hint mode from the seat. The label keys are plain letters, which
/// is exactly what an input method claims first — the same trap copy
/// mode fell into — so this stage is here to keep them typeable.
/// Shift+label is the copy override, checked through a paste back.
fn hintsStage(allocator: std.mem.Allocator, app: *appdrive.App, sock_path: [:0]const u8) ?[]const u8 {
    // `clear` first: labels are handed out in reading order, so a
    // clean screen makes the first label deterministic.
    // `clear` wipes the echoed command line too, so exactly one
    // occurrence is left on screen — and exactly one hint to label.
    app.typeText(null, "clear; echo /tmp/zh-hint-file\n") catch return "injecting the hint sample failed";
    if (!waitMarkerCount(allocator, sock_path, "/tmp/zh-hint-file", 1, 15_000))
        return "the hint sample never reached the shell";
    _ = app.waitIdle(300, 5_000);

    app.pressKey(null, "ctrl+shift+e") catch return "entering hint mode failed";
    _ = app.waitIdle(300, 5_000);
    // Shift+label: copy whatever the match is, instead of its own
    // action (a path would otherwise try to open in an editor).
    app.pressKey(null, "shift+a") catch return "picking a hint label failed";
    _ = app.waitIdle(300, 5_000);

    app.pressKey(null, "ctrl+shift+v") catch return "pasting the hinted text failed";
    if (!waitMarkerCount(allocator, sock_path, "/tmp/zh-hint-file", 2, 10_000)) {
        if (roundtrip(allocator, sock_path, "{\"cmd\":\"get-text\",\"pane\":1}\n")) |resp| {
            defer allocator.free(resp);
            _ = c.fprintf(platform.stderr(), "smoke-e2e: hints pane text: %.*s\n", @as(c_int, @intCast(@min(resp.len, 2000))), resp.ptr);
        }
        return "the hint label never copied its match";
    }
    app.pressKey(null, "ctrl+u") catch return "clearing the pasted line failed";
    _ = app.waitIdle(300, 5_000);
    return null;
}

/// The overlay scrollbar, driven by real pointer input. The geometry
/// is unit-tested in `render/scrollbar.zig`; what only a live run can
/// prove is the wiring — that a press on the track reaches the
/// scrollbar BEFORE selection and before the app's mouse reporting,
/// and that dragging it actually moves the view.
///
/// The mouse-mode half is the point of the stage: with DECSET 1000
/// on, a pane that forwarded the press would both fail to scroll and
/// leave an `^[[<` report in the grid (`cat -v` renders it), so one
/// assertion catches either mistake.
fn scrollbarStage(allocator: std.mem.Allocator, app: *appdrive.App, sock_path: [:0]const u8) ?[]const u8 {
    if (app.windows.items.len == 0) return "the display session has no window to drive";
    const win = app.windows.items[0];
    const win_w: f64 = @floatFromInt(win.w);
    const win_h: f64 = @floatFromInt(win.h);
    if (win_w <= 0 or win_h <= 0) return "the GUI's window has no size";
    // Enough scrollback that one screenful is a small part of it.
    app.typeText(null, "clear; seq 1 400 | sed 's/.*/SBLINE&END/'\n") catch
        return "injecting the scrollback filler failed";
    if (!waitPaneText(allocator, sock_path, 1, "SBLINE400END", 25_000))
        return "the scrollback filler never ran";
    _ = app.waitIdle(300, 5_000);

    // The track hugs the PANE's right edge, which is NOT the
    // toplevel's: a client-side-decorated window carries a shadow
    // margin whose width the compositor negotiates. Measure it off a
    // real frame — the last fully opaque column is the pane's edge —
    // rather than hard-coding a margin that would rot.
    var track_x: f64 = 0;
    var bottom_y: f64 = 0;
    {
        const shot = app.snapshotRgba(win.id, null) catch return "snapshotting the window failed";
        defer allocator.free(shot.px);
        if (shot.w < 16 or shot.h < 16) return "the window frame is too small to locate the scrollbar";
        const mid_row = shot.h / 2;
        var right: u32 = shot.w;
        while (right > 0) : (right -= 1) {
            if (shot.px[(mid_row * shot.w + right - 1) * 4 + 3] == 255) break;
        }
        if (right < 8) return "no opaque content found on the window's right edge";
        // 3 px in: inside the 4 px track, clear of both the 2 px
        // focus border and the toplevel's own resize edge.
        const col = right - 3;
        var bottom: u32 = shot.h;
        while (bottom > 0) : (bottom -= 1) {
            if (shot.px[((bottom - 1) * shot.w + col) * 4 + 3] == 255) break;
        }
        if (bottom < 16) return "no opaque content found on the window's bottom edge";
        track_x = @floatFromInt(col);
        bottom_y = @floatFromInt(bottom - 10);
        _ = c.fprintf(
            platform.stderr(),
            "smoke-e2e: scrollbar track at x=%.0f, pane bottom at y=%.0f (surface %ux%u)\n",
            track_x,
            bottom_y,
            shot.w,
            shot.h,
        );
    }

    // 1. Grab the thumb (parked at the bottom) and drag it upward.
    //    The drag ENDS inside the window: a compositor that does not
    //    implement the implicit pointer grab stops delivering motion
    //    the moment the pointer leaves the surface.
    app.drag(win.id, track_x, bottom_y, track_x, win_h * 0.25, 1) catch
        return "dragging the scrollbar thumb failed";
    if (!waitPaneTextAbsent(allocator, sock_path, 1, "SBLINE400END", 10_000))
        return "dragging the scrollbar thumb did not scroll the view back";

    // 2. A click in the trough BELOW the thumb pages toward the
    //    click, the way every scrollbar does.
    const before = roundtrip(allocator, sock_path, "{\"cmd\":\"get-text\",\"pane\":1}\n") orelse
        return "reading the pane text before the trough click failed";
    defer allocator.free(before);
    app.click(win.id, track_x, bottom_y, 1) catch return "clicking the scrollbar trough failed";
    var waited: u32 = 0;
    const paged = while (waited < 10_000) : (waited += 200) {
        if (roundtrip(allocator, sock_path, "{\"cmd\":\"get-text\",\"pane\":1}\n")) |now| {
            defer allocator.free(now);
            if (!std.mem.eql(u8, now, before)) break true;
        }
        _ = c.usleep(200_000);
    } else false;
    if (!paged) return "a click in the scrollbar trough did not page the view";

    // 3. Same drag with the running app holding the mouse. `cat -v`
    //    makes any leaked report visible as text.
    app.typeText(null, "printf '\\033[?1000h'; echo MOUSEON; timeout 30 cat -v; printf '\\033[?1000l'; echo MOUSEOFF\n") catch
        return "injecting the mouse-mode command failed";
    if (!waitMarkerCount(allocator, sock_path, "MOUSEON", 2, 15_000))
        return "the shell never enabled mouse reporting";
    _ = app.waitIdle(300, 5_000);
    app.drag(win.id, track_x, bottom_y, track_x, win_h * 0.25, 1) catch
        return "dragging the scrollbar under mouse mode failed";
    if (!waitPaneTextAbsent(allocator, sock_path, 1, "MOUSEON", 10_000))
        return "the scrollbar stopped working once the app took the mouse";
    // Ctrl+D ends `cat` — and, being a keystroke, snaps the view back
    // to the live bottom so the tail markers are on screen again.
    app.pressKey(null, "ctrl+d") catch return "ending the mouse-mode command failed";
    if (!waitMarkerCount(allocator, sock_path, "MOUSEOFF", 2, 20_000))
        return "the pane never returned to a plain shell";
    // The whole session's text, so a report emitted while scrolled
    // back is still caught.
    if (roundtrip(allocator, sock_path, "{\"cmd\":\"get-text\",\"pane\":1,\"scrollback\":1}\n")) |all| {
        defer allocator.free(all);
        if (std.mem.indexOf(u8, all, "^[[<") != null)
            return "the scrollbar press was forwarded to the app as a mouse report";
    }
    app.typeText(null, "clear\n") catch return "clearing after the scrollbar stage failed";
    return null;
}

/// Poll a pane's text until `needle` is NOT in it.
fn waitPaneTextAbsent(
    allocator: std.mem.Allocator,
    sock: [:0]const u8,
    pane: u32,
    needle: []const u8,
    ms: u32,
) bool {
    var waited: u32 = 0;
    while (waited < ms) : (waited += 200) {
        var buf: [128]u8 = undefined;
        const req = std.fmt.bufPrint(&buf, "{{\"cmd\":\"get-text\",\"pane\":{d}}}\n", .{pane}) catch return false;
        if (roundtrip(allocator, sock, req)) |resp| {
            defer allocator.free(resp);
            if (std.mem.indexOf(u8, resp, needle) == null) return true;
        }
        _ = c.usleep(200_000);
    }
    return false;
}

/// Poll a pane's text until `needle` appears at least `want` times.
fn waitMarkerCount(
    allocator: std.mem.Allocator,
    sock: [:0]const u8,
    needle: []const u8,
    want: usize,
    ms: u32,
) bool {
    var waited: u32 = 0;
    while (waited < ms) : (waited += 200) {
        if (roundtrip(allocator, sock, "{\"cmd\":\"get-text\",\"pane\":1}\n")) |resp| {
            defer allocator.free(resp);
            if (std.mem.count(u8, resp, needle) >= want) return true;
        }
        _ = c.usleep(200_000);
    }
    return false;
}

/// Poll `list` until it reports the wanted number of `"id":` fields
/// (tab + panes). Split and close are asynchronous on the GUI side
/// (widget teardown, daemon session kill), so a fixed sleep here is a
/// flake generator the moment the machine is loaded.
fn waitIdCount(allocator: std.mem.Allocator, sock_path: [:0]const u8, want: usize, exact: bool, ms: u32) bool {
    var waited: u32 = 0;
    while (true) {
        const resp = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse return false;
        const n = std.mem.count(u8, resp, "\"id\":");
        const ok = std.mem.indexOf(u8, resp, "\"ok\":true") != null;
        allocator.free(resp);
        if (ok and (if (exact) n == want else n >= want)) return true;
        if (waited >= ms) return false;
        _ = c.usleep(100_000);
        waited += 100;
    }
}

fn waitPaneGone(allocator: std.mem.Allocator, sock_path: [:0]const u8, pane: u32, ms: u32) bool {
    var waited: u32 = 0;
    while (true) {
        var buf: [128]u8 = undefined;
        const req = std.fmt.bufPrint(&buf, "{{\"cmd\":\"screen-info\",\"pane\":{d}}}\n", .{pane}) catch return false;
        const resp = roundtrip(allocator, sock_path, req) orelse return false;
        const gone = std.mem.indexOf(u8, resp, "\"ok\":false") != null and
            std.mem.indexOf(u8, resp, "no such pane") != null;
        allocator.free(resp);
        if (gone) return true;
        if (waited >= ms) return false;
        _ = c.usleep(100_000);
        waited += 100;
    }
}

/// The editor tab is the active tab and fills the window, so a click in
/// the middle lands on its canvas. Drives Ctrl+F (opens a GtkEntry —
/// unreachable over IPC, which is why this used to be an X-only check)
/// and asserts the pixels changed both on open and on Escape.
fn editorInputStage(allocator: std.mem.Allocator, app: *appdrive.App) ?[]const u8 {
    _ = app.drainLive(3_000);
    if (app.windows.items.len == 0) return "the display session lost its window";
    const win_id = app.windows.items[0].id;
    const cx = @as(f64, @floatFromInt(app.windows.items[0].w)) / 2;
    const cy = @as(f64, @floatFromInt(app.windows.items[0].h)) / 2;

    app.clickEx(win_id, cx, cy, 1, 100, 1) catch return "clicking the editor canvas failed";
    _ = app.waitIdle(300, 5_000);

    // GTK only creates a zwp_text_input_v3 when a GtkIMMulticontext
    // resolves to the Wayland IM module, which needs BOTH a compositor
    // advertising text-input-v3 and a face that asked for a real IME
    // (the GUI child runs with GTK_IM_MODULE=wayland). Under X11 this
    // object cannot exist at all — which is precisely why input
    // verification there was worthless.
    var im_tries: u32 = 0;
    while (im_tries < 50 and textInputCount(app) == 0) : (im_tries += 1) _ = app.pumpOnce(100);
    if (textInputCount(app) == 0)
        return "the focused editor created no zwp_text_input_v3 — GTK is NOT on its Wayland input-method path";

    var ref = app.frameRef(win_id, true) orelse return "no baseline frame for the editor";
    defer ref.deinit(allocator);
    app.pressKey(null, "ctrl+f") catch return "injecting ctrl+f failed";
    if (!app.waitChangeSince(win_id, &ref, 15_000, 0.02, null))
        return "ctrl+f on a real seat did not change the editor's pixels (no search bar?)";

    var ref2 = app.frameRef(win_id, true) orelse return "no post-search frame";
    defer ref2.deinit(allocator);
    app.pressKey(null, "escape") catch return "injecting escape failed";
    if (!app.waitChangeSince(win_id, &ref2, 15_000, 0.02, null))
        return "escape did not close the editor's search bar";
    return null;
}

/// Dead-key composition end to end, on a Belgian (AZERTY) seat.
///
/// The one input behaviour that no codepoint-based injection can reach:
/// `ipc/xkblayout.zig` skips every dead keysym, so `typeText("^")` is
/// impossible by construction. This stage injects raw evdev HARDWARE
/// keycodes instead (`App.tapKeyCodes`) — keymap-independent, exactly
/// what a physical keyboard puts on the wire — and lets the session's
/// Belgian keymap turn code 26 into `dead_circumflex` and code 18 into
/// `e`. What must come out is one composed `ê`.
///
/// Its own display session, because a session's keymap is fixed at
/// creation. Its own GUI instance, because that instance must run
/// WITHOUT `GTK_IM_MODULE=wayland`: that variable is what makes the
/// main instance's editor face take a GtkIMMulticontext, and a
/// multicontext on Wayland resolves to GTK's `wayland` IM module, which
/// carries no compose engine at all (see ui/imhost.zig). Composition is
/// GtkIMContextSimple's job, and `auto` picks it only when the session
/// declares no real input method. So both instances are needed: the
/// main one proves the IME/text-input-v3 path exists, this one proves
/// the compose path works — in BOTH faces.
fn deadKeyStage(allocator: std.mem.Allocator, rt: []const u8, mux_sock: []const u8) ?[]const u8 {
    // ── a Belgian display session ─────────────────────────────────
    var wl_z: [4096:0]u8 = undefined;
    {
        const r = runDisplayCli(allocator, &.{
            "create", "--name",    DEADKEY_SESSION, "--kb-layout", "be",
            "--ttl",  DISPLAY_TTL, "--json",        "--socket",    mux_sock,
        });
        defer allocator.free(r.out);
        if (r.code != 0) return "could not create a Belgian-layout display session";
        dk_ready = true;
        var parsed = std.json.parseFromSlice(CreateReply, allocator, r.out, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return "the Belgian display create did not answer the documented JSON";
        defer parsed.deinit();
        const wl = parsed.value.environment.WAYLAND_DISPLAY;
        if (wl.len == 0 or wl[0] != '/') return "the Belgian display returned no absolute WAYLAND_DISPLAY";
        _ = std.fmt.bufPrintZ(&wl_z, "{s}", .{wl}) catch return "WAYLAND_DISPLAY too long";
    }

    // Attach before the GUI starts — the compositor brain is
    // client-side, so an unattended hub configures no toplevel.
    dk_drive = appdrive.App.attachExisting(allocator, DEADKEY_SESSION, "be", mux_sock) catch
        return "could not attach a viewer to the Belgian display session";
    const app = dk_drive.?;

    const pid = c.fork();
    if (pid < 0) return "fork for the Belgian GUI failed";
    if (pid == 0) {
        dieWithParent();
        _ = c.setenv("SKETERM_APP_ID", "dev.sker.sketerm.e2e.deadkey", 1);
        _ = c.setenv("WAYLAND_DISPLAY", &wl_z, 1);
        _ = c.setenv("GDK_BACKEND", "wayland", 1);
        _ = c.unsetenv("DISPLAY");
        _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
        // The whole point of a second instance: no declared input
        // method, so `input_method = auto` resolves BOTH faces to
        // GtkIMContextSimple and compose/dead keys are live.
        _ = c.unsetenv("GTK_IM_MODULE");
        _ = c.setenv("SKETERM_VERIFY_TREE", "1", 1);
        // Same hermeticity rule as the primary GUI child above.
        _ = c.setenv("GTK_A11Y", "none", 1);
        const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm", "--no-save", null };
        _ = c.execv("zig-out/bin/sketerm", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    dk_pid = pid;

    const sock = std.fmt.allocPrintSentinel(allocator, "{s}/sketerm/{d}.sock", .{ rt, pid }, 0) catch
        return "alloc";
    defer allocator.free(sock);
    var waited: u32 = 0;
    while (c.access(sock.ptr, c.F_OK) != 0) {
        _ = c.usleep(100_000);
        waited += 1;
        if (waited > 150) return "the Belgian GUI never opened its control socket";
    }
    if (!app.waitFirstWindow(60_000)) return "the Belgian GUI never committed a window";
    _ = c.usleep(1_200_000); // first pane's shell

    if (app.windows.items.len == 0) return "the Belgian display session lost its window";
    const win_id = app.windows.items[0].id;
    const cx = @as(f64, @floatFromInt(app.windows.items[0].w)) / 2;
    const cy = @as(f64, @floatFromInt(app.windows.items[0].h)) / 2;

    // ── face 1: the terminal pane ─────────────────────────────────
    app.clickEx(win_id, cx, cy, 1, 100, 1) catch return "clicking the Belgian GUI's pane failed";
    _ = app.waitIdle(300, 5_000);
    // 26 = dead_circumflex, 18 = e (BE keymap; xkb <AD11>/<AD03> minus
    // the constant 8 offset between xkb and evdev keycodes).
    app.tapKeyCodes(null, &.{ 26, 18 }) catch return "injecting the dead-key sequence failed";
    if (!waitPaneText(allocator, sock, 1, "\u{ea}", 15_000))
        return "the terminal pane never showed a composed 'e-circumflex' from a real dead-key sequence";

    // ── face 2: an editor tab ─────────────────────────────────────
    var path_buf: [512]u8 = undefined;
    const efile = std.fmt.bufPrintZ(&path_buf, "{s}/e2e-deadkey.txt", .{rt}) catch return "editor path";
    var req_buf: [700]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"new-editor-tab\",\"data\":\"{s}\"}}\n", .{efile}) catch
        return "editor req fmt";
    const resp = roundtrip(allocator, sock, req) orelse return "Belgian new-editor-tab roundtrip";
    defer allocator.free(resp);
    if (std.mem.indexOf(u8, resp, "\"ok\":true") == null) return "Belgian new-editor-tab not ok";
    const epane = parseNumAfter(resp, "\"pane\":") orelse return "Belgian new-editor-tab reply has no pane id";
    _ = c.usleep(1_200_000); // tab spawn + async load of a missing file

    var freq_buf: [128]u8 = undefined;
    const freq = std.fmt.bufPrint(&freq_buf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{epane}) catch return "fmt";
    const fresp = roundtrip(allocator, sock, freq) orelse return "Belgian editor focus roundtrip";
    allocator.free(fresp);
    // ...and a real click on the canvas, so the seat's keyboard focus
    // is genuinely there and not merely GTK's idea of it.
    app.clickEx(win_id, cx, cy, 1, 100, 1) catch return "clicking the Belgian editor canvas failed";
    _ = app.waitIdle(300, 5_000);

    app.tapKeyCodes(null, &.{ 26, 18 }) catch return "injecting the editor dead-key sequence failed";
    if (!waitPaneText(allocator, sock, epane, "\u{ea}", 15_000))
        return "the editor buffer never showed a composed 'e-circumflex' from a real dead-key sequence";

    dkTeardown();
    return null;
}

/// Poll `get-text` on one pane until its reply contains `needle`.
/// Automatic config reload (`config_auto_reload`): the GUI watches
/// config.conf and applies it with no keystroke.
///
/// Seven steps, each a way this feature is shipped broken:
///
///  1. A plain in-place write, into a directory that has no
///     config.conf yet — the CREATE path, and the one a `cat >` or a
///     `sed -i` on some filesystems produces.
///  2. A temp file renamed over the target — how every editor
///     actually saves. It swaps the inode out from under the monitor,
///     which is why watching is so often shipped working exactly once.
///  3. `config_auto_reload = false` arriving IN the watched file: the
///     apply frees the watcher from inside the watcher's own callback.
///  4. With it off, a further save must change nothing.
///  5. `reload_config` puts the defaults back — and re-installs the
///     watcher, because the reloaded config has the key back on.
///  6. That re-installed watcher still sees a save.
///  7. Deleting config.conf keeps the running config (see the step).
///
/// `font_size` is the observable: applyConfigChange rebuilds the pane's
/// atlas, which recomputes the grid, so `screen-info`'s `cols` moves
/// and moves back. No pixels involved, so the assertion cannot be
/// fooled by a repaint that came from somewhere else.
fn configReloadStage(allocator: std.mem.Allocator, sock_path: [:0]const u8, rt: []const u8) ?[]const u8 {
    var path_buf: [512:0]u8 = undefined;
    const cfg_path = std.fmt.bufPrintZ(&path_buf, "{s}/sketerm/config.conf", .{rt}) catch return "config path";
    var tmp_buf: [512:0]u8 = undefined;
    const tmp_path = std.fmt.bufPrintZ(&tmp_buf, "{s}/sketerm/config.conf.editor-tmp", .{rt}) catch return "temp path";

    const base_cols = paneCols(allocator, sock_path) orelse return "screen-info reported no cols";

    // 1. In-place write of a bigger font: fewer columns.
    if (!writeFile(cfg_path, "# smoke\nfont_size = 24\n")) return "could not write config.conf";
    const grew = waitCols(allocator, sock_path, base_cols, false, 15_000);
    if (grew == null) return "config.conf was written but the GUI never reloaded it";

    // 2. Rename-over, the editor save. If the monitor is left pointing
    //    at the replaced inode this is the write that goes unnoticed.
    if (!writeFile(tmp_path, "# smoke\nfont_size = 14\n")) return "could not write the temp config";
    if (c.rename(tmp_path.ptr, cfg_path.ptr) != 0) return "could not rename the temp config over config.conf";
    if (waitCols(allocator, sock_path, base_cols, true, 15_000) == null)
        return "a rename-over save was not picked up (the monitor died with the old inode)";

    // 3. The key switching ITSELF off. The apply tears the watcher
    //    down from inside the watcher's own callback, so this is the
    //    use-after-free shape as much as it is the feature.
    if (!writeFile(cfg_path, "# smoke\nconfig_auto_reload = false\nfont_size = 24\n"))
        return "could not write the auto-reload-off config";
    const off_cols = waitCols(allocator, sock_path, base_cols, false, 15_000) orelse
        return "the config that turns auto-reload off was itself never applied";

    // 4. ...and with it off, a further save must do nothing.
    if (!writeFile(cfg_path, "# smoke\nconfig_auto_reload = false\nfont_size = 30\n"))
        return "could not write the ignored config";
    _ = c.usleep(3_000_000);
    if (paneCols(allocator, sock_path) != off_cols)
        return "config_auto_reload = false still reloaded on a file change";

    // 5. Back to defaults on demand — which re-installs the watcher,
    //    since the reloaded config has the key at its default (on).
    _ = c.unlink(cfg_path.ptr);
    const rl = roundtrip(allocator, sock_path, "{\"cmd\":\"action\",\"data\":\"reload_config\"}\n") orelse
        return "reload_config roundtrip";
    allocator.free(rl);
    if (waitCols(allocator, sock_path, base_cols, true, 15_000) == null)
        return "an on-demand reload did not restore the default font";

    // 6. The re-installed watcher still works.
    if (!writeFile(cfg_path, "# smoke\nfont_size = 24\n")) return "could not write the final config";
    if (waitCols(allocator, sock_path, base_cols, false, 15_000) == null)
        return "the watcher was not re-installed when auto-reload came back on";

    // 7. A vanished file keeps the running config. Deliberate: an
    //    editor that saves by unlink-then-create makes the file
    //    briefly absent, and "reset every setting" is the wrong way to
    //    resolve that ambiguity. Wanting the defaults back is what
    //    reload_config is for.
    const big_cols = paneCols(allocator, sock_path) orelse return "screen-info stopped answering";
    _ = c.unlink(cfg_path.ptr);
    _ = c.usleep(2_000_000);
    if (paneCols(allocator, sock_path) != big_cols)
        return "deleting config.conf wiped the running config";

    const rl2 = roundtrip(allocator, sock_path, "{\"cmd\":\"action\",\"data\":\"reload_config\"}\n") orelse
        return "final reload_config roundtrip";
    allocator.free(rl2);
    if (waitCols(allocator, sock_path, base_cols, true, 15_000) == null)
        return "the stage could not put the defaults back for the stages after it";
    return null;
}

/// Combined user+system jiffies of a pid, from /proc/<pid>/stat.
/// The comm field can contain spaces and parentheses, so the parse
/// starts after the LAST ')'.
fn cpuJiffies(pid: c.pid_t) ?u64 {
    var path: [64:0]u8 = undefined;
    _ = std.fmt.bufPrintZ(&path, "/proc/{d}/stat", .{pid}) catch return null;
    const fp = c.fopen(&path, "rb") orelse return null;
    defer _ = c.fclose(fp);
    var buf: [1024]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len - 1, fp);
    if (n == 0) return null;
    const text = buf[0..n];
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    var it = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    // Fields after comm: state(3) ... utime(14) stime(15), so the
    // 12th and 13th tokens here.
    var idx: usize = 0;
    var utime: u64 = 0;
    while (it.next()) |tok| {
        idx += 1;
        if (idx == 12) utime = std.fmt.parseInt(u64, tok, 10) catch return null;
        if (idx == 13) return utime + (std.fmt.parseInt(u64, tok, 10) catch return null);
    }
    return null;
}

/// CPU jiffies burned by `pid` over `ms` of wall clock.
fn cpuOver(pid: c.pid_t, ms: u32) ?u64 {
    const before = cpuJiffies(pid) orelse return null;
    _ = c.usleep(ms * 1000);
    const after = cpuJiffies(pid) orelse return null;
    return after -| before;
}

/// The cursor trail's one dangerous property, measured rather than
/// asserted by construction: that it stops.
///
/// The trail is the only thing in a pane that schedules its own
/// redraws, and a 60 fps timeout left armed would pin the process at
/// frame rate forever — a battery and compositor bug (this rig's GL
/// is software, so a leaked timer is loud). Nothing observable from
/// outside says "no GLib source is armed", but CPU does: with the
/// trail settled the GUI must cost no more than it did before the
/// trail existed, over a window long enough that 60 fps of software
/// GL could not hide in it.
///
/// The animating measurement in the middle is a diagnostic, not an
/// assertion — its magnitude depends on the host's GL — but it is
/// what makes the idle number mean something: if the trail never ran
/// at all, the third measurement would pass trivially.
fn cursorTrailStage(
    allocator: std.mem.Allocator,
    sock_path: [:0]const u8,
    rt: []const u8,
    gui: c.pid_t,
) ?[]const u8 {
    var path_buf: [512:0]u8 = undefined;
    const cfg_path = std.fmt.bufPrintZ(&path_buf, "{s}/sketerm/config.conf", .{rt}) catch return "config path";

    const base_cols = paneCols(allocator, sock_path) orelse return "screen-info reported no cols";

    // Baseline: the pane at rest with the trail OFF. The blinking
    // cursor still repaints twice a second, so this is not zero, and
    // that is exactly why it is the reference and not a constant.
    _ = c.usleep(1_000_000);
    const idle_off = cpuOver(gui, 2_000) orelse return "could not read the GUI's CPU time";

    // Turn the trail on. font_size rides along purely so `cols` moves
    // and the stage can tell the config was actually applied.
    if (!writeFile(cfg_path, "# smoke\ncursor_trail = true\ncursor_trail_ms = 300\nfont_size = 24\n"))
        return "could not write the cursor-trail config";
    if (waitCols(allocator, sock_path, base_cols, false, 15_000) == null)
        return "the cursor-trail config was never applied";

    // Jump the cursor across the viewport, over and over, for about
    // two seconds. Every jump is far enough to get the long
    // animation rather than the typing one.
    const jump =
        "{\"cmd\":\"send-text\",\"pane\":1,\"data\":\"" ++
        "for i in 1 2 3 4 5 6 7 8 9 10; do printf '\\\\033[2;4H'; sleep 0.1; printf '\\\\033[12;40H'; sleep 0.1; done; printf 'TRAILDONE\\\\n'\\n" ++
        "\"}\n";
    const jr = roundtrip(allocator, sock_path, jump) orelse return "cursor-jump roundtrip";
    allocator.free(jr);
    _ = c.usleep(300_000);
    const busy = cpuOver(gui, 2_000) orelse return "could not read the GUI's CPU time while animating";

    // Let the loop finish and the last trail land, then measure the
    // same window again. The shell is back at an idle prompt for it,
    // which is exactly the state the baseline was measured in.
    if (!waitPaneText(allocator, sock_path, 1, "TRAILDONE", 15_000))
        return "the cursor-jump loop never finished";
    _ = c.usleep(1_500_000);
    const idle_on = cpuOver(gui, 3_000) orelse return "could not read the GUI's CPU time after settling";

    _ = c.fprintf(
        platform.stderr(),
        "smoke-e2e: cursor trail CPU jiffies — trail off idle=%llu, animating=%llu, settled idle=%llu\n",
        @as(c_ulonglong, idle_off),
        @as(c_ulonglong, busy),
        @as(c_ulonglong, idle_on),
    );

    // Over three seconds, a leaked 60 fps timeout is ~180 software-GL
    // frames. The allowance below is 0.6 s of CPU, which those cannot
    // fit inside on any host where this rig is worth running.
    if (idle_on > idle_off + 60)
        return "the pane kept burning CPU after the cursor trail settled (a redraw timer was left armed)";

    // Restore the defaults for the stages that follow. DELETING
    // config.conf would not do it: a vanished file deliberately keeps
    // the running config (configReloadStage step 7 asserts exactly
    // that), so the way back is an EMPTY file — every key absent means
    // every key default. This stage never ran while copy mode was red,
    // which is how an unlink survived here.
    if (!writeFile(cfg_path, "# smoke: back to defaults\n"))
        return "could not write the defaults config";
    const rl = roundtrip(allocator, sock_path, "{\"cmd\":\"action\",\"data\":\"reload_config\"}\n") orelse
        return "reload_config roundtrip";
    allocator.free(rl);
    if (waitCols(allocator, sock_path, base_cols, true, 15_000) == null)
        return "the stage could not put the default config back";
    return null;
}

/// `cols` of pane 1, via the GUI's own screen-info command.
fn paneCols(allocator: std.mem.Allocator, sock_path: [:0]const u8) ?u32 {
    const resp = roundtrip(allocator, sock_path, "{\"cmd\":\"screen-info\",\"pane\":1}\n") orelse return null;
    defer allocator.free(resp);
    return parseNumAfter(resp, "\"cols\":");
}

/// Poll until pane 1's column count equals (`want_equal`) or differs
/// from (`!want_equal`) `reference`. Returns the observed value.
fn waitCols(
    allocator: std.mem.Allocator,
    sock_path: [:0]const u8,
    reference: u32,
    want_equal: bool,
    ms: u32,
) ?u32 {
    var waited: u32 = 0;
    while (waited < ms) : (waited += 250) {
        if (paneCols(allocator, sock_path)) |cols| {
            if ((cols == reference) == want_equal) return cols;
        }
        _ = c.usleep(250_000);
    }
    return null;
}

fn writeFile(path: [:0]const u8, body: []const u8) bool {
    const fp = c.fopen(path.ptr, "wb") orelse return false;
    defer _ = c.fclose(fp);
    return c.fwrite(body.ptr, 1, body.len, fp) == body.len;
}

/// Whole small file, or null when it does not exist / cannot be read.
fn readFileAlloc(allocator: std.mem.Allocator, path: [:0]const u8) ?[]u8 {
    const fp = c.fopen(path.ptr, "rb") orelse return null;
    defer _ = c.fclose(fp);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, fp);
        if (n == 0) break;
        out.appendSlice(allocator, buf[0..n]) catch {
            out.deinit(allocator);
            return null;
        };
    }
    return out.toOwnedSlice(allocator) catch null;
}

fn waitPaneText(
    allocator: std.mem.Allocator,
    sock: [:0]const u8,
    pane: u32,
    needle: []const u8,
    ms: u32,
) bool {
    var waited: u32 = 0;
    while (waited < ms) : (waited += 200) {
        var buf: [128]u8 = undefined;
        const req = std.fmt.bufPrint(&buf, "{{\"cmd\":\"get-text\",\"pane\":{d}}}\n", .{pane}) catch return false;
        if (roundtrip(allocator, sock, req)) |resp| {
            defer allocator.free(resp);
            if (std.mem.indexOf(u8, resp, needle) != null) return true;
        }
        _ = c.usleep(200_000);
    }
    return false;
}

/// First unsigned integer following `key` in `text` (JSON scraping).
fn parseNumAfter(text: []const u8, key: []const u8) ?u32 {
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    var i = at + key.len;
    var v: u32 = 0;
    var any = false;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
        v = v * 10 + (text[i] - '0');
        any = true;
    }
    return if (any) v else null;
}

/// One connect → one request line → one response line. Caller frees.
///
/// Also pumps the display-session viewer: this process IS the
/// compositor brain for the GUI's toplevel, so an IPC stage that never
/// pumps would starve configure/frame handling for its whole duration.
fn roundtrip(allocator: std.mem.Allocator, sock_path: [:0]const u8, line: []const u8) ?[]u8 {
    if (drive) |app| app.drain();
    const client = c.g_socket_client_new();
    defer c.g_object_unref(client);
    const addr = c.g_unix_socket_address_new(sock_path.ptr);
    defer c.g_object_unref(addr);
    var gerr: [*c]c.GError = null;
    const conn = c.g_socket_client_connect(client, @ptrCast(@alignCast(addr)), null, &gerr);
    if (conn == null) {
        if (gerr != null) c.g_error_free(gerr);
        return null;
    }
    defer c.g_object_unref(conn);
    const out_stream = c.g_io_stream_get_output_stream(@ptrCast(conn));
    var written: c.gsize = 0;
    if (c.g_output_stream_write_all(out_stream, line.ptr, line.len, &written, null, &gerr) == 0) {
        if (gerr != null) c.g_error_free(gerr);
        return null;
    }
    const din = c.g_data_input_stream_new(c.g_io_stream_get_input_stream(@ptrCast(conn)));
    defer c.g_object_unref(din);
    var rlen: c.gsize = 0;
    const resp = c.g_data_input_stream_read_line(din, &rlen, null, &gerr);
    if (resp == null) {
        if (gerr != null) c.g_error_free(gerr);
        return null;
    }
    defer c.g_free(resp);
    return allocator.dupe(u8, resp[0..rlen]) catch null;
}
