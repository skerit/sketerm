//! smoke-usage: the disk-usage analyzer keeps its rows, selection,
//! keyboard focus and scroll offset while the scan streams in and while
//! the browser re-renders the tab under it, on the REAL GUI and
//! sketerm's own compositor (CLAUDE.md "Headless GUI testing"; never X).
//!
//! The rig analyzes a synthetic folder, then clicks result rows and
//! makes the folder's own listing change (new files in the watched
//! directory, which re-render the browser tab): no row may be rebuilt,
//! and the selection, focus, scroll offset and the clicked row's place
//! on screen must hold. Drilling into a folder must leave keyboard
//! focus in the list, and Alt+Up must come back to the folder it left,
//! selected and focused. Every step is read back through the
//! `browser-usage` verification command.
//!
//! Screenshots land in zig-out/smoke-usage-*.png. Everything created
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
const SESSION = "usagesmoke";
/// `dir-NN` folders and `file-NN.bin` files with distinct sizes that
/// interleave, so the size order is fixed and both kinds share screens.
const DIRS = 60;
const FILES = 30;
/// Empty files under `bulk/`, so the scan reports progress for a while.
const BULK = 20_000;
const BLOCK = 16 * 1024;

var g_alloc: std.mem.Allocator = undefined;
var g_mux_sock: []const u8 = "";
var g_gui_sock: [:0]const u8 = "";
var g_win: u32 = 0;
var g_files_dir: []const u8 = "";
var drive: ?*appdrive.App = null;
var child_pid: c.pid_t = 0;
var daemon_pid: c.pid_t = 0;
var display_ready = false;
var touch_serial: u32 = 0;

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&buf, "smoke-usage: " ++ fmt ++ "\n", args, 0) catch return;
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
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&buf, "smoke-usage: FAIL - " ++ fmt ++ "\n", args, 0) catch "FAIL\n";
    _ = c.fprintf(platform.stderr(), "%s", s.ptr);
    teardown();
    return 1;
}

fn pumpFor(app: *appdrive.App, ms: i64) void {
    const t0 = clock.nowMs();
    while (clock.nowMs() - t0 < ms) _ = app.pumpOnce(20);
}

fn savePng(app: *appdrive.App, stem: []const u8) void {
    const png = app.screenshotPng(g_win, 1600, null, 0) catch return;
    defer g_alloc.free(png.png);
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "zig-out/smoke-usage-{s}.png", .{stem}, 0) catch return;
    const f = c.fopen(path.ptr, "wb") orelse return;
    defer _ = c.fclose(f);
    _ = c.fwrite(png.png.ptr, 1, png.png.len, f);
}

const Row = struct {
    path: []const u8,
    pos: i32,
    x: f64,
    y: f64,
    selected: bool,
};
const Usage = struct {
    running: bool = false,
    current: []const u8 = "",
    scroll: f64 = 0,
    upper: f64 = 0,
    page: f64 = 0,
    n_rows: u32 = 0,
    selected: []const u8 = "",
    focus: []const u8 = "",
    focus_widget: []const u8 = "",
    renders: u64 = 0,
    external_renders: u64 = 0,
    rows_built: u64 = 0,
    rows_dropped: u64 = 0,
    nodes: u64 = 0,
    rows: []Row = &.{},
};
const Reply = struct { ok: bool = false, usage: Usage = .{} };
const Snap = std.json.Parsed(Reply);

fn usageCmd(app: *appdrive.App, label: []const u8, start: ?[]const u8, quiet: bool) ?Snap {
    var req_buf: [512]u8 = undefined;
    const req = if (start) |root|
        std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"browser-usage\",\"pane\":1,\"data\":\"{s}\"}}\n", .{root}) catch return null
    else
        "{\"cmd\":\"browser-usage\",\"pane\":1}\n";
    const reply = ctlsock.roundtrip(g_alloc, app, g_gui_sock, req) orelse return null;
    defer g_alloc.free(reply);
    const parsed = std.json.parseFromSlice(Reply, g_alloc, reply, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
        say("browser-usage reply: {s}", .{reply[0..@min(reply.len, 600)]});
        return null;
    };
    if (!parsed.value.ok) {
        say("browser-usage reply: {s}", .{reply[0..@min(reply.len, 600)]});
        parsed.deinit();
        return null;
    }
    if (!quiet) {
        const u = parsed.value.usage;
        say("{s}: {s}{s}, scroll {d:.0}/{d:.0}, {d} rows ({d} on screen), selected '{s}', focus '{s}' ({s}), renders {d} (external {d}), rows built {d} dropped {d}", .{
            label,          std.fs.path.basename(u.current),  if (u.running) " (scanning)" else "",
            u.scroll,       u.upper,                          u.n_rows,
            u.rows.len,     std.fs.path.basename(u.selected), std.fs.path.basename(u.focus),
            u.focus_widget, u.renders,                        u.external_renders,
            u.rows_built,   u.rows_dropped,
        });
    }
    return parsed;
}

