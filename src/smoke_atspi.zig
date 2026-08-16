//! AT-SPI accessibility smoke — `zig build smoke-atspi` (Linux).
//!
//! Proves that the terminal pane's GPU canvas is genuinely readable by a
//! screen reader, over a REAL accessibility bus: a private dbus-daemon +
//! at-spi2-registryd (spawned by `mux/a11yhub.zig`, which encodes the five
//! independent requirements a populated tree needs), a private mux daemon
//! + display session for the GUI to render into, and a pure-Zig D-Bus
//! client asserting on actual `org.a11y.atspi.Text` replies:
//!
//!   1. a node with the TERMINAL role exists in the tree;
//!   2. its Text contents contain what was typed into the pane;
//!   3. the caret offset sits after the typed text and MOVES when more
//!      is typed;
//!   4. a real pointer drag creates exactly one AT-SPI selection whose
//!      range yields the dragged text, and a click clears it again.
//!
//! and that the EDITOR canvas — a second GtkGLArea, same bridge over
//! the rope instead of the grid — is readable the same way:
//!
//!   5. an editable TEXT_BOX node named after the open file appears;
//!   6. its Text contents are exactly what was typed (no inlay hints,
//!      no gutter, no decorations — the document, not the rendering);
//!   7. the caret advances by the number of characters typed, counting
//!      a multi-byte character as ONE;
//!   8. Shift+Home reports a selection whose range yields the line.
//!
//! Deliberately a separate target from smoke-e2e: that harness runs its
//! GUI children with GTK_A11Y=none (correct isolation on a desktop with a
//! live at-spi), so a11y coverage needs its own private bus — this one.
//!
//! SKIPs (exit 0) when dbus-daemon or at-spi2-registryd is not installed.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const platform = @import("util/platform.zig");
const display_cli = @import("mux/display.zig");
const appdrive = @import("ipc/appdrive.zig");
const A11yHub = @import("mux/a11yhub.zig").Hub;

const DISPLAY_SESSION = "a11y-display";
const DISPLAY_TTL = "900";
/// Typed into the pane's shell prompt (NOT executed — the echo is the
/// point) and asserted back out of org.a11y.atspi.Text.
const MARKER = "a11ymark7431";

var child_pid: c.pid_t = 0;
var daemon_pid: c.pid_t = 0;
var drive: ?*appdrive.App = null;
var display_ready = false;
var hub: ?A11yHub = null;
var g_alloc: std.mem.Allocator = undefined;
var g_mux_sock: []const u8 = "";

