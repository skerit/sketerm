//! `sketerm app <host> <command...>` — run a remote GUI application
//! with its windows on the LOCAL desktop.
//!
//! The remote `sketerm-mux` daemon hosts the app and forwards its
//! Wayland protocol (parsed, never re-encoded) over the mux
//! connection; the running sketerm GUI is the compositor brain that
//! renders each window locally. There is therefore one hard
//! requirement: a sketerm window must already be open on this desktop.
//!
//! Transports mirror `sketerm mux`: automatic UDP with SSH fallback or forced Tor;
//! `-u` forces roaming UDP. `$SKETERM_SSH` overrides the ssh binary (tests fake
//! a remote host); key/agent auth is required (BatchMode — no password
//! prompts on a non-tty pipe).

const std = @import("std");
const c = @import("c.zig").c;
const Config = @import("config.zig").Config;
const mux_client = @import("mux/client.zig");

fn errMsg(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("sketerm app: " ++ fmt ++ "\n", args);
}

const USAGE =
    \\Usage: sketerm app [-u] [-i] [--headless] [--gpu] [user@]<host|domain> <command...>
    \\
    \\Run a graphical application on <host> (localhost works) with its
    \\windows on this desktop: the host's sketerm-mux daemon is the
    \\app's Wayland display, and an open sketerm window here renders
    \\the forwarded windows. Without a sketerm window the app still
    \\runs, headlessly, against that display — attach a viewer later
    \\with `sketerm mux <host> attach <session>`. Remote hosts need
    \\key/agent SSH auth and `sketerm-mux` installed.
    \\
    \\The command runs ON THE HOST'S DAEMON: cwd defaults to the
    \\daemon's own working directory (normally $HOME) and the
    \\environment is minimal, so pass absolute paths. For a synchronous headless run that
    \\inherits stdio and exits with the command's status (the
    \\xvfb-run replacement), use `sketerm run <command...>` /
    \\`sketerm-mux display run -- <command...>` instead.
    \\
    \\  -u    force mosh-style encrypted UDP. Without it, sketerm
    \\        probes UDP automatically and falls back to SSH.
    \\  --headless  don't look for a sketerm window at all: spawn the
    \\        app session, print its name + attach hint, exit 0.
    \\  -i    isolate: run under a private runtime dir + no shared D-Bus
    \\        bus, so single-instance apps (pcmanfm, GApplication) open
    \\        here instead of handing off to a copy already rendering on
    \\        another client. Cost: this session won't share the remote's
    \\        audio / notifications / portals.
    \\  --gpu render on the host's real GPU: the session compositor
    \\        announces linux-dmabuf and the app keeps its hardware GL
    \\        driver (default is software GL). LINEAR buffers use mmap;
    \\        tiled/modifier buffers use runtime EGL/GLES import.
    \\
    \\  sketerm app devbox gnome-calculator
    \\  sketerm app -u flaky-wifi-box firefox --new-window
    \\  sketerm app -i archdev pcmanfm
    \\
    \\<domain> names from config.conf `[domain.<name>]` sections work
    \\(transport defaults to auto; ssh/udp/tor can be forced per domain).
    \\
;

pub const Parsed = struct {
    host: []const u8,
    command: []const []const u8,
    udp: bool = false,
    isolated: bool = false,
    gpu: bool = false,
    headless: bool = false,
};

