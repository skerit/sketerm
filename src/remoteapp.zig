//! `sketerm app <host> <command...>` — run a remote GUI application
//! with its windows on the LOCAL desktop.
//!
//! Generic front end over per-remote-OS backends; the user never
//! names a backend. Phase 1 ships one: Wayland forwarding via
//! waypipe over SSH (Linux remote → Wayland local). The remote probe
//! (`uname` + tool discovery) is the seam where future backends
//! (e.g. a macOS window-streaming agent) plug in.
//!
//! Like the mux, `$SKETERM_SSH` overrides the ssh binary so tests
//! can fake a remote host, and key/agent auth is required
//! (BatchMode — no password prompts on a non-tty pipe).

const std = @import("std");
const c = @import("c.zig").c;
const Config = @import("config.zig").Config;

fn errMsg(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("sketerm app: " ++ fmt ++ "\n", args);
}

const USAGE =
    \\Usage: sketerm app [-u] [user@]<host|domain> <command...>
    \\
    \\Run a graphical application on a remote host with its windows on
    \\this desktop. The remote needs key/agent SSH auth and (for Linux
    \\remotes) the `waypipe` package; window data is compressed and
    \\damage-tracked, so this is far faster than X11 forwarding.
    \\
    \\  -u    mosh-style: bootstrap over SSH, then run over encrypted
    \\        UDP with roaming — the app survives network changes.
    \\        Needs `sketerm-mux` installed on the remote.
    \\
    \\  sketerm app devbox gnome-calculator
    \\  sketerm app -u flaky-wifi-box firefox --new-window
    \\
    \\<domain> names from config.conf `[domain.<name>]` sections work
    \\(udp-transport domains imply -u).
    \\
;

pub const Parsed = struct {
    host: []const u8,
    command: []const []const u8,
    udp: bool = false,
};

/// Pure argv split: optional -u, then host, rest = remote command.
/// Null = show usage (missing host/command, or -h/--help).
pub fn parseArgs(args_in: []const []const u8) ?Parsed {
    var args = args_in;
    var udp = false;
    if (args.len > 0 and std.mem.eql(u8, args[0], "-u")) {
        udp = true;
        args = args[1..];
    }
    if (args.len < 2) return null;
    if (std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")) return null;
    if (args[0].len == 0) return null;
    return .{ .host = args[0], .command = args[1..], .udp = udp };
}

/// What the remote probe found. The dispatch point for backends.
pub const RemoteKind = union(enum) {
    /// Linux with waypipe installed → Wayland forwarding backend.
    /// `gpu` = a Vulkan ICD exists there, so GPU-buffer (dmabuf)
    /// forwarding can work; without one waypipe 0.11 ABORTS the
    /// connection when the compositor advertises dmabuf, so we must
    /// pass --no-gpu (software/shm transfer) instead.
    wayland: struct { gpu: bool },
    /// Linux, but no waypipe on PATH.
    linux_no_waypipe: void,
    /// macOS — no backend yet (needs the streaming agent).
    darwin: void,
    /// Something else (BSD, …).
    other: []const u8,
};

/// Classify the probe output: line 1 `uname`, line 2 the waypipe
/// path (or "-"), line 3 "vk"/"-" for a Vulkan ICD. Pure for
/// testability.
pub fn classifyProbe(output: []const u8) ?RemoteKind {
    var it = std.mem.splitScalar(u8, output, '\n');
    const uname = std.mem.trim(u8, it.next() orelse return null, &std.ascii.whitespace);
    const tool = std.mem.trim(u8, it.next() orelse "", &std.ascii.whitespace);
    const vk = std.mem.trim(u8, it.next() orelse "", &std.ascii.whitespace);
    if (std.mem.eql(u8, uname, "Linux")) {
        if (tool.len > 0 and !std.mem.eql(u8, tool, "-"))
            return .{ .wayland = .{ .gpu = std.mem.eql(u8, vk, "vk") } };
        return .linux_no_waypipe;
    }
    if (std.mem.eql(u8, uname, "Darwin")) return .darwin;
    if (uname.len == 0) return null;
    return .{ .other = uname };
}

/// Any Vulkan ICD manifest installed locally? Same check the probe
/// runs remotely. Loaders look in these two; lavapipe (software
/// Vulkan) counts and works. Also used by wlbridge + the mux daemon:
/// waypipe (0.11) needs Vulkan for GPU-buffer transfer and ABORTS
/// connections without it, so Vulkan-less ends must pass --no-gpu.
pub fn hasLocalVulkanIcd() bool {
    for ([_][*:0]const u8{ "/usr/share/vulkan/icd.d", "/etc/vulkan/icd.d" }) |dir| {
        const d = c.opendir(dir) orelse continue;
        defer _ = c.closedir(d);
        while (c.readdir(d)) |ent| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
            if (std.mem.endsWith(u8, name, ".json")) return true;
        }
    }
    return false;
}