fn usage(app: *appdrive.App, label: []const u8) ?Snap {
    return usageCmd(app, label, null, false);
}

fn findRow(u: Usage, path: []const u8) ?Row {
    for (u.rows) |r| if (std.mem.eql(u8, r.path, path)) return r;
    return null;
}

/// A fully on-screen row whose basename starts with `prefix`, at or
/// after the `skip`-th visible row.
fn pickRow(u: Usage, prefix: []const u8, skip: usize, buf: []u8) ?[]const u8 {
    if (u.rows.len < 3) return null;
    // Not the first or last visible row: those can be half clipped.
    const lo = @min(skip, u.rows.len - 2);
    for (u.rows[@max(lo, 1) .. u.rows.len - 1]) |r| {
        if (!std.mem.startsWith(u8, std.fs.path.basename(r.path), prefix)) continue;
        if (r.path.len > buf.len) return null;
        @memcpy(buf[0..r.path.len], r.path);
        return buf[0..r.path.len];
    }
    return null;
}

var why_buf: [768]u8 = undefined;

/// Null when the selection and keyboard focus are both on `path`.
fn cursorOn(u: Usage, path: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, u.selected, path))
        return std.fmt.bufPrint(&why_buf, "the selected row is '{s}', not '{s}'", .{ u.selected, path }) catch "selection elsewhere";
    if (!std.mem.eql(u8, u.focus, path))
        return std.fmt.bufPrint(&why_buf, "keyboard focus is on '{s}' ({s}), not '{s}'", .{ u.focus, u.focus_widget, path }) catch "focus elsewhere";
    return null;
}

/// Null when nothing between `before` and `after` was rebuilt or moved.
fn unchurned(before: Usage, after: Usage, path: []const u8) ?[]const u8 {
    if (after.rows_built != before.rows_built or after.rows_dropped != before.rows_dropped)
        return std.fmt.bufPrint(&why_buf, "{d} row widgets were rebuilt and {d} dropped", .{
            after.rows_built - before.rows_built, after.rows_dropped - before.rows_dropped,
        }) catch "rows rebuilt";
    if (@abs(after.scroll - before.scroll) > 1)
        return std.fmt.bufPrint(&why_buf, "the scroll offset moved from {d:.0} to {d:.0}", .{ before.scroll, after.scroll }) catch "scroll moved";
    const b = findRow(before, path) orelse return "the row was not on screen before";
    const a = findRow(after, path) orelse return "the row is no longer on screen";
    if (@abs(a.y - b.y) > 1)
        return std.fmt.bufPrint(&why_buf, "the row moved on screen from y={d:.0} to y={d:.0}", .{ b.y, a.y }) catch "row moved";
    return cursorOn(after, path);
}

/// New files in the analyzed folder: the browser's own subscription to
/// it re-renders the tab, which is what used to rebuild the analyzer.
fn churnListing(app: *appdrive.App, before: Usage) ?[]const u8 {
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        touch_serial += 1;
        touch("{s}/new-{d}.txt", .{ g_files_dir, touch_serial }, 0);
        pumpFor(app, 400);
    }
    pumpFor(app, 800);
    const s = usageCmd(app, "probe", null, true) orelse return "no report";
    defer s.deinit();
    if (s.value.usage.external_renders == before.external_renders)
        return "the listing changes never re-rendered the tab (the rig did not exercise the path)";
    return null;
}

fn clickRow(app: *appdrive.App, u: Usage, path: []const u8) bool {
    const r = findRow(u, path) orelse return false;
    app.click(g_win, r.x, r.y, 1) catch return false;
    pumpFor(app, 700);
    return true;
}