/// Tear down everything this process created, in dependency order and
/// by exact pid — never by name. Idempotent.
fn teardown() void {
    if (drive) |app| {
        app.detach();
        drive = null;
    }
    if (child_pid > 0) {
        _ = c.kill(child_pid, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(child_pid, &status, 0);
        child_pid = 0;
    }
    if (hub != null) {
        hub.?.deinit();
        hub = null;
    }
    if (display_ready and g_mux_sock.len > 0) {
        const r = runDisplayCli(g_alloc, &.{ "destroy", DISPLAY_SESSION, "--socket", g_mux_sock });
        g_alloc.free(r.out);
        display_ready = false;
    }
    if (daemon_pid > 0) {
        _ = c.kill(daemon_pid, c.SIGTERM);
        var status: c_int = 0;
        _ = c.waitpid(daemon_pid, &status, 0);
        daemon_pid = 0;
    }
}

fn fail(comptime msg: []const u8) u8 {
    _ = c.fprintf(platform.stderr(), "smoke-atspi: FAIL: " ++ msg ++ "\n");
    teardown();
    return 1;
}

fn say(msg: []const u8) void {
    _ = c.fprintf(platform.stdout(), "smoke-atspi: %.*s\n", @as(c_int, @intCast(msg.len)), msg.ptr);
    _ = c.fflush(platform.stdout());
}

/// Die with the harness so a SIGKILLed run can't orphan the daemon/GUI.
fn dieWithParent() void {
    if (builtin.os.tag != .linux) return;
    const PR_SET_PDEATHSIG: c_long = 1;
    _ = c.syscall(@intFromEnum(std.os.linux.SYS.prctl), PR_SET_PDEATHSIG, @as(c_long, c.SIGKILL));
}

const CliResult = struct { code: u8, out: []u8 };

/// Run the real `sketerm-mux display` CLI in-process, stdout captured.
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

/// The bus/registry binaries this smoke depends on. Absent = SKIP, not
/// FAIL: a11y infrastructure is an optional install on minimal hosts.
fn busToolingPresent() bool {
    if (c.system("command -v dbus-daemon >/dev/null 2>&1") != 0) return false;
    const candidates = [_][*:0]const u8{
        "/usr/lib/at-spi2-registryd",
        "/usr/libexec/at-spi2-registryd",
        "/usr/lib/at-spi2-core/at-spi2-registryd",
        "/usr/lib64/at-spi2-registryd",
    };
    for (candidates) |p| if (c.access(p, c.X_OK) == 0) return true;
    return false;
}

pub fn main() u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    g_alloc = allocator;

    if (platform.is_macos) {
        say("SKIP: AT-SPI is Linux-only (macOS is covered by smoke-a11y)");
        return 0;
    }
    if (!busToolingPresent()) {
        say("SKIP: dbus-daemon / at-spi2-registryd not installed");
        return 0;
    }

    // Every mutable path and the daemon itself are private to this smoke.
    var rt_buf: [256]u8 = undefined;
    const rt = std.fmt.bufPrintZ(&rt_buf, "/tmp/sketerm-a11y-{d}", .{c.getpid()}) catch return fail("runtime path");
    _ = c.mkdir(rt.ptr, 0o700);
    _ = c.setenv("XDG_RUNTIME_DIR", rt.ptr, 1);
    _ = c.setenv("XDG_CONFIG_HOME", rt.ptr, 1);
    _ = c.setenv("XDG_STATE_HOME", rt.ptr, 1);
    _ = c.unsetenv("SKETERM_SOCKET");
    // dbus-broker silently reuses the HOST accessibility bus; every bus
    // process this smoke spawns (dbus-daemon → at-spi-bus-launcher →
    // registryd) inherits this and stays on the private one.
    _ = c.setenv("ATSPI_DBUS_IMPLEMENTATION", "dbus-daemon", 1);
    defer @import("mux/daemon.zig").removeTreeBestEffort(rt);

    // A fresh XDG_CONFIG_HOME changes fontconfig's cache key; warming it
    // single-threaded here keeps concurrent cache rebuilds from racing
    // pango into heap corruption at GUI startup.
    _ = c.system("fc-cache >/dev/null 2>&1");

    // Private mux daemon.
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

    // Display session (sketerm serving itself; no X anywhere).
    var wl_z: [4096:0]u8 = undefined;
    {
        const r = runDisplayCli(allocator, &.{
            "create", "--name", DISPLAY_SESSION, "--ttl", DISPLAY_TTL, "--json", "--socket", mux_sock,
        });
        defer allocator.free(r.out);
        if (r.code != 0) {
            _ = c.fprintf(platform.stderr(), "smoke-atspi: display create said: %.*s\n", @as(c_int, @intCast(r.out.len)), r.out.ptr);
            return fail("could not create a display session");
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
    }
    say("display session up");

    // The private accessibility bus: dbus-daemon + at-spi2-registryd,
    // org.a11y.Status enabled — all BEFORE the GUI starts (toolkits
    // check exactly once, at startup, and never retry registration).
    hub = A11yHub.setup(allocator, rt, "smoke") orelse
        return fail("could not start the private a11y bus (dbus-daemon spawn failed?)");
    say("private a11y bus + registry up");

    // Attach the compositor brain BEFORE the GUI: nothing configures
    // the toplevel otherwise and the window never paints.
    drive = appdrive.App.attachExisting(allocator, DISPLAY_SESSION, null, mux_sock, null) catch {
        _ = c.fprintf(platform.stderr(), "smoke-atspi: attach said: %s\n", appdrive.lastLaunchErr().ptr);
        return fail("could not attach a viewer to the display session");
    };

    // The GUI under test, on the private bus with its AT-SPI backend ON.
    const pid = c.fork();
    if (pid < 0) return fail("fork");
    if (pid == 0) {
        dieWithParent();
        _ = c.setenv("SKETERM_APP_ID", "dev.sker.sketerm.a11y", 1);
        _ = c.setenv("WAYLAND_DISPLAY", &wl_z, 1);
        _ = c.setenv("GDK_BACKEND", "wayland", 1);
        _ = c.unsetenv("DISPLAY");
        _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
        // `atspi`, not `1`: GTK4 silently ignores the GTK3-ism.
        _ = c.setenv("GTK_A11Y", "atspi", 1);
        _ = c.setenv("DBUS_SESSION_BUS_ADDRESS", hub.?.bus_addr_z.ptr, 1);
        // The final SIGTERM follows a real Wayland GL commit. Make the
        // GUI abort if TerminalSurface storage reaches deinit before
        // its callbacks and live GL state are synchronously severed.
        _ = c.setenv("SKETERM_VERIFY_SURFACE_TEARDOWN", "1", 1);
        // Keep the TabBar effect/warning sources live and require its
        // pre-widget teardown to remove every raw-data closure.
        _ = c.setenv("SKETERM_VERIFY_TABBAR_TEARDOWN", "1", 1);
        const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm", "--no-save", null };
        _ = c.execv("zig-out/bin/sketerm", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    child_pid = pid;

    const sock_path = std.fmt.allocPrintSentinel(allocator, "{s}/sketerm/{d}.sock", .{ rt, pid }, 0) catch return fail("alloc");
    defer allocator.free(sock_path);
    waited = 0;
    while (c.access(sock_path.ptr, c.F_OK) != 0) {
        _ = c.usleep(100_000);
        waited += 1;
        if (waited > 100) return fail("GUI control socket never appeared (10s)");
    }
    if (!drive.?.waitFirstWindow(60_000))
        return fail("the GUI never committed a window into the display session");
    say("GUI window rendered");
    _ = c.usleep(700_000);

    // ── 1. the TERMINAL node exists on the real bus ──────────────────
    const term_id = findTerminalNode(allocator, 30_000) orelse
        return fail("no TERMINAL-role node appeared in the AT-SPI tree (empty tree?)");
    defer allocator.free(term_id);
    say("TERMINAL node found in the AT-SPI tree");

    // ── 2. typed text is readable over org.a11y.atspi.Text ──────────
    {
        const req = "{\"cmd\":\"send-text\",\"pane\":1,\"data\":\"" ++ MARKER ++ "\"}\n";
        const resp = roundtrip(allocator, sock_path, req) orelse return fail("send-text roundtrip");
        defer allocator.free(resp);
        if (std.mem.indexOf(u8, resp, "\"ok\":true") == null) return fail("send-text not ok");
    }
    var caret0: i32 = -1;
    {
        var tries: u32 = 0;
        var ok = false;
        while (tries < 100) : (tries += 1) {
            if (drive) |app| app.drain();
            if (hub.?.textState(allocator, term_id)) |ts| {
                defer allocator.free(ts.text);
                if (std.mem.indexOf(u8, ts.text, MARKER) != null) {
                    // The caret must sit right after the typed marker.
                    const cb = charToByte(ts.text, ts.caret);
                    if (std.mem.endsWith(u8, ts.text[0..cb], MARKER)) {
                        caret0 = ts.caret;
                        ok = true;
                        break;
                    }
                }
            }
            _ = c.usleep(200_000);
        }
        if (!ok) return fail("Text.GetText never showed the typed marker with the caret after it");
    }
    say("typed text readable; caret sits after it");

    // ── 3. the caret moves with the cursor ───────────────────────────
    {
        const resp = roundtrip(allocator, sock_path, "{\"cmd\":\"send-text\",\"pane\":1,\"data\":\"xyz\"}\n") orelse return fail("send-text 2 roundtrip");
        defer allocator.free(resp);
        if (std.mem.indexOf(u8, resp, "\"ok\":true") == null) return fail("send-text 2 not ok");
        var tries: u32 = 0;
        var ok = false;
        while (tries < 100) : (tries += 1) {
            if (drive) |app| app.drain();
            if (hub.?.textState(allocator, term_id)) |ts| {
                defer allocator.free(ts.text);
                const cb = charToByte(ts.text, ts.caret);
                if (ts.caret == caret0 + 3 and std.mem.endsWith(u8, ts.text[0..cb], MARKER ++ "xyz")) {
                    ok = true;
                    break;
                }
            }
            _ = c.usleep(200_000);
        }
        if (!ok) return fail("CaretOffset did not advance by 3 after typing 3 more characters");
    }
    say("caret moved with the cursor");

    // ── 4. a pointer drag becomes an AT-SPI selection ────────────────
    {
        // Fill the screen so the drag has text under it (kill the
        // pending prompt line first — 0x15 is readline's unix-line-discard).
        const resp = roundtrip(allocator, sock_path, "{\"cmd\":\"send-text\",\"pane\":1,\"data\":\"\\u0015seq 1 30\\n\"}\n") orelse return fail("seq roundtrip");
        defer allocator.free(resp);
        if (std.mem.indexOf(u8, resp, "\"ok\":true") == null) return fail("seq send not ok");
        var tries: u32 = 0;
        while (tries < 100) : (tries += 1) {
            if (drive) |app| app.drain();
            if (hub.?.textState(allocator, term_id)) |ts| {
                defer allocator.free(ts.text);
                if (std.mem.indexOf(u8, ts.text, "29\n30") != null) break;
            }
            _ = c.usleep(200_000);
        } else return fail("seq output never appeared in the a11y text");

        const app = drive.?;
        _ = app.drainLive(2_000);
        if (app.windows.items.len == 0) return fail("display session lost its window");
        const win = app.windows.items[0];
        const w: f64 = @floatFromInt(win.w);
        const h: f64 = @floatFromInt(win.h);
        // A vertical drag through the pane's middle: spans several rows,
        // so the selected text must be non-empty and multi-line whatever
        // the exact font metrics are.
        app.drag(win.id, w * 0.30, h * 0.35, w * 0.35, h * 0.70, 1) catch return fail("injecting the selection drag failed");

        var sel_ok = false;
        tries = 0;
        while (tries < 100) : (tries += 1) {
            if (drive) |a| a.drain();
            const n = hub.?.textNSelections(allocator, term_id) orelse -1;
            if (n == 1) {
                const range = hub.?.textSelection(allocator, term_id) orelse continue;
                if (range[1] > range[0]) {
                    const ts = hub.?.textState(allocator, term_id) orelse continue;
                    defer allocator.free(ts.text);
                    const b0 = charToByte(ts.text, range[0]);
                    const b1 = charToByte(ts.text, range[1]);
                    const seltext = ts.text[b0..b1];
                    if (seltext.len > 0 and std.mem.indexOfScalar(u8, seltext, '\n') != null) {
                        sel_ok = true;
                        break;
                    }
                }
            }
            _ = c.usleep(200_000);
        }
        if (!sel_ok) return fail("a pointer drag never became a (multi-line) AT-SPI selection");
        say("drag selection readable over Text.GetSelection");

        // A plain click clears it — and AT-SPI must agree.
        app.clickEx(win.id, w * 0.5, h * 0.5, 1, 60, 1) catch return fail("injecting the clearing click failed");
        var cleared = false;
        tries = 0;
        while (tries < 100) : (tries += 1) {
            if (drive) |a| a.drain();
            if ((hub.?.textNSelections(allocator, term_id) orelse -1) == 0) {
                cleared = true;
                break;
            }
            _ = c.usleep(200_000);
        }
        if (!cleared) return fail("the selection did not clear on click");
        say("selection cleared on click");
    }

    // ── 5. the pane's context menu, over the same bridge ─────────────
    if (contextMenuStage(allocator, sock_path)) |msg| {
        _ = c.fprintf(platform.stderr(), "smoke-atspi: FAIL: %.*s\n", @as(c_int, @intCast(msg.len)), msg.ptr);
        teardown();
        return 1;
    }

    // ── 5b. the headerbar hamburger ─────────────────────────────────
    if (hamburgerStage(allocator)) |msg| {
        _ = c.fprintf(platform.stderr(), "smoke-atspi: FAIL: %.*s\n", @as(c_int, @intCast(msg.len)), msg.ptr);
        teardown();
        return 1;
    }

    // ── 6. the shared per-tab menu on the editor's document tabs ────
    if (tabMenuStage(allocator, rt, sock_path)) |msg| {
        _ = c.fprintf(platform.stderr(), "smoke-atspi: FAIL: %.*s\n", @as(c_int, @intCast(msg.len)), msg.ptr);
        teardown();
        return 1;
    }

    // ── 7-10. the editor canvas ──────────────────────────────────────
    if (editorStage(allocator, rt, sock_path)) |msg| {
        _ = c.fprintf(platform.stderr(), "smoke-atspi: FAIL: %.*s\n", @as(c_int, @intCast(msg.len)), msg.ptr);
        teardown();
        return 1;
    }

    // ── 11. the editor's CHROME: gutter menu, status menu, sticky ───
    if (editorChromeStage(allocator, rt, sock_path)) |msg| {
        _ = c.fprintf(platform.stderr(), "smoke-atspi: FAIL: %.*s\n", @as(c_int, @intCast(msg.len)), msg.ptr);
        teardown();
        return 1;
    }

    // Graceful GUI shutdown.
    _ = c.kill(pid, c.SIGTERM);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    child_pid = 0;
    if (!(c.WIFEXITED(status) and c.WEXITSTATUS(status) == 0)) return fail("GUI exited abnormally");

    teardown();
    _ = c.fputs("smoke-atspi: PASS\n", platform.stdout());
    return 0;
}

/// Byte offset of character offset `n` (codepoints) in UTF-8 `text`.
fn charToByte(text: []const u8, n: i32) usize {
    if (n <= 0) return 0;
    var chars: i32 = 0;
    var i: usize = 0;
    while (i < text.len and chars < n) {
        i += std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        chars += 1;
    }
    return @min(i, text.len);
}

/// Poll the registry tree for a node with the TERMINAL role (AT-SPI
/// role 60) and return its node id (caller frees). The id is the first
/// `"id"` value preceding the first `"role":60` in the serialized tree.
fn findTerminalNode(allocator: std.mem.Allocator, budget_ms: u32) ?[]u8 {
    var waited: u32 = 0;
    while (waited < budget_ms) : (waited += 500) {
        if (drive) |app| app.drain();
        if (hub.?.treeJson(allocator)) |json| {
            defer allocator.free(json);
            if (std.mem.indexOf(u8, json, "\"role\":60")) |at| {
                const id_key = "{\"id\":\"";
                if (std.mem.lastIndexOf(u8, json[0..at], id_key)) |istart| {
                    const vstart = istart + id_key.len;
                    if (std.mem.indexOfScalarPos(u8, json, vstart, '"')) |vend| {
                        return allocator.dupe(u8, json[vstart..vend]) catch null;
                    }
                }
            }
        }
        _ = c.usleep(500_000);
    }
    return null;
}

/// First integer following `key` in `json`, or null.
fn parseNumAfter(json: []const u8, key: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, json, key) orelse return null;
    var i = at + key.len;
    var v: u64 = 0;
    var any = false;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {
        v = v * 10 + (json[i] - '0');
        any = true;
    }
    return if (any) v else null;
}

/// AT-SPI role GTK 4 maps `GTK_ACCESSIBLE_ROLE_TEXT_BOX` onto:
/// ATSPI_ROLE_TEXT (61), which is what GtkTextView reports too — NOT
/// ATSPI_ROLE_ENTRY (79), and emphatically not the terminal's
/// ATSPI_ROLE_TERMINAL (60).
const ROLE_TEXT_BOX: u32 = 61;

/// Typed into the editor tab. The `é` is deliberate: it is two BYTES
/// and one CHARACTER, so a caret that advances by 2 for "é!" proves the
/// bridge reports character offsets and not rope byte offsets.
const ED_HEAD = "edmark1";
const ED_TAIL = "\u{e9}!";

const NodeRef = struct { id: []u8, role: u32, states_lo: u32 };

/// ATSPI_STATE_EDITABLE is bit 7 of the low state word.
const STATE_EDITABLE_BIT: u32 = 1 << 7;

/// Find the tree node whose accessible Name is exactly `name` AND
/// whose role is `want_role`, and return its id (caller frees).
///
/// The name has to be matched together with the role because the tab
/// STRIP also names its page after the open file: several nodes carry
/// the same name and only one of them is the canvas. Roles that were
/// seen under that name but rejected are reported on failure, so a GTK
/// that maps `GTK_ACCESSIBLE_ROLE_TEXT_BOX` somewhere else says so
/// instead of just timing out.
fn findNamedNode(allocator: std.mem.Allocator, name: []const u8, want_role: u32, budget_ms: u32) ?NodeRef {
    var needle_buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, ",\"name\":\"{s}\"", .{name}) catch return null;
    var seen: [8]u32 = undefined;
    var n_seen: usize = 0;
    var waited: u32 = 0;
    while (waited < budget_ms) : (waited += 500) {
        if (drive) |app| app.drain();
        if (hub.?.treeJson(allocator)) |json| {
            defer allocator.free(json);
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, json, from, needle)) |at| {
                from = at + needle.len;
                const id_key = "{\"id\":\"";
                const istart = std.mem.lastIndexOf(u8, json[0..at], id_key) orelse continue;
                const vstart = istart + id_key.len;
                const vend = std.mem.indexOfScalarPos(u8, json, vstart, '"') orelse continue;
                const role_key = "\",\"role\":";
                var role: u32 = 0;
                if (std.mem.indexOfPos(u8, json, vend, role_key)) |rk| {
                    var i = rk + role_key.len;
                    while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1)
                        role = role * 10 + (json[i] - '0');
                }
                if (role == want_role) {
                    const st_key = ",\"states\":[";
                    var st_lo: u32 = 0;
                    if (std.mem.indexOfPos(u8, json, vend, st_key)) |sk| {
                        var i = sk + st_key.len;
                        while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1)
                            st_lo = st_lo * 10 + (json[i] - '0');
                    }
                    const id = allocator.dupe(u8, json[vstart..vend]) catch return null;
                    return .{ .id = id, .role = role, .states_lo = st_lo };
                }
                if (n_seen < seen.len) {
                    seen[n_seen] = role;
                    n_seen += 1;
                }
            }
        }
        _ = c.usleep(500_000);
    }
    for (seen[0..n_seen]) |r|
        _ = c.fprintf(platform.stderr(), "smoke-atspi: node named '%.*s' had role %u\n", @as(c_int, @intCast(name.len)), name.ptr, r);
    return null;
}

