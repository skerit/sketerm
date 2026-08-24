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
//   1. re-exec with LD_PRELOAD=libcef.so (LINUX only; see below),
//   2. cef_api_hash — the FIRST libcef call of any process,
//   3. cef_execute_process — returns for CEF's own subprocesses,
//   4. cef_initialize, then the socket loop.
//
// macOS differs in two ways, both in build.zig and documented there:
// the framework is linked directly (dyld binds it through the
// framework's own @executable_path/../Frameworks install name, so
// step 1 has nothing to fix), and there is no ozone platform — the
// engine renders through its own windowing layer and only the
// SOFTWARE paint path is wired up (see buildCefArgv).

const std = @import("std");
const builtin = @import("builtin");
const c = @import("cbindings");
const build_options = @import("build_options");
const cefargs = @import("cefargs.zig");
const cefhost = @import("cefhost.zig");
const ozone = @import("ozone.zig");
const server = @import("server.zig");
const pathz = @import("../util/pathz.zig");

const USAGE =
    \\sketerm-web --socket PATH [--cache-dir PATH] [--linger-ms N]
    \\           (--socket-fd N and --frames-inline are the daemon's
    \\            remote-helper launch shape)
    \\
    \\Browser helper for sketerm. Listens on PATH, serves any number of
    \\clients, and exits when the last one disconnects — or, with
    \\--linger-ms N, keeps listening that long for the next client
    \\first (the broker-owned lifecycle).
    \\
;

/// Marks a process that already re-exec'd; CEF's own subprocesses
/// inherit it through the environment and so never re-exec themselves.
const PRELOAD_GUARD = "SKETERM_WEB_PRELOADED";

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;

    // (1) DT_NEEDED order workaround, LINUX ONLY. Zig always emits libc
    // BEFORE libcef, and libcef's zygote resolves dlsym(RTLD_NEXT,
    // "close") — which then misses glibc and aborts with SIGTRAP.
    // LD_PRELOAD of libcef.so fixes the resolution order, and it can
    // only be set before the loader runs, hence the re-exec.
    //
    // macOS needs nothing here: there is no zygote process on that
    // platform, and the framework is bound by dyld through its own
    // `@executable_path/../Frameworks/…` install name, so no load order
    // is ours to fix. Do not "port" this — a re-exec would only cost a
    // process spawn.
    if (builtin.target.os.tag != .macos and c.getenv(PRELOAD_GUARD) == null) {
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
    var linger_ms: i64 = 0;
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
        } else if (std.mem.eql(u8, a, "--linger-ms") and i + 1 < argv.len) {
            // Broker-owned lifecycle: survive the LAST client's exit
            // and keep listening this long for the next one, then run
            // the normal graceful drain (`cef_shutdown` — the jar
            // flush) and exit. 0 keeps the exit-with-last-client shape.
            i += 1;
            linger_ms = std.fmt.parseInt(i64, std.mem.span(argv[i]), 10) catch 0;
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
    var disable_cap = cefargs.disable_features_prefix.len + cefargs.read_anything_feature.len + 2;
    for (argv) |a| {
        const value = cefargs.disableFeaturesValue(std.mem.span(a)) orelse continue;
        const extra = std.math.add(usize, value.len, 1) catch {
            std.debug.print("sketerm-web: --disable-features is too large\n", .{});
            return 1;
        };
        disable_cap = std.math.add(usize, disable_cap, extra) catch {
            std.debug.print("sketerm-web: --disable-features is too large\n", .{});
            return 1;
        };
    }
    const disable_storage = std.heap.c_allocator.alloc(u8, disable_cap) catch {
        std.debug.print("sketerm-web: cannot allocate CEF arguments\n", .{});
        return 1;
    };
    defer std.heap.c_allocator.free(disable_storage);
    var disable_builder = cefargs.Builder.init(disable_storage) catch return 1;
    for (argv) |a| {
        const value = cefargs.disableFeaturesValue(std.mem.span(a)) orelse continue;
        disable_builder.add(value) catch return 1;
    }
    const disable_features = disable_builder.finish() catch return 1;

    var argv_buf: [64][*c]u8 = undefined;
    const cef_argv = buildCefArgv(argv, disable_features, &argv_buf);

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
        srv.linger_ms = linger_ms;
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

/// The argv handed to CEF: ours plus compatibility and platform switches.
/// Existing disable-features values are replaced by `disable_features`,
/// which coalesces them so Chromium's last-switch-wins parser loses none.
/// The pointer list is truncated rather than overflowed.
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
fn buildCefArgv(argv: []const [*:0]const u8, disable_features: [:0]u8, buf: *[64][*c]u8) [][*c]u8 {
    var n: usize = 0;
    for (argv) |a| {
        if (cefargs.disableFeaturesValue(std.mem.span(a)) != null) continue;
        // The compatibility switch is mandatory, so reserve its slot
        // when an unusually large command line reaches this fixed list.
        if (n + 1 >= buf.len) break;
        buf[n] = @ptrCast(@constCast(a));
        n += 1;
    }
    buf[n] = @ptrCast(disable_features.ptr);
    n += 1;
    // macOS has no ozone at all — Chromium uses its own windowing
    // layer, and `--ozone-platform=` is simply not a switch there. The
    // GPU decision the rest of this function makes is likewise moot:
    // an accelerated OSR paint on macOS delivers an IOSurface, not
    // dma-buf planes (`cef_accelerated_paint_info_t` has no `planes`
    // array there), and there is neither a wire frame nor a GTK
    // importer for one. So the helper stays on the SOFTWARE paint path
    // and says so, rather than probing for a compositor that cannot
    // exist. An IOSurface frame family would be a new capability, not
    // a tweak here.
    if (builtin.target.os.tag == .macos) {
        cefhost.setAccelerated(false);
        // Chromium's cookie store encrypts at rest with a key from the
        // KEYCHAIN ("Chrome Safe Storage"). For this helper — headless,
        // often ad-hoc-signed, re-identified every dev build — the
        // SecKeychain call never returns: no prompt appears, the key
        // never arrives, the cookie store never initializes, and CEF
        // then holds EVERY http(s) request on its cookie load
        // (`MaybeLoadCookies` in the interception wrapper), which
        // presented as "no page over the network ever finishes
        // loading" while data: URLs worked fine. The mock keychain is
        // Chromium's own test escape for exactly this; cookies still
        // persist, keyed by a mock secret instead of a keychain item.
        // Revisit only alongside a stable signing identity AND a
        // measured, bounded real-keychain path.
        var have = false;
        for (buf[0..n]) |a| {
            if (std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(a))), "--use-mock-keychain")) have = true;
        }
        if (!have and n < buf.len) {
            buf[n] = @ptrCast(@constCast("--use-mock-keychain"));
            n += 1;
        }
        return buf[0..n];
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
        if (std.mem.startsWith(u8, s, "--ozone-platform=")) explicit = s["--ozone-platform=".len..];
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
            buf[n] = @ptrCast(@constCast(want));
            n += 1;
        }
    }
    if (choice.disable_gpu and n < buf.len) {
        buf[n] = @ptrCast(@constCast("--disable-gpu"));
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
        buf[n] = @ptrCast(@constCast("--enable-lcd-text"));
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
