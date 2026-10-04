//! smoke-agents-gui: the sub-agent glance on the REAL GUI, on sketerm's
//! own Wayland compositor (CLAUDE.md "Headless GUI testing"; never X).
//!
//! Same rig shape as smoke-lsp-gui: a private broker daemon on a short
//! isolated socket, a display session, a viewer attached BEFORE the GUI
//! starts, then a plain `sketerm` window as a Wayland client of it. The
//! rig then plays an MCP server: it registers a record with the
//! registry's own writer (`mcp_registry.Lease`, held flock and all)
//! whose `session`/`session_socket` name the GUI pane's session, and
//! asserts on pixels and OCR that
//!
//!   1. the titlebar appears on its own with "2 agents working";
//!   2. after one agent turns `needs_input` the chip shows the amber
//!      "1 needs input" pill and the tab badge turns amber;
//!   3. clicking the chip opens the popover listing both agent ids;
//!   4. removing the record hides the chip, the badge and the titlebar.
//!
//! Screenshots of every state land in zig-out/smoke-agents-gui-*.png.
//! Everything created here is destroyed by exact pid / session name.

const std = @import("std");
const c = @import("c.zig").c;
const platform = @import("util/platform.zig");
const appdrive = @import("ipc/appdrive.zig");
const clock = @import("util/clock.zig");
const ocr = @import("util/ocr.zig");
const png_util = @import("util/png.zig");
const mcp_registry = @import("ipc/mcp_registry.zig");
const glance = @import("ipc/agentglance.zig");
const mux_client = @import("mux/client.zig");
const mux_cli = @import("ipc/mux_cli.zig");
const smokecli = @import("smoke/displaycli.zig");

const TTL = "180";
const SESSION = "agentsmoke";
/// The default `title_active_bg` (config.zig): the bar's own colour.
const BAR_RGB = [3]u8{ 200, 0, 3 };
const AMBER = glance.swatch(.needs_input).bg;
const RING = glance.glyphOnChip(.working);

var g_alloc: std.mem.Allocator = undefined;
var g_mux_sock: []const u8 = "";
var drive: ?*appdrive.App = null;
var child_pid: c.pid_t = 0;
var daemon_pid: c.pid_t = 0;
var display_ready = false;
var lease: ?mcp_registry.Lease = null;

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "smoke-agents-gui: " ++ fmt ++ "\n", args) catch return;
    _ = c.fprintf(platform.stdout(), "%s", s.ptr);
    _ = c.fflush(platform.stdout());
}

fn teardown() void {
    if (lease) |*l| {
        l.deinit();
        lease = null;
    }
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
    if (display_ready and g_mux_sock.len > 0) {
        const r = smokecli.runDisplayCli(g_alloc, &.{ "destroy", SESSION, "--socket", g_mux_sock });
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

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "smoke-agents-gui: FAIL - " ++ fmt ++ "\n", args) catch "FAIL\n";
    _ = c.fprintf(platform.stderr(), "%s", s.ptr);
    teardown();
    return 1;
}

fn writeFile(path: [*:0]const u8, bytes: []const u8) bool {
    const f = c.fopen(path, "wb") orelse return false;
    defer _ = c.fclose(f);
    return c.fwrite(bytes.ptr, 1, bytes.len, f) == bytes.len;
}

fn pumpFor(app: *appdrive.App, ms: i64) void {
    const t0 = clock.nowMs();
    while (clock.nowMs() - t0 < ms) _ = app.pumpOnce(20);
}

fn savePng(app: *appdrive.App, win_id: u32, path: [*:0]const u8) void {
    const png = app.screenshotPng(win_id, 1600, null, 0) catch return;
    defer g_alloc.free(png.png);
    _ = writeFile(path, png.png);
}

fn near(px: []const u8, i: usize, want: [3]u8, tol: i32) bool {
    inline for (0..3) |ch| {
        const d = @as(i32, px[i + ch]) - @as(i32, want[ch]);
        if (d > tol or d < -tol) return false;
    }
    return true;
}

/// Bounding box {x0, y0, x1, y1} and count of pixels near `want` inside
/// rows [y_lo, y_hi).
const Hits = struct { n: usize = 0, x0: u32 = std.math.maxInt(u32), y0: u32 = std.math.maxInt(u32), x1: u32 = 0, y1: u32 = 0 };

