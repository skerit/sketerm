//! smoke-dragout: file-browser entries dragged out of sketerm, or copied
//! with Ctrl+C / Ctrl+X, arrive as FILES, on the REAL GUI and sketerm's
//! own compositor (CLAUDE.md "Headless GUI testing"; never X).
//!
//! The drag receiver is the `dnd-probe` verification window, a second
//! toplevel of the GUI. Its left zone reads a drop the way a foreign
//! application (Chromium/Electron, a GTK app) does: raw text/uri-list
//! bytes, which runs the drag's own content provider, the remote fetch
//! and GTK's serializer. Its right zone lists the gtypes sketerm's own
//! file-list targets list and records which one GTK picked. What the
//! probe cannot be is another process: the compositor does within-app
//! dnd only, so the bytes travel GDK's in-process pipe rather than a
//! wl_data_offer fd. Everything up to the pipe is the real path.
//!
//! The clipboard receiver IS another process: the rig itself asks the
//! GUI's selection for a MIME type over `wl_data_source.send`
//! (`appdrive.getClipboardMime`), the request a paste in Slack, Nautilus
//! or Dolphin makes.
//!
//! Drag stages: a local file (percent-encoded URI, CRLF, readable
//! content); the same drop on the sketerm zone gets specs and fetches
//! nothing; a remote file over a fake-ssh host (no fetch for the sketerm
//! zone, a staged copy with the original name and content for the
//! external one); a remote directory, recursively; a re-drag reusing the
//! finished copy; and an unreadable remote file failing the drop instead
//! of hanging it. Clipboard stages: a local copy (CRLF URI list, GNOME
//! copied-files, path text); a remote copy fetched only when its URI
//! list is read; sketerm's own paste of it transferring host to host
//! without staging anything; a remote cut announced as a copy whose
//! original survives the external paste; and a remote file over the
//! clipboard cap offered as its path only.

const std = @import("std");
const bindir = @import("smoke/bindir.zig");
const c = @import("c.zig").c;
const unsetEnv = @import("util/env.zig").unset;
const platform = @import("util/platform.zig");
const appdrive = @import("ipc/appdrive.zig");
const clock = @import("util/clock.zig");
const smokecli = @import("smoke/displaycli.zig");
const ctlsock = @import("smoke/ctlsock.zig");

const TTL = "240";
const SESSION = "dragoutsmoke";
const HOST = "rbox";

var g_alloc: std.mem.Allocator = undefined;
var g_mux_sock: []const u8 = "";
var g_gui_sock: [:0]const u8 = "";
var g_win: u32 = 0;
var g_probe: u32 = 0;
var drive: ?*appdrive.App = null;
var child_pid: c.pid_t = 0;
var daemon_pid: c.pid_t = 0;
var remote_pid: c.pid_t = 0;
var display_ready = false;

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&buf, "smoke-dragout: " ++ fmt ++ "\n", args, 0) catch return;
    _ = c.fprintf(platform.stdout(), "%s", s.ptr);
    _ = c.fflush(platform.stdout());
}

fn reap(pid: *c.pid_t, sig: c_int) void {
    if (pid.* <= 0) return;
    _ = c.kill(pid.*, sig);
    var status: c_int = 0;
    _ = c.waitpid(pid.*, &status, 0);
    pid.* = 0;
}

fn teardown() void {
    if (drive) |app| {
        app.detach();
        drive = null;
    }
    reap(&child_pid, c.SIGKILL);
    if (display_ready and g_mux_sock.len > 0) {
        const r = smokecli.runDisplayCli(g_alloc, &.{ "destroy", SESSION, "--socket", g_mux_sock });
        g_alloc.free(r.out);
        display_ready = false;
    }
    reap(&daemon_pid, c.SIGTERM);
    reap(&remote_pid, c.SIGTERM);
}

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&buf, "smoke-dragout: FAIL - " ++ fmt ++ "\n", args, 0) catch "FAIL\n";
    _ = c.fprintf(platform.stderr(), "%s", s.ptr);
    teardown();
    return 1;
}

fn pumpFor(app: *appdrive.App, ms: i64) void {
    const t0 = clock.nowMs();
    while (clock.nowMs() - t0 < ms) _ = app.pumpOnce(20);
}

fn writeFile(path: [:0]const u8, body: []const u8) bool {
    const f = c.fopen(path.ptr, "wb") orelse return false;
    defer _ = c.fclose(f);
    return c.fwrite(body.ptr, 1, body.len, f) == body.len;
}

/// The whole file, or null. Caller frees.
fn readFile(path: [:0]const u8) ?[]u8 {
    const f = c.fopen(path.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        out.appendSlice(g_alloc, buf[0..n]) catch return null;
    }
    return out.toOwnedSlice(g_alloc) catch null;
}

const Row = struct { path: []const u8, y: f64, label_x: f64 };
const Listing = struct { n_items: u32 = 0, rows: []Row = &.{} };
const RowsReply = struct { ok: bool = false, listing: Listing = .{} };

const ProbeResult = struct { state: []const u8 = "", mime: []const u8 = "", data: []const u8 = "", err: []const u8 = "" };
const Probe = struct { drops: u32 = 0, external: ProbeResult = .{}, internal: ProbeResult = .{}, fetches: u64 = 0 };
const ProbeReply = struct { ok: bool = false, probe: Probe = .{} };

