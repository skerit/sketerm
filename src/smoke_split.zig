//! smoke-split: a pane split keeps its proportions on the REAL GUI, on
//! sketerm's own compositor at a fractional scale (CLAUDE.md "Headless
//! GUI testing"; never X).
//!
//! The viewer announces scale 1.3 before the GUI starts: that is where
//! the divider used to creep (every rescale was snapped down to the
//! 10-px device grid and remembered). The rig splits a terminal pane,
//! runs the window through an interactive-style shrink and grow, drags
//! the divider and resizes again, then turns both halves into file
//! views and squeezes the window below their minimum widths and back.
//! After each step the `split-geometry` verification command must show
//! the divider where the split's fraction puts it.
//!
//! Screenshots land in zig-out/smoke-split-*.png. Everything created
//! here is destroyed by exact pid / session name.

const std = @import("std");
const bindir = @import("smoke/bindir.zig");
const c = @import("c.zig").c;
const unsetEnv = @import("util/env.zig").unset;
const platform = @import("util/platform.zig");
const appdrive = @import("ipc/appdrive.zig");
const clock = @import("util/clock.zig");
const smokecli = @import("smoke/displaycli.zig");
const ctlsock = @import("smoke/ctlsock.zig");

const TTL = "180";
const SESSION = "splitsmoke";
/// Scale x120 the viewer announces: 1.3, whose device grid is 10 px.
const SCALE120 = 156;
/// How far the divider may sit from where the fraction puts it: half the
/// 10-px grid plus a pixel of rounding.
const TOLERANCE = 6;

var g_alloc: std.mem.Allocator = undefined;
var g_mux_sock: []const u8 = "";
var drive: ?*appdrive.App = null;
var child_pid: c.pid_t = 0;
var daemon_pid: c.pid_t = 0;
var display_ready = false;

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&buf, "smoke-split: " ++ fmt ++ "\n", args, 0) catch return;
    _ = c.fprintf(platform.stdout(), "%s", s.ptr);
    _ = c.fflush(platform.stdout());
}

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
    const s = std.fmt.bufPrintSentinel(&buf, "smoke-split: FAIL - " ++ fmt ++ "\n", args, 0) catch "FAIL\n";
    _ = c.fprintf(platform.stderr(), "%s", s.ptr);
    teardown();
    return 1;
}

fn pumpFor(app: *appdrive.App, ms: i64) void {
    const t0 = clock.nowMs();
    while (clock.nowMs() - t0 < ms) _ = app.pumpOnce(20);
}

fn savePng(app: *appdrive.App, win_id: u32, stem: []const u8) void {
    const png = app.screenshotPng(win_id, 1600, null, 0) catch return;
    defer g_alloc.free(png.png);
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "zig-out/smoke-split-{s}.png", .{stem}, 0) catch return;
    const f = c.fopen(path.ptr, "wb") orelse return;
    defer _ = c.fclose(f);
    _ = c.fwrite(png.png.ptr, 1, png.png.len, f);
}

const Split = struct {
    vertical: bool,
    ratio: f32,
    position: i32,
    start: i32,
    end: i32,
    handle_x: f64,
    handle_y: f64,
};
const GeometryReply = struct { ok: bool = false, splits: []Split = &.{} };

/// The first split of `pane`'s tab, or null when the GUI did not say.
fn geometry(app: *appdrive.App, gui_sock: [:0]const u8, pane: u32) ?Split {
    var req_buf: [96]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"split-geometry\",\"pane\":{d}}}\n", .{pane}) catch return null;
    const reply = ctlsock.roundtrip(g_alloc, app, gui_sock, req) orelse return null;
    defer g_alloc.free(reply);
    const parsed = std.json.parseFromSlice(GeometryReply, g_alloc, reply, .{ .ignore_unknown_fields = true }) catch {
        say("split-geometry reply: {s}", .{reply});
        return null;
    };
    defer parsed.deinit();
    if (!parsed.value.ok or parsed.value.splits.len == 0) {
        say("split-geometry reply: {s}", .{reply});
        return null;
    }
    return parsed.value.splits[0];
}

