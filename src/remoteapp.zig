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
    \\Usage: sketerm app [user@]<host|domain> <command...>
    \\
    \\Run a graphical application on a remote host with its windows on
    \\this desktop. The remote needs key/agent SSH auth and (for Linux
    \\remotes) the `waypipe` package; window data is compressed and
    \\damage-tracked, so this is far faster than X11 forwarding.
    \\
    \\  sketerm app devbox gnome-calculator
    \\  sketerm app user@10.0.0.7 firefox --new-window
    \\
    \\<domain> names from config.conf `[domain.<name>]` sections work.
    \\
;

pub const Parsed = struct {
    host: []const u8,
    command: []const []const u8,
};

/// Pure argv split: first arg = host, rest = remote command.
/// Null = show usage (missing host/command, or -h/--help).
pub fn parseArgs(args: []const []const u8) ?Parsed {
    if (args.len < 2) return null;
    if (std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")) return null;
    if (args[0].len == 0) return null;
    return .{ .host = args[0], .command = args[1..] };
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
/// Vulkan) counts and works.
fn hasLocalVulkanIcd() bool {
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
/// full path (allocated) or null.
fn findInPath(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
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
    // domain still reaches its host — remote apps ride SSH for now
    // (the roaming transport is a later phase).
    var cfg = Config.load(allocator);
    defer cfg.deinit();
    var host: []const u8 = parsed.host;
    const domain_spec = cfg.resolveDomain(host, allocator);
    defer if (domain_spec) |s| allocator.free(s);
    if (domain_spec) |s| host = s;
    if (std.mem.startsWith(u8, host, "udp:")) host = host["udp:".len..];

    var host_z_buf: [300:0]u8 = undefined;
    const host_z = std.fmt.bufPrintZ(&host_z_buf, "{s}", .{host}) catch {
        errMsg("host too long", .{});
        return 2;
    };

    // Local preflight: we need a Wayland session and the local half
    // of the forwarder.
    if (c.getenv("WAYLAND_DISPLAY") == null) {
        errMsg("no Wayland session ($WAYLAND_DISPLAY unset) — remote apps need a local Wayland compositor", .{});
        return 1;
    }
    const local_waypipe = findInPath(allocator, "waypipe") orelse {
        errMsg("`waypipe` is not installed locally (Arch: pacman -S waypipe)", .{});
        return 1;
    };
    defer allocator.free(local_waypipe);

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
            errMsg("{s} is macOS — remote macOS apps aren't supported yet (needs the window-streaming backend)", .{host});
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
    argv.append(allocator, "--ssh-bin") catch return 1;
    argv.append(allocator, sshBin()) catch return 1;
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

// ---------------- tests ----------------

test "remoteapp: parseArgs splits host + command" {
    const args = [_][]const u8{ "devbox", "firefox", "--new-window" };
    const p = parseArgs(&args).?;
    try std.testing.expectEqualStrings("devbox", p.host);
    try std.testing.expectEqual(@as(usize, 2), p.command.len);
    try std.testing.expectEqualStrings("--new-window", p.command[1]);
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
