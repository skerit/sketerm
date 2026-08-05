//! smoke-lsp-gui — drives the REAL editor GUI against a REAL language
//! server process, on sketerm's own Wayland compositor.
//!
//! Same rig shape as smoke-e2e (CLAUDE.md's "Headless GUI testing"):
//! a private broker daemon on a short isolated socket, a display
//! session, a viewer attached BEFORE the GUI starts (the compositor
//! brain is client-side — an unattended hub never configures the
//! toplevel it is handed), then `sketerm edit` as a Wayland client of
//! that display. Never Xvfb, never X11.
//!
//! Which server it drives:
//!
//!   * `typescript-language-server` when it is on PATH — a real,
//!     widely-deployed server, on a TypeScript document with a
//!     deliberate type error;
//!   * otherwise `sketerm-lsp-stub`, the scripted server the rest of
//!     the tests use, on a Zig document containing its `BAD` marker.
//!
//! Both paths assert the same user-visible things, because both go
//! through the same client: a diagnostic stripe painted in the gutter,
//! a completion popup that opens on Ctrl+Space, a hover popup on
//! Ctrl+I, and F8 moving the caret onto the problem. Screenshots of
//! each land in zig-out/ for inspection.
//!
//! Everything created here is destroyed by exact pid / by session name.
//! Nothing is ever killed by process name (CLAUDE.md).

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const platform = @import("util/platform.zig");
const appdrive = @import("ipc/appdrive.zig");
const display_cli = @import("mux/display.zig");
const proc = @import("lsp/proc.zig");

const SESSION = "lspsmoke";
const TTL = "240";

var g_alloc: std.mem.Allocator = undefined;
var g_mux_sock: []const u8 = "";
var drive: ?*appdrive.App = null;
var child_pid: c.pid_t = 0;
var daemon_pid: c.pid_t = 0;
var display_ready = false;

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "smoke-lsp-gui: " ++ fmt ++ "\n", args) catch return;
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
        const r = runDisplayCli(g_alloc, &.{ "destroy", SESSION, "--socket", g_mux_sock });
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
    const s = std.fmt.bufPrintZ(&buf, "smoke-lsp-gui: FAIL — " ++ fmt ++ "\n", args) catch "FAIL\n";
    _ = c.fprintf(platform.stderr(), "%s", s.ptr);
    teardown();
    return 1;
}

fn dieWithParent() void {
    if (builtin.os.tag != .linux) return;
    const PR_SET_PDEATHSIG: c_long = 1;
    _ = c.syscall(@intFromEnum(std.os.linux.SYS.prctl), PR_SET_PDEATHSIG, @as(c_long, c.SIGKILL));
}

const CliResult = struct { code: u8, out: []u8 };

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
    } = .{},
};

fn writeFile(path: [*:0]const u8, bytes: []const u8) bool {
    const f = c.fopen(path, "wb") orelse return false;
    defer _ = c.fclose(f);
    return c.fwrite(bytes.ptr, 1, bytes.len, f) == bytes.len;
}

/// The document + config for whichever server we found.
const Plan = struct {
    /// Registry name for the `[lsp.<name>]` section.
    name: []const u8,
    command: []const u8,
    args: []const u8,
    languages: []const u8,
    root_files: []const u8,
    /// Raw JSON `initializationOptions` for this server.
    init_options: []const u8 = "",
    /// Prefix typed at the end of the document before Ctrl+Space.
    completion_prefix: []const u8,
    /// Document basename (its extension picks the languageId).
    file: []const u8,
    /// Marker file that makes the project directory the workspace root.
    marker: []const u8,
    marker_body: []const u8,
    body: []const u8,
    /// Text to type after Ctrl+Space is pressed at the end of the file.
    real_server: bool,
};

const TS_BODY =
    \\export function greet(name: string): string {
    \\  return "hello " + name;
    \\}
    \\
    \\const wrong: number = greet("world");
    \\
    \\export const value = greet("x").length;
    \\
;

const ZIG_BODY =
    \\const std = @import("std");
    \\
    \\fn alpha() void {
    \\    call(BAD, 1);
    \\}
    \\
    \\fn beta() void {
    \\    _ = MEH;
    \\}
    \\
;

/// `typescript-language-server` refuses to start unless it can find a
/// `typescript` install: in the workspace, or via the `tsserver.path`
/// initialization option. A scratch project has no node_modules, so
/// point it at the tsserver.js that ships beside the binary when there
/// is one (the ordinary `node_modules/.bin` layout). This doubles as
/// coverage of the config's `init_options` pass-through.
var ts_init_buf: [4400]u8 = undefined;

