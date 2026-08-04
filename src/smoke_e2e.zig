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
/// Seat/pixel side of the harness: a viewer of the display session the
/// GUI renders into. null on macOS (no hub) — see the module docs.
var drive: ?*appdrive.App = null;
var display_ready = false;
/// Same three, for the Belgian-layout dead-key session.
var dk_pid: c.pid_t = 0;
var dk_drive: ?*appdrive.App = null;
var dk_ready = false;
var g_alloc: std.mem.Allocator = undefined;
var g_mux_sock: []const u8 = "";

/// Tear down everything this process created, in dependency order and
/// by exact pid — never by name. Idempotent: the success path and
/// every `fail` go through it.
fn teardown() void {
    dkTeardown();
    if (drive) |app| {
        // detach, not kill: the session is destroyed by name below, so
        // a half-torn-down client never decides that for us.
        app.detach();
        drive = null;
    }
    if (child_pid > 0) {
        _ = c.kill(child_pid, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(child_pid, &status, 0);
        child_pid = 0;
    }
    if (display_ready and g_mux_sock.len > 0) {
        const r = runDisplayCli(g_alloc, &.{ "destroy", DISPLAY_SESSION, "--socket", g_mux_sock });
        g_alloc.free(r.out);
        display_ready = false;
    }
    if (daemon_pid > 0) {
        // Let the broker terminate and reap its exact worker children.
        _ = c.kill(daemon_pid, c.SIGTERM);
        var status: c_int = 0;
        _ = c.waitpid(daemon_pid, &status, 0);
        daemon_pid = 0;
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

    // Every mutable path and the daemon itself are private to this smoke.
    // A protocol bump must never classify the user's live daemon as stale
    // and shut it down.
    var rt_buf: [256]u8 = undefined;
    const rt = std.fmt.bufPrintZ(&rt_buf, "/tmp/sketerm-smoke-e2e-{d}", .{c.getpid()}) catch return fail("runtime path");
    _ = c.mkdir(rt.ptr, 0o700);
    _ = c.setenv("XDG_RUNTIME_DIR", rt.ptr, 1);
    _ = c.setenv("XDG_CONFIG_HOME", rt.ptr, 1);
    _ = c.setenv("XDG_STATE_HOME", rt.ptr, 1);
    _ = c.unsetenv("SKETERM_SOCKET");
    defer @import("mux/daemon.zig").removeTreeBestEffort(rt);

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
    }

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
    if (std.mem.indexOf(u8, split_browser, "\"ok\":true") == null) return fail("browser split not ok");
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