fn hits(shot: appdrive.App.RgbaShot, want: [3]u8, tol: i32, y_lo: u32, y_hi: u32) Hits {
    var h: Hits = .{};
    var y = y_lo;
    while (y < @min(y_hi, shot.h)) : (y += 1) {
        var x: u32 = 0;
        while (x < shot.w) : (x += 1) {
            const i = (@as(usize, y) * shot.w + x) * 4;
            if (!near(shot.px, i, want, tol)) continue;
            h.n += 1;
            h.x0 = @min(h.x0, x);
            h.y0 = @min(h.y0, y);
            h.x1 = @max(h.x1, x);
            h.y1 = @max(h.y1, y);
        }
    }
    return h;
}

/// The pane titlebar's rows: where the bar colour fills most of a row.
fn barRows(shot: appdrive.App.RgbaShot) ?[2]u32 {
    var lo: ?u32 = null;
    var hi: u32 = 0;
    var y: u32 = 0;
    while (y < shot.h) : (y += 1) {
        var n: u32 = 0;
        var x: u32 = 0;
        while (x < shot.w) : (x += 1) {
            if (near(shot.px, (@as(usize, y) * shot.w + x) * 4, BAR_RGB, 6)) n += 1;
        }
        if (n * 3 > shot.w) {
            if (lo == null) lo = y;
            hi = y + 1;
        }
    }
    return if (lo) |l| .{ l, hi } else null;
}

/// OCR of a region, native scale first, then upscaled (small UI fonts).
fn ocrText(app: *appdrive.App, win_id: u32, region: ?appdrive.App.Region) ?[]u8 {
    const shot = app.snapshotRgba(win_id, region) catch return null;
    defer g_alloc.free(shot.px);
    var best: ?[]u8 = null;
    for ([_]u32{ 1, 3 }) |up| {
        const px = if (up == 1) shot.px else png_util.upscaleRgba(g_alloc, shot.px, shot.w, shot.h, up) catch continue;
        defer if (up != 1) g_alloc.free(px);
        var res = ocr.recognize(g_alloc, px, shot.w * up, shot.h * up, .{ .psm = 11 }) catch continue;
        defer res.deinit(g_alloc);
        const joined = std.mem.concat(g_alloc, u8, &.{ best orelse "", "\n", res.text }) catch continue;
        if (best) |b| g_alloc.free(b);
        best = joined;
    }
    return best;
}

/// Case- and whitespace-insensitive: OCR of an 11px label routinely
/// drops the space between a number and its word ("2agents").
fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    var hb: [4096]u8 = undefined;
    var nb: [128]u8 = undefined;
    return std.ascii.indexOfIgnoreCase(squeeze(&hb, hay), squeeze(&nb, needle)) != null;
}

fn squeeze(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |ch| {
        if (std.ascii.isWhitespace(ch)) continue;
        if (n == buf.len) break;
        buf[n] = ch;
        n += 1;
    }
    return buf[0..n];
}