/// ATSPI_STATE_SENSITIVE is bit 24 of the low state word — what GTK
/// clears for a button whose GAction is disabled. Reading it is how
/// this rig tells "greyed out" from "absent", which is the difference
/// between a menu row that explains itself and one that silently does
/// nothing.
const STATE_SENSITIVE_BIT: u32 = 1 << 24;

/// ATSPI_ROLE_PUSH_BUTTON. The pane menu builds its rows as
/// GtkButtons (GtkPopoverMenu cannot render per-item icons), so every
/// row is a push button in the tree.
const ROLE_PUSH_BUTTON: u32 = 43;

/// A context-menu row, located by its visible label.
fn findMenuRow(allocator: std.mem.Allocator, label: []const u8, budget_ms: u32) ?NodeRef {
    return findNamedNode(allocator, label, ROLE_PUSH_BUTTON, budget_ms);
}

/// The terminal pane's right-click menu, asserted through AT-SPI.
///
/// This is the half `smoke_e2e` cannot do: it runs with GTK_A11Y=none,
/// so it can only prove the popup surface appeared. Here the rows are
/// real accessible objects, so their presence, their sensitivity and
/// their activation are all checkable — and a menu invisible to a
/// screen reader fails outright.
fn contextMenuStage(allocator: std.mem.Allocator, sock_path: [:0]const u8) ?[]const u8 {
    const app = drive orelse return "the display session has no driver";
    _ = app.drainLive(2_000);
    if (app.windows.items.len == 0) return "the display session lost its window";
    const win = app.windows.items[0];
    const w: f64 = @floatFromInt(win.w);
    const h: f64 = @floatFromInt(win.h);

    // The preceding stage left a plain click in the middle of the
    // pane, i.e. an ACTIVE BUT EMPTY selection. That is exactly the
    // state in which Copy must be greyed out.
    app.clickEx(win.id, w * 0.5, h * 0.5, 3, 80, 1) catch
        return "injecting a right-click failed";

    const paste = findMenuRow(allocator, "Paste", 10_000) orelse
        return "no Paste row appeared in the AT-SPI tree after a right-click";
    defer allocator.free(paste.id);
    if (paste.states_lo & STATE_SENSITIVE_BIT == 0)
        return "Paste is insensitive; it should always be available";

    const copy = findMenuRow(allocator, "Copy", 5_000) orelse
        return "the context menu exposes no Copy row";
    defer allocator.free(copy.id);
    if (copy.states_lo & STATE_SENSITIVE_BIT != 0)
        return "Copy is sensitive with an empty selection — it must grey out, not copy nothing";

    // Rows added alongside the keyboard path must be reachable too.
    if (findMenuRow(allocator, "Select All", 5_000)) |n| {
        allocator.free(n.id);
    } else return "the context menu exposes no Select All row";
    if (findMenuRow(allocator, "Find\u{2026}", 5_000)) |n| {
        allocator.free(n.id);
    } else return "the context menu exposes no Find row";

    // ── a row that genuinely acts ───────────────────────────────
    const split = findMenuRow(allocator, "Split Left / Right", 5_000) orelse
        return "the context menu exposes no Split Left / Right row";
    defer allocator.free(split.id);
    if (split.states_lo & STATE_SENSITIVE_BIT == 0) return "Split Left / Right is greyed out";

    const before = paneIdCount(allocator, sock_path) orelse
        return "listing panes before the menu split failed";
    if (!hub.?.doAction(allocator, split.id, 0))
        return "activating the Split row over AT-SPI failed";

    var tries: u32 = 0;
    while (tries < 100) : (tries += 1) {
        app.drain();
        if (paneIdCount(allocator, sock_path)) |now| {
            if (now > before) break;
        }
        _ = c.usleep(200_000);
    } else return "the menu's Split row did not actually split the pane";
    say("context menu: rows exposed to AT-SPI, Copy greyed out on an empty selection, Split really split");

    // Put the layout back so the editor stage sees what it expects.
    const closed = roundtrip(allocator, sock_path, "{\"cmd\":\"close-pane\",\"pane\":2}\n") orelse
        return "closing the pane the menu split off failed";
    allocator.free(closed);
    tries = 0;
    while (tries < 100) : (tries += 1) {
        app.drain();
        if (paneIdCount(allocator, sock_path)) |now| {
            if (now == before) break;
        }
        _ = c.usleep(200_000);
    } else return "the pane split off by the menu never closed again";
    return null;
}

/// The window's headerbar hamburger, asserted through AT-SPI.
///
/// It is activated through the bridge rather than clicked at a guessed
/// pixel: the a11y tree reports every rect at 0,0 on Wayland, so there
/// is no honest coordinate for a headerbar button. The rows are then
/// real accessible objects, which is what turns "a popup appeared"
/// into "the menu lists the verbs it promises" — including the About
/// and Keyboard Shortcuts rows every identity's hamburger carries.
fn hamburgerStage(allocator: std.mem.Allocator) ?[]const u8 {
    const app = drive orelse return "the display session has no driver";
    _ = app.drainLive(2_000);
    const burger = findNamedNode(allocator, "Main Menu", ROLE_PUSH_BUTTON, 15_000) orelse
        return "the headerbar hamburger is not in the AT-SPI tree";
    defer allocator.free(burger.id);
    if (!hub.?.doAction(allocator, burger.id, 0))
        return "activating the headerbar hamburger over AT-SPI failed";
    // Rows the window menu promises: the spec-sourced verbs and the
    // shared Help tail.
    for ([_][]const u8{
        "New Tab",
        "Split Left / Right",
        "Split Top / Bottom",
        "Preferences\u{2026}",
        "Keyboard Shortcuts",
        "About Sketerm",
    }) |label| {
        if (findMenuRow(allocator, label, 5_000)) |n| {
            allocator.free(n.id);
        } else {
            _ = c.fprintf(platform.stderr(), "smoke-atspi: hamburger has no '%.*s' row\n", @as(c_int, @intCast(label.len)), label.ptr);
            return "the window hamburger is missing a row";
        }
    }
    // The Session submenu's own rows live in a child popover that is
    // only realized on hover, so the parent row is what the tree can
    // see here; its contents are the pane menu's, already asserted.
    if (findMenuRow(allocator, "Session", 5_000)) |n| {
        allocator.free(n.id);
    } else return "the window hamburger has no Session submenu row";
    dismissPopup(app);
    _ = waitTabPopup(app, false, 5_000);
    say("window hamburger: opened over AT-SPI, every spec row and the shared Help tail present");
    return null;
}

/// Number of `"id":` fields the GUI's control socket reports (one tab
/// id plus one per pane).
fn paneIdCount(allocator: std.mem.Allocator, sock_path: [:0]const u8) ?usize {
    const resp = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse return null;
    defer allocator.free(resp);
    if (std.mem.indexOf(u8, resp, "\"ok\":true") == null) return null;
    return std.mem.count(u8, resp, "\"id\":");
}

/// ATSPI_ROLE_PAGE_TAB — what GTK4 maps a GtkNotebook tab onto. The
/// inner document tabs of the editor and the file browser are these.
const ROLE_PAGE_TAB: u32 = 37;

const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

const TabNode = struct { id: []u8, rect: Rect, states_lo: u32 };