/// Search $PATH for an executable; returns the matched directory's
/// full path (allocated, sentinel-carrying so free() sees the true
/// size) or null.
fn findInPath(allocator: std.mem.Allocator, name: []const u8) ?[:0]u8 {
    const path_env = c.getenv("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, std.mem.span(path_env), ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, name }, 0) catch return null;
        if (c.access(full.ptr, c.X_OK) == 0) return full;
        allocator.free(full);
    }
    return null;
}

fn sshBin() [*:0]const u8 {
    const env = c.getenv("SKETERM_SSH");
    return if (env != null) env else "ssh";
}

/// One ssh round trip: `uname` + waypipe discovery. Returns the raw
/// probe output (caller frees) or an error when the host is
/// unreachable / auth fails.
fn probeRemote(allocator: std.mem.Allocator, host: [:0]const u8) ![]u8 {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.PipeFailed;
    const rd = fds[0];
    const wr = fds[1];

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(rd);
        _ = c.close(wr);
        return error.ForkFailed;
    }
    if (pid == 0) {
        // Child: stdout → pipe; stderr passes through so ssh's own
        // auth/connection errors reach the user verbatim.
        _ = c.close(rd);
        _ = c.dup2(wr, 1);
        _ = c.close(wr);
        const argv = [_:null]?[*:0]const u8{
            sshBin(), "-T", "-o", "BatchMode=yes", host.ptr,
            "uname; command -v waypipe || echo -; " ++
                "ls /usr/share/vulkan/icd.d/*.json /etc/vulkan/icd.d/*.json >/dev/null 2>&1 && echo vk || echo -",
            null,
        };
        _ = c.execvp(argv[0].?, @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    _ = c.close(wr);
    defer _ = c.close(rd);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [512]u8 = undefined;
    while (true) {
        const n = c.read(rd, &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
        if (out.items.len > 4096) break; // probe output is two short lines
    }
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    const code: u8 = if (c.WIFEXITED(status)) @intCast(c.WEXITSTATUS(status)) else 255;
    if (code != 0) {
        out.deinit(allocator);
        return error.SshFailed;
    }
    return out.toOwnedSlice(allocator);
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
    var host: []const u8 = parsed.host;
    var use_udp = parsed.udp;
    const domain_spec = cfg.resolveDomain(host, allocator);
    defer if (domain_spec) |s| allocator.free(s);
    if (domain_spec) |s| host = s;
    if (std.mem.startsWith(u8, host, "udp:")) {
        use_udp = true;
        host = host["udp:".len..];
    }

    var host_z_buf: [300:0]u8 = undefined;
    const host_z = std.fmt.bufPrintZ(&host_z_buf, "{s}", .{host}) catch {
        errMsg("host too long", .{});
        return 2;
    };

    // NATIVE-FIRST: with a sketerm GUI running (the compositor
    // brain) and sketerm-mux on the remote, no waypipe is involved
    // on either end — spawn an app session and let the GUI render.
    if (!use_udp) {
        if (runNativeApp(allocator, host, parsed.command)) |code| return code;
    }

    // Legacy waypipe fallbacks. Local preflight: we need a Wayland
    // session and the local half of the forwarder.
    if (c.getenv("WAYLAND_DISPLAY") == null) {
        errMsg("no Wayland session ($WAYLAND_DISPLAY unset) — remote apps need a local Wayland compositor", .{});
        return 1;
    }
    const local_waypipe = findInPath(allocator, "waypipe") orelse {
        errMsg("`waypipe` is not installed locally (Arch: pacman -S waypipe)", .{});
        return 1;
    };
    defer allocator.free(local_waypipe);

    // Roaming transport: one-shot mux session over encrypted UDP.
    // The remote daemon wraps the app in waypipe server itself; the
    // ssh probe below is not needed (the bootstrap IS the probe).
    if (use_udp) {
        const range: ?[]const u8 = if (cfg.mux_udp_port_range.len > 0)
            cfg.mux_udp_port_range
        else
            null;
        return runMuxApp(allocator, host, parsed.command, range);
    }

    // Remote probe → backend dispatch.
    const probe = probeRemote(allocator, host_z) catch {
        errMsg("could not reach {s} over ssh (key/agent auth required; check `ssh {s}` works)", .{ host, host });
        return 1;
    };
    defer allocator.free(probe);
    const kind = classifyProbe(probe) orelse {
        errMsg("unexpected probe reply from {s}: '{s}'", .{ host, std.mem.trim(u8, probe, &std.ascii.whitespace) });
        return 1;
    };
    var no_gpu = false;
    switch (kind) {
        .wayland => |w| {
            // GPU-buffer forwarding needs working Vulkan on BOTH
            // ends; otherwise force shm transfer or waypipe aborts.
            no_gpu = !w.gpu or !hasLocalVulkanIcd();
        },
        .linux_no_waypipe => {
            errMsg("{s} has no `waypipe` — install it there (Arch: pacman -S waypipe; Debian: apt install waypipe)", .{host});
            return 1;
        },
        .darwin => {
            // macOS apps stream as pixels via the mux daemon's
            // ScreenCaptureKit agent — a durable-session feature,
            // not a one-shot exec like the waypipe path.
            errMsg("{s} is macOS — run the app in a durable session instead: `sketerm mux {s}`, then launch it from the session shell (needs a capture-enabled sketerm-mux on the Mac: docs/REMOTE.md \"Remote macOS apps\")", .{ host, host });
            return 1;
        },
        .other => |u| {
            errMsg("{s} runs '{s}', which has no remote-app backend yet", .{ host, u });
            return 1;
        },
    }

    return execWaypipeSsh(allocator, host_z, parsed.command, no_gpu);
}

/// Hand the process over to `waypipe ssh`: it forwards the Wayland
/// socket over the ssh connection, runs the command remotely, and
/// exits when the app does. Replacing our process keeps signals and
/// the exit status flowing naturally.
fn execWaypipeSsh(allocator: std.mem.Allocator, host: [:0]const u8, command: []const []const u8, no_gpu: bool) u8 {
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer argv.deinit(allocator);

    // Remote windows get a visible "[host] " title prefix.
    var title_buf: [320:0]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "[{s}] ", .{host}) catch "[remote] ";

    argv.append(allocator, "waypipe") catch return 1;
    if (no_gpu) argv.append(allocator, "--no-gpu") catch return 1;
    argv.append(allocator, "--title-prefix") catch return 1;
    argv.append(allocator, title.ptr) catch return 1;
    // waypipe 0.11 dropped --ssh-bin; it finds `ssh` on PATH.
    // ($SKETERM_SSH is honored by the mux transports, not here.)
    argv.append(allocator, "ssh") catch return 1;
    argv.append(allocator, host.ptr) catch return 1;
    for (command) |arg| {
        const z = allocator.dupeZ(u8, arg) catch return 1;
        argv.append(allocator, z.ptr) catch return 1;
    }
    argv.append(allocator, null) catch return 1;

    _ = c.execvp("waypipe", @ptrCast(argv.items.ptr));
    errMsg("failed to exec waypipe", .{});
    return 1;
}

// ── Roaming transport: one-shot mux session over rudp ───────────

const mux_client = @import("mux/client.zig");
const mux_wire = @import("mux/wire.zig");
const wlbridge = @import("wlbridge.zig");

/// A forwarded app stream in the CLI pump (mirror of the GUI's
/// Terminal.WlChan, but poll-driven instead of GLib-watched).
const PumpChan = struct {
    id: u32,
    fd: c_int,
    pending: std.ArrayList(u8) = .empty,
};

/// `sketerm app -u`: bootstrap the daemon over SSH, then run the app
/// as a one-shot mux session over encrypted roaming UDP. The daemon
/// wraps the command in `waypipe server`; its display connections
/// come back as byte channels which we pump into the local waypipe
/// client. The session's terminal output streams to our stdout.
/// The sketerm-native path for plain `sketerm app`: spawn an
/// app-kind session on the host's daemon over SSH and hand it to
/// the running GUI, whose compositor brain renders the windows.
/// Null = prerequisites missing (no GUI / no remote daemon) —
/// caller falls back to waypipe.
fn runNativeApp(allocator: std.mem.Allocator, host: []const u8, command: []const []const u8) ?u8 {
    const ipc_client = @import("ipc/client.zig");
    const gui_sock = ipc_client.resolveSocket(allocator, null) orelse return null;
    allocator.free(gui_sock);

    var conn = mux_client.Conn.connectSsh(allocator, host) catch return null;
    defer conn.deinit();

    var rnd: [4]u8 = undefined;
    _ = c.getentropy(&rnd, rnd.len);
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "app-{d}-{x}", .{
        c.getpid(),
        std.mem.readInt(u32, &rnd, .little),
    }) catch return null;

    conn.sendJson(.spawn, .{
        .name = name,
        .argv = command,
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
        .app = true,
    }) catch return null;
    const ok = conn.recvExpect(&.{.ok}) catch {
        errMsg("daemon on {s} refused the app session", .{host});
        return 1;
    };
    ok.deinit(allocator);

    // The GUI attaches with its own connection and owns the session
    // from here. Inside a sketerm pane, THIS pane becomes the
    // session view (like `sketerm mux attach`); outside, a new tab.
    if (!@import("ipc/mux_cli.zig").guiCommand(allocator, "attach-session", name, host, true)) {
        errMsg("session '{s}' spawned on {s}, but no sketerm GUI took it (attach manually: sketerm mux {s} attach {s})", .{ name, host, host, name });
        return 1;
    }
    std.debug.print("sketerm: app session '{s}' on {s} — windows render via the sketerm GUI\n", .{ name, host });
    return 0;
}