/// The GUI pane's session: the one live terminal session on the daemon.
fn paneSession(allocator: std.mem.Allocator, sock: []const u8, out: []u8) ?[]const u8 {
    var conn = mux_client.Conn.connectProbed(allocator, sock) catch return null;
    defer conn.deinit();
    conn.setNonBlocking();
    conn.sendFrame(.list, "") catch return null;
    const f = conn.recvExpectFor(&.{.welcome}, 5000) catch return null;
    defer f.deinit(allocator);
    const parsed = std.json.parseFromSlice(mux_cli.Welcome, allocator, f.payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    defer parsed.deinit();
    for (parsed.value.sessions) |s| {
        if (s.app or s.exited) continue;
        if (s.name.len > out.len) return null;
        @memcpy(out[0..s.name.len], s.name);
        return out[0..s.name.len];
    }
    return null;
}

fn publish(second_attention: []const u8, second_state: []const u8) !void {
    const agents = [_]mcp_registry.Agent{
        .{ .id = "claude-kilo", .app = "claude", .sessions = &.{"agent-claude-kilo"}, .location = "user", .attention = "working", .state = "working" },
        .{ .id = "claude-mike", .app = "claude", .sessions = &.{"agent-claude-mike"}, .location = "user", .attention = second_attention, .state = second_state },
    };
    try lease.?.publishAgents(&agents);
}

/// Wait until `pred` holds for a fresh snapshot (or the budget runs out).
fn waitShot(app: *appdrive.App, win_id: u32, budget_ms: i64, ctx: anytype, comptime pred: fn (@TypeOf(ctx), appdrive.App.RgbaShot) bool) bool {
    const t0 = clock.nowMs();
    while (clock.nowMs() - t0 < budget_ms) {
        pumpFor(app, 200);
        const shot = app.snapshotRgba(win_id, null) catch continue;
        defer g_alloc.free(shot.px);
        if (pred(ctx, shot)) return true;
    }
    return false;
}

const Want = struct {
    bar: bool,
    amber_chip: bool = false,
    amber_tab: bool = false,
    ring: bool = false,
};

fn stateHolds(want: Want, shot: appdrive.App.RgbaShot) bool {
    const rows = barRows(shot);
    if ((rows != null) != want.bar) return false;
    const top: u32 = if (rows) |r| r[0] else shot.h / 6;
    // The tab strip is above the pane titlebar (or, with no bar, the
    // top sixth of the window).
    const tab_amber = hits(shot, AMBER, 6, 0, top).n > 20;
    if (tab_amber != want.amber_tab) return false;
    if (rows) |r| {
        const chip_amber = hits(shot, AMBER, 6, r[0], r[1]).n > 20;
        if (chip_amber != want.amber_chip) return false;
        if (want.ring and hits(shot, RING, 30, r[0], r[1]).n < 4) return false;
    }
    return true;
}

pub fn main() u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    g_alloc = allocator;

    if (platform.is_macos) {
        say("skipped (no Wayland display sessions on macOS)", .{});
        return 0;
    }
    if (!@import("util/lifetime.zig").arm()) return fail("lifetime fence", .{});

    // Short isolated runtime dir: a long socket path cannot bind and the
    // GUI would autostart the INSTALLED daemon (CLAUDE.md).
    var rt_buf: [128]u8 = undefined;
    const rt = std.fmt.bufPrintZ(&rt_buf, "/tmp/ska-{d}", .{c.getpid()}) catch return fail("runtime path", .{});
    _ = c.mkdir(rt.ptr, 0o700);
    _ = c.setenv("XDG_RUNTIME_DIR", rt.ptr, 1);
    _ = c.setenv("XDG_CONFIG_HOME", rt.ptr, 1);
    _ = c.setenv("XDG_STATE_HOME", rt.ptr, 1);
    for ([_][*:0]const u8{ "SKETERM_SOCKET", "SKETERM_MUX_SOCKET", "SKETERM_SESSION", "SKETERM_PANE_ID", "SKETERM_SESSION_ORIGIN_ID" }) |name| _ = c.unsetenv(name);
    defer @import("util/pathz.zig").removeTree(rt);
    // Isolated XDG_CONFIG_HOME races pango/fontconfig unless warmed.
    _ = c.system("fc-cache >/dev/null 2>&1");

    // ── private daemon ────────────────────────────────────────────
    const mux_pid = c.fork();
    if (mux_pid < 0) return fail("mux fork", .{});
    if (mux_pid == 0) {
        platform.dieWithParent();
        const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm-mux", "--broker", null };
        _ = c.execv("zig-out/bin/sketerm-mux", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    daemon_pid = mux_pid;
    var sock_buf: [256]u8 = undefined;
    const mux_sock = std.fmt.bufPrintZ(&sock_buf, "{s}/sketerm/mux.sock", .{rt}) catch return fail("sock path", .{});
    var waited: u32 = 0;
    while (c.access(mux_sock.ptr, c.F_OK) != 0) {
        _ = c.usleep(50_000);
        waited += 1;
        if (waited > 100) return fail("private mux socket never appeared", .{});
    }
    g_mux_sock = mux_sock;

    // ── display session + viewer (BEFORE the GUI) ─────────────────
    var wl_z: [4096:0]u8 = undefined;
    {
        const r = smokecli.runDisplayCli(allocator, &.{ "create", "--name", SESSION, "--ttl", TTL, "--size", "1100x700", "--json", "--socket", mux_sock });
        defer allocator.free(r.out);
        if (r.code != 0) return fail("display create failed", .{});
        display_ready = true;
        var parsed = std.json.parseFromSlice(smokecli.CreateReply, allocator, r.out, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
            return fail("display create JSON", .{});
        defer parsed.deinit();
        const wl = parsed.value.environment.WAYLAND_DISPLAY;
        if (wl.len == 0 or wl[0] != '/') return fail("no absolute WAYLAND_DISPLAY", .{});
        _ = std.fmt.bufPrintZ(&wl_z, "{s}", .{wl}) catch return fail("WAYLAND_DISPLAY too long", .{});
    }
    drive = appdrive.App.attachExisting(allocator, SESSION, null, mux_sock, null) catch
        return fail("could not attach a viewer", .{});
    const app = drive.?;

    // ── the GUI: one terminal pane, titlebar hidden by default ────
    const pid = c.fork();
    if (pid < 0) return fail("fork", .{});
    if (pid == 0) {
        platform.dieWithParent();
        _ = c.setenv("SKETERM_APP_ID", "dev.sker.sketerm.agentsmoke", 1);
        _ = c.setenv("WAYLAND_DISPLAY", &wl_z, 1);
        _ = c.setenv("GDK_BACKEND", "wayland", 1);
        _ = c.unsetenv("DISPLAY");
        _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
        _ = c.setenv("GTK_A11Y", "none", 1);
        _ = c.setenv("SKETERM_WELCOME", "0", 1);
        const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm", null };
        _ = c.execv("zig-out/bin/sketerm", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    child_pid = pid;
    if (!app.waitFirstWindow(60_000)) return fail("the GUI never committed a window", .{});
    const win_id: u32 = blk: {
        for (app.windows.items) |w| if (!w.popup and w.w > 0) break :blk w.id;
        break :blk 0;
    };
    if (win_id == 0) return fail("no toplevel window", .{});

    var name_buf: [256]u8 = undefined;
    const session = blk: {
        const t0 = clock.nowMs();
        while (clock.nowMs() - t0 < 20_000) {
            pumpFor(app, 250);
            if (paneSession(allocator, mux_sock, &name_buf)) |s| break :blk s;
        }
        return fail("the GUI pane's session never appeared on the daemon", .{});
    };
    say("GUI up, pane session '{s}'", .{session});
    pumpFor(app, 1500);
    {
        const shot = app.snapshotRgba(win_id, null) catch return fail("no pixels", .{});
        defer allocator.free(shot.px);
        if (barRows(shot) != null) return fail("the titlebar shows before any agent exists", .{});
    }
    savePng(app, win_id, "zig-out/smoke-agents-gui-0-none.png");

    // ── 1. two agents working: the titlebar appears with the chip ─
    var inst_buf: [256]u8 = undefined;
    const inst_sock = std.fmt.bufPrint(&inst_buf, "{s}/sketerm/mcp-agentsmoke/mux.sock", .{rt}) catch return fail("instance path", .{});
    lease = mcp_registry.Lease.acquire(allocator, .{
        .mode = .isolated,
        .name = "agentsmoke",
        .mux_socket = inst_sock,
        .session = session,
        .session_socket = mux_sock,
    }) catch |err| return fail("registry lease: {s}", .{@errorName(err)});
    publish("working", "working") catch return fail("publish", .{});
    if (!waitShot(app, win_id, 15_000, Want{ .bar = true, .ring = true }, stateHolds)) {
        savePng(app, win_id, "zig-out/smoke-agents-gui-1-FAIL.png");
        return fail("no titlebar with a working chip (zig-out/smoke-agents-gui-1-FAIL.png)", .{});
    }
    pumpFor(app, 400);
    savePng(app, win_id, "zig-out/smoke-agents-gui-1-working.png");
    const rows1 = blk: {
        const shot = app.snapshotRgba(win_id, null) catch return fail("no pixels", .{});
        defer allocator.free(shot.px);
        break :blk barRows(shot).?;
    };
    {
        const text = ocrText(app, win_id, .{ .x = 0, .y = rows1[0], .w = @intCast(app.winById(win_id).?.w), .h = rows1[1] - rows1[0] }) orelse
            return fail("OCR of the titlebar failed", .{});
        defer allocator.free(text);
        if (!containsIgnoreCase(text, "2 agents working")) {
            say("titlebar OCR: {s}", .{text});
            return fail("the chip does not read '2 agents working'", .{});
        }
    }
    say("PASS 1: titlebar appeared with '2 agents working' -> zig-out/smoke-agents-gui-1-working.png", .{});

    // ── 2. one needs input: amber pill on the chip and the tab ────
    publish("needs_input", "waiting_user") catch return fail("publish", .{});
    if (!waitShot(app, win_id, 15_000, Want{ .bar = true, .ring = true, .amber_chip = true, .amber_tab = true }, stateHolds)) {
        savePng(app, win_id, "zig-out/smoke-agents-gui-2-FAIL.png");
        return fail("no amber chip pill + tab badge (zig-out/smoke-agents-gui-2-FAIL.png)", .{});
    }
    pumpFor(app, 400);
    savePng(app, win_id, "zig-out/smoke-agents-gui-2-needs-input.png");
    const chip_box = blk: {
        const shot = app.snapshotRgba(win_id, null) catch return fail("no pixels", .{});
        defer allocator.free(shot.px);
        const r = barRows(shot).?;
        const amber = hits(shot, AMBER, 6, r[0], r[1]);
        {
            const text = ocrText(app, win_id, .{ .x = 0, .y = r[0], .w = shot.w, .h = r[1] - r[0] }) orelse
                return fail("OCR of the titlebar failed", .{});
            defer allocator.free(text);
            if (!containsIgnoreCase(text, "needs input") or !containsIgnoreCase(text, "2 agents")) {
                say("titlebar OCR: {s}", .{text});
                return fail("the chip does not read '2 agents' + '1 needs input'", .{});
            }
        }
        break :blk amber;
    };
    say("PASS 2: amber '1 needs input' pill and amber tab badge -> zig-out/smoke-agents-gui-2-needs-input.png", .{});

    // ── 3. click the chip: the popover lists both agents ──────────
    const popups_before = popupCount(app);
    // Left of the amber pill is the chip's own label.
    const cx: f64 = @floatFromInt(if (chip_box.x0 > 30) chip_box.x0 - 30 else chip_box.x0);
    const cy: f64 = @floatFromInt((chip_box.y0 + chip_box.y1) / 2);
    app.click(win_id, cx, cy, 1) catch return fail("click", .{});
    var popup: ?u32 = null;
    {
        const t0 = clock.nowMs();
        while (clock.nowMs() - t0 < 8_000 and popup == null) {
            pumpFor(app, 200);
            if (popupCount(app) > popups_before) popup = newestPopup(app);
        }
    }
    const pop_id = popup orelse return fail("clicking the chip opened no popover", .{});
    pumpFor(app, 600);
    savePng(app, pop_id, "zig-out/smoke-agents-gui-3-popover.png");
    {
        const text = ocrText(app, pop_id, null) orelse return fail("OCR of the popover failed", .{});
        defer allocator.free(text);
        if (!containsIgnoreCase(text, "claude-kilo") or !containsIgnoreCase(text, "claude-mike")) {
            say("popover OCR: {s}", .{text});
            return fail("the popover does not list both agents", .{});
        }
    }
    say("PASS 3: the chip's popover lists claude-kilo and claude-mike -> zig-out/smoke-agents-gui-3-popover.png", .{});
    app.pressKey(win_id, "Escape") catch {};
    pumpFor(app, 500);

    // ── 4. the record goes: chip, badge and titlebar go too ───────
    if (lease) |*l| l.deinit();
    lease = null;
    if (!waitShot(app, win_id, 15_000, Want{ .bar = false }, stateHolds)) {
        savePng(app, win_id, "zig-out/smoke-agents-gui-4-FAIL.png");
        return fail("titlebar or badge still shown after the record left (zig-out/smoke-agents-gui-4-FAIL.png)", .{});
    }
    pumpFor(app, 400);
    savePng(app, win_id, "zig-out/smoke-agents-gui-4-gone.png");
    say("PASS 4: record removed, chip + badge + titlebar hidden -> zig-out/smoke-agents-gui-4-gone.png", .{});

    teardown();
    say("all stages passed", .{});
    return 0;
}

fn popupCount(app: *appdrive.App) usize {
    var n: usize = 0;
    for (app.windows.items) |w| {
        if (w.popup and w.w > 0 and w.h > 0 and w.frames > 0) n += 1;
    }
    return n;
}

fn newestPopup(app: *appdrive.App) ?u32 {
    var best: ?u32 = null;
    var best_ms: i64 = -1;
    for (app.windows.items) |w| {
        if (!w.popup or w.w <= 0 or w.frames == 0) continue;
        if (w.last_commit_ms > best_ms) {
            best_ms = w.last_commit_ms;
            best = w.id;
        }
    }
    return best;
}