/// Click a file row, then let the listing change under it.
fn selectStage(app: *appdrive.App, label: []const u8, skip: usize) ?[]const u8 {
    const s0 = usage(app, label) orelse return "no report";
    defer s0.deinit();
    var pb: [512]u8 = undefined;
    const path = pickRow(s0.value.usage, "file-", skip, &pb) orelse return "no file row on screen";
    say("{s}: clicking {s}", .{ label, std.fs.path.basename(path) });
    if (!clickRow(app, s0.value.usage, path)) return "click failed";
    const s1 = usage(app, "  selected") orelse return "no report after the click";
    defer s1.deinit();
    if (cursorOn(s1.value.usage, path)) |why| return why;
    if (churnListing(app, s1.value.usage)) |why| return why;
    const s2 = usage(app, "  after listing churn") orelse return "no report after the churn";
    defer s2.deinit();
    savePng(app, "selected");
    return unchurned(s1.value.usage, s2.value.usage, path);
}

fn scrollDown(app: *appdrive.App, x: f64, y: f64, min_scroll: f64) bool {
    var i: u32 = 0;
    while (i < 12) : (i += 1) {
        app.scroll(g_win, x, y, 0, 3) catch return false;
        pumpFor(app, 250);
        const s = usageCmd(app, "scrolling", null, true) orelse return false;
        defer s.deinit();
        if (s.value.usage.scroll >= min_scroll) return true;
    }
    return false;
}

