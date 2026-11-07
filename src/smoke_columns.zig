//! smoke-columns: a file view's details columns never starve the Name
//! column, on the REAL GUI and sketerm's own compositor (CLAUDE.md
//! "Headless GUI testing"; never X).
//!
//! GtkColumnView autoscrolls while a header-grip drag sits within 30 px
//! of the view's edge, and every autoscroll frame widens the dragged
//! column again (gtkcolumnview.c autoscroll_cb -> update_column_resize)
//! with no pointer motion at all. The rig drags the Size grip into that
//! edge, then squeezes the window to a narrow split-like width and back,
//! and after each step asks the `browser-columns` verification command
//! for the live widths: Name must keep its minimum and no column may
//! push the listing past the viewport while it has room.
//!
//! Screenshots land in zig-out/smoke-columns-*.png. Everything created
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
const colfit = @import("filebrowser/colfit.zig");
const model = @import("filebrowser/model.zig");

const TTL = "180";
const SESSION = "colsmoke";

var g_alloc: std.mem.Allocator = undefined;
var g_mux_sock: []const u8 = "";
var drive: ?*appdrive.App = null;
var child_pid: c.pid_t = 0;
var daemon_pid: c.pid_t = 0;
var display_ready = false;

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&buf, "smoke-columns: " ++ fmt ++ "\n", args, 0) catch return;
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
    const s = std.fmt.bufPrintSentinel(&buf, "smoke-columns: FAIL - " ++ fmt ++ "\n", args, 0) catch "FAIL\n";
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
    const path = std.fmt.bufPrintSentinel(&path_buf, "zig-out/smoke-columns-{s}.png", .{stem}, 0) catch return;
    const f = c.fopen(path.ptr, "wb") orelse return;
    defer _ = c.fclose(f);
    _ = c.fwrite(png.png.ptr, 1, png.png.len, f);
}

const Column = struct {
    title: []const u8,
    fixed_width: i32,
    expand: bool,
    stored: i32,
    x: f64,
    width: f64,
    y: f64,
};
const Listing = struct { viewport: i32 = 0, columns: []Column = &.{} };
const Reply = struct { ok: bool = false, listing: Listing = .{} };

fn columns(app: *appdrive.App, gui_sock: [:0]const u8, label: []const u8) ?std.json.Parsed(Reply) {
    const reply = ctlsock.roundtrip(g_alloc, app, gui_sock, "{\"cmd\":\"browser-columns\",\"pane\":1}\n") orelse return null;
    defer g_alloc.free(reply);
    const parsed = std.json.parseFromSlice(Reply, g_alloc, reply, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
        say("browser-columns reply: {s}", .{reply});
        return null;
    };
    if (!parsed.value.ok or parsed.value.listing.columns.len == 0) {
        say("browser-columns reply: {s}", .{reply});
        parsed.deinit();
        return null;
    }
    var line_buf: [900]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line_buf);
    for (parsed.value.listing.columns) |col|
        w.print(" | {s} {d:.0}px (fixed {d}, stored {d}{s})", .{ col.title, col.width, col.fixed_width, col.stored, if (col.expand) ", expand" else "" }) catch break;
    say("{s}: viewport {d}{s}", .{ label, parsed.value.listing.viewport, w.buffered() });
    return parsed;
}

fn find(l: Listing, title: []const u8) ?Column {
    for (l.columns) |col| if (std.mem.eql(u8, col.title, title)) return col;
    return null;
}

fn defaultWidthOf(title: []const u8) i32 {
    for (std.enums.values(model.Column)) |col|
        if (std.mem.eql(u8, std.mem.span(col.title()), title)) return col.width();
    return model.ATTR_COLUMN_WIDTH;
}