/// Null when the divider sits where `want` (a fraction of the content
/// space) puts it; otherwise why not.
fn checkSplit(app: *appdrive.App, gui_sock: [:0]const u8, pane: u32, want: f32, label: []const u8) ?[]const u8 {
    const g = geometry(app, gui_sock, pane) orelse return "no split geometry";
    const avail = g.start + g.end;
    const expect: i32 = @intFromFloat(@round(want * @as(f32, @floatFromInt(avail))));
    say("{s}: start {d} | end {d} (position {d}, fraction {d:.4}; want start {d})", .{ label, g.start, g.end, g.position, g.ratio, expect });
    if (@abs(g.ratio - want) > 0.002) return "the split's fraction moved";
    if (@abs(g.start - expect) > TOLERANCE) return "the divider is off the split's fraction";
    return null;
}

/// An interactive-style resize: `step`-px configures down to `low` and back
/// to `high`, letting the GUI lay out each one.
fn resizeRun(app: *appdrive.App, win_id: u32, high: i32, low: i32, h: i32, step: i32) !void {
    var w = high;
    while (w > low) {
        w = @max(low, w - step);
        try app.resizeWindow(win_id, w, h);
        pumpFor(app, 30);
    }
    while (w < high) {
        w = @min(high, w + step);
        try app.resizeWindow(win_id, w, h);
        pumpFor(app, 30);
    }
    pumpFor(app, 800);
}