/// Pure argv split: leading -u/-i/--headless/--gpu flags (any order),
/// then host, rest = remote command (so the app's own flags pass
/// through). Null = show usage (missing host/command, or -h/--help).
pub fn parseArgs(args_in: []const []const u8) ?Parsed {
    var args = args_in;
    var udp = false;
    var isolated = false;
    var gpu = false;
    var headless = false;
    while (args.len > 0) {
        if (std.mem.eql(u8, args[0], "-u")) {
            udp = true;
        } else if (std.mem.eql(u8, args[0], "-i") or std.mem.eql(u8, args[0], "--isolated")) {
            isolated = true;
        } else if (std.mem.eql(u8, args[0], "--gpu")) {
            gpu = true;
        } else if (std.mem.eql(u8, args[0], "--headless")) {
            headless = true;
        } else break;
        args = args[1..];
    }
    if (args.len < 2) return null;
    if (std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")) return null;
    if (args[0].len == 0) return null;
    return .{ .host = args[0], .command = args[1..], .udp = udp, .isolated = isolated, .gpu = gpu, .headless = headless };
}

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const parsed = parseArgs(args) orelse {
        // An explicit --help is a successful request, so its usage goes
        // to stdout like every other exit-0 usage; a missing operand is
        // an error and stays on stderr.
        if (@import("util/invocation.zig").helpRequested(args)) {
            _ = c.fputs(USAGE, @import("util/platform.zig").stdout());
            return 0;
        }
        std.debug.print("{s}", .{USAGE});
        return 2;
    };

    // [domain.<name>] resolution, same as `sketerm ssh`. A udp:
    // domain (or -u) picks the roaming mux transport.
    var cfg = Config.load(allocator);
    defer cfg.deinit();
    var host_spec: []const u8 = parsed.host;
    const domain_spec = cfg.resolveDomain(host_spec, allocator);
    defer if (domain_spec) |s| allocator.free(s);
    if (domain_spec) |s| host_spec = s;
    var forced_udp_buf: [320]u8 = undefined;
    if (parsed.udp) {
        const remote = mux_client.RemoteSpec.parse(host_spec);
        host_spec = std.fmt.bufPrint(&forced_udp_buf, "udp:{s}", .{remote.host}) catch return 1;
    }

    // Spawn an app-kind session on the host's daemon and hand it to
    // the running GUI, whose compositor brain renders the windows.
    return runNativeApp(allocator, host_spec, parsed.command, cfg.muxConnectOptions(), parsed.isolated, parsed.gpu, parsed.headless, cfg.app_keyboard_layout);
}

/// The session runs whether or not a viewer renders it; say so
/// plainly instead of letting "no window here" read as "it failed".
///
/// `wayland` distinguishes the two host kinds: a Linux daemon forwards
/// surfaces from the session's own Wayland display, a macOS one has no
/// Wayland at all and streams captured window pixels. Claiming the
/// Wayland one unconditionally describes an architecture the Mac host
/// does not have.
fn headlessNotice(name: []const u8, host: []const u8, wayland: bool) void {
    const backend = if (wayland)
        "against its own Wayland display"
    else
        "and its windows stream as captured pixels (this host has no Wayland)";
    std.debug.print(
        "sketerm app: '{s}' is running HEADLESS on {s} {s} (no sketerm window here to render into).\n" ++
            "  Attach later:   sketerm mux {s} attach {s}\n" ++
            "  Still running?  sketerm mux {s} list   (an instant exit usually means the command failed on the host — cwd is the daemon's own, normally $HOME, and the env is minimal there, so use host-absolute paths)\n",
        .{ name, host, backend, host, name, host },
    );
    if (!wayland) {
        std.debug.print(
            "  On a Mac host:  Apple's OWN apps (Calculator, TextEdit, Safari, …) are SIGKILLed the instant they are started this way — macOS launch constraints refuse to let them be an ordinary child process. Use a third-party or self-built binary as the capture target.\n",
            .{},
        );
    }
}

/// Is `name` absent from the host's session list? True means the app
/// already exited — distinguishing "no viewer here" from "there is
/// nothing left to view". Unreachable daemon answers false: the
/// headless notice is the safer of the two claims.
fn sessionGone(allocator: std.mem.Allocator, name: []const u8, host: ?[]const u8) bool {
    const mux_cli = @import("ipc/mux_cli.zig");
    const parsed = mux_cli.fetchSessions(allocator, host) orelse return false;
    defer parsed.deinit();
    for (parsed.value.sessions) |s| {
        if (std.mem.eql(u8, s.name, name)) return false;
    }
    return true;
}

/// The app exited before any viewer could attach. Say that plainly —
/// and on a Mac host name the trap that causes it most often.
fn exitedNotice(name: []const u8, host: []const u8, wayland: bool) void {
    std.debug.print(
        "sketerm app: '{s}' EXITED on {s} before a window ever appeared — the command failed to start, it did not stay headless.\n" ++
            "  cwd is the daemon's own (normally $HOME) and its environment is minimal, so pass host-absolute paths.\n",
        .{ name, host },
    );
    if (!wayland) {
        std.debug.print(
            "  On a Mac host:  Apple's OWN apps (Calculator, TextEdit, Safari, …) are SIGKILLed the instant they are started this way — macOS launch constraints refuse to let them be an ordinary child process. Use a third-party or self-built binary.\n",
            .{},
        );
    }
}