fn runMuxApp(allocator: std.mem.Allocator, host: []const u8, command: []const []const u8, port_range: ?[]const u8) u8 {
    var conn = mux_client.Conn.connectUdp(allocator, host, port_range) catch {
        errMsg("UDP transport to {s} failed (needs key auth + sketerm-mux installed there)", .{host});
        return 1;
    };
    defer conn.deinit();

    // Unique one-shot session name.
    var rnd: [4]u8 = undefined;
    _ = c.getentropy(&rnd, rnd.len);
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "app-{d}-{x}", .{
        c.getpid(),
        std.mem.readInt(u32, &rnd, .little),
    }) catch return 1;

    // Pipeline spawn + attach in back-to-back frames: the daemon
    // handles both in order before the freshly-spawned app can race
    // its first display connection against our attachment.
    // This client is headless: no compositor brain, only the local
    // waypipe-client bridge — the session must use the waypipe wrap.
    conn.sendJson(.spawn, .{ .name = name, .argv = command, .rows = @as(u16, 24), .cols = @as(u16, 80), .app = true, .wl_mode = "waypipe" }) catch {
        errMsg("spawn failed", .{});
        return 1;
    };
    conn.sendJson(.attach, .{ .name = name }) catch {
        errMsg("attach failed", .{});
        return 1;
    };

    return pumpMuxApp(allocator, &conn);
}