fn parseNumAfter(s: []const u8, key: []const u8) ?u32 {
    const at = std.mem.indexOf(u8, s, key) orelse return null;
    var i = at + key.len;
    while (i < s.len and s[i] == ' ') i += 1;
    var end = i;
    while (end < s.len and s[end] >= '0' and s[end] <= '9') end += 1;
    return std.fmt.parseInt(u32, s[i..end], 10) catch null;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    if (!bindir.init(init.args.vector)) return 1;
    g_alloc = allocator;

    if (platform.is_macos) {
        say("skipped (no Wayland display sessions on macOS)", .{});
        return 0;
    }
    if (!@import("util/lifetime.zig").arm()) return fail("lifetime fence", .{});

    // Short isolated runtime dir: a long socket path cannot bind and the
    // GUI would autostart the INSTALLED daemon (CLAUDE.md).
    var rt_buf: [128]u8 = undefined;
    const rt = std.fmt.bufPrintSentinel(&rt_buf, "/tmp/sks-{d}", .{c.getpid()}, 0) catch return fail("runtime path", .{});
    _ = c.mkdir(rt.ptr, 0o700);
    _ = c.setenv("XDG_RUNTIME_DIR", rt.ptr, 1);
    _ = c.setenv("XDG_CONFIG_HOME", rt.ptr, 1);
    _ = c.setenv("XDG_STATE_HOME", rt.ptr, 1);
    for ([_][*:0]const u8{ "SKETERM_SOCKET", "SKETERM_MUX_SOCKET", "SKETERM_SESSION", "SKETERM_PANE_ID", "SKETERM_SESSION_ORIGIN_ID" }) |name| _ = unsetEnv(name);
    defer @import("util/pathz.zig").removeTree(rt);
    // Isolated XDG_CONFIG_HOME races pango/fontconfig unless warmed.
    _ = c.system("fc-cache >/dev/null 2>&1");

    // ── private daemon ────────────────────────────────────────────
    const mux_pid = c.fork();
    if (mux_pid < 0) return fail("mux fork", .{});
    if (mux_pid == 0) {
        platform.dieWithParent();
        const argv = [_:null]?[*:0]const u8{ bindir.path(.@"sketerm-mux"), "--broker", null };
        _ = c.execv(bindir.path(.@"sketerm-mux"), @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    daemon_pid = mux_pid;
    var sock_buf: [256]u8 = undefined;
    const mux_sock = std.fmt.bufPrintSentinel(&sock_buf, "{s}/sketerm/mux.sock", .{rt}, 0) catch return fail("sock path", .{});
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
        const r = smokecli.runDisplayCli(allocator, &.{ "create", "--name", SESSION, "--ttl", TTL, "--size", "1600x1000", "--json", "--socket", mux_sock });
        defer allocator.free(r.out);
        if (r.code != 0) return fail("display create failed", .{});
        display_ready = true;
        var parsed = std.json.parseFromSlice(smokecli.CreateReply, allocator, r.out, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
            return fail("display create JSON", .{});
        defer parsed.deinit();
        const wl = parsed.value.environment.WAYLAND_DISPLAY;
        if (wl.len == 0 or wl[0] != '/') return fail("no absolute WAYLAND_DISPLAY", .{});
        _ = std.fmt.bufPrintSentinel(&wl_z, "{s}", .{wl}, 0) catch return fail("WAYLAND_DISPLAY too long", .{});
    }
    drive = appdrive.App.attachExisting(allocator, SESSION, null, mux_sock, null) catch
        return fail("could not attach a viewer", .{});
    const app = drive.?;

    // ── the GUI ───────────────────────────────────────────────────
    const pid = c.fork();
    if (pid < 0) return fail("fork", .{});
    if (pid == 0) {
        platform.dieWithParent();
        _ = c.setenv("SKETERM_APP_ID", "dev.sker.sketerm.splitsmoke", 1);
        _ = c.setenv("WAYLAND_DISPLAY", &wl_z, 1);
        _ = c.setenv("GDK_BACKEND", "wayland", 1);
        _ = unsetEnv("DISPLAY");
        _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
        _ = c.setenv("GTK_A11Y", "none", 1);
        _ = c.setenv("SKETERM_WELCOME", "0", 1);
        _ = c.setenv("SKETERM_VERIFY_TREE", "1", 1);
        const argv = [_:null]?[*:0]const u8{ bindir.path(.sketerm), null };
        _ = c.execv(bindir.path(.sketerm), @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    child_pid = pid;
    if (!app.waitFirstWindow(60_000)) return fail("the GUI never committed a window", .{});
    // Only a connected client's channel hears the scale, so announce it
    // once the GUI is up.
    app.setViewerScale120(SCALE120) catch return fail("announcing scale 1.3", .{});
    const win_id: u32 = blk: {
        for (app.windows.items) |w| if (!w.popup and w.w > 0) break :blk w.id;
        break :blk 0;
    };
    if (win_id == 0) return fail("no toplevel window", .{});
    var gui_buf: [256]u8 = undefined;
    const gui_sock = std.fmt.bufPrintSentinel(&gui_buf, "{s}/sketerm/{d}.sock", .{ rt, child_pid }, 0) catch return fail("GUI socket path", .{});
    {
        const t0 = clock.nowMs();
        while (true) {
            pumpFor(app, 200);
            if (ctlsock.roundtrip(allocator, app, gui_sock, "{\"cmd\":\"list\"}\n")) |r| {
                defer allocator.free(r);
                if (std.mem.indexOf(u8, r, "\"ok\":true") != null) break;
            }
            if (clock.nowMs() - t0 > 30_000) return fail("the GUI control socket never answered", .{});
        }
    }
    const W: i32 = 1400;
    const H: i32 = 800;
    app.resizeWindow(win_id, W, H) catch return fail("sizing the window", .{});
    {
        // Wait for the GUI to re-render for the 1.3 pixel grid.
        const t0 = clock.nowMs();
        while (app.winById(win_id).?.w < W * 5 / 4) {
            pumpFor(app, 100);
            if (clock.nowMs() - t0 > 15_000) return fail("the GUI never rendered at scale 1.3 (buffer {d} px wide)", .{app.winById(win_id).?.w});
        }
    }
    pumpFor(app, 1500);
    {
        const win = app.winById(win_id).?;
        say("GUI up: window buffer {d}x{d}, buffer scale {d}", .{ win.w, win.h, win.scale });
    }

    // ── 1. split a terminal pane: an even split ───────────────────
    const second: u32 = blk: {
        const r = ctlsock.roundtrip(allocator, app, gui_sock, "{\"cmd\":\"split\",\"pane\":1,\"direction\":\"h\"}\n") orelse
            return fail("split roundtrip", .{});
        defer allocator.free(r);
        break :blk parseNumAfter(r, "\"pane\":") orelse return fail("split reply has no pane: {s}", .{r});
    };
    pumpFor(app, 1500);
    savePng(app, win_id, "1-split");
    if (checkSplit(app, gui_sock, 1, 0.5, "after split")) |why| return fail("{s} (zig-out/smoke-split-1-split.png)", .{why});

    // ── 2. interactive-style resizes keep it even ─────────────────
    for ([_]i32{ 7, 3, 13 }) |step| {
        resizeRun(app, win_id, W, 800, H, step) catch return fail("resizing the window", .{});
        var label_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "after a {d}-px resize run", .{step}) catch "after a resize run";
        if (checkSplit(app, gui_sock, 1, 0.5, label)) |why| {
            savePng(app, win_id, "2-FAIL");
            return fail("{s} (zig-out/smoke-split-2-FAIL.png)", .{why});
        }
    }
    savePng(app, win_id, "2-resized");

    // ── 3. a drag becomes the new fraction and survives resizes ───
    {
        const g = geometry(app, gui_sock, 1) orelse return fail("no split geometry before the drag", .{});
        app.drag(win_id, g.handle_x, g.handle_y, g.handle_x - 300, g.handle_y, 1) catch return fail("dragging the divider", .{});
        pumpFor(app, 1000);
        const after = geometry(app, gui_sock, 1) orelse return fail("no split geometry after the drag", .{});
        say("drag from ({d:.0},{d:.0}): start {d} -> {d}, fraction {d:.4}", .{ g.handle_x, g.handle_y, g.start, after.start, after.ratio });
        if (after.start > g.start - 200) {
            savePng(app, win_id, "3-FAIL");
            return fail("the drag did not move the divider (zig-out/smoke-split-3-FAIL.png)", .{});
        }
        const dragged = after.ratio;
        resizeRun(app, win_id, W, 900, H, 7) catch return fail("resizing the window", .{});
        if (checkSplit(app, gui_sock, 1, dragged, "dragged split after a resize run")) |why| {
            savePng(app, win_id, "3-FAIL");
            return fail("{s} (zig-out/smoke-split-3-FAIL.png)", .{why});
        }
        // Back to even for the file-view stage.
        const now = geometry(app, gui_sock, 1).?;
        const shift: f64 = @floatFromInt(@divFloor(now.end - now.start, 2));
        app.drag(win_id, now.handle_x, now.handle_y, now.handle_x + shift, now.handle_y, 1) catch return fail("dragging the divider back", .{});
        pumpFor(app, 1000);
    }
    savePng(app, win_id, "3-dragged");
    const even = (geometry(app, gui_sock, 1) orelse return fail("no split geometry", .{})).ratio;

    // ── 4. two file views squeezed below their minimums and back ──
    for ([_]u32{ 1, second }) |pane| {
        var req_buf: [96]u8 = undefined;
        const req = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"browser-here\",\"pane\":{d}}}\n", .{pane}) catch return fail("browser-here format", .{});
        const r = ctlsock.roundtrip(allocator, app, gui_sock, req) orelse return fail("browser-here roundtrip", .{});
        defer allocator.free(r);
        if (std.mem.indexOf(u8, r, "\"ok\":true") == null) return fail("browser-here refused: {s}", .{r});
    }
    pumpFor(app, 2500);
    savePng(app, win_id, "4-files");
    if (checkSplit(app, gui_sock, 1, even, "two file views")) |why| return fail("{s} (zig-out/smoke-split-4-files.png)", .{why});
    app.resizeWindow(win_id, 500, H) catch return fail("squeezing the window", .{});
    pumpFor(app, 1500);
    savePng(app, win_id, "4-squeezed");
    if (geometry(app, gui_sock, 1)) |g| say("squeezed to 500: start {d} | end {d} (fraction {d:.4})", .{ g.start, g.end, g.ratio });
    app.resizeWindow(win_id, W, H) catch return fail("restoring the window", .{});
    pumpFor(app, 1500);
    savePng(app, win_id, "4-restored");
    if (checkSplit(app, gui_sock, 1, even, "file views restored")) |why| return fail("{s} (zig-out/smoke-split-4-restored.png)", .{why});

    say("PASS: splits hold their fraction through resizes, a drag and a squeeze at scale 1.3", .{});
    teardown();
    return 0;
}