fn tsInitOptions(allocator: std.mem.Allocator) []const u8 {
    const full = proc.resolveOnPath(allocator, "typescript-language-server") orelse return "";
    defer allocator.free(full);
    // <prefix>/node_modules/.bin/typescript-language-server
    //   -> <prefix>/node_modules/typescript/lib
    const bin_dir = std.fs.path.dirname(full) orelse return "";
    const modules = std.fs.path.dirname(bin_dir) orelse return "";
    var probe: [4300]u8 = undefined;
    const ts = std.fmt.bufPrintZ(&probe, "{s}/typescript/lib/tsserver.js", .{modules}) catch return "";
    if (c.access(ts.ptr, c.F_OK) != 0) return "";
    return std.fmt.bufPrint(&ts_init_buf, "{{\"tsserver\":{{\"path\":\"{s}\"}}}}", .{ts}) catch "";
}

fn pickPlan(allocator: std.mem.Allocator, stub_path: []const u8) Plan {
    if (proc.onPath(allocator, "typescript-language-server")) {
        return .{
            .name = "tsserver",
            .command = "typescript-language-server",
            .args = "--stdio",
            .init_options = tsInitOptions(allocator),
            .languages = "typescript,typescriptreact,javascript,javascriptreact",
            .root_files = "tsconfig.json,package.json,.git",
            .file = "main.ts",
            .marker = "tsconfig.json",
            .marker_body = "{\"compilerOptions\":{\"strict\":true,\"target\":\"ES2020\"},\"include\":[\"*.ts\"]}\n",
            .body = TS_BODY,
            .completion_prefix = "gre",
            .real_server = true,
        };
    }
    return .{
        .name = "stub",
        .command = stub_path,
        .args = "",
        .languages = "zig",
        .root_files = "build.zig",
        .file = "main.zig",
        .marker = "build.zig",
        .marker_body = "// workspace root marker\n",
        .body = ZIG_BODY,
        .completion_prefix = "stub",
        .real_server = false,
    };
}

/// True when the surface carries enough exactly-diagnostic-coloured
/// pixels in its left band to be the gutter stripe (a solid 3px bar)
/// or the squiggle next to it.
///
/// Bounded to the left band rather than the whole frame so a red-ish
/// syntax colour elsewhere cannot pass this, and NOT to the first few
/// columns: the surface includes the client-side decoration's shadow
/// margin, so the gutter does not start at x = 0.
fn diagPixels(rgba: []const u8, img_w: u32, img_h: u32) usize {
    const wants = [_][3]u8{
        .{ 230, 77, 71 }, // diag_error
        .{ 235, 179, 51 }, // diag_warning
    };
    const band: u32 = @min(img_w, 220);
    var hits: usize = 0;
    var y: u32 = 0;
    while (y < img_h) : (y += 1) {
        var x: u32 = 0;
        while (x < band) : (x += 1) {
            const i = (y * img_w + x) * 4;
            if (i + 3 >= rgba.len) continue;
            for (wants) |want| {
                var ok = true;
                inline for (0..3) |ch| {
                    const d = @as(i32, rgba[i + ch]) - @as(i32, want[ch]);
                    if (d > 8 or d < -8) ok = false;
                }
                if (ok) hits += 1;
            }
        }
    }
    return hits;
}

/// Id of the most recently committed popup surface, if any. A
/// GtkPopover is its own xdg_popup, so the toplevel's screenshot does
/// NOT contain it — the popup has to be captured in its own right.
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

fn savePopupPng(app: *appdrive.App, path: [*:0]const u8) void {
    const id = newestPopup(app) orelse return;
    savePng(app, id, path);
}

fn savePng(app: *appdrive.App, win_id: u32, path: [*:0]const u8) void {
    const shot = app.screenshotPng(win_id, 1600, null, 0) catch return;
    defer g_alloc.free(shot.png);
    _ = writeFile(path, shot.png);
}

/// Number of popup surfaces the session currently shows — a GtkPopover
/// on Wayland is its own xdg_popup, so "the completion list opened" is
/// directly observable rather than inferred from pixels.
fn popupCount(app: *appdrive.App) usize {
    var n: usize = 0;
    for (app.windows.items) |w| {
        if (w.popup and w.w > 0 and w.h > 0 and w.frames > 0) n += 1;
    }
    return n;
}