/// Poll loop: mux frames on one side, local waypipe-client sockets
/// on the other, until the remote app exits.
fn pumpMuxApp(allocator: std.mem.Allocator, conn: *mux_client.Conn) u8 {
    var chans: std.ArrayList(*PumpChan) = .empty;
    defer {
        for (chans.items) |ch| {
            _ = c.close(ch.fd);
            ch.pending.deinit(allocator);
            allocator.destroy(ch);
        }
        chans.deinit(allocator);
    }

    while (true) {
        var fds: std.ArrayList(c.struct_pollfd) = .empty;
        defer fds.deinit(allocator);
        fds.append(allocator, .{ .fd = conn.fd, .events = c.POLLIN, .revents = 0 }) catch return 1;
        for (chans.items) |ch| {
            var ev: c_short = c.POLLIN;
            if (ch.pending.items.len > 0) ev |= c.POLLOUT;
            fds.append(allocator, .{ .fd = ch.fd, .events = ev, .revents = 0 }) catch return 1;
        }
        const pr = c.poll(fds.items.ptr, @intCast(fds.items.len), 1000);
        if (pr < 0 and std.posix.errno(pr) != .INTR) return 1;

        // Mux side: read, peel, dispatch.
        if (fds.items[0].revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) {
            var tmp: [32768]u8 = undefined;
            const n = c.read(conn.fd, &tmp, tmp.len);
            if (n <= 0) {
                errMsg("connection lost", .{});
                return 1;
            }
            conn.rbuf.appendSlice(allocator, tmp[0..@intCast(n)]) catch return 1;
            while (true) {
                const peeled = (mux_wire.peelFrame(conn.rbuf.items) catch return 1) orelse break;
                const verdict = handleMuxAppFrame(allocator, conn, &chans, peeled.frame);
                const remaining = conn.rbuf.items.len - peeled.consumed;
                std.mem.copyForwards(u8, conn.rbuf.items[0..remaining], conn.rbuf.items[peeled.consumed..]);
                conn.rbuf.shrinkRetainingCapacity(remaining);
                if (verdict) |code| return code;
            }
        }

        // Channel sockets. The fds snapshot may be stale after a
        // handler removed a channel — re-match by fd.
        var fi: usize = 1;
        while (fi < fds.items.len) : (fi += 1) {
            const pfd = fds.items[fi];
            if (pfd.revents == 0) continue;
            const ch = findPumpChanByFd(&chans, pfd.fd) orelse continue;
            if (pfd.revents & c.POLLIN != 0) {
                var buf: [4 + 16384]u8 = undefined;
                const n = c.read(ch.fd, buf[4..].ptr, buf.len - 4);
                if (n <= 0) {
                    closePumpChan(allocator, conn, &chans, ch, true);
                    continue;
                }
                std.mem.writeInt(u32, buf[0..4], ch.id, .little);
                conn.sendFrame(.chan_data, buf[0 .. 4 + @as(usize, @intCast(n))]) catch return 1;
            }
            if (findPumpChanByFd(&chans, pfd.fd) == null) continue;
            if (pfd.revents & c.POLLOUT != 0 and ch.pending.items.len > 0) {
                const w = c.write(ch.fd, ch.pending.items.ptr, ch.pending.items.len);
                if (w < 0 and std.posix.errno(w) != .AGAIN) {
                    closePumpChan(allocator, conn, &chans, ch, true);
                    continue;
                }
                if (w > 0) {
                    const wn: usize = @intCast(w);
                    const remaining = ch.pending.items.len - wn;
                    std.mem.copyForwards(u8, ch.pending.items[0..remaining], ch.pending.items[wn..]);
                    ch.pending.shrinkRetainingCapacity(remaining);
                }
            }
            if (pfd.revents & (c.POLLHUP | c.POLLERR) != 0 and pfd.revents & c.POLLIN == 0) {
                closePumpChan(allocator, conn, &chans, ch, true);
            }
        }
    }
}