/// `"rect":[x,y,w,h]` starting at or after `from`, plus the offset
/// just past it.
fn parseRectAt(json: []const u8, from: usize) ?struct { rect: Rect, end: usize } {
    const key = ",\"rect\":[";
    const at = std.mem.indexOfPos(u8, json, from, key) orelse return null;
    var i = at + key.len;
    var vals: [4]i32 = undefined;
    for (&vals) |*v| {
        var neg = false;
        if (i < json.len and json[i] == '-') {
            neg = true;
            i += 1;
        }
        var n: i32 = 0;
        var any = false;
        while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {
            n = n * 10 + @as(i32, json[i] - '0');
            any = true;
        }
        if (!any) return null;
        v.* = if (neg) -n else n;
        if (i < json.len and (json[i] == ',' or json[i] == ']')) i += 1;
    }
    return .{ .rect = .{ .x = vals[0], .y = vals[1], .w = vals[2], .h = vals[3] }, .end = i };
}

/// Width of the application's toplevel (role FRAME), which the
/// driver's window box exceeds by the client-side-decoration margin.
fn frameWidth(json: []const u8) f64 {
    const key = "\"role\":23,";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, json, from, key)) |at| {
        from = at + key.len;
        const hit = parseRectAt(json, at) orelse continue;
        if (hit.rect.w > 0) return @floatFromInt(hit.rect.w);
    }
    return 0;
}

/// A document tab in an inner tab strip, located by its label. The
/// rect carries the tab's SIZE only (see locateTabStrip on why the
/// position is unusable).
fn findTabNode(allocator: std.mem.Allocator, name: []const u8, budget_ms: u32) ?TabNode {
    var needle_buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, ",\"name\":\"{s}\"", .{name}) catch return null;
    var waited: u32 = 0;
    while (waited < budget_ms) : (waited += 500) {
        if (drive) |app| app.drain();
        if (hub.?.treeJson(allocator)) |json| {
            defer allocator.free(json);
            frame_w = frameWidth(json);
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, json, from, needle)) |at| {
                from = at + needle.len;
                const id_key = "{\"id\":\"";
                const istart = std.mem.lastIndexOf(u8, json[0..at], id_key) orelse continue;
                const vstart = istart + id_key.len;
                const vend = std.mem.indexOfScalarPos(u8, json, vstart, '"') orelse continue;
                const role_key = "\",\"role\":";
                var role: u32 = 0;
                if (std.mem.indexOfPos(u8, json, vend, role_key)) |rk| {
                    var i = rk + role_key.len;
                    while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1)
                        role = role * 10 + (json[i] - '0');
                }
                if (role != ROLE_PAGE_TAB) continue;
                const st_key = ",\"states\":[";
                var st_lo: u32 = 0;
                const sk = std.mem.indexOfPos(u8, json, vend, st_key) orelse continue;
                var i = sk + st_key.len;
                while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1)
                    st_lo = st_lo * 10 + (json[i] - '0');
                const hit = parseRectAt(json, sk) orelse continue;
                const id = allocator.dupe(u8, json[vstart..vend]) catch return null;
                return .{ .id = id, .rect = hit.rect, .states_lo = st_lo };
            }
            dumpTree(json);
        }
        _ = c.usleep(500_000);
    }
    return null;
}

/// A PNG of an open popup surface, for a human to look at. Same
/// artefact convention as smoke-e2e's menu shots.
fn shotPopup(allocator: std.mem.Allocator, id: u32, path: [*:0]const u8) void {
    const app = drive orelse return;
    const shot = app.screenshotPng(id, 1024, null, 0) catch return;
    defer allocator.free(shot.png);
    const f = c.fopen(path, "wb") orelse return;
    _ = c.fwrite(shot.png.ptr, 1, shot.png.len, f);
    _ = c.fclose(f);
}

/// Last tree walked, for diagnosing a stage that cannot find its node.
fn dumpTree(json: []const u8) void {
    const f = c.fopen("/tmp/sketerm-atspi-tree.json", "wb") orelse return;
    _ = c.fwrite(json.ptr, 1, json.len, f);
    _ = c.fclose(f);
}

/// Right-click a point and wait for the menu's popup surface.
///
/// A GTK4 popover is its OWN xdg_popup surface, so "the menu opened"
/// is counted on the compositor side; the a11y rows alone could come
/// from a stale tree.
fn rightClickAt(x: f64, y: f64, ms: u32) ?u32 {
    const app = drive orelse return null;
    _ = app.drainLive(500);
    if (app.windows.items.len == 0) return null;
    const win = app.windows.items[0];
    app.clickEx(win.id, x, y, 3, 80, 1) catch return null;
    return waitTabPopup(app, true, ms);
}

/// An open MENU popup surface. Size-filtered: GTK tooltips are
/// xdg_popups too, and the toolbar above the tab strip has one on
/// every button — an unfiltered "is a popup" test reports those.
/// Every menu here is at least four rows tall.
fn tabPopup(app: *appdrive.App) ?u32 {
    _ = app.pumpOnce(120);
    for (app.windows.items) |w| {
        if (w.popup and w.frames > 0 and w.h >= 70 and w.w >= 120) return w.id;
    }
    return null;
}

fn waitTabPopup(app: *appdrive.App, want_open: bool, ms: u32) ?u32 {
    var waited: u32 = 0;
    while (true) {
        const id = tabPopup(app);
        if ((id != null) == want_open) return id orelse 0;
        if (waited >= ms) return null;
        _ = app.pumpOnce(200);
        waited += 200;
    }
}

const Point = struct { x: f64, y: f64 };

/// Toplevel width as the a11y tree measures it (role FRAME), so the
/// driver's client-side-decoration margin can be subtracted. Filled
/// by findTabNode on every tree walk.
var frame_w: f64 = 0;

/// ATSPI_STATE_SELECTED is bit 23 of the low state word — set on the
/// tab a GtkNotebook currently shows.
const STATE_SELECTED_BIT: u32 = 1 << 23;

/// Window-local point on the tab strip's FIRST tab, found by probing
/// down the column of a tab that is NOT currently selected with LEFT
/// clicks until the a11y tree reports that tab selected.
///
/// Probing, not extents: GTK4 on Wayland reports every accessible rect
/// at 0,0 (a client cannot know its own screen position), so the tree
/// gives sizes and nothing to aim with. Left clicks, not right ones:
/// a right click that misses opens some other surface's menu, and
/// dismissing that eats the next press — the probe then chases its own
/// wake instead of finding the strip. A left click that misses only
/// moves a caret, and the hit is confirmed by an EFFECT (the tab it
/// selects) rather than by a popup appearing. The probed column is an
/// unselected tab because a tab that is already selected cannot
/// confirm anything.
fn locateTabStrip(allocator: std.mem.Allocator, names: []const []const u8, tab_w: i32, tab_h: i32) ?Point {
    const app = drive orelse return null;
    if (app.windows.items.len == 0) return null;
    const win = app.windows.items[0];
    // Client-side decorations: the driver's window box is bigger than
    // the toplevel the a11y tree measures, by an even margin.
    const margin: f64 = @max(0.0, (@as(f64, @floatFromInt(win.w)) - frame_w) / 2);
    const w: f64 = @floatFromInt(tab_w);

    var target: ?usize = null;
    for (names, 0..) |name, i| {
        const node = findTabNode(allocator, name, 2_000) orelse continue;
        defer allocator.free(node.id);
        if (node.states_lo & STATE_SELECTED_BIT == 0) target = i;
    }
    const idx = target orelse return null;
    const x = margin + w * (@as(f64, @floatFromInt(idx)) + 0.5);
    var y: f64 = margin;
    const limit: f64 = margin + 420;
    while (y < limit) : (y += 10) {
        app.clickEx(win.id, x, y, 1, 60, 1) catch return null;
        _ = app.waitIdle(200, 1_500);
        const node = findTabNode(allocator, names[idx], 1) orelse continue;
        defer allocator.free(node.id);
        if (node.states_lo & STATE_SELECTED_BIT == 0) continue;
        // A third of a tab down from the first row that works: the
        // topmost such row is the notebook's own tab-area edge, where
        // a press reaches the strip gesture but not the label box.
        return .{ .x = margin + w * 0.5, .y = y + @as(f64, @floatFromInt(tab_h)) / 3 };
    }
    return null;
}

/// Close whatever menu is open (Escape, then an inside-the-content
/// click — never near the window edge, which is a resize band).
fn dismissPopup(app: *appdrive.App) void {
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        if (tabPopup(app) == null) return;
        app.pressKey(null, "Escape") catch {};
        if (waitTabPopup(app, false, 1_500) != null) return;
        if (app.windows.items.len == 0) return;
        const win = app.windows.items[0];
        app.clickEx(win.id, @as(f64, @floatFromInt(win.w)) / 2, @as(f64, @floatFromInt(win.h)) - 60, 1, 60, 1) catch {};
        if (waitTabPopup(app, false, 1_500) != null) return;
    }
}

