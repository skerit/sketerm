// sketerm-web — the CEF browser helper process.
//
// Hosts windowless (OSR) browsers and speaks the v1 wire protocol from
// docs/proposal-browser-protocol.md over a unix socket. It is the ONLY
// binary that links CEF: the GUI and the daemon never see a CEF type,
// which is also what keeps CEF's GTK3 dependency out of a GTK4 process.
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
const server = @import("server.zig");

const USAGE =
    \\sketerm-web --socket PATH [--cache-dir PATH]
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

    // (3) Headless by construction: no display is ever required, so the
    // helper runs identically under a GUI session and under MCP-only
    // automation. This argv must be handed to cef_execute_process TOO,
    // not just cef_initialize: Chromium's global command line is
    // initialized by whichever runs first, and switches missing there
    // are silently ignored (a browser process that keeps its GPU
    // process paints EMPTY frames in windowless mode).
    var argv_buf: [64][*c]u8 = undefined;
    const cef_argv = buildCefArgv(argv, &argv_buf);

    // (4) CEF subprocess passthrough (renderer, gpu, zygote, ...).
    if (cefhost.executeProcess(@intCast(cef_argv.len), cef_argv.ptr)) |code| return code;

    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var socket_path: ?[]const u8 = null;
    var cache_dir: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = std.mem.span(argv[i]);
        if (std.mem.eql(u8, a, "--socket") and i + 1 < argv.len) {
            i += 1;
            socket_path = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, a, "--cache-dir") and i + 1 < argv.len) {
            i += 1;
            cache_dir = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, a, "--keep")) {
            // Defensive: a daemon that ever spawns /proc/self/exe as a
            // session keeper must not get a browser helper instead.
            return 0;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("{s}", .{USAGE});
            return 0;
        }
    }
    const sock = socket_path orelse {
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
    defer srv.deinit();
    srv.listen() catch |e| {
        std.debug.print("sketerm-web: listen on {s} failed: {s}\n", .{ sock, @errorName(e) });
        return 1;
    };
    srv.run() catch |e| {
        std.debug.print("sketerm-web: serve failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
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

/// The argv handed to CEF: ours plus the headless switches when the
/// caller did not already supply them. Written into `buf` (no
/// allocator: this runs before one exists) and truncated rather than
/// overflowed, since Chromium ignores what it never sees anyway.
fn buildCefArgv(argv: []const [*:0]const u8, buf: *[64][*c]u8) [][*c]u8 {
    const extra = [_][*:0]const u8{ "--ozone-platform=headless", "--disable-gpu" };
    var n: usize = 0;
    for (argv) |a| {
        if (n == buf.len) break;
        buf[n] = @constCast(@ptrCast(a));
        n += 1;
    }
    for (extra) |e| {
        if (n == buf.len) break;
        const want = std.mem.span(e);
        const head = if (std.mem.indexOfScalar(u8, want, '=')) |eq| want[0 .. eq + 1] else want;
        var present = false;
        for (argv) |a| {
            const s = std.mem.span(a);
            if (std.mem.eql(u8, s, want) or std.mem.startsWith(u8, s, head)) present = true;
        }
        if (present) continue;
        buf[n] = @constCast(@ptrCast(e));
        n += 1;
    }
    return buf[0..n];
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
    var buf: [4096]u8 = undefined;
    if (path.len + 1 > buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and buf[i] != '/') continue;
        const save = buf[i];
        buf[i] = 0;
        _ = c.mkdir(@ptrCast(&buf), 0o700);
        buf[i] = save;
    }
}