/// Spawn an app session over the chosen transport, then have the
/// running GUI attach and render it. Inside a sketerm pane THIS pane
/// becomes the session view (like `sketerm mux attach`); outside, a
/// new tab. No GUI (or --headless) is NOT a failure: the session
/// keeps running headlessly and the notice says how to attach.
fn runNativeApp(
    allocator: std.mem.Allocator,
    host_spec: []const u8,
    command: []const []const u8,
    connect_options: mux_client.ConnectOptions,
    isolated: bool,
    gpu: bool,
    headless: bool,
    kb_layout: []const u8,
) u8 {
    const remote = mux_client.RemoteSpec.parse(host_spec);
    var conn = mux_client.Conn.connectRemote(allocator, host_spec, connect_options) catch {
        errMsg("could not reach {s} using {s} transport policy (key/agent auth + sketerm-mux required there)", .{ remote.host, @tagName(remote.mode) });
        return 1;
    };
    defer conn.deinit();

    var rnd: [4]u8 = undefined;
    _ = c.getentropy(&rnd, rnd.len);
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "app-{d}-{x}", .{
        c.getpid(),
        std.mem.readInt(u32, &rnd, .little),
    }) catch return 1;

    conn.sendJson(.spawn, .{
        .name = name,
        .argv = command,
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
        .app = true,
        .isolated = isolated,
        .gpu = gpu,
        .kb_layout = kb_layout,
    }) catch return 1;
    const ok = conn.recvExpectFor(&.{.ok}, 20_000) catch {
        errMsg("daemon on {s} refused the app session", .{remote.host});
        return 1;
    };
    // Which backend will render this session? The spawn reply carries
    // the session's Wayland display path; a macOS daemon has none and
    // captures window pixels instead. Read it before the frame dies.
    const Spawned = struct { wl_display: []const u8 = "" };
    var wayland = true;
    if (std.json.parseFromSlice(Spawned, allocator, ok.payload, .{ .ignore_unknown_fields = true })) |sp| {
        defer sp.deinit();
        wayland = sp.value.wl_display.len > 0 and !std.mem.eql(u8, sp.value.wl_display, "-");
    } else |_| {}
    ok.deinit(allocator);

    if (headless) {
        std.debug.print("sketerm app: '{s}' running headless on {s} over {s} — attach with: sketerm mux {s} attach {s}\n", .{ name, remote.host, @tagName(conn.transport), host_spec, name });
        return 0;
    }

    // A viewer needs a running GUI. None here = the app simply stays
    // headless (the spawn above already succeeded).
    const ipc_client = @import("ipc/client.zig");
    if (ipc_client.resolveSocket(allocator, null)) |gui_sock| {
        allocator.free(gui_sock);
    } else {
        // Same distinction as after a failed attach: with no window to
        // render into the session normally keeps running, but if the
        // command died on arrival there is nothing to attach to later
        // and saying otherwise just sends the user chasing a ghost.
        if (sessionGone(allocator, name, host_spec)) {
            exitedNotice(name, host_spec, wayland);
            return 1;
        }
        headlessNotice(name, host_spec, wayland);
        return 0;
    }

    // The GUI attaches with its own connection and owns the session
    // from here — over the same transport, so UDP sessions roam.
    const attach_host = host_spec;
    if (!@import("ipc/mux_cli.zig").guiCommand(allocator, "attach-session", name, attach_host, true)) {
        // guiCommand already printed the specific reason (e.g. "no
        // running sketerm window found", or "attach failed: no such
        // session"). Usually the session is unaffected by a failed
        // viewer attach — but an app that exits INSTANTLY is already
        // gone from the daemon by the time the GUI tries, and telling
        // the user it "is running HEADLESS" is then simply false. Ask
        // the daemon which of the two happened.
        if (sessionGone(allocator, name, attach_host)) {
            exitedNotice(name, attach_host, wayland);
            return 1;
        }
        headlessNotice(name, attach_host, wayland);
        return 0;
    }
    std.debug.print("sketerm: app session '{s}' on {s} over {s} — windows render via the sketerm GUI\n", .{ name, remote.host, @tagName(conn.transport) });
    return 0;
}

