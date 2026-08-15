// sketerm-webengine — the CEF browser helper process.
//
// Hosts windowless (OSR) browsers and speaks the v1 wire protocol from
// protocol.zig over a unix socket. It is the ONLY binary that links
// CEF: the GUI and the daemon never see a CEF type, which is what keeps
// an engine swap to a new helper rather than a rewrite. It is a
// SEPARATE PROCESS for crash isolation — an engine crash must not take
// down the terminal and every shell in it. (Not for GTK reasons:
// libcef links no GTK, in either the upstream or the distro build.)
//
// Startup order matters and is not negotiable:
//   1. re-exec with LD_PRELOAD=libcef.so (see below),
//   2. cef_api_hash — the FIRST libcef call of any process,
//   3. cef_execute_process — returns for CEF's own subprocesses,
//   4. cef_initialize, then the socket loop.

const std = @import("std");
const c = @import("cbindings");
const build_options = @import("build_options");
const cefhost = @import("cefhost.zig");
const ozone = @import("ozone.zig");
const server = @import("server.zig");
const pathz = @import("../util/pathz.zig");

const USAGE =
    \\sketerm-web --socket PATH [--cache-dir PATH]
    \\           (--socket-fd N and --frames-inline are the daemon's
    \\            remote-helper launch shape)
    \\
    \\Browser helper for sketerm. Listens on PATH for one client (the
    \\sketerm GUI) and exits when that client disconnects.
    \\
;

