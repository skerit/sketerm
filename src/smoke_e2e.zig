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
const display_cli = @import("mux/display.zig");
const appdrive = @import("ipc/appdrive.zig");
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
var dk_drive: ?*appdrive.App = null;
var dk_ready = false;
var g_alloc: std.mem.Allocator = undefined;
var g_mux_sock: []const u8 = "";
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
    _ = c.unsetenv("SKETERM_SOCKET");
    defer @import("mux/daemon.zig").removeTreeBestEffort(rt);

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
        const rmt_pid = c.fork();
        if (rmt_pid < 0) return fail("remote mux fork");
        if (rmt_pid == 0) {
            dieWithParent();
            _ = c.setenv("XDG_RUNTIME_DIR", rrt.ptr, 1);
            _ = c.setenv("XDG_STATE_HOME", rrt.ptr, 1);
            _ = c.setenv("XDG_CONFIG_HOME", rrt.ptr, 1);
            const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm-mux", null };
            _ = c.execv("zig-out/bin/sketerm-mux", @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        remote_mux_pid = rmt_pid;
        var rsock_buf: [512]u8 = undefined;
        const rsock = std.fmt.bufPrintZ(&rsock_buf, "{s}/sketerm/mux.sock", .{rrt}) catch return fail("remote sock path");
        var rwaited: u32 = 0;
        while (c.access(rsock.ptr, c.F_OK) != 0) {
            _ = c.usleep(50_000);
            rwaited += 1;
            if (rwaited > 100) return fail("private remote mux socket never appeared (5s)");
        }

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
    const split2 = roundtrip(allocator, sock_path, "{\"cmd\":\"split\",\"pane\":2,\"direction\":\"v\"}\n") orelse return fail("split2 roundtrip");
    defer allocator.free(split2);
    if (std.mem.indexOf(u8, split2, "\"ok\":true") == null) return fail("split2 not ok");
    _ = c.usleep(500_000);
    const close2 = roundtrip(allocator, sock_path, "{\"cmd\":\"close-pane\",\"pane\":2}\n") orelse return fail("close-pane roundtrip");
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
    const browser_here = roundtrip(allocator, sock_path, "{\"cmd\":\"browser-here\",\"pane\":4,\"data\":\"/\"}\n") orelse return fail("browser-here roundtrip");
    defer allocator.free(browser_here);
    if (std.mem.indexOf(u8, browser_here, "\"ok\":true") == null) return fail("browser-here not ok");
    const close_browser = roundtrip(allocator, sock_path, "{\"cmd\":\"close-pane\",\"pane\":4}\n") orelse return fail("browser close roundtrip");
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
        if (panelStage(allocator, app, sock_path, rt)) |why| return failMsg(why);
        say("panel: document rendered in its own window, a real click and a slider drag came back as events, patch/list/close held");

        // 6c-5. The same panels through a REAL `sketerm mcp` server —
        // the path an assistant actually takes.
        if (mcpPanelStage(allocator, app, sock_path)) |why| return failMsg(why);
        say("mcp: ui_show rendered a panel, ui_wait_event returned a real click, ui_save read the live document back (another process's panel included), save/load/close/delete held");

        // 6c-6. The same store, retrieved by the USER: the saved-panel
        // picker the command palette opens, driven by real keystrokes.
        if (panelPickerStage(allocator, app, sock_path, rt)) |why| return failMsg(why);
        say("picker: a saved panel reopened from the GUI (corrupt document refused), and Close Panel took it down again");

        // 6c-7. The pane-face lifetime, with the fuse it needs: a panel
        // put ON an existing pane, closed, and then the GUI kept
        // running long enough for the face's widgets to be finalized.
        if (panePanelLifetimeStage(allocator, app, sock_path)) |why| return failMsg(why);
        say("panel face on a pane: shown and closed three times, and the GUI outlived every deferred widget destroy");
    }

    // 6c-8. The process-global signal targets: a secondary window
    // freed while the AdwStyleManager singleton keeps emitting.
    if (!platform.is_macos) {
        if (themeSingletonStage(allocator, drive, rt, &wl_z)) |why| return failMsg(why);
        say("secondary window detached and closed while the global style manager kept flipping light/dark");
    }

    // 6c-9. Cast playback: `sketerm play` end to end, with the
    // fixed_grid render path and every transport control on a real
    // seat, cross-checked against the daemon's play_state stream.
    if (drive) |app| {
        if (have_wl) {
            if (castPlaybackStage(allocator, app, rt, mux_sock, &wl_z)) |why| return failMsg(why);
            say("cast playback: rendered, paused, seeked to EOF, restarted and closed (session died with the window)");

            // 6c-10. The same recording INSIDE the Sketerm Viewer, in
            // a mixed image+cast batch, navigated both directions.
            if (viewerCastStage(allocator, app, rt, mux_sock, &wl_z)) |why| return failMsg(why);
            say("viewer cast: played in place, paused, and batch navigation killed/rebuilt the ephemeral session without a leak");
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

    // Shut down via SIGTERM (graceful path) and check socket cleanup.
    _ = c.kill(pid, c.SIGTERM);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    const gui_ok = c.WIFEXITED(status) and c.WEXITSTATUS(status) == 0;
    child_pid = 0;
    if (!gui_ok) return fail("GUI exited abnormally during final teardown");
    if (c.access(sock_path.ptr, c.F_OK) == 0) return fail("socket not unlinked on shutdown");

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
fn lightPixelsRight(allocator: std.mem.Allocator, app: *appdrive.App, win_id: u32) usize {
    const shot = app.snapshotRgba(win_id, null) catch return 0;
    defer allocator.free(shot.px);
    if (shot.w < 260) return 0;
    var n: usize = 0;
    // Only the CANVAS band: the window chrome above and the project
    // panel below are light whatever the outline does.
    if (shot.h < 500) return 0;
    var y: u32 = 220;
    while (y < shot.h - 230) : (y += 1) {
        var x: u32 = shot.w - 240;
        while (x < shot.w - 30) : (x += 1) {
            const i = (y * shot.w + x) * 4;
            if (i + 2 >= shot.px.len) break;
            if (shot.px[i] > 180 and shot.px[i + 1] > 180 and shot.px[i + 2] > 180) n += 1;
        }
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
        const light_before = lightPixelsRight(allocator, app, win_id);
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
        const light_after = lightPixelsRight(allocator, app, win_id);
        _ = c.fprintf(platform.stderr(), "smoke-e2e: outline column chrome %zu -> %zu px\n", light_before, light_after);
        if (light_after < light_before + 20_000)
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
    const mux_client = @import("mux/client.zig");
    var conn = mux_client.Conn.connectProbed(allocator, mux_sock) catch return buf[0..0];
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
    const mux_client = @import("mux/client.zig");

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

    var side = mux_client.Conn.connectProbed(allocator, mux_sock) catch return "side connect failed";
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

/// Cast playback INSIDE the Sketerm Viewer: `sketerm view` on a mixed
/// batch (image + cast), navigated both directions on a real seat.
/// What only a live run can prove: the shared CastPlayerBox renders
/// through the viewer's content slot, Space reaches the daemon as a
/// pause, and BATCH NAVIGATION tears the ephemeral cast session down
/// completely (no leaked session) and can rebuild a fresh one.
fn viewerCastStage(
    allocator: std.mem.Allocator,
    app: *appdrive.App,
    rt: []const u8,
    mux_sock: []const u8,
    wl: [*:0]const u8,
) ?[]const u8 {
    const mux_client = @import("mux/client.zig");

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
        const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm", "view", img_path.ptr, cast_path.ptr, null };
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
        var side = mux_client.Conn.connectProbed(allocator, mux_sock) catch return "side connect failed";
        defer side.deinit();
        side.sendJson(.attach, .{ .name = name, .kind = "cli", .read_only = true }) catch return "side attach send failed";
        const snap = side.recvExpectFor(&.{.snapshot}, 10_000) catch return "side attach got no snapshot";
        snap.deinit(allocator);
        var st: CastObserved = .{};
        app.pressKey(vwin, "space") catch return "injecting space failed";
        if (!castWaitState(allocator, &side, "paused", 8_000, &st))
            return "space did not pause the cast inside the viewer";
        // Resume so the teardown below kills a RUNNING playback.
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
        const ev_req = std.fmt.bufPrint(&ev_buf, "{{\"cmd\":\"panel-events\",\"panel_id\":{d}}}\n", .{panel_id}) catch
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
        "{{\"cmd\":\"panel-patch\",\"panel_id\":{d},\"patch\":\"[{{\\\"op\\\":\\\"title\\\",\\\"value\\\":\\\"Epoch 42\\\"}}]\"}}\n",
        .{panel_id},
    ) catch return "panel-patch fmt";
    const patched = roundtrip(allocator, sock_path, patch_req) orelse return "panel-patch roundtrip";
    defer allocator.free(patched);
    if (std.mem.indexOf(u8, patched, "\"ok\":true") == null) return "panel-patch not ok";

    // A patch naming a component that does not exist must fail with the
    // parser's message and leave the panel alone.
    const bad_patch_req = std.fmt.bufPrint(
        &patch_buf,
        "{{\"cmd\":\"panel-patch\",\"panel_id\":{d},\"patch\":\"[{{\\\"op\\\":\\\"remove\\\",\\\"id\\\":\\\"ghost\\\"}}]\"}}\n",
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
        const ev_req = std.fmt.bufPrint(&ev_buf, "{{\"cmd\":\"panel-events\",\"panel_id\":{d}}}\n", .{panel_id}) catch
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
    const cmp = roundtrip(allocator, sock_path, cmp_req) orelse return "panel-show(compare) roundtrip";
    defer allocator.free(cmp);
    if (std.mem.indexOf(u8, cmp, "\"ok\":true") == null) return "panel-show(compare) not ok";
    const cmp_id = parseNumAfter(cmp, "\"panel_id\":") orelse return "compare panel has no panel_id";

    const term_win = known[0];
    _ = app.waitVisualSettle(term_win, 500, 10_000, 0.002, null);
    const before = app.screenshotPng(term_win, 640, null, 0) catch return "screenshotting the compare panel failed";
    defer allocator.free(before.png);
    const tw = app.winById(term_win) orelse return "the terminal window vanished";
    const ty = @as(f64, @floatFromInt(tw.h)) * 0.5;
    // Not zoomed, so a drag anywhere on the surface moves the split.
    app.drag(term_win, @as(f64, @floatFromInt(tw.w)) * 0.5, ty, @as(f64, @floatFromInt(tw.w)) * 0.2, ty, 1) catch
        return "dragging the compare split failed";
    _ = app.waitVisualSettle(term_win, 400, 8_000, 0.002, null);
    const after = app.screenshotPng(term_win, 640, null, 0) catch return "screenshotting after the drag failed";
    defer allocator.free(after.png);
    if (std.mem.eql(u8, before.png, after.png))
        return "dragging the image_compare split repainted nothing";

    // 7. Close both. The compare panel sat ON pane 1, so closing it
    // must give the pane back to its shell rather than close the tab.
    var close_buf: [128]u8 = undefined;
    const close_cmp = std.fmt.bufPrint(&close_buf, "{{\"cmd\":\"panel-close\",\"panel_id\":{d}}}\n", .{cmp_id}) catch
        return "panel-close fmt";
    const closed_cmp = roundtrip(allocator, sock_path, close_cmp) orelse return "panel-close roundtrip";
    defer allocator.free(closed_cmp);
    if (std.mem.indexOf(u8, closed_cmp, "\"ok\":true") == null) return "panel-close(compare) not ok";

    const close_req = std.fmt.bufPrint(&close_buf, "{{\"cmd\":\"panel-close\",\"panel_id\":{d}}}\n", .{panel_id}) catch
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
        const tclose_req = std.fmt.bufPrint(&tclose, "{{\"cmd\":\"panel-close\",\"panel_id\":{d}}}\n", .{tab_id}) catch
            return "fmt";
        const tclosed = roundtrip(allocator, sock_path, tclose_req) orelse return "panel-close(tab) roundtrip";
        defer allocator.free(tclosed);
        if (std.mem.indexOf(u8, tclosed, "\"ok\":true") == null) return "panel-close(tab) not ok";
        if (!waitIdCount(allocator, sock_path, ids_before, true, 10_000))
            return "closing a tab panel left its tab behind";
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
        "--socket",     sock_path,   "panel-show", "--name", "cli-panel",
        "--session",    "e2e-scope", "--target",   "window", "--file",
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
    const cli_close = runCli(allocator, &.{ "--socket", sock_path, "panel-close", "--panel-id", id_str });
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
            // --shared skips the private daemon entirely (no second
            // mux to clean up); --socket points it at THIS GUI.
            const argv = [_:null]?[*:0]const u8{
                "zig-out/bin/sketerm", "mcp", "--shared", "--socket", sock_path.ptr, null,
            };
            _ = c.execv("zig-out/bin/sketerm", @ptrCast(@constCast(&argv)));
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
        const req = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"smoke-e2e\",\"version\":\"0\"}}}}}}", .{self.id}) catch return false;
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
        \\{"name":"mcp-e2e","session":"e2e-mcp","target":"window","document":{"title":"Epoch 41","root":"ok","components":{"ok":{"type":"button","text":"Approve","action":"approve","class":["expand"]}}}}
    , 30_000) orelse return "ui_show timed out";
    if (std.mem.indexOf(u8, show, "isError") != null) return "ui_show returned an error";
    const panel_id = parseNumAfter(show, "\\\"panel_id\\\":") orelse return "ui_show returned no panel_id";

    // A malformed document must come back with the parser's own text.
    const bad = m.call("ui_show",
        \\{"name":"mcp-bad","session":"e2e-mcp","document":{"root":"r","components":{"r":{"type":"webview"}}}}
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
        \\{"name":"mcp-e2e","session":"e2e-mcp","timeout_ms":20000}
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
        \\{"name":"mcp-e2e","session":"e2e-mcp","patch":[{"op":"title","value":"Epoch 42"}]}
    , 20_000) orelse return "ui_patch timed out";
    if (std.mem.indexOf(u8, patched, "isError") != null) return "ui_patch returned an error";
    const listed = m.call("ui_panels", "{\"session\":\"e2e-mcp\"}", 20_000) orelse return "ui_panels timed out";
    if (std.mem.indexOf(u8, listed, "Epoch 42") == null) return "ui_panels does not show the patched title";
    if (std.mem.indexOf(u8, listed, "\\\"saved\\\":[]") == null) return "ui_panels claims a saved document that was never saved";

    // 4. ui_save with no document persists what is on screen, patch
    // included. The server keeps NO copy of what it showed: it reads
    // the document back over panel-get, so the bytes on disk must equal
    // the live document byte for byte (both are doc.toJson canonical).
    const saved = m.call("ui_save", "{\"name\":\"mcp-e2e\",\"session\":\"e2e-mcp\"}", 20_000) orelse
        return "ui_save timed out";
    if (std.mem.indexOf(u8, saved, "isError") != null) return "ui_save (from the live document) returned an error";
    if (savedPanelMatchesLive(allocator, sock_path, "e2e-mcp", "mcp-e2e", panel_id)) |why| return why;

    // 4b. The hole a server-side mirror could never cover: a panel THIS
    // server never showed. It was shown over the control socket by this
    // smoke process, so only a read-back from the GUI can save it.
    const foreign_req =
        "{\"cmd\":\"panel-show\",\"name\":\"foreign\",\"session\":\"e2e-mcp\",\"target\":\"window\"," ++
        "\"document\":\"{\\\"title\\\":\\\"Not mine\\\",\\\"root\\\":\\\"t\\\"," ++
        "\\\"components\\\":{\\\"t\\\":{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"shown by another process\\\"}}}\"}\n";
    const foreign = roundtrip(allocator, sock_path, foreign_req) orelse return "panel-show(foreign) roundtrip";
    defer allocator.free(foreign);
    if (std.mem.indexOf(u8, foreign, "\"ok\":true") == null) return "panel-show(foreign) not ok";
    const foreign_id = parseNumAfter(foreign, "\"panel_id\":") orelse return "foreign panel has no panel_id";
    _ = app.pumpOnce(300);
    const foreign_saved = m.call("ui_save", "{\"name\":\"foreign\",\"session\":\"e2e-mcp\"}", 20_000) orelse
        return "ui_save(foreign) timed out";
    if (std.mem.indexOf(u8, foreign_saved, "isError") != null)
        return "ui_save could not persist a panel shown by another process";
    if (savedPanelMatchesLive(allocator, sock_path, "e2e-mcp", "foreign", foreign_id)) |why| return why;
    {
        var fbuf: [128]u8 = undefined;
        const fclose_req = std.fmt.bufPrint(&fbuf, "{{\"cmd\":\"panel-close\",\"panel_id\":{d}}}\n", .{foreign_id}) catch
            return "panel-close fmt";
        const fclosed = roundtrip(allocator, sock_path, fclose_req) orelse return "panel-close(foreign) roundtrip";
        defer allocator.free(fclosed);
        if (std.mem.indexOf(u8, fclosed, "\"ok\":true") == null) return "panel-close(foreign) not ok";
    }
    const dropped = m.call("ui_delete", "{\"name\":\"foreign\",\"session\":\"e2e-mcp\"}", 20_000) orelse
        return "ui_delete(foreign) timed out";
    if (std.mem.indexOf(u8, dropped, "isError") != null) return "ui_delete(foreign) returned an error";
    _ = app.pumpOnce(300);

    // ui_save cannot invent a document for a panel that is not on
    // screen: that is a refusal, never a stale save.
    const ghost = m.call("ui_save", "{\"name\":\"never-shown\",\"session\":\"e2e-mcp\"}", 20_000) orelse
        return "ui_save(ghost) timed out";
    if (std.mem.indexOf(u8, ghost, "isError") == null)
        return "ui_save claimed to save a panel that was never shown";
    const closed = m.call("ui_close", "{\"name\":\"mcp-e2e\",\"session\":\"e2e-mcp\"}", 20_000) orelse
        return "ui_close timed out";
    if (std.mem.indexOf(u8, closed, "isError") != null) return "ui_close returned an error";
    _ = app.pumpOnce(500);
    const after_close = m.call("ui_panels", "{\"session\":\"e2e-mcp\"}", 20_000) orelse return "ui_panels timed out";
    if (std.mem.indexOf(u8, after_close, "\\\"live\\\":[]") == null) return "a closed panel is still listed as live";
    if (std.mem.indexOf(u8, after_close, "Epoch 42") == null) return "ui_close destroyed the saved document";

    // 5. The saved document renders again, and ui_delete removes only
    // the stored copy.
    const reshown = m.call("ui_show",
        \\{"name":"mcp-e2e","session":"e2e-mcp","target":"window","load":"mcp-e2e"}
    , 30_000) orelse return "ui_show(load) timed out";
    if (std.mem.indexOf(u8, reshown, "isError") != null) return "ui_show could not re-open the saved panel";
    _ = app.pumpOnce(500);
    const deleted = m.call("ui_delete", "{\"name\":\"mcp-e2e\",\"session\":\"e2e-mcp\"}", 20_000) orelse
        return "ui_delete timed out";
    if (std.mem.indexOf(u8, deleted, "isError") != null) return "ui_delete returned an error";
    const final = m.call("ui_panels", "{\"session\":\"e2e-mcp\"}", 20_000) orelse return "ui_panels timed out";
    if (std.mem.indexOf(u8, final, "\\\"saved\\\":[]") == null) return "ui_delete left the saved document behind";
    if (std.mem.indexOf(u8, final, "\\\"live\\\":[]") != null) return "ui_delete closed the live panel too";

    const gone = m.call("ui_close", "{\"name\":\"mcp-e2e\",\"session\":\"e2e-mcp\"}", 20_000) orelse
        return "final ui_close timed out";
    if (std.mem.indexOf(u8, gone, "isError") != null) return "the re-opened panel could not be closed";
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
    const panelstore = @import("ipc/panelstore.zig");

    var req_buf: [128]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"panel-get\",\"panel_id\":{d}}}\n", .{panel_id}) catch
        return "panel-get fmt";
    const resp = roundtrip(allocator, sock_path, req) orelse return "panel-get roundtrip";
    defer allocator.free(resp);
    if (std.mem.indexOf(u8, resp, "\"ok\":true") == null) return "panel-get not ok";

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch
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
    const stored = panelstore.loadJson(allocator, session, name, null) catch
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
    var sess_buf: [128]u8 = undefined;
    const session = blk: {
        const key = "\"session\":\"";
        const at = std.mem.indexOf(u8, probe, key) orelse return "the probe did not echo its session";
        const rest = probe[at + key.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return "malformed session in the probe reply";
        if (end == 0 or end > sess_buf.len) return "implausible session name";
        @memcpy(sess_buf[0..end], rest[0..end]);
        break :blk sess_buf[0..end];
    };
    var close_buf: [128]u8 = undefined;
    const close_probe = std.fmt.bufPrint(&close_buf, "{{\"cmd\":\"panel-close\",\"panel_id\":{d}}}\n", .{probe_id}) catch
        return "panel-close fmt";
    const probe_closed = roundtrip(allocator, sock_path, close_probe) orelse return "panel-close(probe) roundtrip";
    defer allocator.free(probe_closed);
    if (std.mem.indexOf(u8, probe_closed, "\"ok\":true") == null) return "panel-close(probe) not ok";
    _ = app.pumpOnce(500);
    _ = roundtrip(allocator, sock_path, "{\"cmd\":\"focus\",\"pane\":1}\n");

    // The fixture: one document that parses, one that does not. This
    // process shares XDG_STATE_HOME with the GUI, so the store it
    // writes IS the store the GUI reads.
    const SAVED_DOC =
        "{\"version\":1,\"title\":\"Saved By Hand\",\"root\":\"r\",\"components\":" ++
        "{\"r\":{\"type\":\"heading\",\"text\":\"Reopened from the palette\",\"level\":2}}}";
    panelstore.saveJson(allocator, session, "e2e-saved", SAVED_DOC, null) catch
        return "saving the panel document failed";
    {
        const dir = panelstore.sessionDir(allocator, session) catch return "resolving the session dir failed";
        defer allocator.free(dir);
        const broken = std.fmt.allocPrintSentinel(allocator, "{s}/e2e-broken.json", .{dir}, 0) catch return "alloc";
        defer allocator.free(broken);
        // Valid JSON, invalid document: the root names a component that
        // is not there, which is what `panelstore` calls Corrupt.
        if (!writeFile(broken, "{\"root\":\"gone\",\"components\":{}}"))
            return "could not stage the corrupt panel document";
    }
    {
        const listed = panelstore.list(allocator, session) catch return "listing the fixture failed";
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
    const list_req = std.fmt.bufPrint(&list_buf, "{{\"cmd\":\"panel-list\",\"session\":\"{s}\"}}\n", .{session}) catch
        return "panel-list fmt";

    // The chord now opens the picker: the dialog covers a good part of
    // the window, so its arrival is a pixel fact rather than a guess.
    {
        _ = app.waitVisualSettle(term_win, 500, 8_000, 0.002, null);
        var ref = app.frameRef(term_win, true) orelse return "no baseline frame for the picker";
        defer ref.deinit(allocator);
        app.pressKey(term_win, "ctrl+shift+F9") catch return "injecting the panel_open chord failed";
        if (!app.waitChangeSince(term_win, &ref, 10_000, 0.02, null))
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
    _ = app.pumpOnce(400);
    app.pressKey(term_win, "Return") catch return "opening the saved panel failed";

    tries = 0;
    while (tries < 50) : (tries += 1) {
        _ = app.pumpOnce(200);
        const live = roundtrip(allocator, sock_path, list_req) orelse continue;
        defer allocator.free(live);
        if (std.mem.indexOf(u8, live, "\"name\":\"e2e-saved\"") == null) continue;
        if (std.mem.indexOf(u8, live, "\"title\":\"Saved By Hand\"") == null)
            return "the reopened panel is not the saved document";
        if (std.mem.indexOf(u8, live, "\"target\":\"tab\"") == null)
            return "the picker opened the panel somewhere other than its own tab";
        break;
    } else return "the picker never opened the saved panel";

    // "Close Panel" takes it down again. The panel sits on its own tab
    // and a panel face swallows no chords of its own, so the chord is
    // sent from the terminal pane — exactly the ladder `closeNearest`
    // exists for.
    _ = roundtrip(allocator, sock_path, "{\"cmd\":\"focus\",\"pane\":1}\n");
    _ = app.pumpOnce(500);
    app.pressKey(term_win, "ctrl+shift+F10") catch return "injecting the panel_close chord failed";
    var closed = false;
    tries = 0;
    while (tries < 50 and !closed) : (tries += 1) {
        _ = app.pumpOnce(200);
        const live = roundtrip(allocator, sock_path, list_req) orelse continue;
        defer allocator.free(live);
        closed = std.mem.indexOf(u8, live, "\"name\":\"e2e-saved\"") == null;
    }
    if (!closed) return "Close Panel left the panel live";

    // Closing is not deleting: both stored documents are still there.
    const still = panelstore.list(allocator, session) catch return "re-listing the store failed";
    defer panelstore.freeList(allocator, still);
    if (still.len != 2) return "closing a panel disturbed the stored documents";

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

    // Interactive components on purpose: a button and a slider each
    // carry their own heap signal context, so this also exercises the
    // per-component teardown alongside the view's own.
    const show_req =
        "{\"cmd\":\"panel-show\",\"name\":\"e2e-life\",\"session\":\"e2e-scope\"," ++
        "\"target\":\"pane\",\"pane\":1,\"document\":\"{\\\"title\\\":\\\"Lifetime\\\"," ++
        "\\\"root\\\":\\\"c\\\",\\\"components\\\":{\\\"c\\\":{\\\"type\\\":\\\"column\\\"," ++
        "\\\"children\\\":[\\\"h\\\",\\\"b\\\",\\\"s\\\"]}," ++
        "\\\"h\\\":{\\\"type\\\":\\\"heading\\\",\\\"text\\\":\\\"On the pane\\\",\\\"level\\\":2}," ++
        "\\\"b\\\":{\\\"type\\\":\\\"button\\\",\\\"text\\\":\\\"Press\\\",\\\"action\\\":\\\"go\\\"}," ++
        "\\\"s\\\":{\\\"type\\\":\\\"slider\\\",\\\"min\\\":0,\\\"max\\\":10,\\\"value\\\":3}}}\"}\n";

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

        var buf: [128]u8 = undefined;
        const close_req = std.fmt.bufPrint(&buf, "{{\"cmd\":\"panel-close\",\"panel_id\":{d}}}\n", .{id}) catch
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
/// `deferredWindowFree` while the process lives on, so anything still
/// pointing at it from a PROCESS-GLOBAL object is a use-after-free
/// waiting for the next emission. The one that bit was the
/// `AdwStyleManager` singleton's `notify::dark`: connected per window
/// in `Window.init`, never disconnected, and the singleton outlives
/// every window. Detach a tab, close that window, then keep flipping
/// light/dark and keep asking whether the GUI still answers.
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

    // Windows already on the hub belong to the other instances; only
    // ids that appear after this fork are ours.
    _ = app.drainLive(500);
    var pre: std.ArrayList(u32) = .empty;
    defer pre.deinit(allocator);
    for (app.windows.items) |w| pre.append(allocator, w.id) catch return "alloc";

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
    var secondary: u32 = 0;
    for (app.windows.items) |w| {
        if (w.popup) continue;
        if (std.mem.indexOfScalar(u32, pre.items, w.id) != null) continue;
        secondary = w.id;
    }
    if (secondary == 0) return "detach_tab produced no new window on the display session";

    app.closeWindow(secondary) catch return "closing the detached window failed";
    var gone: u32 = 0;
    while (gone < 8_000) : (gone += 250) {
        _ = app.pumpOnce(250);
        if (app.windowGone(secondary)) break;
    }
    if (!app.windowGone(secondary)) return "the detached window never closed";

    // The fuse. `deferredWindowFree` runs on an idle after the destroy
    // chain unwinds, and the flip timer fires five times a second, so
    // by the end of this loop a handler left on the style manager has
    // dispatched into the freed Window many times over.
    var alive_waited: u32 = 0;
    while (alive_waited < 5_000) : (alive_waited += 250) {
        _ = app.pumpOnce(250);
        const alive = roundtrip(allocator, sock, "{\"cmd\":\"screen-info\",\"pane\":1}\n") orelse
            return "the GUI stopped serving after a secondary window was closed under a theme flip";
        defer allocator.free(alive);
        if (std.mem.indexOf(u8, alive, "\"ok\":true") == null)
            return "the GUI went unhealthy after a secondary window was closed under a theme flip";
    }
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
fn copyModeStage(allocator: std.mem.Allocator, app: *appdrive.App, sock_path: [:0]const u8) ?[]const u8 {
    // Three words sharing a prefix, so a motion that stops one word
    // early or late yanks something visibly different.
    app.typeText(null, "echo ZQalpha ZQbeta ZQgamma\n") catch return "injecting the sample line failed";
    // Twice: the echoed command line, and its output.
    if (!waitMarkerCount(allocator, sock_path, "ZQbeta", 2, 15_000))
        return "the sample line never reached the shell";
    _ = app.waitIdle(300, 5_000);

    app.pressKey(null, "ctrl+shift+x") catch return "entering copy mode failed";
    _ = app.waitIdle(300, 5_000);
    // Up onto the output line, to its start, then select the MIDDLE
    // word: w to its first character, e to its last.
    const motions = [_][]const u8{ "k", "0", "w", "v", "e", "y" };
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
            "create",      "--name", DEADKEY_SESSION, "--kb-layout", "be",
            "--ttl",       DISPLAY_TTL,               "--json",      "--socket",
            mux_sock,
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
        @as(c_ulonglong, idle_off), @as(c_ulonglong, busy), @as(c_ulonglong, idle_on),
    );

    // Over three seconds, a leaked 60 fps timeout is ~180 software-GL
    // frames. The allowance below is 0.6 s of CPU, which those cannot
    // fit inside on any host where this rig is worth running.
    if (idle_on > idle_off + 60)
        return "the pane kept burning CPU after the cursor trail settled (a redraw timer was left armed)";

    // Restore the defaults for the stages that follow.
    _ = c.unlink(cfg_path.ptr);
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