/// Non-null = exit the pump with this status code.
fn handleMuxAppFrame(
    allocator: std.mem.Allocator,
    conn: *mux_client.Conn,
    chans: *std.ArrayList(*PumpChan),
    frame: mux_wire.Frame,
) ?u8 {
    switch (frame.ftype) {
        .ok, .snapshot => {}, // spawn ack / attach snapshot — nothing to mirror
        .err => {
            errMsg("daemon: {s}", .{frame.payload});
            return 1;
        },
        .events => printEventsText(allocator, frame.payload),
        .exit => {
            if (frame.payload.len >= 4) {
                const status = std.mem.readInt(i32, frame.payload[0..4], .little);
                if (status != 0) errMsg("app exited with status {d}", .{status});
                return if (status >= 0 and status <= 255) @intCast(status) else 1;
            }
            return 0;
        },
        .gone => {
            errMsg("session closed by daemon", .{});
            return 1;
        },
        .chan_open => {
            const open = mux_wire.decodeChanOpen(frame.payload) orelse return null;
            var hdr: [4]u8 = undefined;
            if (open.kind != .wayland) {
                conn.sendFrame(.chan_close, mux_wire.putChanHeader(&hdr, open.id)) catch {};
                return null;
            }
            const fd = wlbridge.connectApp() orelse {
                conn.sendFrame(.chan_close, mux_wire.putChanHeader(&hdr, open.id)) catch {};
                return null;
            };
            const ch = allocator.create(PumpChan) catch {
                _ = c.close(fd);
                return null;
            };
            ch.* = .{ .id = open.id, .fd = fd };
            chans.append(allocator, ch) catch {
                _ = c.close(fd);
                allocator.destroy(ch);
            };
        },
        .chan_data => {
            const id = mux_wire.decodeChanId(frame.payload) orelse return null;
            const ch = findPumpChan(chans, id) orelse return null;
            const bytes = frame.payload[4..];
            var off: usize = 0;
            if (ch.pending.items.len == 0) {
                while (off < bytes.len) {
                    const n = c.write(ch.fd, bytes.ptr + off, bytes.len - off);
                    if (n <= 0) break;
                    off += @intCast(n);
                }
            }
            if (off < bytes.len) {
                ch.pending.appendSlice(allocator, bytes[off..]) catch {
                    closePumpChan(allocator, conn, chans, ch, true);
                };
            }
        },
        .chan_close => {
            const id = mux_wire.decodeChanId(frame.payload) orelse return null;
            if (findPumpChan(chans, id)) |ch| closePumpChan(allocator, conn, chans, ch, false);
        },
        else => {},
    }
    return null;
}