/// Marks a process that already re-exec'd; CEF's own subprocesses
/// inherit it through the environment and so never re-exec themselves.
const PRELOAD_GUARD = "SKETERM_WEB_PRELOADED";

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;

    // (1) DT_NEEDED order workaround. Zig always emits libc BEFORE
    // libcef, and libcef's zygote resolves dlsym(RTLD_NEXT, "close") —
    // which then misses glibc and aborts with SIGTRAP. LD_PRELOAD of
    // libcef.so fixes the resolution order, and it can only be set
    // before the loader runs, hence the re-exec.
    if (c.getenv(PRELOAD_GUARD) == null) {
        reexecPreloaded(argv);
        // Only reachable if the re-exec failed; carry on and hope the
        // zygote never needs the symbol.
    }

    // (2) Configures the API version for every later libcef call.
    if (!cefhost.apiHash()) {
        std.debug.print("sketerm-web: cef_api_hash failed\n", .{});
        return 1;
    }

    // (3) OUR OWN ARGUMENTS, COPIED, BEFORE CEF EVER SEES ARGV.
    //
    // Chromium rewrites the process's argv BLOCK in place — switches
    // first, positional arguments after — as soon as its command line
    // contains a switch it has to act on early (an explicit
    // `--ozone-platform=` is one). `--socket /path` then reads back as
    // `--socket --cache-dir`, the helper binds a socket called
    // "--cache-dir" in its working directory, and the client waits
    // forever for a socket that will never appear. Parsing after
    // `cef_execute_process` was therefore always a latent bug; it only
    // stayed hidden while every switch we appended lived in .rodata
    // rather than in the argv block.
    var sock_buf: [4096]u8 = undefined;
    var cache_buf: [4096]u8 = undefined;
    var socket_path: ?[]const u8 = null;
    var cache_dir: ?[]const u8 = null;
    var socket_fd: c_int = -1;
    var frames_inline = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = std.mem.span(argv[i]);
        if (std.mem.eql(u8, a, "--socket") and i + 1 < argv.len) {
            i += 1;
            socket_path = copyArg(&sock_buf, std.mem.span(argv[i]));
        } else if (std.mem.eql(u8, a, "--socket-fd") and i + 1 < argv.len) {
            // A pre-connected client descriptor from the spawning
            // daemon (remote-helper launch): no listen/accept at all.
            // The fd survived the LD_PRELOAD re-exec because nothing
            // set CLOEXEC on it yet; the server sets it the moment it
            // adopts the fd, before CEF spawns any subprocess.
            i += 1;
            socket_fd = std.fmt.parseInt(c_int, std.mem.span(argv[i]), 10) catch -1;
        } else if (std.mem.eql(u8, a, "--frames-inline")) {
            // Remote-helper mode: frames ride the socket in-band. The
            // GPU path would hand out dma-buf descriptors the bridge
            // cannot carry, so force the software path BEFORE the
            // ozone decision below reads the environment.
            frames_inline = true;
            _ = c.setenv("SKETERM_WEB_GPU", "0", 1);
        } else if (std.mem.eql(u8, a, "--cache-dir") and i + 1 < argv.len) {
            i += 1;
            cache_dir = copyArg(&cache_buf, std.mem.span(argv[i]));
        } else if (std.mem.eql(u8, a, "--keep")) {
            // Defensive: a daemon that ever spawns /proc/self/exe as a
            // session keeper must not get a browser helper instead.
            return 0;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("{s}", .{USAGE});
            return 0;
        }
    }

    // (4) The argv handed to CEF must go to cef_execute_process TOO,
    // not just cef_initialize: Chromium's global command line is
    // initialized by whichever runs first, and switches missing there
    // are silently ignored (a browser process that keeps its GPU
    // process paints EMPTY frames in windowless mode).
    var argv_buf: [64][*c]u8 = undefined;
    const cef_argv = buildCefArgv(argv, &argv_buf);

    // (5) CEF subprocess passthrough (renderer, gpu, zygote, ...).
    if (cefhost.executeProcess(@intCast(cef_argv.len), cef_argv.ptr)) |code| return code;

    // All CEF + allocator teardown runs inside this block (its defers);
    // the hard `_exit` below then terminates the browser process. A
    // browser process that hosted a WebExtensions background page can
    // otherwise HANG in libc's normal exit path — a CEF worker thread
    // outlives `cef_shutdown` and the atexit join never returns — so we
    // exit deterministically once our own teardown is complete rather
    // than returning through the C runtime.
    var exit_code: u8 = 0;
    {
        var gpa_state: std.heap.DebugAllocator(.{}) = .{};
        defer _ = gpa_state.deinit();
        const gpa = gpa_state.allocator();

        const sock = socket_path orelse blk: {
            if (socket_fd >= 0) break :blk "";
            std.debug.print("sketerm-web: --socket PATH is required\n{s}", .{USAGE});
            return 2;
        };

        const cache = cache_dir orelse defaultCacheDir(gpa) orelse {
            std.debug.print("sketerm-web: no --cache-dir and no HOME\n", .{});
            return 2;
        };
        defer if (cache_dir == null) gpa.free(cache);
        mkdirAll(cache);
        const log_path = std.fmt.allocPrint(gpa, "{s}/cef.log", .{cache}) catch return 1;
        defer gpa.free(log_path);

        if (!cefhost.initialize(@intCast(cef_argv.len), cef_argv.ptr, cache, log_path)) {
            std.debug.print("sketerm-web: cef_initialize failed\n", .{});
            return 1;
        }
        defer cefhost.shutdown();

        var srv = server.Server.init(gpa, sock);
        srv.profile_dir = cache;
        srv.force_inline = frames_inline;
        defer srv.deinit();
        if (socket_fd >= 0) {
            srv.adoptClientFd(socket_fd);
        } else srv.listen() catch |e| {
            std.debug.print("sketerm-web: listen on {s} failed: {s}\n", .{ sock, @errorName(e) });
            return 1;
        };
        srv.run() catch |e| {
            std.debug.print("sketerm-web: serve failed: {s}\n", .{@errorName(e)});
            exit_code = 1;
        };
    }
    c._exit(exit_code);
}

/// Re-exec this binary with LD_PRELOAD pointing at the CEF library the
/// build linked against. Returns only on failure.
fn reexecPreloaded(argv: []const [*:0]const u8) void {
    var preload: [4096]u8 = undefined;
    const lib = std.fmt.bufPrintZ(&preload, "{s}/libcef.so", .{build_options.cef_release_dir}) catch return;
    if (c.setenv("LD_PRELOAD", lib.ptr, 1) != 0) return;
    if (c.setenv(PRELOAD_GUARD, "1", 1) != 0) return;

    var vec: [256:null]?[*:0]u8 = undefined;
    if (argv.len + 1 > vec.len) return;
    for (argv, 0..) |a, i| vec[i] = @constCast(a);
    vec[argv.len] = null;
    var exe: [4096:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&exe, "/proc/self/exe", .{}) catch return;
    _ = c.execv(path.ptr, @ptrCast(&vec));
}