// ---------------- tests ----------------

test "remoteapp: parseArgs splits host + command" {
    const args = [_][]const u8{ "devbox", "firefox", "--new-window" };
    const p = parseArgs(&args).?;
    try std.testing.expectEqualStrings("devbox", p.host);
    try std.testing.expectEqual(@as(usize, 2), p.command.len);
    try std.testing.expectEqualStrings("--new-window", p.command[1]);
}

test "remoteapp: parseArgs handles -u" {
    const args = [_][]const u8{ "-u", "devbox", "firefox" };
    const p = parseArgs(&args).?;
    try std.testing.expect(p.udp);
    try std.testing.expectEqualStrings("devbox", p.host);
    const no_u = [_][]const u8{ "devbox", "firefox" };
    try std.testing.expect(!parseArgs(&no_u).?.udp);
    const u_only = [_][]const u8{ "-u", "devbox" };
    try std.testing.expect(parseArgs(&u_only) == null);
}

test "remoteapp: parseArgs handles -i (any order, with -u)" {
    const i_only = [_][]const u8{ "-i", "devbox", "pcmanfm" };
    const p = parseArgs(&i_only).?;
    try std.testing.expect(p.isolated and !p.udp);
    try std.testing.expectEqualStrings("devbox", p.host);
    try std.testing.expectEqualStrings("pcmanfm", p.command[0]);
    // Long form and order-independence with -u.
    const both = [_][]const u8{ "-u", "--isolated", "box", "app" };
    const q = parseArgs(&both).?;
    try std.testing.expect(q.isolated and q.udp);
    const both_rev = [_][]const u8{ "-i", "-u", "box", "app" };
    const r = parseArgs(&both_rev).?;
    try std.testing.expect(r.isolated and r.udp);
    // Default off; flags only consumed when leading.
    try std.testing.expect(!parseArgs(&[_][]const u8{ "box", "app" }).?.isolated);
    try std.testing.expect(!parseArgs(&[_][]const u8{ "box", "-i" }).?.isolated);
}

test "remoteapp: parseArgs handles --gpu (any order, pass-through after host)" {
    const g = [_][]const u8{ "--gpu", "devbox", "blender" };
    const p = parseArgs(&g).?;
    try std.testing.expect(p.gpu and !p.udp and !p.isolated);
    try std.testing.expectEqualStrings("devbox", p.host);
    const mixed = [_][]const u8{ "-u", "--gpu", "-i", "box", "app" };
    const q = parseArgs(&mixed).?;
    try std.testing.expect(q.gpu and q.udp and q.isolated);
    // Default off; a trailing --gpu belongs to the app, not us.
    const trailing = [_][]const u8{ "box", "app", "--gpu" };
    const r = parseArgs(&trailing).?;
    try std.testing.expect(!r.gpu);
    try std.testing.expectEqualStrings("--gpu", r.command[1]);
}

test "remoteapp: parseArgs handles --headless (any order, pass-through after host)" {
    const h = [_][]const u8{ "--headless", "box", "app" };
    const p = parseArgs(&h).?;
    try std.testing.expect(p.headless and !p.udp);
    const mixed = [_][]const u8{ "-u", "--headless", "--gpu", "box", "app" };
    const q = parseArgs(&mixed).?;
    try std.testing.expect(q.headless and q.udp and q.gpu);
    const trailing = [_][]const u8{ "box", "app", "--headless" };
    const r = parseArgs(&trailing).?;
    try std.testing.expect(!r.headless);
    try std.testing.expectEqualStrings("--headless", r.command[1]);
}

test "remoteapp: parseArgs rejects missing command / help" {
    const just_host = [_][]const u8{"devbox"};
    try std.testing.expect(parseArgs(&just_host) == null);
    const help = [_][]const u8{ "--help", "x" };
    try std.testing.expect(parseArgs(&help) == null);
    const empty = [_][]const u8{};
    try std.testing.expect(parseArgs(&empty) == null);
}