fn probe(app: *appdrive.App, reset: bool) ?std.json.Parsed(ProbeReply) {
    const req = if (reset) "{\"cmd\":\"dnd-probe\",\"data\":\"reset\"}\n" else "{\"cmd\":\"dnd-probe\"}\n";
    const reply = ctlsock.roundtrip(g_alloc, app, g_gui_sock, req) orelse return null;
    defer g_alloc.free(reply);
    const parsed = std.json.parseFromSlice(ProbeReply, g_alloc, reply, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
        say("dnd-probe reply: {s}", .{reply[0..@min(reply.len, 600)]});
        return null;
    };
    if (!parsed.value.ok) {
        say("dnd-probe reply: {s}", .{reply[0..@min(reply.len, 600)]});
        parsed.deinit();
        return null;
    }
    return parsed;
}

/// Row geometry for the entry named `name` in pane 1's current tab.
fn findRow(app: *appdrive.App, name: []const u8, timeout_ms: i64) ?struct { x: f64, y: f64 } {
    const t0 = clock.nowMs();
    while (clock.nowMs() - t0 < timeout_ms) {
        pumpFor(app, 150);
        const reply = ctlsock.roundtrip(g_alloc, app, g_gui_sock, "{\"cmd\":\"browser-rows\",\"pane\":1}\n") orelse continue;
        defer g_alloc.free(reply);
        const s = std.json.parseFromSlice(RowsReply, g_alloc, reply, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
        defer s.deinit();
        for (s.value.listing.rows) |r| {
            if (std.mem.eql(u8, std.fs.path.basename(r.path), name)) return .{ .x = r.label_x + 20, .y = r.y };
        }
    }
    return null;
}

const Zone = enum { external, internal };

fn zonePoint(app: *appdrive.App, zone: Zone) struct { x: f64, y: f64 } {
    const w = app.winById(g_probe).?;
    const fw: f64 = @floatFromInt(w.w);
    const fh: f64 = @floatFromInt(w.h);
    return .{ .x = fw * (if (zone == .external) @as(f64, 0.3) else 0.7), .y = fh * 0.6 };
}

/// Drag the row named `name` onto a probe zone and wait for that zone's
/// result. Caller deinits.
fn dragTo(app: *appdrive.App, name: []const u8, zone: Zone, timeout_ms: i64) ?std.json.Parsed(ProbeReply) {
    if (probe(app, true)) |p| p.deinit() else return null;
    // A gesture the compositor did not turn into a drop (the press
    // landed mid-rebind of a row the listing just refreshed) is retried
    // once; the drop itself is what every stage asserts on.
    var attempt: u32 = 0;
    while (attempt < 2) : (attempt += 1) {
        const row = findRow(app, name, 15_000) orelse {
            say("no row named '{s}' in the listing", .{name});
            return null;
        };
        const dst = zonePoint(app, zone);
        say("dragging '{s}' onto the {s} zone{s}", .{ name, @tagName(zone), if (attempt > 0) " (again: no drop arrived)" else "" });
        app.dragDndBetween(g_win, row.x, row.y, g_probe, dst.x, dst.y, 1) catch |err| {
            say("drag failed: {s}", .{@errorName(err)});
            return null;
        };
        const t0 = clock.nowMs();
        var dropped = false;
        while (clock.nowMs() - t0 < timeout_ms) {
            pumpFor(app, 200);
            const p = probe(app, false) orelse continue;
            const r = if (zone == .external) p.value.probe.external else p.value.probe.internal;
            if (std.mem.eql(u8, r.state, "done") or std.mem.eql(u8, r.state, "failed")) return p;
            dropped = dropped or p.value.probe.drops > 0;
            p.deinit();
            if (!dropped and clock.nowMs() - t0 > 5_000) break;
        }
        if (dropped) break;
    }
    say("the {s} zone never finished reading the drop", .{@tagName(zone)});
    return probe(app, false);
}

/// The one local path a single-URI uri-list names, or null. Caller frees.
fn singlePath(data: []const u8) ?[:0]u8 {
    if (!std.mem.endsWith(u8, data, "\r\n")) return null;
    const uri = data[0 .. data.len - 2];
    if (std.mem.indexOf(u8, uri, "\r\n") != null) return null;
    const uri_z = g_alloc.dupeSentinel(u8, uri, 0) catch return null;
    defer g_alloc.free(uri_z);
    const raw = c.g_filename_from_uri(uri_z.ptr, null, null) orelse return null;
    defer c.g_free(raw);
    return g_alloc.dupeSentinel(u8, std.mem.span(@as([*:0]const u8, @ptrCast(raw))), 0) catch null;
}

fn expectContent(path: [:0]const u8, want: []const u8) ?[]const u8 {
    const got = readFile(path) orelse return "the file the URI names cannot be read";
    defer g_alloc.free(got);
    if (!std.mem.eql(u8, got, want)) return "the file the URI names has the wrong content";
    return null;
}

const LOCAL_NAME = "local note #1 é.txt";
const LOCAL_BODY = "local bytes\n";
const REMOTE_NAME = "remote report.txt";
const REMOTE_BODY = "remote bytes, fetched on demand\n";
const GONE_NAME = "unreadable.txt";
const CLIP_NAME = "clip remote.txt";
const CLIP_BODY = "copied on one host, pasted as a file\n";
const CUT_NAME = "cut me.txt";
const CUT_BODY = "a cut must not take this away\n";
const BIG_NAME = "big.bin";

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

    // Short isolated runtime dir (sockaddr_un caps at ~108 bytes; a
    // daemon that cannot bind makes the GUI autostart the INSTALLED one).
    var rt_buf: [128]u8 = undefined;
    const rt = std.fmt.bufPrintSentinel(&rt_buf, "/tmp/skd-{d}", .{c.getpid()}, 0) catch return fail("runtime path", .{});
    _ = c.mkdir(rt.ptr, 0o700);
    var cache_buf: [160]u8 = undefined;
    const cache = std.fmt.bufPrintSentinel(&cache_buf, "{s}/cache", .{rt}, 0) catch return fail("cache path", .{});
    _ = c.mkdir(cache.ptr, 0o700);
    _ = c.setenv("XDG_RUNTIME_DIR", rt.ptr, 1);
    _ = c.setenv("XDG_CONFIG_HOME", rt.ptr, 1);
    _ = c.setenv("XDG_STATE_HOME", rt.ptr, 1);
    // The staging cache is the point of this rig: keep it in the sandbox.
    _ = c.setenv("XDG_CACHE_HOME", cache.ptr, 1);
    for ([_][*:0]const u8{ "SKETERM_SOCKET", "SKETERM_MUX_SOCKET", "SKETERM_SESSION", "SKETERM_PANE_ID", "SKETERM_SESSION_ORIGIN_ID", "SKETERM_SSH" }) |name| _ = unsetEnv(name);
    defer removeSandbox(rt);
    _ = c.system("fc-cache >/dev/null 2>&1");

    // ── the files ─────────────────────────────────────────────────
    var local_dir_buf: [200]u8 = undefined;
    const local_dir = std.fmt.bufPrintSentinel(&local_dir_buf, "{s}/files", .{rt}, 0) catch return fail("files path", .{});
    _ = c.mkdir(local_dir.ptr, 0o755);
    var p_buf: [400]u8 = undefined;
    if (!writeFile(std.fmt.bufPrintSentinel(&p_buf, "{s}/{s}", .{ local_dir, LOCAL_NAME }, 0) catch return fail("path", .{}), LOCAL_BODY))
        return fail("writing the local file", .{});
    var remote_dir_buf: [200]u8 = undefined;
    const remote_dir = std.fmt.bufPrintSentinel(&remote_dir_buf, "{s}/rfiles", .{rt}, 0) catch return fail("rfiles path", .{});
    _ = c.mkdir(remote_dir.ptr, 0o755);
    if (!writeFile(std.fmt.bufPrintSentinel(&p_buf, "{s}/{s}", .{ remote_dir, REMOTE_NAME }, 0) catch return fail("path", .{}), REMOTE_BODY))
        return fail("writing the remote file", .{});
    if (!writeFile(std.fmt.bufPrintSentinel(&p_buf, "{s}/{s}", .{ remote_dir, GONE_NAME }, 0) catch return fail("path", .{}), "soon gone\n"))
        return fail("writing the unreadable file", .{});
    for ([_][]const u8{ "rdir", "rdir/sub" }) |rel| {
        const d = std.fmt.bufPrintSentinel(&p_buf, "{s}/{s}", .{ remote_dir, rel }, 0) catch return fail("path", .{});
        _ = c.mkdir(d.ptr, 0o755);
    }
    if (!writeFile(std.fmt.bufPrintSentinel(&p_buf, "{s}/rdir/a.txt", .{remote_dir}, 0) catch return fail("path", .{}), "aaa\n")) return fail("rdir/a", .{});
    if (!writeFile(std.fmt.bufPrintSentinel(&p_buf, "{s}/rdir/sub/b.txt", .{remote_dir}, 0) catch return fail("path", .{}), "bbb\n")) return fail("rdir/sub/b", .{});
    for ([_]struct { name: []const u8, body: []const u8 }{
        .{ .name = CLIP_NAME, .body = CLIP_BODY },
        .{ .name = CUT_NAME, .body = CUT_BODY },
    }) |f| if (!writeFile(std.fmt.bufPrintSentinel(&p_buf, "{s}/{s}", .{ remote_dir, f.name }, 0) catch return fail("path", .{}), f.body))
        return fail("writing {s}", .{f.name});
    {
        // Sparse, just over the clipboard's fetch cap.
        const big = std.fmt.bufPrintSentinel(&p_buf, "{s}/{s}", .{ remote_dir, BIG_NAME }, 0) catch return fail("path", .{});
        if (!writeFile(big, "")) return fail("writing the big file", .{});
        if (c.truncate(big.ptr, 65 * 1024 * 1024) != 0) return fail("growing the big file", .{});
    }

    // ── the "remote" host: a second private daemon behind fake ssh ─
    var rrt_buf: [160]u8 = undefined;
    const rrt = std.fmt.bufPrintSentinel(&rrt_buf, "{s}/r", .{rt}, 0) catch return fail("remote rt path", .{});
    _ = c.mkdir(rrt.ptr, 0o700);
    var mux_abs_buf: [4096]u8 = undefined;
    const mux_abs_raw = c.realpath(bindir.path(.@"sketerm-mux"), &mux_abs_buf) orelse return fail("realpath sketerm-mux", .{});
    const mux_abs = std.mem.span(@as([*:0]const u8, @ptrCast(mux_abs_raw)));
    {
        const pid = c.fork();
        if (pid < 0) return fail("remote mux fork", .{});
        if (pid == 0) {
            platform.dieWithParent();
            _ = c.setenv("XDG_RUNTIME_DIR", rrt.ptr, 1);
            _ = c.setenv("XDG_STATE_HOME", rrt.ptr, 1);
            _ = c.setenv("XDG_CONFIG_HOME", rrt.ptr, 1);
            const argv = [_:null]?[*:0]const u8{ bindir.path(.@"sketerm-mux"), "--broker", null };
            _ = c.execv(bindir.path(.@"sketerm-mux"), @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        remote_pid = pid;
    }
    var rsock_buf: [256]u8 = undefined;
    const rsock = std.fmt.bufPrintSentinel(&rsock_buf, "{s}/sketerm/mux.sock", .{rrt}, 0) catch return fail("remote sock path", .{});
    {
        var waited: u32 = 0;
        while (c.access(rsock.ptr, c.F_OK) != 0) : (waited += 1) {
            if (waited > 100) return fail("remote mux socket never appeared", .{});
            _ = c.usleep(50_000);
        }
    }
    var ssh_buf: [200:0]u8 = undefined;
    const ssh_path = std.fmt.bufPrintSentinel(&ssh_buf, "{s}/fake-ssh", .{rt}, 0) catch return fail("fake ssh path", .{});
    {
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
        , .{ rrt, rrt, rrt, mux_abs, mux_abs }) catch return fail("fake ssh body", .{});
        if (!writeFile(ssh_path, body)) return fail("fake ssh write", .{});
        if (c.chmod(ssh_path.ptr, 0o755) != 0) return fail("fake ssh chmod", .{});
    }
    // Before the LOCAL daemon: its cross_copy job dials the host too.
    _ = c.setenv("SKETERM_SSH", ssh_path.ptr, 1);

    // ── private local daemon ──────────────────────────────────────
    {
        const pid = c.fork();
        if (pid < 0) return fail("mux fork", .{});
        if (pid == 0) {
            platform.dieWithParent();
            const argv = [_:null]?[*:0]const u8{ bindir.path(.@"sketerm-mux"), "--broker", null };
            _ = c.execv(bindir.path(.@"sketerm-mux"), @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        daemon_pid = pid;
    }
    var sock_buf: [256]u8 = undefined;
    const mux_sock = std.fmt.bufPrintSentinel(&sock_buf, "{s}/sketerm/mux.sock", .{rt}, 0) catch return fail("sock path", .{});
    {
        var waited: u32 = 0;
        while (c.access(mux_sock.ptr, c.F_OK) != 0) : (waited += 1) {
            if (waited > 100) return fail("private mux socket never appeared", .{});
            _ = c.usleep(50_000);
        }
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
    {
        const pid = c.fork();
        if (pid < 0) return fail("fork", .{});
        if (pid == 0) {
            platform.dieWithParent();
            _ = c.setenv("SKETERM_APP_ID", "dev.sker.sketerm.dragoutsmoke", 1);
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
    }
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
    app.resizeWindow(g_win, 1000, 700) catch return fail("sizing the window", .{});
    pumpFor(app, 1000);

    // ── the probe window ──────────────────────────────────────────
    if (probe(app, true)) |p| p.deinit() else return fail("dnd-probe refused", .{});
    {
        const t0 = clock.nowMs();
        while (g_probe == 0) {
            pumpFor(app, 200);
            for (app.windows.items) |w| {
                if (w.popup or w.w <= 0 or w.id == g_win) continue;
                if (w.title) |t| if (std.mem.eql(u8, t, "sketerm-dnd-probe")) {
                    g_probe = w.id;
                };
            }
            if (clock.nowMs() - t0 > 20_000) return fail("the probe window never appeared", .{});
        }
    }
    say("probe window {d} is up next to window {d}", .{ g_probe, g_win });

    // ── 1. a local file ───────────────────────────────────────────
    browserAt(app, local_dir) orelse return fail("browser-here refused the local folder", .{});
    {
        const p = dragTo(app, LOCAL_NAME, .external, 20_000) orelse return fail("local external drop never answered", .{});
        defer p.deinit();
        const r = p.value.probe.external;
        if (!std.mem.eql(u8, r.state, "done")) return fail("local external drop: {s} ({s})", .{ r.state, r.err });
        say("local external drop read {s}: {s}", .{ r.mime, std.mem.trimEnd(u8, r.data, "\r\n") });
        if (std.mem.indexOf(u8, r.data, "%20") == null or std.mem.indexOf(u8, r.data, "%23") == null or std.mem.indexOf(u8, r.data, "%C3%A9") == null)
            return fail("the URI is not percent-encoded: {s}", .{r.data});
        const path = singlePath(r.data) orelse return fail("not exactly one CRLF-terminated file:// URI: {s}", .{r.data});
        defer allocator.free(path);
        var want_buf: [400]u8 = undefined;
        const want = std.fmt.bufPrint(&want_buf, "{s}/{s}", .{ local_dir, LOCAL_NAME }) catch return fail("path", .{});
        if (!std.mem.eql(u8, path, want)) return fail("a local file must be handed out in place, got {s}", .{path});
        if (expectContent(path, LOCAL_BODY)) |why| return fail("local: {s}", .{why});
        if (p.value.probe.fetches != 0) return fail("a local drag started {d} fetches", .{p.value.probe.fetches});
    }
    say("PASS a local file leaves as its own percent-encoded file:// URI", .{});
    {
        const p = dragTo(app, LOCAL_NAME, .internal, 20_000) orelse return fail("local internal drop never answered", .{});
        defer p.deinit();
        const r = p.value.probe.internal;
        if (!std.mem.eql(u8, r.mime, "SketermDragSpecs")) return fail("sketerm's own targets got {s} instead of the specs flavor", .{r.mime});
        var want_buf: [400]u8 = undefined;
        const want = std.fmt.bufPrint(&want_buf, "'{s}/{s}'", .{ local_dir, LOCAL_NAME }) catch return fail("path", .{});
        if (!std.mem.eql(u8, r.data, want)) return fail("in-sketerm drop text {s}, want {s}", .{ r.data, want });
    }
    say("PASS a sketerm target still gets the quoted spec", .{});

    // ── 2. a remote file ──────────────────────────────────────────
    var spec_buf: [300]u8 = undefined;
    const remote_spec = std.fmt.bufPrint(&spec_buf, HOST ++ ":{s}", .{remote_dir}) catch return fail("spec", .{});
    browserAt(app, remote_spec) orelse return fail("browser-here refused the remote folder", .{});
    {
        const p = dragTo(app, REMOTE_NAME, .internal, 30_000) orelse return fail("remote internal drop never answered", .{});
        defer p.deinit();
        const r = p.value.probe.internal;
        if (!std.mem.eql(u8, r.mime, "SketermDragSpecs")) return fail("remote: sketerm's own targets got {s}", .{r.mime});
        var want_buf: [400]u8 = undefined;
        const want = std.fmt.bufPrint(&want_buf, "'" ++ HOST ++ ":{s}/{s}'", .{ remote_dir, REMOTE_NAME }) catch return fail("path", .{});
        if (!std.mem.eql(u8, r.data, want)) return fail("remote in-sketerm drop text {s}, want {s}", .{ r.data, want });
        if (p.value.probe.fetches != 0) return fail("a drop on a sketerm target fetched the remote file", .{});
    }
    say("PASS a remote drop on a sketerm target fetches nothing", .{});
    var staged_file: [512]u8 = undefined;
    var staged_len: usize = 0;
    {
        const p = dragTo(app, REMOTE_NAME, .external, 90_000) orelse return fail("remote external drop never answered", .{});
        defer p.deinit();
        const r = p.value.probe.external;
        if (!std.mem.eql(u8, r.state, "done")) return fail("remote external drop: {s} ({s})", .{ r.state, r.err });
        say("remote external drop read {s}: {s}", .{ r.mime, std.mem.trimEnd(u8, r.data, "\r\n") });
        const path = singlePath(r.data) orelse return fail("not exactly one file:// URI: {s}", .{r.data});
        defer allocator.free(path);
        var root_buf: [300]u8 = undefined;
        const root = std.fmt.bufPrint(&root_buf, "{s}/sketerm/dnd/drag-", .{cache}) catch return fail("path", .{});
        if (!std.mem.startsWith(u8, path, root)) return fail("the staged copy is not under the drag cache: {s}", .{path});
        if (!std.mem.eql(u8, std.fs.path.basename(path), REMOTE_NAME)) return fail("the staged copy lost its name: {s}", .{path});
        if (expectContent(path, REMOTE_BODY)) |why| return fail("remote: {s}", .{why});
        if (p.value.probe.fetches != 1) return fail("expected exactly one fetch, saw {d}", .{p.value.probe.fetches});
        @memcpy(staged_file[0..path.len], path);
        staged_len = path.len;
    }
    say("PASS a remote file is fetched on request and leaves as a staged file:// URI", .{});
    {
        const p = dragTo(app, REMOTE_NAME, .external, 30_000) orelse return fail("second remote drop never answered", .{});
        defer p.deinit();
        const r = p.value.probe.external;
        if (!std.mem.eql(u8, r.state, "done")) return fail("second remote drop: {s} ({s})", .{ r.state, r.err });
        const path = singlePath(r.data) orelse return fail("second drop URI: {s}", .{r.data});
        defer allocator.free(path);
        if (!std.mem.eql(u8, path, staged_file[0..staged_len])) return fail("the unchanged file was fetched again: {s}", .{path});
        if (p.value.probe.fetches != 1) return fail("the re-drag started a fetch ({d} total)", .{p.value.probe.fetches});
    }
    say("PASS a re-drag of the unchanged file reuses the staged copy", .{});

    // ── 3. a remote directory, recursively ────────────────────────
    {
        const p = dragTo(app, "rdir", .external, 90_000) orelse return fail("directory drop never answered", .{});
        defer p.deinit();
        const r = p.value.probe.external;
        if (!std.mem.eql(u8, r.state, "done")) return fail("directory drop: {s} ({s})", .{ r.state, r.err });
        const path = singlePath(r.data) orelse return fail("directory URI: {s}", .{r.data});
        defer allocator.free(path);
        if (!std.mem.eql(u8, std.fs.path.basename(path), "rdir")) return fail("the staged directory lost its name: {s}", .{path});
        var f_buf: [600]u8 = undefined;
        if (expectContent(std.fmt.bufPrintSentinel(&f_buf, "{s}/a.txt", .{path}, 0) catch return fail("path", .{}), "aaa\n")) |why| return fail("rdir/a.txt: {s}", .{why});
        if (expectContent(std.fmt.bufPrintSentinel(&f_buf, "{s}/sub/b.txt", .{path}, 0) catch return fail("path", .{}), "bbb\n")) |why| return fail("rdir/sub/b.txt: {s}", .{why});
    }
    say("PASS a remote directory is staged whole, nested files included", .{});

    // ── 4. a fetch that fails ends the drop, it does not hang it ───
    {
        const gone = std.fmt.bufPrintSentinel(&p_buf, "{s}/{s}", .{ remote_dir, GONE_NAME }, 0) catch return fail("path", .{});
        // Unreadable on the host: still listed, but its copy fails
        // (permanently, so no automatic retry stretches the wait).
        if (c.chmod(gone.ptr, 0) != 0) return fail("chmod the unreadable file", .{});
        defer _ = c.chmod(gone.ptr, 0o644);
        const p = dragTo(app, GONE_NAME, .external, 90_000) orelse return fail("the failing drop never answered", .{});
        defer p.deinit();
        const r = p.value.probe.external;
        // DnD has no error channel: a provider that fails its write
        // closes the pipe, and every receiver reads an empty offer.
        if (std.mem.eql(u8, r.state, "done") and r.data.len != 0)
            return fail("an unreadable remote file was handed out anyway: {s}", .{r.data});
        if (p.value.probe.fetches != 3) return fail("expected the unreadable file's fetch to be the third, saw {d}", .{p.value.probe.fetches});
        say("PASS a failed fetch ends the drop empty ({s}{s})", .{ r.state, if (r.err.len > 0) r.err else "" });
    }

    // ── 5. clipboard: a local copy ────────────────────────────────
    // "local:" -- a bare path would stay on the tab's current host, rbox.
    var local_spec_buf: [300]u8 = undefined;
    const local_spec = std.fmt.bufPrint(&local_spec_buf, "local:{s}", .{local_dir}) catch return fail("spec", .{});
    browserAt(app, local_spec) orelse return fail("browser-here refused the local folder", .{});
    {
        var want_buf: [400]u8 = undefined;
        const want = std.fmt.bufPrint(&want_buf, "{s}/{s}", .{ local_dir, LOCAL_NAME }) catch return fail("path", .{});
        clipRow(app, LOCAL_NAME, "ctrl+c", want) orelse return fail("Ctrl+C on the local file never reached the clipboard", .{});
        const uris = readClip(app, "text/uri-list", 20_000) orelse return fail("reading the local copy's text/uri-list", .{});
        defer allocator.free(uris);
        say("local copy text/uri-list: {s}", .{std.mem.trimEnd(u8, uris, "\r\n")});
        if (std.mem.indexOf(u8, uris, "%20") == null or std.mem.indexOf(u8, uris, "%23") == null or std.mem.indexOf(u8, uris, "%C3%A9") == null)
            return fail("the copied URI is not percent-encoded: {s}", .{uris});
        const path = singlePath(uris) orelse return fail("not exactly one CRLF-terminated file:// URI: {s}", .{uris});
        defer allocator.free(path);
        if (!std.mem.eql(u8, path, want)) return fail("a local copy must name the file in place, got {s}", .{path});
        if (expectContent(path, LOCAL_BODY)) |why| return fail("local copy: {s}", .{why});
        const gnome = readClip(app, "x-special/gnome-copied-files", 20_000) orelse return fail("reading GNOME copied-files", .{});
        defer allocator.free(gnome);
        var g_buf: [600]u8 = undefined;
        const want_gnome = std.fmt.bufPrint(&g_buf, "copy\n{s}", .{uris[0 .. uris.len - 2]}) catch return fail("path", .{});
        if (!std.mem.eql(u8, gnome, want_gnome)) return fail("GNOME copied-files {s}, want {s}", .{ gnome, want_gnome });
        const kde = readClip(app, "application/x-kde-cutselection", 20_000) orelse return fail("reading the KDE cut flag", .{});
        defer allocator.free(kde);
        if (!std.mem.eql(u8, kde, "0")) return fail("a copy announced KDE cut flag {s}", .{kde});
        if (fetchCount(app) != 3) return fail("a local copy started a fetch", .{});
    }
    say("PASS a local copy pastes elsewhere as its own file (CRLF URI list, GNOME, KDE)", .{});

    // ── 6. clipboard: a remote copy, fetched only for a file read ──
    browserAt(app, remote_spec) orelse return fail("browser-here refused the remote folder", .{});
    {
        var want_buf: [400]u8 = undefined;
        const want = std.fmt.bufPrint(&want_buf, "{s}/{s}", .{ remote_dir, CLIP_NAME }) catch return fail("path", .{});
        clipRow(app, CLIP_NAME, "ctrl+c", want) orelse return fail("Ctrl+C on the remote file never reached the clipboard", .{});
        // Copying, and reading the path text, fetch nothing.
        pumpFor(app, 1500);
        if (fetchCount(app) != 3) return fail("copying a remote file fetched it before anyone asked for files", .{});
        const uris = readClip(app, "text/uri-list", 90_000) orelse return fail("reading the remote copy's text/uri-list", .{});
        defer allocator.free(uris);
        say("remote copy text/uri-list: {s}", .{std.mem.trimEnd(u8, uris, "\r\n")});
        const path = singlePath(uris) orelse return fail("remote copy: not exactly one CRLF file:// URI: {s}", .{uris});
        defer allocator.free(path);
        var root_buf: [300]u8 = undefined;
        const root = std.fmt.bufPrint(&root_buf, "{s}/sketerm/dnd/drag-", .{cache}) catch return fail("path", .{});
        if (!std.mem.startsWith(u8, path, root)) return fail("the pasted copy is not a staged one: {s}", .{path});
        if (!std.mem.eql(u8, std.fs.path.basename(path), CLIP_NAME)) return fail("the staged copy lost its name: {s}", .{path});
        if (expectContent(path, CLIP_BODY)) |why| return fail("remote copy: {s}", .{why});
        if (fetchCount(app) != 4) return fail("expected the copy's first file read to fetch once, saw {d} fetches", .{fetchCount(app)});
        // A second reader (GNOME's type) gets the same staged file.
        const gnome = readClip(app, "x-special/gnome-copied-files", 20_000) orelse return fail("reading GNOME copied-files", .{});
        defer allocator.free(gnome);
        if (!std.mem.startsWith(u8, gnome, "copy\n") or !std.mem.eql(u8, gnome[5..], uris[0 .. uris.len - 2]))
            return fail("GNOME copied-files {s} disagrees with the URI list", .{gnome});
        if (fetchCount(app) != 4) return fail("a second read of the same copy fetched again", .{});
    }
    say("PASS a remote copy is fetched when a receiver reads files, once", .{});

    // ── 7. sketerm's own paste of that copy stages nothing ─────────
    browserAt(app, local_spec) orelse return fail("browser-here refused the local folder", .{});
    {
        const dirs_before = stagingDirs(cache);
        const row = findRow(app, LOCAL_NAME, 15_000) orelse return fail("no local row to focus", .{});
        app.click(g_win, row.x, row.y, 1) catch return fail("click", .{});
        pumpFor(app, 300);
        app.pressKey(g_win, "ctrl+v") catch return fail("Ctrl+V", .{});
        var dst_buf: [400]u8 = undefined;
        const dst = std.fmt.bufPrintSentinel(&dst_buf, "{s}/{s}", .{ local_dir, CLIP_NAME }, 0) catch return fail("path", .{});
        const t0 = clock.nowMs();
        while (expectContent(dst, CLIP_BODY) != null) {
            if (clock.nowMs() - t0 > 60_000) return fail("sketerm's own paste never produced {s}", .{dst});
            pumpFor(app, 250);
        }
        if (fetchCount(app) != 4) return fail("sketerm's own paste started a staging fetch", .{});
        if (stagingDirs(cache) != dirs_before) return fail("sketerm's own paste created a staging directory", .{});
    }
    say("PASS sketerm's own paste transfers host to host and stages nothing", .{});

    // ── 8. a remote cut reaches other apps as a copy ───────────────
    browserAt(app, remote_spec) orelse return fail("browser-here refused the remote folder", .{});
    {
        var want_buf: [400]u8 = undefined;
        const want = std.fmt.bufPrint(&want_buf, "{s}/{s}", .{ remote_dir, CUT_NAME }) catch return fail("path", .{});
        clipRow(app, CUT_NAME, "ctrl+x", want) orelse return fail("Ctrl+X on the remote file never reached the clipboard", .{});
        const gnome = readClip(app, "x-special/gnome-copied-files", 90_000) orelse return fail("reading the cut's GNOME copied-files", .{});
        defer allocator.free(gnome);
        say("remote cut x-special/gnome-copied-files: {s}", .{gnome});
        if (!std.mem.startsWith(u8, gnome, "copy\nfile://")) return fail("a remote cut must reach other apps as a copy: {s}", .{gnome});
        const kde = readClip(app, "application/x-kde-cutselection", 20_000) orelse return fail("reading the KDE cut flag", .{});
        defer allocator.free(kde);
        if (!std.mem.eql(u8, kde, "0")) return fail("a remote cut announced KDE cut flag {s}", .{kde});
        const uris = readClip(app, "text/uri-list", 20_000) orelse return fail("reading the cut's text/uri-list", .{});
        defer allocator.free(uris);
        const path = singlePath(uris) orelse return fail("remote cut URI: {s}", .{uris});
        defer allocator.free(path);
        if (expectContent(path, CUT_BODY)) |why| return fail("remote cut staged copy: {s}", .{why});
        // What a file manager does with a cut: take the file it was given.
        if (c.unlink(path.ptr) != 0) return fail("removing the staged copy as a mover would", .{});
        pumpFor(app, 2000);
        var orig_buf: [400]u8 = undefined;
        const orig = std.fmt.bufPrintSentinel(&orig_buf, "{s}/{s}", .{ remote_dir, CUT_NAME }, 0) catch return fail("path", .{});
        if (expectContent(orig, CUT_BODY)) |why| return fail("the cut's remote original: {s}", .{why});
        if (fetchCount(app) != 5) return fail("expected one fetch for the cut, saw {d} total", .{fetchCount(app)});
    }
    say("PASS a remote cut pasted elsewhere hands over a copy and keeps the original", .{});

    // ── 9. over the clipboard cap: the path, never a download ──────
    {
        var want_buf: [400]u8 = undefined;
        const want = std.fmt.bufPrint(&want_buf, "{s}/{s}", .{ remote_dir, BIG_NAME }) catch return fail("path", .{});
        clipRow(app, BIG_NAME, "ctrl+c", want) orelse return fail("Ctrl+C on the big file never reached the clipboard", .{});
        for ([_][]const u8{ "text/uri-list", "x-special/gnome-copied-files" }) |mime| {
            const got = readClip(app, mime, 20_000) orelse return fail("reading {s} of the big copy", .{mime});
            defer allocator.free(got);
            if (got.len != 0) return fail("a copy over the cap offered {s}: {s}", .{ mime, got });
        }
        pumpFor(app, 1000);
        if (fetchCount(app) != 5) return fail("a copy over the cap fetched", .{});
    }
    say("PASS a remote copy over the cap reaches other apps as its path only", .{});

    say("PASS: dragged and copied files reach other applications as files, local and remote", .{});
    teardown();
    return 0;
}

/// Point pane 1's file view at `spec` and let it list.
fn browserAt(app: *appdrive.App, spec: []const u8) ?void {
    var req_buf: [512]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"browser-here\",\"pane\":1,\"data\":\"{s}\"}}\n", .{spec}) catch return null;
    const r = ctlsock.roundtrip(g_alloc, app, g_gui_sock, req) orelse return null;
    defer g_alloc.free(r);
    if (std.mem.indexOf(u8, r, "\"ok\":true") == null) {
        say("browser-here: {s}", .{r});
        return null;
    }
    pumpFor(app, 2000);
}

/// The GUI's selection in `mime`, read as another client would. Caller frees.
fn readClip(app: *appdrive.App, mime: []const u8, timeout_ms: i64) ?[]u8 {
    return app.getClipboardMime(mime, timeout_ms) catch |err| {
        say("clipboard read of {s}: {s}", .{ mime, @errorName(err) });
        return null;
    };
}

/// Select the row named `name`, press `chord`, and wait until the GUI's
/// selection reads as `text` (the copy's path text).
fn clipRow(app: *appdrive.App, name: []const u8, chord: []const u8, text: []const u8) ?void {
    var attempt: u32 = 0;
    while (attempt < 2) : (attempt += 1) {
        const row = findRow(app, name, 15_000) orelse {
            say("no row named '{s}' in the listing", .{name});
            return null;
        };
        app.click(g_win, row.x, row.y, 1) catch return null;
        pumpFor(app, 300);
        say("{s} on '{s}'", .{ chord, name });
        app.pressKey(g_win, chord) catch return null;
        const t0 = clock.nowMs();
        while (clock.nowMs() - t0 < 5_000) {
            pumpFor(app, 200);
            const got = app.getClipboardMime("text/plain;charset=utf-8", 5_000) catch continue;
            defer g_alloc.free(got);
            if (std.mem.eql(u8, got, text)) return;
        }
    }
    return null;
}

fn fetchCount(app: *appdrive.App) u64 {
    const p = probe(app, false) orelse return std.math.maxInt(u64);
    defer p.deinit();
    return p.value.probe.fetches;
}

/// Staging directories under the drag cache root.
fn stagingDirs(cache: [:0]const u8) usize {
    var buf: [300]u8 = undefined;
    const root = std.fmt.bufPrintSentinel(&buf, "{s}/sketerm/dnd", .{cache}, 0) catch return 0;
    const d = c.opendir(root.ptr) orelse return 0;
    defer _ = c.closedir(d);
    var n: usize = 0;
    while (c.readdir(d)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
        if (std.mem.startsWith(u8, name, "drag-")) n += 1;
    }
    return n;
}

/// Remove the sandbox once the GUI's FUSE mount of the fake host (made
/// when the file view entered `rbox:`) has gone: its helper exits after
/// the GUI and would otherwise leave its mountpoint behind.
fn removeSandbox(rt: [:0]const u8) void {
    const t0 = clock.nowMs();
    while (clock.nowMs() - t0 < 5_000) {
        const mounts = readFile("/proc/mounts") orelse break;
        defer g_alloc.free(mounts);
        if (std.mem.indexOf(u8, mounts, rt) == null) break;
        _ = c.usleep(100_000);
    }
    // The helper may still be creating its mountpoint as it exits.
    _ = c.usleep(300_000);
    @import("util/pathz.zig").removeTree(rt);
}