/// Null when the listing honours the invariant; otherwise why not.
fn check(l: Listing) ?[]const u8 {
    const name = find(l, "Name") orelse return "no Name column";
    var total: f64 = 0;
    for (l.columns) |col| total += col.width;
    if (name.width + 0.5 < @as(f64, colfit.MIN_NAME_WIDTH)) return "the Name column is starved below its minimum";
    // Every other column at min(its width, its default): the most the
    // policy may ever shrink them to.
    var floors: i32 = 0;
    for (l.columns) |col| if (!std.mem.eql(u8, col.title, "Name")) {
        floors += @min(@as(i32, @intFromFloat(col.width)), defaultWidthOf(col.title));
    };
    const reserve = colfit.nameReserve(l.viewport);
    if (floors + reserve <= l.viewport) {
        // A widened column may never take Name's reserve, unless Name
        // itself was dragged narrower than that.
        const name_wants = if (name.stored > 0) @min(name.stored, reserve) else reserve;
        if (name.width + 0.5 < @as(f64, @floatFromInt(name_wants))) return "a widened column took the Name column's reserve";
        if (total > @as(f64, @floatFromInt(l.viewport)) + 1) return "the columns overflow a viewport that holds them all";
    }
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
    const rt = std.fmt.bufPrintSentinel(&rt_buf, "/tmp/skc-{d}", .{c.getpid()}, 0) catch return fail("runtime path", .{});
    _ = c.mkdir(rt.ptr, 0o700);
    _ = c.setenv("XDG_RUNTIME_DIR", rt.ptr, 1);
    _ = c.setenv("XDG_CONFIG_HOME", rt.ptr, 1);
    _ = c.setenv("XDG_STATE_HOME", rt.ptr, 1);
    for ([_][*:0]const u8{ "SKETERM_SOCKET", "SKETERM_MUX_SOCKET", "SKETERM_SESSION", "SKETERM_PANE_ID", "SKETERM_SESSION_ORIGIN_ID" }) |name| _ = unsetEnv(name);
    defer @import("util/pathz.zig").removeTree(rt);
    // Isolated XDG_CONFIG_HOME races pango/fontconfig unless warmed.
    _ = c.system("fc-cache >/dev/null 2>&1");

    // A folder with a few files for the listing.
    var files_buf: [160]u8 = undefined;
    const files_dir = std.fmt.bufPrintSentinel(&files_buf, "{s}/files", .{rt}, 0) catch return fail("files path", .{});
    _ = c.mkdir(files_dir.ptr, 0o755);
    for ([_][]const u8{ "alpha.txt", "a fairly long file name that wants room.md", "zeta.bin" }, 0..) |name, i| {
        var p_buf: [256]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&p_buf, "{s}/{s}", .{ files_dir, name }, 0) catch continue;
        const f = c.fopen(p.ptr, "wb") orelse continue;
        var k: usize = 0;
        while (k < (i + 1) * 1500) : (k += 1) _ = c.fputc('x', f);
        _ = c.fclose(f);
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
        _ = c.setenv("SKETERM_APP_ID", "dev.sker.sketerm.colsmoke", 1);
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
    const W: i32 = 1200;
    const H: i32 = 700;
    app.resizeWindow(win_id, W, H) catch return fail("sizing the window", .{});
    pumpFor(app, 1500);

    // ── the file view ─────────────────────────────────────────────
    {
        var req_buf: [256]u8 = undefined;
        const req = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"browser-here\",\"pane\":1,\"data\":\"{s}\"}}\n", .{files_dir}) catch return fail("browser-here format", .{});
        const r = ctlsock.roundtrip(allocator, app, gui_sock, req) orelse return fail("browser-here roundtrip", .{});
        defer allocator.free(r);
        if (std.mem.indexOf(u8, r, "\"ok\":true") == null) return fail("browser-here refused: {s}", .{r});
    }
    pumpFor(app, 2500);
    savePng(app, win_id, "1-initial");
    {
        const p = columns(app, gui_sock, "initial") orelse return fail("no column geometry", .{});
        defer p.deinit();
        if (check(p.value.listing)) |why| return fail("initial: {s}", .{why});
    }

    // ── 1. drag the Size grip into GTK's autoscroll edge ──────────
    // Auto Name first, then an explicit Name (dragged narrower), since
    // the two expand policies hand the surplus out differently; the
    // repeats keep dragging the same grip until only the clamp can
    // stop it.
    for ([_][]const u8{ "auto Name", "explicit Name", "explicit Name, again", "explicit Name, third", "explicit Name, fourth" }, 0..) |mode, round| {
        if (round == 1) {
            const p = columns(app, gui_sock, "before the Name drag") orelse return fail("no column geometry", .{});
            defer p.deinit();
            const name = find(p.value.listing, "Name").?;
            const gx = name.x + name.width - 1;
            app.drag(win_id, gx, name.y, gx - 200, name.y, 1) catch return fail("dragging the Name grip", .{});
            pumpFor(app, 800);
        }
        const p = columns(app, gui_sock, "before the Size drag") orelse return fail("no column geometry", .{});
        const size = find(p.value.listing, "Size") orelse {
            p.deinit();
            return fail("no Size column", .{});
        };
        // The right edge of the listing, in surface coordinates.
        var right: f64 = 0;
        for (p.value.listing.columns) |col| right = @max(right, col.x + col.width);
        const view_right = (find(p.value.listing, "Name").?).x + @as(f64, @floatFromInt(p.value.listing.viewport));
        p.deinit();
        const gx = size.x + size.width - 1;
        say("{s}: dragging the Size grip from x={d:.0} to x={d:.0} (view edge {d:.0})", .{ mode, gx, view_right - 6, view_right });
        // The pointer RESTS at the edge for a moment, as a hand does:
        // that pause is all GTK's autoscroll needs.
        app.dragHold(win_id, gx, size.y, view_right - 6, size.y, 1, 1500) catch return fail("dragging the Size grip", .{});
        pumpFor(app, 1000);
        var stem_buf: [32]u8 = undefined;
        const stem = std.fmt.bufPrint(&stem_buf, "2-dragged-{d}", .{round}) catch "2-dragged";
        savePng(app, win_id, stem);
        const after = columns(app, gui_sock, "after the Size drag") orelse return fail("no column geometry", .{});
        defer after.deinit();
        if (check(after.value.listing)) |why| return fail("{s}, Size grip dragged into the edge: {s} (zig-out/smoke-columns-{s}.png)", .{ mode, why, stem });
        const s2 = find(after.value.listing, "Size").?;
        if (s2.width > @as(f64, @floatFromInt(colfit.MAX_COLUMN_WIDTH))) return fail("{s}: Size grew to {d:.0}px", .{ mode, s2.width });
    }

    // ── 2. a squeeze and back keeps Name alive ────────────────────
    for ([_]i32{ 520, 380, W }) |w| {
        app.resizeWindow(win_id, w, H) catch return fail("resizing the window", .{});
        pumpFor(app, 1500);
        var label_buf: [48]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "window {d} wide", .{w}) catch "resized";
        const p = columns(app, gui_sock, label) orelse return fail("no column geometry", .{});
        defer p.deinit();
        var stem_buf: [32]u8 = undefined;
        const stem = std.fmt.bufPrint(&stem_buf, "3-w{d}", .{w}) catch "3-resized";
        savePng(app, win_id, stem);
        if (check(p.value.listing)) |why| return fail("{s}: {s} (zig-out/smoke-columns-{s}.png)", .{ label, why, stem });
    }

    say("PASS: grip drags into the autoscroll edge and squeezes never starve the Name column", .{});
    teardown();
    return 0;
}