/// The argv handed to CEF: ours plus the ozone platform switch when the
/// caller did not already supply one. Written into `buf` (no allocator:
/// this runs before one exists) and truncated rather than overflowed,
/// since Chromium ignores what it never sees anyway.
///
/// THE OZONE PLATFORM IS THE WHOLE GPU DECISION, and it is a runtime one
/// because the helper must keep working with no display at all (headless
/// CI, the smoke rig, a future remote helper). MEASURED 2026-08-10 on
/// Arch with CEF 150, an animating page at 3840x2160 physical:
///
///   --ozone-platform=headless   no `--type=gpu-process` is EVER
///                               spawned — not with --enable-gpu, not
///                               with --ignore-gpu-blocklist, not with
///                               --use-angle=gl-egl/vulkan (those make
///                               the GPU process start and immediately
///                               exit: "Requested GL implementation not
///                               found in allowed implementations").
///                               Everything composites in software and
///                               `on_accelerated_paint` cannot fire.
///   --ozone-platform=x11        a GPU process appears and holds a
///                               render node, but paints still arrive
///                               through `on_paint`: no shared textures.
///   --ozone-platform=wayland    a GPU process appears, holds
///                               /dev/dri/renderD*, and
///                               `on_accelerated_paint` delivers
///                               single-plane BGRA dma-bufs. THE path.
///
/// The catch is that wayland ozone is not optional-with-fallback inside
/// Chromium: with no reachable compositor, `cef_initialize` fails and
/// the process exits 1. Hence `waylandReachable` — a real connect() to
/// the socket — decides BEFORE CEF starts, and anything short of a
/// working compositor plus a render node picks headless.
///
/// `--disable-gpu` and an explicit `--ozone-platform=` are passed
/// through untouched: that is how the smoke rig pins a mode.
fn buildCefArgv(argv: []const [*:0]const u8, buf: *[64][*c]u8) [][*c]u8 {
    var n: usize = 0;
    for (argv) |a| {
        if (n == buf.len) break;
        buf[n] = @constCast(@ptrCast(a));
        n += 1;
    }
    // A CEF subprocess is this binary re-executed with Chromium's own
    // command line, which already carries the platform the browser
    // process chose — so the probes below run exactly once, in the
    // browser process, and every child inherits its answer. The
    // decision itself lives in ozone.zig (`SKETERM_WEB_OZONE` is
    // webdrive forcing the helper onto a mux session's display);
    // probes stay short-circuited here so a headless pick costs no
    // compositor connect.
    var explicit: ?[]const u8 = null;
    for (argv) |a| {
        const s = std.mem.span(a);
        if (std.mem.startsWith(u8, s, "--ozone-platform=")) explicit = s["--ozone-platform=".len ..];
    }
    const override: ?[]const u8 = if (c.getenv("SKETERM_WEB_OZONE")) |o| std.mem.span(o) else null;
    const choice = blk: {
        if (explicit != null) break :blk ozone.choose(explicit, null, gpuWanted(), false, false);
        const forced_wayland = if (override) |o| std.mem.eql(u8, o, "wayland") else false;
        const g = gpuWanted();
        const w = if (g or forced_wayland) waylandReachable() else false;
        const r = if (g and w and !forced_wayland) renderNodePresent() else false;
        break :blk ozone.choose(null, override, g, w, r);
    };
    if (explicit == null) {
        const want: [*:0]const u8 = if (std.mem.eql(u8, choice.platform, "wayland"))
            "--ozone-platform=wayland"
        else
            "--ozone-platform=headless";
        if (n < buf.len) {
            buf[n] = @constCast(@ptrCast(want));
            n += 1;
        }
    }
    if (choice.disable_gpu and n < buf.len) {
        buf[n] = @constCast(@ptrCast("--disable-gpu"));
        n += 1;
    }
    // Subpixel (LCD) text AA. MEASURED on the software (headless-ozone)
    // path: no effect — glyph pixels stay 100% neutral gray with the
    // flag AND an opaque background_color (0 of 6793 ink pixels carried
    // any color). Chromium's software OSR raster is grayscale-AA,
    // period; that is the one residual sharpness difference against a
    // subpixel-AA Firefox. The flag is kept because GPU rasterization
    // (ozone wayland) takes a different text path where it may enable
    // subpixel AA; harmless where it does nothing, and the background
    // is opaque either way.
    if (n < buf.len) {
        buf[n] = @constCast(@ptrCast("--enable-lcd-text"));
        n += 1;
    }
    // Only a real ozone platform ever produces a GPU process here, and
    // only wayland was measured to deliver shared textures.
    cefhost.setAccelerated(choice.accelerated);
    return buf[0..n];
}

