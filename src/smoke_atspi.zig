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
    drive = appdrive.App.attachExisting(allocator, DISPLAY_SESSION, null, mux_sock) catch {
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

    // ── 5-8. the editor canvas ───────────────────────────────────────
    if (editorStage(allocator, rt, sock_path)) |msg| {
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