/// The per-tab context menu shared by the editor and the file browser
/// (ui/tabhost.zig), asserted on the editor's document tabs: the menu
/// opens as a real popup surface, its rows are accessible objects with
/// the sensitivity the document under the pointer implies, a row that
/// copies really writes the clipboard, the keyboard opens the same
/// menu, and Close Other Tabs really closes the others.
fn tabMenuStage(allocator: std.mem.Allocator, rt: []const u8, sock_path: [:0]const u8) ?[]const u8 {
    const app = drive orelse return "the display session has no driver";
    // Three documents in ONE editor face, on the pane that is already
    // in front: `editor-here` converts it, and every further call adds
    // a document tab to that same face.
    var path_buf: [3][512]u8 = undefined;
    var names: [3][]const u8 = undefined;
    var specs: [3][:0]const u8 = undefined;
    for (0..3) |i| {
        specs[i] = std.fmt.bufPrintZ(&path_buf[i], "{s}/tabmenu-{c}.txt", .{ rt, @as(u8, 'a') + @as(u8, @intCast(i)) }) catch
            return "tab menu path";
        names[i] = std.fs.path.basename(std.mem.span(specs[i].ptr));
        const f = c.fopen(specs[i].ptr, "wb") orelse return "creating a tab-menu document failed";
        _ = c.fputs("hello\n", f);
        _ = c.fclose(f);
    }

    var req_buf: [800]u8 = undefined;
    const epane: u64 = 1;
    for (specs) |spec| {
        const rq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"editor-here\",\"pane\":{d},\"data\":\"{s}\"}}\n", .{ epane, spec }) catch return "fmt";
        const rp = roundtrip(allocator, sock_path, rq) orelse return "editor-here roundtrip";
        defer allocator.free(rp);
        if (std.mem.indexOf(u8, rp, "\"ok\":true") == null) return "editor-here was refused";
    }
    var settle: u32 = 0;
    while (settle < 15) : (settle += 1) {
        app.drain();
        _ = c.usleep(100_000);
    }

    // ── find the strip, then open the menu on the FIRST document ──
    const tab_a = findTabNode(allocator, names[0], 30_000) orelse
        return "no PAGE_TAB node named after the first document appeared (see /tmp/sketerm-atspi-tree.json)";
    defer allocator.free(tab_a.id);
    if (waitTabPopup(app, false, 3_000) == null) return "a popup was already open before the tab menu stage";
    const first = locateTabStrip(allocator, &names, tab_a.rect.w, tab_a.rect.h) orelse
        return "clicking down the document tab column never selected a document tab";
    const menu_id = rightClickAt(first.x, first.y, 10_000) orelse
        return "right-clicking the first document's tab opened no menu popup";
    _ = app.waitVisualSettle(menu_id, 300, 5_000, 0.002, null);
    shotPopup(allocator, menu_id, "/tmp/sketerm-atspi-editor-tab-menu.png");

    // ── rows, and what their sensitivity says ───────────────────
    // A freshly loaded document is clean, so Save has nothing to do;
    // Save As always does. Both must be PRESENT — a row that vanishes
    // teaches nothing about why it cannot act.
    const save = findMenuRow(allocator, "Save", 10_000) orelse
        return "the tab menu exposes no Save row";
    defer allocator.free(save.id);
    if (save.states_lo & STATE_SENSITIVE_BIT != 0)
        return "Save is sensitive on a clean document — it must grey out";
    const save_as = findMenuRow(allocator, "Save As\u{2026}", 5_000) orelse
        return "the tab menu exposes no Save As row";
    defer allocator.free(save_as.id);
    if (save_as.states_lo & STATE_SENSITIVE_BIT == 0) return "Save As is greyed out";

    // The documents live in the isolated runtime dir, which has no
    // project marker above it — project.zig answers null, so there is
    // nothing for a relative path to be relative TO.
    const rel = findMenuRow(allocator, "Copy Relative Path", 5_000) orelse
        return "the tab menu exposes no Copy Relative Path row";
    defer allocator.free(rel.id);
    if (rel.states_lo & STATE_SENSITIVE_BIT != 0)
        return "Copy Relative Path is sensitive on a document with no project";

    const others = findMenuRow(allocator, "Close Other Tabs", 5_000) orelse
        return "the tab menu exposes no Close Other Tabs row";
    defer allocator.free(others.id);
    if (others.states_lo & STATE_SENSITIVE_BIT == 0)
        return "Close Other Tabs is greyed out with three documents open";

    // ── a row that really acts: Copy Full Path → the clipboard ──
    const full = findMenuRow(allocator, "Copy Full Path", 5_000) orelse
        return "the tab menu exposes no Copy Full Path row";
    defer allocator.free(full.id);
    if (full.states_lo & STATE_SENSITIVE_BIT == 0) return "Copy Full Path is greyed out on a saved document";
    if (!hub.?.doAction(allocator, full.id, 0)) return "activating Copy Full Path over AT-SPI failed";
    _ = waitTabPopup(app, false, 5_000);
    var clip_ok = false;
    var tries: u32 = 0;
    while (tries < 40) : (tries += 1) {
        app.drain();
        if (app.getClipboard(3_000)) |text| {
            defer allocator.free(text);
            if (std.mem.eql(u8, std.mem.trim(u8, text, " \n\r\t"), std.mem.span(specs[0].ptr))) {
                clip_ok = true;
                break;
            }
        } else |_| {}
        _ = c.usleep(250_000);
    }
    if (!clip_ok) return "Copy Full Path did not put the document's path on the clipboard";
    say("editor tab menu: real popup surface, rows sensitive per document state, Copy Full Path really copied");

    // ── the keyboard path opens the SAME menu ───────────────────
    // Clicking a tab leaves focus on the notebook's tab gizmo, which
    // is where Menu / Shift+F10 is answered.
    app.clickEx(app.windows.items[0].id, first.x, first.y, 1, 60, 1) catch return "clicking the tab failed";
    _ = app.waitIdle(200, 2_000);
    app.pressKey(null, "shift+F10") catch return "injecting Shift+F10 failed";
    if (waitTabPopup(app, true, 10_000) == null)
        return "Shift+F10 on the tab strip opened no tab menu";
    if (findMenuRow(allocator, "Close Other Tabs", 8_000)) |n| {
        allocator.free(n.id);
    } else return "the keyboard-opened tab menu has no rows";
    app.pressKey(null, "Escape") catch return "injecting Escape failed";
    if (waitTabPopup(app, false, 8_000) == null) return "the keyboard-opened tab menu never closed on Escape";
    say("editor tab menu: Shift+F10 on the tab strip opened the same menu, Escape closed it");

    // ── Close Other Tabs really closes the others ───────────────
    if (rightClickAt(first.x, first.y, 10_000) == null)
        return "reopening the tab menu on the first document failed";
    const others2 = findMenuRow(allocator, "Close Other Tabs", 8_000) orelse
        return "the reopened tab menu exposes no Close Other Tabs row";
    defer allocator.free(others2.id);
    if (!hub.?.doAction(allocator, others2.id, 0)) return "activating Close Other Tabs over AT-SPI failed";
    tries = 0;
    while (tries < 60) : (tries += 1) {
        app.drain();
        if (!hasTabNamed(allocator, names[1]) and !hasTabNamed(allocator, names[2])) break;
        _ = c.usleep(250_000);
    } else return "Close Other Tabs left the other documents open";
    if (!hasTabNamed(allocator, names[0])) return "Close Other Tabs closed the tab it was invoked on";
    say("editor tab menu: Close Other Tabs closed the other two documents and kept its own");
    dismissPopup(app);

    // ── the same mechanism on the file browser's tabs ───────────
    if (browserTabMenuStage(allocator, rt, sock_path)) |why| return why;

    // Hand the pane back to its shell for the editor stage, which
    // opens its own editor pane from scratch.
    {
        const rq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"send-keys\",\"pane\":{d},\"keys\":\"ctrl+shift+e\"}}\n", .{epane}) catch return "fmt";
        const rp = roundtrip(allocator, sock_path, rq) orelse return "send-keys roundtrip";
        allocator.free(rp);
    }
    var closed: u32 = 0;
    while (closed < 20) : (closed += 1) {
        app.drain();
        _ = c.usleep(100_000);
    }
    return null;
}

/// The other consumer of the same TabHost mechanism: the file
/// browser's tabs. The shared rows must be the same ones, minus the
/// editor-only Close Unmodified Tabs, plus Duplicate Tab — which the
/// browser has and the editor deliberately does not. Both a domain
/// row (Duplicate) and a shared bulk-close row are activated.
fn browserTabMenuStage(allocator: std.mem.Allocator, rt: []const u8, sock_path: [:0]const u8) ?[]const u8 {
    const app = drive orelse return "the display session has no driver";
    var dir_buf: [3][512]u8 = undefined;
    var dirs: [3][:0]const u8 = undefined;
    var names: [3][]const u8 = undefined;
    for (0..3) |i| {
        dirs[i] = std.fmt.bufPrintZ(&dir_buf[i], "{s}/btab-{c}", .{ rt, @as(u8, 'a') + @as(u8, @intCast(i)) }) catch
            return "browser tab path";
        names[i] = std.fs.path.basename(std.mem.span(dirs[i].ptr));
        _ = c.mkdir(dirs[i].ptr, 0o755);
    }
    var req_buf: [800]u8 = undefined;
    for (dirs) |dir| {
        const rq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"browser-here\",\"pane\":1,\"data\":\"{s}\"}}\n", .{dir}) catch return "fmt";
        const rp = roundtrip(allocator, sock_path, rq) orelse return "browser-here roundtrip";
        defer allocator.free(rp);
        if (std.mem.indexOf(u8, rp, "\"ok\":true") == null) return "browser-here was refused";
    }
    var settle: u32 = 0;
    while (settle < 20) : (settle += 1) {
        app.drain();
        _ = c.usleep(100_000);
    }

    const tab_a = findTabNode(allocator, names[0], 30_000) orelse
        return "no PAGE_TAB node named after the first browser tab appeared";
    defer allocator.free(tab_a.id);
    const first = locateTabStrip(allocator, &names, tab_a.rect.w, tab_a.rect.h) orelse
        return "clicking down the browser tab column never selected a tab";
    const menu_id = rightClickAt(first.x, first.y, 10_000) orelse
        return "right-clicking a browser tab opened no menu popup";
    _ = app.waitVisualSettle(menu_id, 300, 5_000, 0.002, null);
    shotPopup(allocator, menu_id, "/tmp/sketerm-atspi-browser-tab-menu.png");

    if (findMenuRow(allocator, "Close Unmodified Tabs", 1)) |n| {
        allocator.free(n.id);
        return "the browser tab menu has a Close Unmodified Tabs row, which means nothing for a listing";
    }
    const others = findMenuRow(allocator, "Close Other Tabs", 5_000) orelse
        return "the browser tab menu exposes no Close Other Tabs row";
    defer allocator.free(others.id);
    if (others.states_lo & STATE_SENSITIVE_BIT == 0) return "Close Other Tabs is greyed out with three tabs open";
    const right = findMenuRow(allocator, "Close Tabs to the Right", 5_000) orelse
        return "the browser tab menu exposes no Close Tabs to the Right row";
    defer allocator.free(right.id);
    if (right.states_lo & STATE_SENSITIVE_BIT == 0)
        return "Close Tabs to the Right is greyed out on the first of three tabs";

    // ── a row that really acts: Duplicate Tab ───────────────────
    const dup = findMenuRow(allocator, "Duplicate Tab", 10_000) orelse
        return "the browser tab menu exposes no Duplicate Tab row";
    defer allocator.free(dup.id);
    if (dup.states_lo & STATE_SENSITIVE_BIT == 0) return "Duplicate Tab is greyed out on a directory tab";
    const before = countTabsNamed(allocator, names[0]);
    if (!hub.?.doAction(allocator, dup.id, 0)) return "activating Duplicate Tab over AT-SPI failed";
    var tries: u32 = 0;
    while (tries < 60) : (tries += 1) {
        app.drain();
        if (countTabsNamed(allocator, names[0]) > before) break;
        _ = c.usleep(250_000);
    } else return "Duplicate Tab did not open a second tab on the same directory";
    say("browser tab menu: same close rows, no Close Unmodified row, Duplicate Tab really duplicated");

    // ── and the shared bulk close, on this consumer too ─────────
    if (rightClickAt(first.x, first.y, 10_000) == null)
        return "reopening the browser tab menu failed";
    const others2 = findMenuRow(allocator, "Close Other Tabs", 8_000) orelse
        return "the reopened browser tab menu exposes no Close Other Tabs row";
    defer allocator.free(others2.id);
    if (!hub.?.doAction(allocator, others2.id, 0)) return "activating Close Other Tabs over AT-SPI failed";
    tries = 0;
    while (tries < 60) : (tries += 1) {
        app.drain();
        if (!hasTabNamed(allocator, names[1]) and !hasTabNamed(allocator, names[2])) break;
        _ = c.usleep(250_000);
    } else return "Close Other Tabs left the other browser tabs open";
    if (!hasTabNamed(allocator, names[0])) return "Close Other Tabs closed the browser tab it was invoked on";
    say("browser tab menu: Close Other Tabs closed the other browser tabs and kept its own");
    dismissPopup(app);
    return null;
}

