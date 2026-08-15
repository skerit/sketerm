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
//! The battery runs TWICE: once on a local document, then again on a
//! REMOTE one (`rbox:/...`) — a fake-ssh script ($SKETERM_SSH) that
//! execs `sketerm-mux --proxy` into a second private daemon built from
//! THIS tree, which spawns the language server near the files and
//! relays its stdio as a byte channel (the smoke_e2e pattern: hermetic,
//! no passwordless ssh, asserts this build, cannot silently skip).
//! Remote screenshots carry a `-remote-` infix.
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

const TTL = "240";

var g_alloc: std.mem.Allocator = undefined;
var g_mux_sock: []const u8 = "";
var g_session: []const u8 = "lspsmoke";
/// "" on the local leg, "-remote" on the remote one — keeps both legs'
/// screenshots side by side in zig-out/.
var g_leg: []const u8 = "";
var drive: ?*appdrive.App = null;
var child_pid: c.pid_t = 0;
var daemon_pid: c.pid_t = 0;
/// The REMOTE leg's second private daemon (the fake-ssh target).
var remote_mux_pid: c.pid_t = 0;
var display_ready = false;

var g_shot_buf: [160:0]u8 = undefined;

/// "zig-out/smoke-lsp-gui[-remote]-<name>" in a static buffer (one
/// screenshot is saved at a time).
fn shot(comptime name: []const u8) [*:0]const u8 {
    const s = std.fmt.bufPrintZ(&g_shot_buf, "zig-out/smoke-lsp-gui{s}-" ++ name, .{g_leg}) catch unreachable;
    return s.ptr;
}

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
        const r = runDisplayCli(g_alloc, &.{ "destroy", g_session, "--socket", g_mux_sock });
        g_alloc.free(r.out);
        display_ready = false;
    }
    if (daemon_pid > 0) {
        _ = c.kill(daemon_pid, c.SIGTERM);
        var status: c_int = 0;
        _ = c.waitpid(daemon_pid, &status, 0);
        daemon_pid = 0;
    }
    if (remote_mux_pid > 0) {
        _ = c.kill(remote_mux_pid, c.SIGTERM);
        var status: c_int = 0;
        _ = c.waitpid(remote_mux_pid, &status, 0);
        remote_mux_pid = 0;
    }
    _ = c.unsetenv("SKETERM_SSH");
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
    /// Typed at the end of the document to make the server offer
    /// signature help — a call whose trigger character is the `(`.
    /// It must name a TWO-parameter function: the stage then types
    /// `signature_more` to step onto the second one, and a server
    /// correctly answers "no signatures" past the last parameter.
    signature_call: []const u8,
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
    \\export function pair(first: number, second: number): number {
    \\  return first + second;
    \\}
    \\
    \\export function greet(name: string): string {
    \\  return "hello " + name;
    \\}
    \\
    \\const wrong: number = greet("world");
    \\
    \\export const value = greet("x").length;
    \\
;

/// `SEM` is the semantic-token marker: no grammar gives that identifier
/// a colour of its own, and the stub tags it `property`, so the
/// property colour appearing on screen proves the tokens were applied.
const ZIG_BODY =
    \\const std = @import("std");
    \\const SEM = 1;
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