/// Click a folder row (drill down), then Alt+Up back out of it.
fn drillStage(app: *appdrive.App) ?[]const u8 {
    const s0 = usage(app, "drill") orelse return "no report";
    defer s0.deinit();
    const root_scroll = s0.value.usage.scroll;
    var pb: [512]u8 = undefined;
    const path = pickRow(s0.value.usage, "dir-", 2, &pb) orelse return "no folder row on screen";
    const y0 = findRow(s0.value.usage, path).?.y;
    say("drill: clicking {s}", .{std.fs.path.basename(path)});
    if (!clickRow(app, s0.value.usage, path)) return "click failed";
    const s1 = usage(app, "  inside") orelse return "no report inside the folder";
    defer s1.deinit();
    if (!std.mem.eql(u8, s1.value.usage.current, path))
        return std.fmt.bufPrint(&why_buf, "the analyzer shows '{s}', not '{s}'", .{ s1.value.usage.current, path }) catch "did not drill";
    if (s1.value.usage.focus.len == 0)
        return std.fmt.bufPrint(&why_buf, "keyboard focus left the result list (on {s})", .{s1.value.usage.focus_widget}) catch "focus lost";
    if (s1.value.usage.scroll > 1) return "the drilled-into folder did not open at the top";
    app.pressKey(g_win, "Alt+Up") catch return "key failed";
    pumpFor(app, 800);
    const s2 = usage(app, "  Alt+Up") orelse return "no report after Alt+Up";
    defer s2.deinit();
    savePng(app, "back-up");
    if (!std.mem.eql(u8, s2.value.usage.current, g_files_dir))
        return std.fmt.bufPrint(&why_buf, "Alt+Up shows '{s}', not the scan root", .{s2.value.usage.current}) catch "did not go up";
    if (cursorOn(s2.value.usage, path)) |why| return why;
    const back = findRow(s2.value.usage, path) orelse return "the folder we came from is not on screen";
    if (@abs(s2.value.usage.scroll - root_scroll) > 1 or @abs(back.y - y0) > 1)
        return std.fmt.bufPrint(&why_buf, "the list came back at scroll {d:.0} with the folder at y={d:.0}, not {d:.0} / y={d:.0}", .{
            s2.value.usage.scroll, back.y, root_scroll, y0,
        }) catch "moved";
    // The cursor is live: Down moves to the next row.
    const next_pos = back.pos + 1;
    var next_path_buf: [512]u8 = undefined;
    var next_path: []const u8 = "";
    for (s2.value.usage.rows) |r| if (r.pos == next_pos) {
        @memcpy(next_path_buf[0..r.path.len], r.path);
        next_path = next_path_buf[0..r.path.len];
    };
    if (next_path.len == 0) return "no row below the folder";
    app.pressKey(g_win, "Down") catch return "key failed";
    pumpFor(app, 500);
    const s3 = usage(app, "  Down") orelse return "no report after Down";
    defer s3.deinit();
    if (!std.mem.eql(u8, s3.value.usage.focus, next_path))
        return std.fmt.bufPrint(&why_buf, "Down put focus on '{s}', not '{s}'", .{ s3.value.usage.focus, next_path }) catch "Down went elsewhere";
    // Walking past the bottom of the viewport scrolls the cursor along.
    var i: u32 = 0;
    while (i < 14) : (i += 1) {
        app.pressKey(g_win, "Down") catch return "key failed";
        pumpFor(app, 120);
    }
    pumpFor(app, 500);
    const s4 = usage(app, "  14x Down") orelse return "no report after Down";
    defer s4.deinit();
    if (s4.value.usage.scroll <= s3.value.usage.scroll + 1) return "walking down past the viewport did not scroll the list";
    if (s4.value.usage.focus.len == 0 or findRow(s4.value.usage, s4.value.usage.focus) == null)
        return std.fmt.bufPrint(&why_buf, "the cursor row '{s}' is off screen after walking down", .{s4.value.usage.focus}) catch "cursor off screen";
    return null;
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
    const rt = std.fmt.bufPrintSentinel(&rt_buf, "/tmp/sku-{d}", .{c.getpid()}, 0) catch return fail("runtime path", .{});
    _ = c.mkdir(rt.ptr, 0o700);
    _ = c.setenv("XDG_RUNTIME_DIR", rt.ptr, 1);
    _ = c.setenv("XDG_CONFIG_HOME", rt.ptr, 1);
    _ = c.setenv("XDG_STATE_HOME", rt.ptr, 1);
    for ([_][*:0]const u8{ "SKETERM_SOCKET", "SKETERM_MUX_SOCKET", "SKETERM_SESSION", "SKETERM_PANE_ID", "SKETERM_SESSION_ORIGIN_ID" }) |name| _ = unsetEnv(name);
    defer @import("util/pathz.zig").removeTree(rt);
    // Isolated XDG_CONFIG_HOME races pango/fontconfig unless warmed.
    _ = c.system("fc-cache >/dev/null 2>&1");

    // ── the folder ────────────────────────────────────────────────
    var files_buf: [160]u8 = undefined;
    const files_dir = std.fmt.bufPrintSentinel(&files_buf, "{s}/files", .{rt}, 0) catch return fail("files path", .{});
    g_files_dir = files_dir;
    _ = c.mkdir(files_dir.ptr, 0o755);
    {
        var i: u32 = 0;
        while (i < DIRS) : (i += 1) {
            var d_buf: [256]u8 = undefined;
            const d = std.fmt.bufPrintSentinel(&d_buf, "{s}/dir-{d:0>2}", .{ files_dir, i }, 0) catch continue;
            _ = c.mkdir(d.ptr, 0o755);
            touch("{s}/blob", .{d}, (i + 1) * 2 * BLOCK);
            var k: u32 = 0;
            while (k < 3) : (k += 1) touch("{s}/small-{d}.txt", .{ d, k }, BLOCK);
        }
        i = 0;
        while (i < FILES) : (i += 1) touch("{s}/file-{d:0>2}.bin", .{ files_dir, i }, (i * 4 + 3) * BLOCK);
        var bulk_buf: [256]u8 = undefined;
        const bulk = std.fmt.bufPrintSentinel(&bulk_buf, "{s}/bulk", .{files_dir}, 0) catch return fail("bulk path", .{});
        _ = c.mkdir(bulk.ptr, 0o755);
        i = 0;
        while (i < BULK) : (i += 1) touch("{s}/e-{d}", .{ bulk, i }, 0);
    }

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
        _ = c.setenv("SKETERM_APP_ID", "dev.sker.sketerm.usagesmoke", 1);
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
    for (app.windows.items) |w| if (!w.popup and w.w > 0) {
        g_win = w.id;
        break;
    };
    if (g_win == 0) return fail("no toplevel window", .{});
    var gui_buf: [256]u8 = undefined;
    g_gui_sock = std.fmt.bufPrintSentinel(&gui_buf, "{s}/sketerm/{d}.sock", .{ rt, child_pid }, 0) catch return fail("GUI socket path", .{});
    {
        const t0 = clock.nowMs();
        while (true) {
            pumpFor(app, 200);
            if (ctlsock.roundtrip(allocator, app, g_gui_sock, "{\"cmd\":\"list\"}\n")) |r| {
                defer allocator.free(r);
                if (std.mem.indexOf(u8, r, "\"ok\":true") != null) break;
            }
            if (clock.nowMs() - t0 > 30_000) return fail("the GUI control socket never answered", .{});
        }
    }
    app.resizeWindow(g_win, 1200, 700) catch return fail("sizing the window", .{});
    pumpFor(app, 1500);

    // ── the file view, then the analysis ──────────────────────────
    {
        var req_buf: [256]u8 = undefined;
        const req = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"browser-here\",\"pane\":1,\"data\":\"{s}\"}}\n", .{files_dir}) catch return fail("browser-here format", .{});
        const r = ctlsock.roundtrip(allocator, app, g_gui_sock, req) orelse return fail("browser-here roundtrip", .{});
        defer allocator.free(r);
        if (std.mem.indexOf(u8, r, "\"ok\":true") == null) return fail("browser-here refused: {s}", .{r});
    }
    pumpFor(app, 2500);

    // While the scan runs, progress re-renders the analyzer every few
    // hundred ms; none of those may rebuild a row it already has.
    {
        const s = usageCmd(app, "started", files_dir, false) orelse return fail("could not start the analysis", .{});
        s.deinit();
    }
    {
        const t0 = clock.nowMs();
        var last_log: i64 = 0;
        while (true) {
            pumpFor(app, 100);
            const s = usageCmd(app, "scan", null, true) orelse return fail("no report during the scan", .{});
            defer s.deinit();
            const u = s.value.usage;
            if (!u.running) {
                say("scan finished: {d} rows, {d} renders, {d} row widgets built, {d} dropped", .{ u.n_rows, u.renders, u.rows_built, u.rows_dropped });
                // Every result row is built exactly once (+ the "Other"
                // row), and none is torn down while results stream in.
                if (u.renders < 3) return fail("only {d} renders during the scan: the rig did not exercise streaming", .{u.renders});
                if (u.rows_built > u.n_rows + 1 or u.rows_dropped > 1)
                    return fail("the scan built {d} row widgets and dropped {d} for {d} rows: rows were rebuilt as results streamed", .{ u.rows_built, u.rows_dropped, u.n_rows });
                break;
            }
            if (clock.nowMs() - last_log >= 1000) {
                last_log = clock.nowMs();
                say("  t+{d}ms: {d} renders, {d} results, {d} rows built", .{ clock.nowMs() - t0, u.renders, u.nodes, u.rows_built });
            }
            if (clock.nowMs() - t0 > 60_000) return fail("the scan never finished", .{});
        }
    }
    pumpFor(app, 1000);
    savePng(app, "1-done");
    {
        const s = usage(app, "settled") orelse return fail("no report after the scan", .{});
        defer s.deinit();
        const u = s.value.usage;
        if (u.n_rows < DIRS + FILES) return fail("only {d} result rows", .{u.n_rows});
        if (u.rows.len < 5) return fail("only {d} rows on screen", .{u.rows.len});
    }

    if (selectStage(app, "select at the top", 2)) |why| return fail("selection at the top: {s} (zig-out/smoke-usage-selected.png)", .{why});
    {
        const s = usage(app, "scroll") orelse return fail("no report", .{});
        defer s.deinit();
        const r = s.value.usage.rows[s.value.usage.rows.len / 2];
        if (!scrollDown(app, r.x, r.y, 200)) return fail("could not scroll the result list down", .{});
    }
    if (selectStage(app, "select scrolled", 2)) |why| return fail("selection in a scrolled list: {s} (zig-out/smoke-usage-selected.png)", .{why});
    if (drillStage(app)) |why| return fail("drill down and back: {s} (zig-out/smoke-usage-back-up.png)", .{why});

    say("PASS: the analyzer keeps its rows, selection, focus and scroll through streaming results and re-renders", .{});
    teardown();
    return 0;
}

fn touch(comptime fmt: []const u8, args: anytype, bytes: usize) void {
    var p_buf: [400]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&p_buf, fmt, args, 0) catch return;
    const f = c.fopen(p.ptr, "wb") orelse return;
    defer _ = c.fclose(f);
    var block: [BLOCK]u8 = @splat('x');
    var left = bytes;
    while (left > 0) {
        const n = @min(left, block.len);
        _ = c.fwrite(&block, 1, n, f);
        left -= n;
    }
}