/// How many document tabs currently carry this label.
fn countTabsNamed(allocator: std.mem.Allocator, name: []const u8) usize {
    var needle_buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, ",\"name\":\"{s}\"", .{name}) catch return 0;
    const json = hub.?.treeJson(allocator) orelse return 0;
    defer allocator.free(json);
    var n: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, json, from, needle)) |at| {
        from = at + needle.len;
        // Each node object opens with its id and then its role, both
        // BEFORE the name this matched.
        const obj = std.mem.lastIndexOf(u8, json[0..at], "{\"id\":\"") orelse continue;
        const role_key = "\",\"role\":";
        const rk = std.mem.indexOfPos(u8, json, obj, role_key) orelse continue;
        var role: u32 = 0;
        var i = rk + role_key.len;
        while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1)
            role = role * 10 + (json[i] - '0');
        if (role == ROLE_PAGE_TAB) n += 1;
    }
    return n;
}

/// Is a document tab with this label in the tree right now?
fn hasTabNamed(allocator: std.mem.Allocator, name: []const u8) bool {
    const n = findTabNode(allocator, name, 1) orelse return false;
    allocator.free(n.id);
    return true;
}

/// The editor canvas over the same bridge: an editable TEXT_BOX node
/// named after the open file, whose Text is the document (and only the
/// document), whose caret counts characters, and whose selection is
/// readable. Returns an error message, or null on pass.
fn editorStage(allocator: std.mem.Allocator, rt: []const u8, sock_path: [:0]const u8) ?[]const u8 {
    var path_buf: [512]u8 = undefined;
    const efile = std.fmt.bufPrintZ(&path_buf, "{s}/a11y-editor.txt", .{rt}) catch return "editor path";
    const base = std.fs.path.basename(std.mem.span(efile.ptr));

    var req_buf: [700]u8 = undefined;
    var epane: u64 = 0;
    {
        const rq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"new-editor-tab\",\"data\":\"{s}\"}}\n", .{efile}) catch return "editor req fmt";
        const rp = roundtrip(allocator, sock_path, rq) orelse return "new-editor-tab roundtrip";
        defer allocator.free(rp);
        if (std.mem.indexOf(u8, rp, "\"ok\":true") == null) return "new-editor-tab not ok";
        epane = parseNumAfter(rp, "\"pane\":") orelse return "new-editor-tab reply has no pane id";
    }
    // An unaddressed `new-editor-tab` CREATES the tab without selecting
    // it (remotectl only selects when a pane was addressed), and an
    // unselected AdwTabView page contributes nothing to the AT-SPI
    // tree. A screen reader reads the tab in front, so select it.
    {
        const rq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{epane}) catch return "fmt";
        const rp = roundtrip(allocator, sock_path, rq) orelse return "editor focus roundtrip";
        defer allocator.free(rp);
        if (std.mem.indexOf(u8, rp, "\"ok\":true") == null) return "focusing the editor tab was refused";
    }
    // The tab spawns and its (missing-file) load resolves asynchronously.
    var settle: u32 = 0;
    while (settle < 10) : (settle += 1) {
        if (drive) |app| app.drain();
        _ = c.usleep(100_000);
    }

    // ── 5. an editable TEXT_BOX named after the document ─────────────
    const node = findNamedNode(allocator, base, ROLE_TEXT_BOX, 30_000) orelse
        return "no editable TEXT_BOX node named after the open document appeared";
    defer allocator.free(node.id);
    if (node.states_lo & STATE_EDITABLE_BIT == 0) {
        _ = c.fprintf(platform.stderr(), "smoke-atspi: editor node states_lo=%u (no EDITABLE bit)\n", node.states_lo);
        return "the editor canvas is not exposed as EDITABLE";
    }
    say("editor node found in the AT-SPI tree (editable TEXT_BOX, named after the file)");

    // ── 6. the Text IS the document ──────────────────────────────────
    if (typeInto(allocator, sock_path, epane, ED_HEAD)) |m| return m;
    if (awaitText(allocator, node.id, ED_HEAD, ED_HEAD.len)) |m| return m;
    say("editor text readable and exactly the document");

    // ── 7. the caret counts characters, not bytes ────────────────────
    if (typeInto(allocator, sock_path, epane, ED_TAIL)) |m| return m;
    // "é!" is 3 bytes and 2 characters: the caret must land on 9.
    if (awaitText(allocator, node.id, ED_HEAD ++ ED_TAIL, ED_HEAD.len + 2)) |m| return m;
    say("editor caret advanced in characters (not rope bytes)");

    // ── 8. a selection is reported ───────────────────────────────────
    // Shift+Home over the REAL seat: `send-keys` on an editor face
    // speaks a small fixed chord set that has no selection chords, and
    // a selection is exactly the thing worth driving through actual
    // input anyway.
    {
        const app = drive orelse return "the display viewer went away";
        _ = app.drainLive(2_000);
        if (app.windows.items.len == 0) return "display session lost its window";
        app.pressKey(app.windows.items[0].id, "shift+home") catch return "injecting Shift+Home failed";
    }
    var tries: u32 = 0;
    var sel_ok = false;
    while (tries < 100) : (tries += 1) {
        if (drive) |app| app.drain();
        if ((hub.?.textNSelections(allocator, node.id) orelse -1) == 1) {
            if (hub.?.textSelection(allocator, node.id)) |range| {
                const ts = hub.?.textState(allocator, node.id) orelse continue;
                defer allocator.free(ts.text);
                const b0 = charToByte(ts.text, range[0]);
                const b1 = charToByte(ts.text, range[1]);
                if (std.mem.eql(u8, ts.text[b0..b1], ED_HEAD ++ ED_TAIL)) {
                    sel_ok = true;
                    break;
                }
            }
        }
        _ = c.usleep(200_000);
    }
    if (!sel_ok) return "Shift+Home never became an AT-SPI selection covering the typed line";
    say("editor selection readable over Text.GetSelection");

    // Save, so the GUI's SIGTERM is not met by a dirty-buffer prompt.
    {
        const rq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"send-keys\",\"pane\":{d},\"data\":\"ctrl+s\"}}\n", .{epane}) catch return "fmt";
        const rp = roundtrip(allocator, sock_path, rq) orelse return "editor ctrl+s roundtrip";
        defer allocator.free(rp);
        if (std.mem.indexOf(u8, rp, "\"ok\":true") == null) return "editor ctrl+s not ok";
    }
    tries = 0;
    while (tries < 50) : (tries += 1) {
        if (drive) |app| app.drain();
        _ = c.usleep(200_000);
        const f = c.fopen(efile.ptr, "rb") orelse continue;
        var content: [64]u8 = undefined;
        const n = c.fread(&content, 1, content.len, f);
        _ = c.fclose(f);
        if (std.mem.eql(u8, content[0..n], ED_HEAD ++ ED_TAIL)) break;
    } else return "the editor buffer never saved (a dirty prompt would block shutdown)";
    return null;
}

/// Type `text` into the focused pane (the editor tab just opened).
fn typeInto(allocator: std.mem.Allocator, sock_path: [:0]const u8, pane: u64, text: []const u8) ?[]const u8 {
    var buf: [512]u8 = undefined;
    const rq = std.fmt.bufPrint(&buf, "{{\"cmd\":\"send-text\",\"pane\":{d},\"data\":\"{s}\"}}\n", .{ pane, text }) catch return "fmt";
    const rp = roundtrip(allocator, sock_path, rq) orelse return "editor send-text roundtrip";
    defer allocator.free(rp);
    if (std.mem.indexOf(u8, rp, "\"ok\":true") == null) return "editor send-text not ok";
    return null;
}

