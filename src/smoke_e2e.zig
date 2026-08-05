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
