//! `sketerm app <host> <command...>` — run a remote GUI application
//! with its windows on the LOCAL desktop.
//!
//! The remote `sketerm-mux` daemon hosts the app and forwards its
//! Wayland protocol (parsed, never re-encoded) over the mux
//! connection; the running sketerm GUI is the compositor brain that
//! renders each window locally. There is therefore one hard
//! requirement: a sketerm window must already be open on this desktop.
//!
//! Transports mirror `sketerm mux`: automatic UDP with SSH fallback;
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
    \\Usage: sketerm app [-u] [-i] [--gpu] [user@]<host|domain> <command...>
    \\
    \\Run a graphical application on a remote host with its windows on
    \\this desktop. A sketerm window must already be open here — it
    \\renders the forwarded windows. The remote needs key/agent SSH
    \\auth and `sketerm-mux` installed.
    \\
    \\  -u    force mosh-style encrypted UDP. Without it, sketerm
    \\        probes UDP automatically and falls back to SSH.
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
    \\(transport defaults to auto; ssh/udp can be forced per domain).
    \\
;

pub const Parsed = struct {
    host: []const u8,
    command: []const []const u8,
    udp: bool = false,
    isolated: bool = false,
    gpu: bool = false,
};

/// Pure argv split: leading -u/-i/--gpu flags (any order), then host,
/// rest = remote command (so the app's own flags pass through). Null =
/// show usage (missing host/command, or -h/--help).
pub fn parseArgs(args_in: []const []const u8) ?Parsed {
    var args = args_in;
    var udp = false;
    var isolated = false;
    var gpu = false;
    while (args.len > 0) {
        if (std.mem.eql(u8, args[0], "-u")) {
            udp = true;
        } else if (std.mem.eql(u8, args[0], "-i") or std.mem.eql(u8, args[0], "--isolated")) {
            isolated = true;
        } else if (std.mem.eql(u8, args[0], "--gpu")) {
            gpu = true;
        } else break;
        args = args[1..];
    }
    if (args.len < 2) return null;
    if (std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")) return null;
    if (args[0].len == 0) return null;
    return .{ .host = args[0], .command = args[1..], .udp = udp, .isolated = isolated, .gpu = gpu };
}

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const parsed = parseArgs(args) orelse {
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
    // Null = no GUI to render into.
    if (runNativeApp(allocator, host_spec, parsed.command, cfg.udpRange(), parsed.isolated, parsed.gpu, cfg.app_keyboard_layout)) |code| return code;
    errMsg("no sketerm window is open on this desktop to render the app — open one and retry", .{});
    return 1;
}

/// Spawn an app session over the chosen transport, then have the
/// running GUI attach and render it. Inside a sketerm pane THIS pane
/// becomes the session view (like `sketerm mux attach`); outside, a
/// new tab. Null = no running GUI (caller reports it); any other
/// failure returns a status with its own message.
fn runNativeApp(
    allocator: std.mem.Allocator,
    host_spec: []const u8,
    command: []const []const u8,
    port_range: ?[]const u8,
    isolated: bool,
    gpu: bool,
    kb_layout: []const u8,
) ?u8 {
    const ipc_client = @import("ipc/client.zig");
    const gui_sock = ipc_client.resolveSocket(allocator, null) orelse return null;
    allocator.free(gui_sock);

    const remote = mux_client.RemoteSpec.parse(host_spec);
    var conn = mux_client.Conn.connectRemote(allocator, host_spec, port_range) catch {
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
    ok.deinit(allocator);

    // The GUI attaches with its own connection and owns the session
    // from here — over the same transport, so UDP sessions roam.
    const attach_host = host_spec;
    if (!@import("ipc/mux_cli.zig").guiCommand(allocator, "attach-session", name, attach_host, true)) {
        // guiCommand already printed the specific reason (e.g. "no
        // running sketerm window found", or "attach failed: no such
        // session"). Add the likely cause + the manual fallback.
        errMsg(
            "couldn't display '{s}' on {s} (reason above). A 'no such session' right after spawn usually means the command exited on the host — the command + paths run THERE, so use host-absolute paths (no client-side ~). Manual attach: sketerm mux {s} attach {s}",
            .{ name, attach_host, attach_host, name },
        );
        return 1;
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

test "remoteapp: parseArgs rejects missing command / help" {
    const just_host = [_][]const u8{"devbox"};
    try std.testing.expect(parseArgs(&just_host) == null);
    const help = [_][]const u8{ "--help", "x" };
    try std.testing.expect(parseArgs(&help) == null);
    const empty = [_][]const u8{};
    try std.testing.expect(parseArgs(&empty) == null);
}