/// Copy one argv value out of the argv block, which Chromium is free to
/// rewrite from under us the moment it parses the command line.
fn copyArg(buf: []u8, value: []const u8) ?[]const u8 {
    if (value.len > buf.len) return null;
    @memcpy(buf[0..value.len], value);
    return buf[0..value.len];
}

/// `SKETERM_WEB_GPU=0` (or `off`/`no`) forces the software path. The
/// escape hatch for a driver quirk no fallback caught, and what the GUI
/// sets when the user turns GPU frames off.
fn gpuWanted() bool {
    const v = c.getenv("SKETERM_WEB_GPU") orelse return true;
    const s = std.mem.span(v);
    return !(std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "no"));
}

/// Whether a Wayland compositor is actually reachable — a connect(),
/// not a getenv: `WAYLAND_DISPLAY` outlives the compositor that set it,
/// and a wrong answer here costs the whole process (cef_initialize
/// exits rather than falling back).
fn waylandReachable() bool {
    var path: [108]u8 = undefined;
    const disp = if (c.getenv("WAYLAND_DISPLAY")) |d| std.mem.span(d) else "wayland-0";
    const full = if (disp.len != 0 and disp[0] == '/')
        std.fmt.bufPrintZ(&path, "{s}", .{disp}) catch return false
    else blk: {
        const dir = c.getenv("XDG_RUNTIME_DIR") orelse return false;
        break :blk std.fmt.bufPrintZ(&path, "{s}/{s}", .{ std.mem.span(dir), disp }) catch return false;
    };

    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    if (full.len + 1 > @sizeOf(@TypeOf(addr.sun_path))) return false;
    addr.sun_family = c.AF_UNIX;
    @memcpy(addr.sun_path[0..full.len], full);
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    return c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) == 0;
}

/// Whether any DRM render node can be opened. Without one the GPU
/// process starts and dies, which costs a second of startup and lands
/// in software anyway.
fn renderNodePresent() bool {
    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        var path: [64]u8 = undefined;
        const p = std.fmt.bufPrintZ(&path, "/dev/dri/renderD{d}", .{128 + @as(u16, i)}) catch return false;
        const fd = c.open(p.ptr, c.O_RDWR | c.O_CLOEXEC);
        if (fd >= 0) {
            _ = c.close(fd);
            return true;
        }
    }
    return false;
}

/// $XDG_STATE_HOME/sketerm/web-cache, else ~/.local/state/... — the
/// browser profile (cookies, cache, Widevine CDM) lives there.
fn defaultCacheDir(gpa: std.mem.Allocator) ?[]const u8 {
    if (c.getenv("XDG_STATE_HOME")) |xdg| {
        const base = std.mem.span(xdg);
        if (base.len != 0) {
            return std.fmt.allocPrint(gpa, "{s}/sketerm/web-cache", .{base}) catch null;
        }
    }
    const home = c.getenv("HOME") orelse return null;
    return std.fmt.allocPrint(gpa, "{s}/.local/state/sketerm/web-cache", .{std.mem.span(home)}) catch null;
}

/// mkdir -p, ignoring every failure but the one that matters (a
/// missing cache dir surfaces as a cef_initialize failure).
fn mkdirAll(path: []const u8) void {
    pathz.makeDirs(path, 0o700) catch {};
}