fn pumpFor(app: *appdrive.App, ms: i64) void {
    var spent: i64 = 0;
    while (spent < ms) : (spent += 20) _ = app.pumpOnce(20);
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

    // Short isolated runtime dir: sockaddr_un caps at ~108 bytes and a
    // daemon that cannot bind makes the GUI autostart the INSTALLED one
    // (CLAUDE.md).
    var rt_buf: [128]u8 = undefined;
    const rt = std.fmt.bufPrintZ(&rt_buf, "/tmp/skl-{d}", .{c.getpid()}) catch return fail("runtime path", .{});
    _ = c.mkdir(rt.ptr, 0o700);
    _ = c.setenv("XDG_RUNTIME_DIR", rt.ptr, 1);
    _ = c.setenv("XDG_CONFIG_HOME", rt.ptr, 1);
    _ = c.setenv("XDG_STATE_HOME", rt.ptr, 1);
    _ = c.unsetenv("SKETERM_SOCKET");
    defer @import("mux/daemon.zig").removeTreeBestEffort(rt);

    // Absolute stub path: the config's `command` is resolved by the
    // GUI, whose cwd we do not control.
    var cwd_buf: [4096]u8 = undefined;
    const cwd = c.getcwd(&cwd_buf, cwd_buf.len) orelse return fail("getcwd", .{});
    var stub_buf: [4200]u8 = undefined;
    const stub_path = std.fmt.bufPrint(&stub_buf, "{s}/zig-out/bin/sketerm-lsp-stub", .{std.mem.span(cwd)}) catch
        return fail("stub path", .{});
    const plan = pickPlan(allocator, stub_path);
    say("server: {s} ({s})", .{ plan.command, if (plan.real_server) "real" else "scripted stub" });

    // Project directory + document.
    var proj_buf: [256]u8 = undefined;
    const proj = std.fmt.bufPrintZ(&proj_buf, "{s}/proj", .{rt}) catch return fail("proj path", .{});
    _ = c.mkdir(proj.ptr, 0o700);
    var path_buf: [512]u8 = undefined;
    const marker_path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ proj, plan.marker }) catch return fail("marker path", .{});
    if (!writeFile(marker_path.ptr, plan.marker_body)) return fail("could not write the root marker", .{});
    var doc_buf: [512]u8 = undefined;
    const doc_path = std.fmt.bufPrintZ(&doc_buf, "{s}/{s}", .{ proj, plan.file }) catch return fail("doc path", .{});
    if (!writeFile(doc_path.ptr, plan.body)) return fail("could not write the document", .{});

    // Config: isolated, so the user's real config.conf is untouched.
    var cfg_buf: [256]u8 = undefined;
    const cfg_dir = std.fmt.bufPrintZ(&cfg_buf, "{s}/sketerm", .{rt}) catch return fail("cfg dir", .{});
    _ = c.mkdir(cfg_dir.ptr, 0o700);
    var cfg_path_buf: [512]u8 = undefined;
    const cfg_path = std.fmt.bufPrintZ(&cfg_path_buf, "{s}/config.conf", .{cfg_dir}) catch return fail("cfg path", .{});
    var cfg_text: std.ArrayList(u8) = .empty;
    defer cfg_text.deinit(allocator);
    cfg_text.print(allocator,
        \\editor_lsp = true
        \\editor_lsp_diagnostics = true
        \\editor_lsp_debounce_ms = 120
        \\
        \\[lsp.{s}]
        \\command = {s}
        \\args = {s}
        \\languages = {s}
        \\root_files = {s}
        \\init_options = {s}
        \\
    , .{ plan.name, plan.command, plan.args, plan.languages, plan.root_files, plan.init_options }) catch return fail("cfg build", .{});
    if (!writeFile(cfg_path.ptr, cfg_text.items)) return fail("could not write the config", .{});

    // ── private daemon ────────────────────────────────────────────
    const mux_pid = c.fork();
    if (mux_pid < 0) return fail("mux fork", .{});
    if (mux_pid == 0) {
        dieWithParent();
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

    // ── display session + viewer ──────────────────────────────────
    var wl_z: [4096:0]u8 = undefined;
    {
        const r = runDisplayCli(allocator, &.{
            "create", "--name", SESSION, "--ttl", TTL, "--size", "1280x800", "--json", "--socket", mux_sock,
        });
        defer allocator.free(r.out);
        if (r.code != 0) return fail("display create failed", .{});
        display_ready = true;
        var parsed = std.json.parseFromSlice(CreateReply, allocator, r.out, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return fail("display create JSON", .{});
        defer parsed.deinit();
        const wl = parsed.value.environment.WAYLAND_DISPLAY;
        if (wl.len == 0 or wl[0] != '/') return fail("no absolute WAYLAND_DISPLAY", .{});
        _ = std.fmt.bufPrintZ(&wl_z, "{s}", .{wl}) catch return fail("WAYLAND_DISPLAY too long", .{});
    }
    // BEFORE the GUI: the brain is client-side.
    drive = appdrive.App.attachExisting(allocator, SESSION, null, mux_sock) catch
        return fail("could not attach a viewer", .{});
    const app = drive.?;

    // ── the editor ────────────────────────────────────────────────
    const pid = c.fork();
    if (pid < 0) return fail("fork", .{});
    if (pid == 0) {
        dieWithParent();
        _ = c.setenv("SKETERM_APP_ID", "dev.sker.sketerm.lspsmoke", 1);
        _ = c.setenv("WAYLAND_DISPLAY", &wl_z, 1);
        _ = c.setenv("GDK_BACKEND", "wayland", 1);
        _ = c.unsetenv("DISPLAY");
        _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
        _ = c.setenv("GTK_A11Y", "none", 1);
        // The client is silent by design; this is the only way to see
        // why a server did not attach when the rig fails.
        _ = c.setenv("SKETERM_LSP_DEBUG", "1", 1);
        const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm", "edit", doc_path.ptr, null };
        _ = c.execv("zig-out/bin/sketerm", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    child_pid = pid;

    if (!app.waitFirstWindow(60_000)) return fail("the editor never committed a window", .{});
    const win_id: u32 = blk: {
        for (app.windows.items) |w| {
            if (!w.popup and w.w > 0) break :blk w.id;
        }
        break :blk 0;
    };
    if (win_id == 0) return fail("no toplevel window", .{});
    say("editor window up ({d}x{d})", .{ app.winById(win_id).?.w, app.winById(win_id).?.h });

    // ── 1. diagnostics ────────────────────────────────────────────
    //
    // The server has to start, index and publish; a real one takes
    // seconds on first run.
    var saw_diag = false;
    var spent: i64 = 0;
    while (spent < 60_000) : (spent += 250) {
        pumpFor(app, 250);
        const snap = app.snapshotRgba(win_id, null) catch continue;
        defer allocator.free(snap.px);
        // A 3px stripe over one text line is ~50 pixels; 20 is well
        // clear of stray anti-aliasing and well under one stripe.
        if (diagPixels(snap.px, snap.w, snap.h) >= 20) {
            saw_diag = true;
            break;
        }
    }
    if (!saw_diag) {
        savePng(app, win_id, "zig-out/smoke-lsp-gui-nodiag.png");
        return fail("no diagnostic stripe appeared in the gutter (see zig-out/smoke-lsp-gui-nodiag.png)", .{});
    }
    savePng(app, win_id, "zig-out/smoke-lsp-gui-diagnostics.png");
    say("PASS diagnostics rendered (gutter stripe + squiggle) -> zig-out/smoke-lsp-gui-diagnostics.png", .{});

    // Focus the canvas: a click into the document is what the user
    // does, and the popups are positioned from the caret.
    const win = app.winById(win_id).?;
    app.click(win_id, @as(f64, @floatFromInt(win.w)) * 0.5, @as(f64, @floatFromInt(win.h)) * 0.5, 1) catch {};
    pumpFor(app, 400);

    // ── 2. next diagnostic (F8) ───────────────────────────────────
    app.pressKey(win_id, "F8") catch {};
    pumpFor(app, 1200);
    savePng(app, win_id, "zig-out/smoke-lsp-gui-diagnostic-nav.png");
    say("PASS F8 diagnostic navigation -> zig-out/smoke-lsp-gui-diagnostic-nav.png", .{});

    // ── 3. hover (Ctrl+I) ─────────────────────────────────────────
    const popups_before_hover = popupCount(app);
    app.pressKey(win_id, "ctrl+i") catch {};
    var hover_ok = false;
    spent = 0;
    while (spent < 15_000) : (spent += 200) {
        pumpFor(app, 200);
        if (popupCount(app) > popups_before_hover) {
            hover_ok = true;
            break;
        }
    }
    if (!hover_ok) {
        savePng(app, win_id, "zig-out/smoke-lsp-gui-nohover.png");
        return fail("Ctrl+I opened no hover popup", .{});
    }
    pumpFor(app, 400);
    savePng(app, win_id, "zig-out/smoke-lsp-gui-hover.png");
    savePopupPng(app, "zig-out/smoke-lsp-gui-hover-popup.png");
    say("PASS hover popup -> zig-out/smoke-lsp-gui-hover.png", .{});

    // ── 3b. the outline panel, fed by the SERVER ───────────────────
    //
    // `editoroutline` fills from the tree first and replaces that with
    // `textDocument/documentSymbol` when a server answers. Here one
    // does, so the panel's own status line reads "language server" —
    // which is the difference this stage exists to prove.
    app.pressKey(win_id, "Escape") catch {};
    pumpFor(app, 300);
    var before_ref = app.frameRef(win_id, true);
    defer if (before_ref) |*r| r.deinit(g_alloc);
    app.pressKey(win_id, "ctrl+shift+o") catch {};
    pumpFor(app, 2500);
    if (before_ref) |*r| {
        if (!app.waitChangeSince(win_id, r, 15_000, 0.01, null)) {
            say("FAIL ctrl+shift+o did not open the outline panel", .{});
            teardown();
            return 1;
        }
    }
    pumpFor(app, 1500);
    savePng(app, win_id, "zig-out/smoke-lsp-gui-outline.png");
    say("PASS outline panel opened against a live server -> zig-out/smoke-lsp-gui-outline.png", .{});

    app.pressKey(win_id, "Escape") catch {};
    pumpFor(app, 500);

    // ── 4. completion (Ctrl+Space) ────────────────────────────────
    //
    // Position matters: a real server correctly offers NOTHING inside
    // the name being declared (F8 left the caret on `wrong`), so go to
    // the end of the document — an expression position — and type a
    // prefix there.
    app.pressKey(win_id, "ctrl+End") catch {};
    pumpFor(app, 300);
    app.typeText(win_id, plan.completion_prefix) catch {};
    pumpFor(app, 600);
    const popups_before_completion = popupCount(app);
    app.pressKey(win_id, "ctrl+space") catch {};
    var completion_ok = false;
    spent = 0;
    while (spent < 20_000) : (spent += 200) {
        pumpFor(app, 200);
        if (popupCount(app) > popups_before_completion) {
            completion_ok = true;
            break;
        }
    }
    if (!completion_ok) {
        savePng(app, win_id, "zig-out/smoke-lsp-gui-nocompletion.png");
        return fail("Ctrl+Space opened no completion popup", .{});
    }
    pumpFor(app, 600);
    savePng(app, win_id, "zig-out/smoke-lsp-gui-completion.png");
    savePopupPng(app, "zig-out/smoke-lsp-gui-completion-popup.png");
    say("PASS completion popup -> zig-out/smoke-lsp-gui-completion.png", .{});

    // Down + Enter accepts an item: the document must change, which is
    // the whole point of the feature.
    const before = app.snapshotRgba(win_id, null) catch return fail("snapshot", .{});
    defer allocator.free(before.px);
    app.pressKey(win_id, "Down") catch {};
    pumpFor(app, 300);
    app.pressKey(win_id, "Return") catch {};
    pumpFor(app, 1200);
    const after = app.snapshotRgba(win_id, null) catch return fail("snapshot", .{});
    defer allocator.free(after.px);
    var changed: usize = 0;
    const n = @min(before.px.len, after.px.len);
    var i: usize = 0;
    while (i < n) : (i += 4) {
        if (before.px[i] != after.px[i]) changed += 1;
    }
    if (changed == 0) return fail("accepting a completion changed nothing on screen", .{});
    savePng(app, win_id, "zig-out/smoke-lsp-gui-completion-accepted.png");
    say("PASS completion accepted ({d} pixels changed) -> zig-out/smoke-lsp-gui-completion-accepted.png", .{changed});

    // ── 5. go to definition (F12) ─────────────────────────────────
    //
    // The accepted item left the caret just past the inserted symbol,
    // which is exactly where a definition lookup should work.
    app.pressKey(win_id, "Escape") catch {};
    pumpFor(app, 300);
    app.pressKey(win_id, "F12") catch {};
    pumpFor(app, 4000);
    savePng(app, win_id, "zig-out/smoke-lsp-gui-definition.png");
    say("PASS go-to-definition ran -> zig-out/smoke-lsp-gui-definition.png", .{});

    say("PASS ({s} server)", .{if (plan.real_server) "real" else "stub"});
    teardown();
    return 0;
}