/// Poll until node `id`'s Text is EXACTLY `want` with the caret at
/// `caret` characters. Exact, not "contains": a gutter, an inlay hint
/// or any other decoration leaking into the accessible text would fail
/// here.
fn awaitText(allocator: std.mem.Allocator, id: []const u8, want: []const u8, caret: usize) ?[]const u8 {
    var tries: u32 = 0;
    while (tries < 100) : (tries += 1) {
        if (drive) |app| app.drain();
        if (hub.?.textState(allocator, id)) |ts| {
            defer allocator.free(ts.text);
            if (std.mem.eql(u8, ts.text, want) and ts.caret == @as(i32, @intCast(caret))) return null;
        }
        _ = c.usleep(200_000);
    }
    return "the editor's Text/CaretOffset never matched what was typed";
}

/// One connect → one request line → one response line on the GUI's
/// control socket. Pumps the display viewer first (this process is the
/// compositor brain; starving it stalls the GUI's frame handling).
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

// ======================================================================
// The editor's CHROME: the gutter menu, the status-line menu, and the
// sticky status message.
//
// All three were dead or defective before: right-clicking the gutter
// gave the caret-oriented CANVAS menu (whose rows act on a selection
// the pointer is not near), right-clicking the status line gave
// nothing at all, and any message written to the status line was
// erased by the next `EditorView.updateStatus` — which runs on every
// caret move, edit, tab switch and diagnostic publish.
//
// The three menus are told apart by rows that exist in exactly one of
// them: `Select This Line` (gutter), `Toggle Line Comment` (canvas),
// `Soft Wrap` (status). Each stage asserts its own row IS there AND
// the other two are NOT, so a routing regression that silently falls
// back to the canvas menu fails here instead of passing.
// ======================================================================

/// A `.zig` document, so the tree-sitter grammar gives the gutter real
/// fold regions to offer.
const CHROME_DOC =
    \\pub fn main() void {
    \\    const a = 1;
    \\    const b = 2;
    \\    const c = 3;
    \\}
    \\
;

/// Full accessible name of the node whose name starts with `prefix`,
/// copied into `out`. The editor's status line is found this way (by
/// its "Ln " prefix) because GTK4-on-Wayland reports every accessible
/// rect at 0,0, so there is nothing to locate it by position with.
fn nameStartingWith(allocator: std.mem.Allocator, prefix: []const u8, out: []u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, ",\"name\":\"{s}", .{prefix}) catch return null;
    const json = hub.?.treeJson(allocator) orelse return null;
    defer allocator.free(json);
    const at = std.mem.indexOf(u8, json, needle) orelse return null;
    const vstart = at + ",\"name\":\"".len;
    const vend = std.mem.indexOfScalarPos(u8, json, vstart, '"') orelse return null;
    const n = @min(vend - vstart, out.len);
    @memcpy(out[0..n], json[vstart..][0..n]);
    return out[0..n];
}

/// The editor status line's current text ("Ln 1, Col 1  —  …").
fn statusLineText(allocator: std.mem.Allocator, out: []u8) ?[]const u8 {
    return nameStartingWith(allocator, "Ln ", out);
}

/// Poll until the status line contains `want`. Pumping the viewer
/// between polls is what lets the GUI actually repaint.
fn awaitStatusContains(allocator: std.mem.Allocator, want: []const u8, budget_ms: u32) bool {
    var waited: u32 = 0;
    while (waited < budget_ms) : (waited += 250) {
        if (drive) |app| app.drain();
        var buf: [512]u8 = undefined;
        if (statusLineText(allocator, &buf)) |txt| {
            if (std.mem.indexOf(u8, txt, want) != null) return true;
        }
        _ = c.usleep(250_000);
    }
    return false;
}

/// True while `want` is ABSENT from the status line for the whole
/// budget — the expiry assertion.
fn awaitStatusLacks(allocator: std.mem.Allocator, want: []const u8, budget_ms: u32) bool {
    var waited: u32 = 0;
    while (waited < budget_ms) : (waited += 500) {
        if (drive) |app| app.drain();
        var buf: [512]u8 = undefined;
        if (statusLineText(allocator, &buf)) |txt| {
            if (std.mem.indexOf(u8, txt, want) == null) return true;
        }
        _ = c.usleep(500_000);
    }
    return false;
}

/// Is a menu row with this label open right now? (Zero budget: asked
/// only about a menu already on screen.)
fn menuHasRow(allocator: std.mem.Allocator, label: []const u8) bool {
    const n = findMenuRow(allocator, label, 1) orelse return false;
    allocator.free(n.id);
    return true;
}

/// Right-click a series of candidate points until one opens a menu
/// containing `marker`, dismissing every wrong menu on the way.
///
/// Probing rather than aiming: the a11y tree reports every rect at
/// 0,0 on Wayland, so the gutter's and the status line's positions can
/// only be found by hitting them (`locateTabStrip` documents the same
/// constraint for the tab strip). The marker row is what confirms the
/// hit, so a near-miss that opens the canvas menu is a retry, not a
/// pass.
fn probeMenuAt(allocator: std.mem.Allocator, points: []const Point, marker: []const u8) ?u32 {
    const app = drive orelse return null;
    for (points) |p| {
        dismissPopup(app);
        _ = waitTabPopup(app, false, 2_000);
        const id = rightClickAt(p.x, p.y, 6_000) orelse continue;
        if (menuHasRow(allocator, marker)) return id;
    }
    dismissPopup(app);
    _ = waitTabPopup(app, false, 2_000);
    return null;
}