/// `caller` exists so clangd has a CALL to hang a parameter inlay hint
/// off; `use` is deliberately unterminated so the end of the file is an
/// expression position for the completion stage.
const C_BODY =
    \\static int add_two(int x) { return x + 2; }
    \\static int add_three(int x) { return x + 3; }
    \\static int add_pair(int a, int b) { return a + b; }
    \\
    \\int wrong = "type mismatch";
    \\
    \\int caller(void) { return add_two(41); }
    \\
    \\int typo = add_twoo(1);
    \\
    \\int use(void) {
    \\    return
;

const ZLS_BODY =
    \\const std = @import("std");
    \\
    \\fn alpha(x: i32) i32 {
    \\    var unused: i32 = 0;
    \\    return x + 1;
    \\}
    \\
    \\fn pair(a: i32, b: i32) i32 {
    \\    return a + b;
    \\}
    \\
    \\pub fn main() void {
    \\    _ = alpha(1);
    \\}
    \\
    \\const probe = std.
;

/// Which server the rig drives: `SKETERM_SMOKE_LSP` forces one
/// (ts|clangd|zls|stub); otherwise the first installed real server
/// wins, the scripted stub last.
fn pickPlan(allocator: std.mem.Allocator, stub_path: []const u8) Plan {
    const forced: []const u8 = if (c.getenv("SKETERM_SMOKE_LSP")) |v| std.mem.span(v) else "";
    const want = struct {
        forced: []const u8,
        fn is(self: @This(), name: []const u8) bool {
            return std.mem.eql(u8, self.forced, name);
        }
        fn auto(self: @This()) bool {
            return self.forced.len == 0;
        }
    }{ .forced = forced };
    if (want.is("ts") or (want.auto() and proc.onPath(allocator, "typescript-language-server"))) {
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
            .signature_call = " pair(",
            .real_server = true,
        };
    }
    if (want.is("clangd") or (want.auto() and proc.onPath(allocator, "clangd"))) {
        // Same command/args/root_files as the servers.zig BUILT-IN
        // definition, so a drift there fails here.
        return .{
            .name = "clangd",
            .command = "clangd",
            .args = "--background-index",
            .languages = "c,cpp,objective-c,objective-cpp,cuda",
            .root_files = "compile_commands.json,compile_flags.txt,.clangd,CMakeLists.txt,Makefile,.git",
            .file = "main.c",
            .marker = "compile_flags.txt",
            .marker_body = "-Wall\n",
            .body = C_BODY,
            // Typed at Ctrl+End — inside `use()`'s unterminated body, an
            // expression position where clangd offers both `add_` fns.
            .completion_prefix = " add_t",
            .signature_call = "; add_pair(",
            .real_server = true,
        };
    }
    if (want.is("zls") or (want.auto() and proc.onPath(allocator, "zls"))) {
        return .{
            .name = "zls",
            .command = "zls",
            .args = "",
            .languages = "zig",
            .root_files = "build.zig,build.zig.zon,.git",
            .file = "main.zig",
            .marker = "build.zig",
            .marker_body = "// workspace root marker\n",
            .body = ZLS_BODY,
            // After the trailing `std.` — member completion.
            .completion_prefix = "deb",
            .signature_call = " pair(",
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
        .signature_call = " stubCall(",
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

/// Pixels within `tol` of one exact RGB, from `x0` rightwards. Glyph
/// fragments are `vec4(colour.rgb, coverage)`, so a fully-covered pixel
/// lands exactly on the colour.
///
/// `x0` is per-check, not a constant: the inlay-hint grey is within a
/// few units of the gutter's line-number grey, so that one has to start
/// well clear of the gutter, while the semantic-token marker sits in
/// the first few columns of the text and needs a much smaller offset.
fn colorPixels(rgba: []const u8, img_w: u32, img_h: u32, want: [3]u8, tol: i32, x0: u32) usize {
    var hits: usize = 0;
    var y: u32 = 0;
    while (y < img_h) : (y += 1) {
        var x: u32 = x0;
        while (x < img_w) : (x += 1) {
            const i = (y * img_w + x) * 4;
            if (i + 3 >= rgba.len) continue;
            var ok = true;
            inline for (0..3) |ch| {
                const d = @as(i32, rgba[i + ch]) - @as(i32, want[ch]);
                if (d > tol or d < -tol) ok = false;
            }
            if (ok) hits += 1;
        }
    }
    return hits;
}

/// Poll the window until `want` shows up in at least `need` pixels.
fn waitForColor(
    app: *appdrive.App,
    win_id: u32,
    want: [3]u8,
    tol: i32,
    need: usize,
    budget_ms: i64,
    x0: u32,
) bool {
    var spent: i64 = 0;
    while (spent < budget_ms) : (spent += 250) {
        pumpFor(app, 250);
        const snap = app.snapshotRgba(win_id, null) catch continue;
        defer g_alloc.free(snap.px);
        if (colorPixels(snap.px, snap.w, snap.h, want, tol, x0) >= need) return true;
    }
    return false;
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
    const png = app.screenshotPng(win_id, 1600, null, 0) catch return;
    defer g_alloc.free(png.png);
    _ = writeFile(path, png.png);
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

    // Leg 1: a LOCAL document served by a locally spawned server.
    const local_rc = runLeg(allocator, false);
    if (local_rc != 0) return local_rc;
    // Leg 2: the SAME battery on a REMOTE document ("rbox:/..."):
    // $SKETERM_SSH fakes the ssh hop into a second private daemon
    // built from THIS tree, which spawns the server near the files and
    // relays its stdio as a byte channel. Hermetic — no passwordless
    // ssh, no installed daemon, and it cannot silently skip.
    return runLeg(allocator, true);
}

fn runLeg(allocator: std.mem.Allocator, remote: bool) u8 {
    g_session = if (remote) "lspsmoker" else "lspsmoke";
    g_leg = if (remote) "-remote" else "";
    say("=== {s} document leg ===", .{if (remote) "remote" else "local"});

    // Short isolated runtime dir: sockaddr_un caps at ~108 bytes and a
    // daemon that cannot bind makes the GUI autostart the INSTALLED one
    // (CLAUDE.md).
    var rt_buf: [128]u8 = undefined;
    const rt = std.fmt.bufPrintZ(&rt_buf, "/tmp/skl{s}-{d}", .{ if (remote) "r" else "", c.getpid() }) catch return fail("runtime path", .{});
    _ = c.mkdir(rt.ptr, 0o700);
    _ = c.setenv("XDG_RUNTIME_DIR", rt.ptr, 1);
    _ = c.setenv("XDG_CONFIG_HOME", rt.ptr, 1);
    _ = c.setenv("XDG_STATE_HOME", rt.ptr, 1);
    _ = c.unsetenv("SKETERM_SOCKET");
    _ = c.unsetenv("SKETERM_SSH");
    defer @import("mux/daemon.zig").removeTreeBestEffort(rt);
    // Isolated XDG_CONFIG_HOME races pango/fontconfig into heap
    // corruption unless the cache is warmed first (memory:
    // isolated-xdg-fontconfig-crash).
    _ = c.system("fc-cache >/dev/null 2>&1");

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

    // The stub writes the didOpen payload SIZE here (see lsp_stub.zig).
    // It is inherited by the GUI and from there by the server child.
    var report_buf: [256]u8 = undefined;
    const report_path = std.fmt.bufPrintZ(&report_buf, "{s}/didopen.txt", .{rt}) catch
        return fail("report path", .{});
    _ = c.unlink(report_path.ptr);

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

    // ── the "remote" host: fake ssh + a second private daemon ─────
    //
    // Same shape smoke_e2e established: $SKETERM_SSH points at a
    // script that execs `sketerm-mux --proxy` against a second daemon
    // under <rt>/r, pre-started here so its pid is owned. The remote
    // daemon inherits SKETERM_LSP_STUB_REPORT because IT is what
    // spawns the stub on this leg.
    if (remote) {
        var rrt_buf: [160]u8 = undefined;
        const rrt = std.fmt.bufPrintZ(&rrt_buf, "{s}/r", .{rt}) catch return fail("remote rt path", .{});
        _ = c.mkdir(rrt.ptr, 0o700);
        var mux_abs_buf: [4096]u8 = undefined;
        const mux_abs_raw = c.realpath("zig-out/bin/sketerm-mux", &mux_abs_buf) orelse return fail("realpath sketerm-mux", .{});
        const mux_abs = std.mem.span(@as([*:0]const u8, @ptrCast(mux_abs_raw)));
        const rmt_pid = c.fork();
        if (rmt_pid < 0) return fail("remote mux fork", .{});
        if (rmt_pid == 0) {
            dieWithParent();
            _ = c.setenv("XDG_RUNTIME_DIR", rrt.ptr, 1);
            _ = c.setenv("XDG_STATE_HOME", rrt.ptr, 1);
            _ = c.setenv("XDG_CONFIG_HOME", rrt.ptr, 1);
            // On this leg the REMOTE daemon spawns the stub, so the
            // didOpen report env must travel with it, not the GUI.
            _ = c.setenv("SKETERM_LSP_STUB_REPORT", report_path.ptr, 1);
            const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm-mux", "--broker", null };
            _ = c.execv("zig-out/bin/sketerm-mux", @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        remote_mux_pid = rmt_pid;
        var rsock_buf: [256]u8 = undefined;
        const rsock = std.fmt.bufPrintZ(&rsock_buf, "{s}/sketerm/mux.sock", .{rrt}) catch return fail("remote sock path", .{});
        var rwaited: u32 = 0;
        while (c.access(rsock.ptr, c.F_OK) != 0) {
            _ = c.usleep(50_000);
            rwaited += 1;
            if (rwaited > 100) return fail("remote mux socket never appeared", .{});
        }
        var ssh_path_buf: [200:0]u8 = undefined;
        const ssh_path = std.fmt.bufPrintZ(&ssh_path_buf, "{s}/fake-ssh", .{rt}) catch return fail("fake ssh path", .{});
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
        if (!writeFile(ssh_path.ptr, body)) return fail("fake ssh write", .{});
        if (c.chmod(ssh_path.ptr, 0o755) != 0) return fail("fake ssh chmod", .{});
        _ = c.setenv("SKETERM_SSH", ssh_path.ptr, 1);
        say("remote daemon up (fake ssh -> {s})", .{rsock});
    }

    // ── display session + viewer ──────────────────────────────────
    var wl_z: [4096:0]u8 = undefined;
    {
        const create_args = [_][]const u8{
            "create", "--name", g_session, "--ttl", TTL, "--size", "1280x800", "--json", "--socket", mux_sock,
        };
        const r = runDisplayCli(allocator, &create_args);
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
    drive = appdrive.App.attachExisting(allocator, g_session, null, mux_sock, null) catch
        return fail("could not attach a viewer", .{});
    const app = drive.?;

    // ── the editor ────────────────────────────────────────────────
    // A host-qualified spec routes the document — and therefore its
    // language server — through the fake ssh hop on the remote leg.
    var spec_buf: [560:0]u8 = undefined;
    const doc_spec: [:0]const u8 = if (remote)
        std.fmt.bufPrintZ(&spec_buf, "rbox:{s}", .{doc_path}) catch return fail("doc spec", .{})
    else
        doc_path;
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
        _ = c.setenv("SKETERM_LSP_STUB_REPORT", report_path.ptr, 1);
        const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm", "edit", doc_spec.ptr, null };
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
        savePng(app, win_id, shot("nodiag.png"));
        return fail("no diagnostic stripe appeared in the gutter (see zig-out/smoke-lsp-gui{s}-nodiag.png)", .{g_leg});
    }
    savePng(app, win_id, shot("diagnostics.png"));
    say("PASS diagnostics rendered (gutter stripe + squiggle) -> zig-out/smoke-lsp-gui{s}-diagnostics.png", .{g_leg});

    // ── 1b. didOpen carried the document ──────────────────────────
    //
    // Only the stub can see this: it writes the size of the didOpen
    // payload it received. A client that opens an EMPTY document and
    // sends the content as a follow-up didChange is otherwise
    // indistinguishable — sync ends up correct either way.
    if (!plan.real_server) {
        const f = c.fopen(report_path.ptr, "rb");
        if (f == null) return fail("the stub never reported a didOpen", .{});
        var rbuf: [128]u8 = undefined;
        const n = c.fread(&rbuf, 1, rbuf.len - 1, f.?);
        _ = c.fclose(f.?);
        rbuf[n] = 0;
        const got = std.mem.trim(u8, rbuf[0..n], " \n\r");
        var want_buf: [64]u8 = undefined;
        const want = std.fmt.bufPrint(&want_buf, "didopen_len={d}", .{plan.body.len}) catch "";
        if (!std.mem.eql(u8, got, want)) {
            say("stub reported '{s}', expected '{s}'", .{ got, want });
            return fail("didOpen did not carry the document's content", .{});
        }
        say("PASS didOpen carried all {d} bytes", .{plan.body.len});
    }

    // ── 1c. inlay hints ───────────────────────────────────────────
    //
    // The hint colour (editor_pass.Colors.inlay) is used by nothing
    // else, so its presence to the right of the gutter is proof that a
    // hint was laid out and drawn.
    const INLAY_RGB = [3]u8{ 122, 133, 148 };
    if (waitForColor(app, win_id, INLAY_RGB, 10, 3, 30_000, 240)) {
        savePng(app, win_id, shot("inlay-hints.png"));
        say("PASS inlay hints rendered -> zig-out/smoke-lsp-gui{s}-inlay-hints.png", .{g_leg});
    } else if (!plan.real_server) {
        savePng(app, win_id, shot("noinlay.png"));
        return fail("the stub's inlay hints never appeared", .{});
    } else {
        // A real server is free to have nothing to annotate here.
        say("SKIP inlay hints: {s} offered none for this document", .{plan.name});
    }

    // ── 1d. semantic tokens ───────────────────────────────────────
    //
    // Stub only: it tags the `SEM` identifier as `property`, a colour
    // no grammar gives that word, so seeing it can only mean the
    // server's tokens were layered on top of the Tree-sitter kinds.
    if (!plan.real_server) {
        const PROPERTY_RGB = [3]u8{ 0xBF, 0xD4, 0xEC };
        if (!waitForColor(app, win_id, PROPERTY_RGB, 8, 3, 30_000, 60)) {
            savePng(app, win_id, shot("nosemantic.png"));
            return fail("the stub's semantic tokens never recoloured anything", .{});
        }
        savePng(app, win_id, shot("semantic-tokens.png"));
        say("PASS semantic tokens recoloured the marker -> zig-out/smoke-lsp-gui{s}-semantic-tokens.png", .{g_leg});
    }

    // Focus the canvas: a click into the document is what the user
    // does, and the popups are positioned from the caret.
    const win = app.winById(win_id).?;
    app.click(win_id, @as(f64, @floatFromInt(win.w)) * 0.5, @as(f64, @floatFromInt(win.h)) * 0.5, 1) catch {};
    pumpFor(app, 400);

    // ── 2. next diagnostic (F8) ───────────────────────────────────
    app.pressKey(win_id, "F8") catch {};
    pumpFor(app, 1200);
    savePng(app, win_id, shot("diagnostic-nav.png"));
    say("PASS F8 diagnostic navigation -> zig-out/smoke-lsp-gui{s}-diagnostic-nav.png", .{g_leg});

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
        savePng(app, win_id, shot("nohover.png"));
        return fail("Ctrl+I opened no hover popup", .{});
    }
    pumpFor(app, 400);
    savePng(app, win_id, shot("hover.png"));
    savePopupPng(app, shot("hover-popup.png"));
    say("PASS hover popup -> zig-out/smoke-lsp-gui{s}-hover.png", .{g_leg});

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
    savePng(app, win_id, shot("outline.png"));
    say("PASS outline panel opened against a live server -> zig-out/smoke-lsp-gui{s}-outline.png", .{g_leg});

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
        savePng(app, win_id, shot("nocompletion.png"));
        return fail("Ctrl+Space opened no completion popup", .{});
    }
    // The popup must SURVIVE, not just flash into one frame: a
    // mid-flight minimum-size change once made GTK popdown it right
    // after the first commit, and a 200ms poll happily "passed" on
    // that single frame while the user saw nothing.
    pumpFor(app, 1500);
    if (popupCount(app) <= popups_before_completion) {
        savePng(app, win_id, shot("nocompletion.png"));
        return fail("completion popup closed itself right after opening", .{});
    }
    savePng(app, win_id, shot("completion.png"));
    savePopupPng(app, shot("completion-popup.png"));
    say("PASS completion popup -> zig-out/smoke-lsp-gui{s}-completion.png", .{g_leg});

    // Down + Enter accepts an item: the document must change, which is
    // the whole point of the feature.
    const before = app.snapshotRgba(win_id, null) catch return fail("snapshot", .{});
    defer allocator.free(before.px);
    app.pressKey(win_id, "Down") catch {};
    pumpFor(app, 300);
    if (popupCount(app) <= popups_before_completion)
        return fail("completion popup vanished before the accept", .{});
    app.pressKey(win_id, "Return") catch {};
    pumpFor(app, 1200);
    // Accepting must CLOSE the list — a Return that fell through to
    // the document (popup already dead) also changes pixels, so the
    // diff below alone is not proof of an accepted completion.
    if (popupCount(app) > popups_before_completion)
        return fail("completion popup still open after accepting", .{});
    const after = app.snapshotRgba(win_id, null) catch return fail("snapshot", .{});
    defer allocator.free(after.px);
    var changed: usize = 0;
    const n = @min(before.px.len, after.px.len);
    var i: usize = 0;
    while (i < n) : (i += 4) {
        if (before.px[i] != after.px[i]) changed += 1;
    }
    if (changed == 0) return fail("accepting a completion changed nothing on screen", .{});
    savePng(app, win_id, shot("completion-accepted.png"));
    say("PASS completion accepted ({d} pixels changed) -> zig-out/smoke-lsp-gui{s}-completion-accepted.png", .{ changed, g_leg });

    // ── 4b. signature help ────────────────────────────────────────
    //
    // Typing the server's own trigger character must open it — no
    // keybinding involved. Both servers declare `(`.
    app.pressKey(win_id, "Escape") catch {};
    pumpFor(app, 300);
    app.pressKey(win_id, "ctrl+End") catch {};
    pumpFor(app, 300);
    const popups_before_sig = popupCount(app);
    app.typeText(win_id, plan.signature_call) catch {};
    var sig_ok = false;
    spent = 0;
    while (spent < 20_000) : (spent += 200) {
        pumpFor(app, 200);
        if (popupCount(app) > popups_before_sig) {
            sig_ok = true;
            break;
        }
    }
    if (!sig_ok) {
        savePng(app, win_id, shot("nosignature.png"));
        return fail("typing '{s}' opened no signature popup", .{plan.signature_call});
    }
    pumpFor(app, 800);
    savePng(app, win_id, shot("signature.png"));
    savePopupPng(app, shot("signature-popup.png"));
    say("PASS signature help -> zig-out/smoke-lsp-gui{s}-signature.png", .{g_leg});
    // …and it survives the caret walking to the next parameter, which
    // is the re-entrant path (a re-request lands while typing).
    app.typeText(win_id, "1,") catch {};
    pumpFor(app, 1500);
    if (popupCount(app) <= popups_before_sig)
        return fail("signature help closed itself while moving to the next parameter", .{});
    savePopupPng(app, shot("signature-param2.png"));
    say("PASS signature help followed the active parameter", .{});
    app.pressKey(win_id, "Escape") catch {};
    pumpFor(app, 400);

    // ── 4c. code actions (Ctrl+.) ─────────────────────────────────
    //
    // F8 puts the caret on a diagnostic, which is where a quick fix
    // exists; the request carries that diagnostic back to the server.
    const popups_before_actions = popupCount(app);
    var actions_ok = false;
    // Walk the diagnostics: which one carries a fix is the server's
    // business, so try each in turn rather than assuming the first.
    var probe: usize = 0;
    while (probe < 6 and !actions_ok) : (probe += 1) {
        app.pressKey(win_id, "F8") catch {};
        pumpFor(app, 700);
        // "ctrl+." not "ctrl+period": chord parsing takes a CHARACTER
        // for anything that is not a named key.
        app.pressKey(win_id, "ctrl+.") catch |e| return fail("ctrl+. rejected: {s}", .{@errorName(e)});
        spent = 0;
        while (spent < 5_000) : (spent += 200) {
            pumpFor(app, 200);
            if (popupCount(app) > popups_before_actions) {
                actions_ok = true;
                break;
            }
        }
    }
    if (!actions_ok) {
        savePng(app, win_id, shot("noactions.png"));
        return fail("Ctrl+. opened no code-action popup", .{});
    }
    pumpFor(app, 800);
    savePng(app, win_id, shot("code-actions.png"));
    savePopupPng(app, shot("code-actions-popup.png"));
    say("PASS code actions -> zig-out/smoke-lsp-gui{s}-code-actions.png", .{g_leg});

    // Applying one must change the document AND close the list.
    {
        const before_a = app.snapshotRgba(win_id, null) catch return fail("snapshot", .{});
        defer allocator.free(before_a.px);
        app.pressKey(win_id, "Return") catch {};
        pumpFor(app, 2500);
        if (popupCount(app) > popups_before_actions)
            return fail("the code-action list stayed open after applying", .{});
        const after_a = app.snapshotRgba(win_id, null) catch return fail("snapshot", .{});
        defer allocator.free(after_a.px);
        var moved: usize = 0;
        const na = @min(before_a.px.len, after_a.px.len);
        var ia: usize = 0;
        while (ia < na) : (ia += 4) {
            if (before_a.px[ia] != after_a.px[ia]) moved += 1;
        }
        if (moved == 0) return fail("applying a code action changed nothing on screen", .{});
        savePng(app, win_id, shot("code-action-applied.png"));
        say("PASS code action applied ({d} pixels changed)", .{moved});
    }

    // ── 4d. mouse-dwell hover ─────────────────────────────────────
    //
    // Resting the pointer over a symbol must pop a hover WITHOUT any
    // key being pressed.
    app.pressKey(win_id, "Escape") catch {};
    pumpFor(app, 400);
    const popups_before_dwell = popupCount(app);
    var dwell_ok = false;
    {
        const w2 = app.winById(win_id).?;
        // Sweep a few points along the first text lines until one lands
        // on a symbol: WHERE a symbol is depends on the plan's document
        // and on the edits the earlier stages made, and a dwell over
        // whitespace correctly produces nothing at all.
        const xs = [_]f64{ 0.14, 0.20, 0.26, 0.32, 0.40 };
        const ys = [_]f64{ 0.13, 0.16, 0.19 };
        outer: for (ys) |yr| {
            for (xs) |xr| {
                const hx = @as(f64, @floatFromInt(w2.w)) * xr;
                const hy = @as(f64, @floatFromInt(w2.h)) * yr;
                _ = app.moveMouse(win_id, hx, hy) catch {};
                pumpFor(app, 60);
                _ = app.moveMouse(win_id, hx + 2, hy) catch {};
                var waited_ms: i64 = 0;
                while (waited_ms < 2_500) : (waited_ms += 200) {
                    pumpFor(app, 200);
                    if (popupCount(app) > popups_before_dwell) {
                        dwell_ok = true;
                        break :outer;
                    }
                }
            }
        }
    }
    if (dwell_ok) {
        // Capture the popup FIRST: the screenshot path wants a surface
        // that has committed recently, and nothing re-commits a hover
        // popover once it is up.
        savePopupPng(app, shot("dwell-hover-popup.png"));
        pumpFor(app, 400);
        savePng(app, win_id, shot("dwell-hover.png"));
        say("PASS mouse-dwell hover -> zig-out/smoke-lsp-gui{s}-dwell-hover.png", .{g_leg});
    } else if (!plan.real_server) {
        savePng(app, win_id, shot("nodwell.png"));
        return fail("resting the pointer opened no hover popup", .{});
    } else {
        // A real server may have nothing to say at that exact point.
        say("SKIP mouse-dwell hover: nothing under the pointer", .{});
    }
    app.pressKey(win_id, "Escape") catch {};
    pumpFor(app, 300);

    // ── 5. go to definition (F12) ─────────────────────────────────
    //
    // The accepted item left the caret just past the inserted symbol,
    // which is exactly where a definition lookup should work.
    app.pressKey(win_id, "Escape") catch {};
    pumpFor(app, 300);
    app.pressKey(win_id, "F12") catch {};
    pumpFor(app, 4000);
    savePng(app, win_id, shot("definition.png"));
    say("PASS go-to-definition ran -> zig-out/smoke-lsp-gui{s}-definition.png", .{g_leg});

    say("PASS ({s} server)", .{if (plan.real_server) "real" else "stub"});
    teardown();
    return 0;
}