fn findPumpChan(chans: *std.ArrayList(*PumpChan), id: u32) ?*PumpChan {
    for (chans.items) |ch| {
        if (ch.id == id) return ch;
    }
    return null;
}

fn findPumpChanByFd(chans: *std.ArrayList(*PumpChan), fd: c_int) ?*PumpChan {
    for (chans.items) |ch| {
        if (ch.fd == fd) return ch;
    }
    return null;
}

fn closePumpChan(
    allocator: std.mem.Allocator,
    conn: *mux_client.Conn,
    chans: *std.ArrayList(*PumpChan),
    ch: *PumpChan,
    notify: bool,
) void {
    if (notify) {
        var hdr: [4]u8 = undefined;
        conn.sendFrame(.chan_close, mux_wire.putChanHeader(&hdr, ch.id)) catch {};
    }
    _ = c.close(ch.fd);
    ch.pending.deinit(allocator);
    for (chans.items, 0..) |it, i| {
        if (it == ch) {
            _ = chans.swapRemove(i);
            break;
        }
    }
    allocator.destroy(ch);
}

/// Best-effort text rendering of the session's terminal output to
/// our stdout — enough to see the app's startup errors. Layout
/// escapes are dropped; only printable runs + newlines survive.
fn printEventsText(allocator: std.mem.Allocator, payload: []const u8) void {
    if (payload.len < 12) return;
    var r = mux_wire.Reader.init(payload[12..]);
    while (!r.atEnd()) {
        var ev = r.getEvent(allocator) catch return;
        switch (ev) {
            .print => |cp| {
                var ubuf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(cp), &ubuf) catch 0;
                if (n > 0) _ = c.write(1, &ubuf, n);
            },
            .print_byte => |b| _ = c.write(1, &b, 1),
            .print_run => |pr| _ = c.write(1, &pr.bytes, pr.len),
            .execute => |b| {
                if (b == '\n' or b == '\r' or b == '\t') _ = c.write(1, &b, 1);
            },
            else => {},
        }
        ev.deinit(allocator);
    }
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

test "remoteapp: parseArgs rejects missing command / help" {
    const just_host = [_][]const u8{"devbox"};
    try std.testing.expect(parseArgs(&just_host) == null);
    const help = [_][]const u8{ "--help", "x" };
    try std.testing.expect(parseArgs(&help) == null);
    const empty = [_][]const u8{};
    try std.testing.expect(parseArgs(&empty) == null);
}

test "remoteapp: classifyProbe backend dispatch" {
    const gpu = classifyProbe("Linux\n/usr/bin/waypipe\nvk\n").?;
    try std.testing.expect(gpu.wayland.gpu);
    const nogpu = classifyProbe("Linux\n/usr/bin/waypipe\n-\n").?;
    try std.testing.expect(!nogpu.wayland.gpu);
    // Old two-line reply (no vk line) degrades to no-gpu.
    const short = classifyProbe("Linux\n/usr/bin/waypipe\n").?;
    try std.testing.expect(!short.wayland.gpu);
    try std.testing.expect(classifyProbe("Linux\n-\n-\n").? == .linux_no_waypipe);
    try std.testing.expect(classifyProbe("Darwin\n-\n-\n").? == .darwin);
    const bsd = classifyProbe("OpenBSD\n-\n-\n").?;
    try std.testing.expectEqualStrings("OpenBSD", bsd.other);
    try std.testing.expect(classifyProbe("") == null);
}