fn editorChromeStage(allocator: std.mem.Allocator, rt: []const u8, sock_path: [:0]const u8) ?[]const u8 {
    const app = drive orelse return "the display session has no driver";
    var path_buf: [512]u8 = undefined;
    const efile = std.fmt.bufPrintZ(&path_buf, "{s}/chrome.zig", .{rt}) catch return "chrome path";
    {
        const f = c.fopen(efile.ptr, "wb") orelse return "creating the chrome document failed";
        _ = c.fwrite(CHROME_DOC.ptr, 1, CHROME_DOC.len, f);
        _ = c.fclose(f);
    }

    var req_buf: [700]u8 = undefined;
    var epane: u64 = 0;
    {
        const rq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"new-editor-tab\",\"data\":\"{s}\"}}\n", .{efile}) catch return "fmt";
        const rp = roundtrip(allocator, sock_path, rq) orelse return "new-editor-tab roundtrip";
        defer allocator.free(rp);
        if (std.mem.indexOf(u8, rp, "\"ok\":true") == null) return "new-editor-tab not ok";
        epane = parseNumAfter(rp, "\"pane\":") orelse return "new-editor-tab reply has no pane id";
    }
    {
        const rq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"focus\",\"pane\":{d}}}\n", .{epane}) catch return "fmt";
        const rp = roundtrip(allocator, sock_path, rq) orelse return "focus roundtrip";
        defer allocator.free(rp);
        if (std.mem.indexOf(u8, rp, "\"ok\":true") == null) return "focusing the chrome editor tab was refused";
    }
    var settle: u32 = 0;
    while (settle < 20) : (settle += 1) {
        app.drain();
        _ = c.usleep(100_000);
    }
    // The status line is the anchor for everything below; if it never
    // reaches the tree there is nothing to assert on.
    if (!awaitStatusContains(allocator, "Ln ", 20_000))
        return "the editor status line never appeared in the AT-SPI tree";
    say("editor chrome: status line readable over AT-SPI");

    _ = app.drainLive(2_000);
    if (app.windows.items.len == 0) return "the display session lost its window";
    const win = app.windows.items[0];
    const w: f64 = @floatFromInt(win.w);
    const h: f64 = @floatFromInt(win.h);
    // Client-side decorations: frame_w is the toplevel width the a11y
    // tree measures, the driver's window is that plus an even margin.
    const margin: f64 = @max(0.0, (w - frame_w) / 2);

    // ── the GUTTER menu ────────────────────────────────────────────
    var pts: [6]Point = undefined;
    for ([_]f64{ 4, 8, 12, 16, 22, 30 }, 0..) |dx, i| pts[i] = .{ .x = margin + dx, .y = h * 0.5 };
    const gutter_id = probeMenuAt(allocator, &pts, "Select This Line") orelse
        return "right-clicking the editor gutter never opened the line menu";
    _ = app.waitVisualSettle(gutter_id, 300, 5_000, 0.002, null);
    shotPopup(allocator, gutter_id, "/tmp/sketerm-atspi-editor-gutter-menu.png");

    // It must be the LINE menu and not the canvas menu that used to
    // answer here.
    if (menuHasRow(allocator, "Toggle Line Comment"))
        return "the gutter opened the CANVAS menu (Toggle Line Comment is present), not the line menu";
    if (menuHasRow(allocator, "Soft Wrap"))
        return "the gutter opened the status-line menu";
    for ([_][]const u8{ "Copy Line Number", "Go to Line\u{2026}", "Fold All", "Unfold All", "Next Change", "Previous Change" }) |label| {
        if (!menuHasRow(allocator, label)) {
            _ = c.fprintf(platform.stderr(), "smoke-atspi: gutter menu has no '%.*s' row\n", @as(c_int, @intCast(label.len)), label.ptr);
            return "the gutter menu is missing a row";
        }
    }
    // Sensitivity is the state at popup time, not a fixed table: the
    // isolated runtime dir is not a repository, so there are no change
    // hunks to step to, and nothing is folded yet.
    if (findMenuRow(allocator, "Next Change", 2_000)) |n| {
        defer allocator.free(n.id);
        if (n.states_lo & STATE_SENSITIVE_BIT != 0)
            return "Next Change is sensitive on a document with no VCS changes";
    } else return "the gutter menu lost its Next Change row";
    if (findMenuRow(allocator, "Unfold All", 2_000)) |n| {
        defer allocator.free(n.id);
        if (n.states_lo & STATE_SENSITIVE_BIT != 0)
            return "Unfold All is sensitive with nothing folded";
    } else return "the gutter menu lost its Unfold All row";
    say("editor chrome: the gutter opens its own line menu, rows sensitive per document state");

    // ── a gutter row that really acts, and its message STICKS ──────
    const copy = findMenuRow(allocator, "Copy Line Number", 5_000) orelse
        return "the gutter menu lost its Copy Line Number row";
    defer allocator.free(copy.id);
    if (!hub.?.doAction(allocator, copy.id, 0)) return "activating Copy Line Number over AT-SPI failed";
    _ = waitTabPopup(app, false, 5_000);
    var line_no: [16]u8 = undefined;
    var line_len: usize = 0;
    {
        var tries: u32 = 0;
        while (tries < 40) : (tries += 1) {
            app.drain();
            if (app.getClipboard(3_000)) |text| {
                defer allocator.free(text);
                const t = std.mem.trim(u8, text, " \n\r\t");
                if (t.len > 0 and t.len < line_no.len and std.ascii.isDigit(t[0])) {
                    @memcpy(line_no[0..t.len], t);
                    line_len = t.len;
                    break;
                }
            } else |_| {}
            _ = c.usleep(250_000);
        }
        if (line_len == 0) return "Copy Line Number put no line number on the clipboard";
    }
    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Copied line number {s}.", .{line_no[0..line_len]}) catch return "fmt";
    if (!awaitStatusContains(allocator, msg, 6_000))
        return "Copy Line Number's message never reached the status line";
    say("editor chrome: Copy Line Number copied the number and reported it");

    // THE defect this stage exists for: `updateStatus` rebuilds the
    // whole label on every caret move and every edit. Typing forces a
    // burst of exactly those rebuilds; a message that is written into
    // the label rather than POSTED is gone by the first one.
    if (typeInto(allocator, sock_path, epane, "abcdef")) |m| return m;
    {
        // Tight budget on purpose: the message is TRANSIENT (8s), so a
        // slow poll here would race its own expiry and report an
        // erasure that never happened.
        var tries: u32 = 0;
        var moved = false;
        while (tries < 16) : (tries += 1) {
            app.drain();
            var buf: [512]u8 = undefined;
            if (statusLineText(allocator, &buf)) |txt| {
                // The caret really moved (so rebuilds really happened)
                // AND the message is still there.
                if (std.mem.indexOf(u8, txt, "Col 7") != null or std.mem.indexOf(u8, txt, "Col 8") != null) {
                    if (std.mem.indexOf(u8, txt, msg) == null) {
                        _ = c.fprintf(platform.stderr(), "smoke-atspi: status line after typing: %.*s\n", @as(c_int, @intCast(txt.len)), txt.ptr);
                        return "the status message did not survive the rebuilds typing caused";
                    }
                    moved = true;
                    break;
                }
            }
            _ = c.usleep(250_000);
        }
        if (!moved) return "typing never moved the caret in the status line (rebuilds not proven)";
    }
    // The artefact a human reviews: the whole editor with the caret
    // six characters further on and the message still on the line.
    // Settle first — the a11y tree updates the instant the label does,
    // but the compositor mirror only has the LAST COMMITTED frame.
    _ = app.waitVisualSettle(win.id, 400, 4_000, 0.0, null);
    if (app.screenshotPng(win.id, 1400, null, 0)) |shot| {
        defer allocator.free(shot.png);
        if (c.fopen("/tmp/sketerm-atspi-editor-sticky-status.png", "wb")) |f| {
            _ = c.fwrite(shot.png.ptr, 1, shot.png.len, f);
            _ = c.fclose(f);
        }
    } else |_| {}
    say("editor chrome: the posted message survived the rebuilds six keystrokes caused");

    // …and it is TRANSIENT, not permanent: it expires on its own with
    // no further interaction (the expiry timer, not another rebuild).
    if (!awaitStatusLacks(allocator, msg, 20_000))
        return "the status message never expired (it is sticky, not transient)";
    say("editor chrome: the message expired on its own");

    // ── the CANVAS menu still answers over the text ────────────────
    // The other half of the gutter routing assertion: the same widget,
    // a different x, must still give the caret-oriented menu.
    var canvas_has_lsp = false;
    {
        var cpts: [1]Point = .{.{ .x = margin + w * 0.4, .y = h * 0.5 }};
        const id = probeMenuAt(allocator, &cpts, "Toggle Line Comment") orelse
            return "right-clicking the editor TEXT no longer opens the canvas menu";
        _ = id;
        if (menuHasRow(allocator, "Select This Line"))
            return "the canvas menu grew the gutter's Select This Line row";
        // Whether a server is attached to a loose .zig file depends on
        // what is installed on the host, so it is not asserted either
        // way — it is CARRIED, and the status menu must agree with it.
        canvas_has_lsp = menuHasRow(allocator, "Go to Definition");
        dismissPopup(app);
        _ = waitTabPopup(app, false, 3_000);
    }
    say("editor chrome: the text still opens the canvas menu, and only that one");

    // ── the STATUS-LINE menu ───────────────────────────────────────
    var spts: [6]Point = undefined;
    for ([_]f64{ 4, 8, 12, 18, 26, 34 }, 0..) |dy, i|
        spts[i] = .{ .x = margin + 40, .y = h - margin - dy };
    const status_id = probeMenuAt(allocator, &spts, "Soft Wrap") orelse
        return "right-clicking the editor status line never opened its menu";
    _ = app.waitVisualSettle(status_id, 300, 5_000, 0.002, null);
    shotPopup(allocator, status_id, "/tmp/sketerm-atspi-editor-status-menu.png");
    if (menuHasRow(allocator, "Toggle Line Comment"))
        return "the status line opened the canvas menu";
    if (menuHasRow(allocator, "Select This Line"))
        return "the status line opened the gutter menu";
    if (!menuHasRow(allocator, "Go to Line\u{2026}")) return "the status menu has no Go to Line row";
    // Diagnostics ride the status line only while a server is attached,
    // and the canvas menu's LSP rows follow the same predicate — so the
    // two menus must agree. Asserting the AGREEMENT rather than a fixed
    // answer keeps this honest on a host that has (or has not) a Zig
    // language server installed.
    if (menuHasRow(allocator, "Next Diagnostic") != canvas_has_lsp) {
        return if (canvas_has_lsp)
            "the canvas menu offers LSP rows but the status menu has no Next Diagnostic"
        else
            "the status menu offers Next Diagnostic with no language server attached";
    }
    say("editor chrome: the status line opens its own menu, its diagnostic rows track the attached server");

    // ── a status row that really acts: Soft Wrap ───────────────────
    const wrap = findMenuRow(allocator, "Soft Wrap", 5_000) orelse
        return "the status menu lost its Soft Wrap row";
    defer allocator.free(wrap.id);
    if (!hub.?.doAction(allocator, wrap.id, 0)) return "activating Soft Wrap over AT-SPI failed";
    _ = waitTabPopup(app, false, 5_000);
    if (!awaitStatusContains(allocator, "Wrap", 10_000))
        return "Soft Wrap did not turn wrapping on (the status line never said Wrap)";
    say("editor chrome: Soft Wrap really wrapped, and the status line says so");
    dismissPopup(app);

    // ── IME preedit stays OUT of the accessible text ───────────────
    //
    // The editor announces an uncommitted composition to a screen
    // reader as transient speech (`a11y/atspi.zig announcePreedit`, via
    // DocSource.setPreedit from EditorView.setPreedit). The design rule
    // that goes with it is asserted here: the accessible TEXT must stay
    // byte-for-byte the COMMITTED document, so no accessible offset
    // ever covers characters the user has not committed. Routing
    // preedit into the rope would break screen-reader navigation
    // silently — nothing on screen would look wrong.
    //
    // NOT asserted: the announcement itself. `gtk_accessible_announce`
    // emits an `object:announcement` D-Bus SIGNAL, and this smoke's bus
    // client (`mux/a11yhub.zig`) only makes method calls — it has no
    // signal subscription — so the speech channel is not observable
    // from here at all. Said plainly rather than covered weakly.
    {
        const node = findNamedNode(allocator, "chrome.zig", ROLE_TEXT_BOX, 15_000) orelse
            return "the chrome document's canvas node vanished from the AT-SPI tree";
        defer allocator.free(node.id);
        const before = hub.?.textState(allocator, node.id) orelse
            return "could not read the editor's accessible text before composing";
        defer allocator.free(before.text);

        // Ctrl+Shift+U starts a composition on ANY layout (no compose
        // key needed), which is why it is the chord used here rather
        // than a dead key — a dead key would need a second display
        // session with a non-US keymap, and this session's other stages
        // type US characters.
        app.pressKey(win.id, "ctrl+shift+u") catch return "injecting Ctrl+Shift+U failed";
        var tries: u32 = 0;
        while (tries < 12) : (tries += 1) {
            app.drain();
            _ = c.usleep(150_000);
            const during = hub.?.textState(allocator, node.id) orelse continue;
            defer allocator.free(during.text);
            if (!std.mem.eql(u8, during.text, before.text)) {
                _ = c.fprintf(platform.stderr(), "smoke-atspi: text during composition: %.*s\n", @as(c_int, @intCast(during.text.len)), during.text.ptr);
                return "the composing string leaked into the editor's accessible text";
            }
        }
        // Cancel the composition; the document must still be untouched.
        app.pressKey(win.id, "Escape") catch return "injecting Escape failed";
        var settled: u32 = 0;
        while (settled < 10) : (settled += 1) {
            app.drain();
            _ = c.usleep(150_000);
        }
        const after = hub.?.textState(allocator, node.id) orelse
            return "could not read the editor's accessible text after cancelling";
        defer allocator.free(after.text);
        if (!std.mem.eql(u8, after.text, before.text))
            return "cancelling the composition changed the editor's accessible text";
    }
    say("editor chrome: a composing string never enters the accessible text (announcement itself is not bus-observable)");

    // Leave nothing dirty behind: the GUI's SIGTERM must not meet an
    // unsaved-buffer prompt.
    {
        const rq = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"send-keys\",\"pane\":{d},\"data\":\"ctrl+s\"}}\n", .{epane}) catch return "fmt";
        const rp = roundtrip(allocator, sock_path, rq) orelse return "ctrl+s roundtrip";
        allocator.free(rp);
    }
    var saved: u32 = 0;
    while (saved < 40) : (saved += 1) {
        app.drain();
        _ = c.usleep(200_000);
    }
    return null;
}
