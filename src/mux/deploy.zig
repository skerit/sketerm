//! Automatic content-addressed deployment of the portable remote mux.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const pathZ = @import("../util/pathz.zig").pathZ;
const filehash = @import("../util/filehash.zig");

const CHECK_MISSING: u8 = 66;
const CHECK_UNSUPPORTED: u8 = 65;
const SSH_TIMEOUT_MS: i64 = 20_000;

const Arch = enum { x86_64, aarch64 };

const Artifact = struct {
    path: []const u8,
    arch: Arch,
    hash: filehash.Sha256,
};

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    /// Shell expression intentionally retains $HOME for remote expansion.
    path: [:0]u8,

    pub fn deinit(self: *Prepared) void {
        self.allocator.free(self.path);
    }
};

const Runner = struct {
    ctx: ?*anyopaque = null,
    run: *const fn (?*anyopaque, [*:0]const u8, []const u8, [:0]const u8, ?[]const u8) u8,
};

/// Ensure the matching portable mux exists remotely; null preserves PATH fallback.
pub fn prepare(allocator: std.mem.Allocator, host: []const u8) ?Prepared {
    // Existing test/transport wrappers expect only the historical proxy argv.
    // An explicit artifact opts a wrapper into deployment testing or use.
    if (c.getenv("SKETERM_SSH") != null and c.getenv("SKETERM_MUX_PORTABLE") == null) return null;

    var artifact_path_buf: [4096:0]u8 = undefined;
    const artifact_path = findPortable(&artifact_path_buf) orelse return null;
    const artifact = inspectArtifact(artifact_path) orelse return null;
    const ssh_env = c.getenv("SKETERM_SSH");
    const ssh_bin: [*:0]const u8 = if (ssh_env) |p| p else "ssh";
    return ensureUsing(allocator, host, ssh_bin, artifact, .{ .run = runSshCommand });
}

/// Resolve the expected content-addressed path without touching the network.
pub fn localPath(allocator: std.mem.Allocator) ?Prepared {
    if (c.getenv("SKETERM_SSH") != null and c.getenv("SKETERM_MUX_PORTABLE") == null) return null;
    var artifact_path_buf: [4096:0]u8 = undefined;
    const artifact_path = findPortable(&artifact_path_buf) orelse return null;
    const artifact = inspectArtifact(artifact_path) orelse return null;
    const remote_path = std.fmt.allocPrintSentinel(
        allocator,
        "$HOME/.cache/sketerm/mux/sketerm-mux-{s}",
        .{&artifact.hash.hex},
        0,
    ) catch return null;
    return .{ .allocator = allocator, .path = remote_path };
}

/// ControlPath uses ~/.ssh, so only request multiplexing when it exists.
pub fn canMultiplex() bool {
    const home_raw = c.getenv("HOME") orelse return false;
    const home = std.mem.span(@as([*:0]const u8, @ptrCast(home_raw)));
    var path_buf: [4096:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/.ssh", .{home}) catch return false;
    var st: c.struct_stat = undefined;
    return c.stat(path.ptr, &st) == 0 and (st.st_mode & c.S_IFMT) == c.S_IFDIR;
}

fn findPortable(buf: *[4096:0]u8) ?[:0]const u8 {
    if (c.getenv("SKETERM_MUX_PORTABLE")) |raw| {
        const value = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        const path = std.fmt.bufPrintZ(buf, "{s}", .{value}) catch return null;
        return if (c.access(path.ptr, c.R_OK) == 0) path else null;
    }

    var exe_buf: [4096]u8 = undefined;
    if (platform.exePath(&exe_buf)) |exe| {
        if (std.mem.lastIndexOfScalar(u8, exe, '/')) |slash| {
            const dir = exe[0..slash];
            const sibling = std.fmt.bufPrintZ(buf, "{s}/sketerm-mux-portable", .{dir}) catch return null;
            if (c.access(sibling.ptr, c.R_OK) == 0) return sibling;
            const installed = std.fmt.bufPrintZ(buf, "{s}/../lib/sketerm/sketerm-mux-portable", .{dir}) catch return null;
            if (c.access(installed.ptr, c.R_OK) == 0) return installed;
        }
    }
    const installed = std.fmt.bufPrintZ(buf, "/usr/lib/sketerm/sketerm-mux-portable", .{}) catch return null;
    return if (c.access(installed.ptr, c.R_OK) == 0) installed else null;
}

fn inspectArtifact(path: []const u8) ?Artifact {
    var path_buf: [4096]u8 = undefined;
    const fd = c.open(pathZ(&path_buf, path) catch return null, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG) return null;
    var header: [20]u8 = undefined;
    if (c.read(fd, &header, header.len) != header.len) return null;
    const arch = elfArch(&header) orelse return null;
    const hash = filehash.sha256File(path) orelse return null;
    return .{ .path = path, .arch = arch, .hash = hash };
}

fn elfArch(header: []const u8) ?Arch {
    if (header.len < 20 or !std.mem.eql(u8, header[0..4], "\x7fELF")) return null;
    if (header[4] != 2 or header[5] != 1) return null; // ELF64, little-endian
    return switch (std.mem.readInt(u16, header[18..20], .little)) {
        62 => .x86_64,
        183 => .aarch64,
        else => null,
    };
}

fn ensureUsing(
    allocator: std.mem.Allocator,
    host: []const u8,
    ssh_bin: [*:0]const u8,
    artifact: Artifact,
    runner: Runner,
) ?Prepared {
    const hash = &artifact.hash.hex;
    const arch_case = switch (artifact.arch) {
        .x86_64 => "Linux:x86_64|Linux:amd64",
        .aarch64 => "Linux:aarch64|Linux:arm64",
    };
    const remote_path = std.fmt.allocPrintSentinel(
        allocator,
        "$HOME/.cache/sketerm/mux/sketerm-mux-{s}",
        .{hash},
        0,
    ) catch return null;
    var keep_remote_path = false;
    defer if (!keep_remote_path) allocator.free(remote_path);

    const check = std.fmt.allocPrintSentinel(
        allocator,
        "case \"$(uname -s 2>/dev/null):$(uname -m 2>/dev/null)\" in {s}) ;; *) exit {d};; esac; " ++
            "p=\"{s}\"; [ -x \"$p\" ] || exit {d}; " ++
            "h=$(sha256sum \"$p\" 2>/dev/null) || exit {d}; [ \"${{h%% *}}\" = \"{s}\" ] || exit {d}; " ++
            "\"$p\" --help >/dev/null 2>&1 || exit {d}",
        .{ arch_case, CHECK_UNSUPPORTED, remote_path, CHECK_MISSING, CHECK_MISSING, hash, CHECK_MISSING, CHECK_MISSING },
        0,
    ) catch return null;
    defer allocator.free(check);

    const checked = runner.run(runner.ctx, ssh_bin, host, check, null);
    if (checked == 0) {
        keep_remote_path = true;
        return .{ .allocator = allocator, .path = remote_path };
    }
    if (checked != CHECK_MISSING) return null;

    const upload = std.fmt.allocPrintSentinel(
        allocator,
        "umask 077; case \"$(uname -s 2>/dev/null):$(uname -m 2>/dev/null)\" in {s}) ;; *) exit {d};; esac; " ++
            "command -v sha256sum >/dev/null 2>&1 || exit 67; " ++
            "d=\"$HOME/.cache/sketerm/mux\"; p=\"{s}\"; mkdir -p \"$d\" || exit 68; chmod 700 \"$HOME/.cache/sketerm\" \"$d\" 2>/dev/null || true; " ++
            "t=\"$p.part.$$\"; trap 'rm -f \"$t\"' EXIT HUP INT TERM; cat >\"$t\" || exit 69; " ++
            "[ \"$(wc -c <\"$t\")\" = \"{d}\" ] || exit 70; h=$(sha256sum \"$t\") || exit 71; " ++
            "[ \"${{h%% *}}\" = \"{s}\" ] || exit 72; chmod 700 \"$t\" || exit 73; mv -f \"$t\" \"$p\" || exit 74; " ++
            "\"$p\" --help >/dev/null 2>&1 || exit 75; trap - EXIT",
        .{ arch_case, CHECK_UNSUPPORTED, remote_path, artifact.hash.size, hash },
        0,
    ) catch return null;
    defer allocator.free(upload);
    if (runner.run(runner.ctx, ssh_bin, host, upload, artifact.path) != 0) return null;
    keep_remote_path = true;
    return .{ .allocator = allocator, .path = remote_path };
}

fn monotonicMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

fn reapChild(pid: c.pid_t, deadline: i64) ?u8 {
    var status: c_int = 0;
    while (monotonicMs() < deadline) {
        const got = c.waitpid(pid, &status, c.WNOHANG);
        if (got == pid) return if (c.WIFEXITED(status)) @intCast(c.WEXITSTATUS(status)) else 255;
        if (got < 0 and std.posix.errno(got) != .INTR) return null;
        _ = c.usleep(10_000);
    }
    _ = c.kill(pid, c.SIGTERM);
    _ = c.usleep(50_000);
    if (c.waitpid(pid, &status, c.WNOHANG) != pid) {
        _ = c.kill(pid, c.SIGKILL);
        while (true) {
            const got = c.waitpid(pid, &status, 0);
            if (got >= 0 or std.posix.errno(got) != .INTR) break;
        }
    }
    return null;
}

fn runSshCommand(_: ?*anyopaque, ssh_bin: [*:0]const u8, host: []const u8, command: [:0]const u8, input_path: ?[]const u8) u8 {
    var host_buf: [256:0]u8 = undefined;
    const host_z = std.fmt.bufPrintZ(&host_buf, "{s}", .{host}) catch return 255;
    var pair: [2]c_int = undefined;
    if (platform.socketpairCloexec(&pair) != 0) return 255;
    const devnull = c.open("/dev/null", c.O_WRONLY | c.O_CLOEXEC);
    if (devnull < 0) {
        _ = c.close(pair[0]);
        _ = c.close(pair[1]);
        return 255;
    }

    const custom = c.getenv("SKETERM_SSH") != null;
    var argv: [16:null]?[*:0]const u8 = .{null} ** 16;
    var n: usize = 0;
    argv[n] = ssh_bin;
    n += 1;
    argv[n] = "-T";
    n += 1;
    argv[n] = "-x";
    n += 1;
    argv[n] = "-o";
    n += 1;
    argv[n] = "BatchMode=yes";
    n += 1;
    if (!custom and canMultiplex()) {
        argv[n] = "-o";
        argv[n + 1] = "ControlMaster=auto";
        argv[n + 2] = "-o";
        argv[n + 3] = "ControlPath=~/.ssh/sketerm-%C";
        argv[n + 4] = "-o";
        argv[n + 5] = "ControlPersist=120";
        n += 6;
    }
    argv[n] = host_z.ptr;
    argv[n + 1] = command.ptr;

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(devnull);
        _ = c.close(pair[0]);
        _ = c.close(pair[1]);
        return 255;
    }
    if (pid == 0) {
        _ = c.dup2(pair[1], 0);
        _ = c.dup2(devnull, 1);
        _ = c.close(devnull);
        _ = c.close(pair[0]);
        _ = c.close(pair[1]);
        _ = c.execvp(ssh_bin, @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    _ = c.close(devnull);
    _ = c.close(pair[1]);
    const deadline = monotonicMs() + SSH_TIMEOUT_MS;
    if (comptime platform.is_macos) {
        var one: c_int = 1;
        _ = c.setsockopt(pair[0], c.SOL_SOCKET, c.SO_NOSIGPIPE, &one, @sizeOf(c_int));
    }
    const flags = c.fcntl(pair[0], c.F_GETFL);
    if (flags >= 0) _ = c.fcntl(pair[0], c.F_SETFL, flags | c.O_NONBLOCK);
    var sent_ok = true;
    if (input_path) |path| {
        var path_buf: [4096]u8 = undefined;
        const path_z: ?[*:0]const u8 = pathZ(&path_buf, path) catch blk: {
            sent_ok = false;
            break :blk null;
        };
        const fd = if (path_z) |z| c.open(z, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK) else -1;
        var st: c.struct_stat = undefined;
        if (fd < 0) {
            sent_ok = false;
        } else if (c.fstat(fd, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG) {
            sent_ok = false;
            _ = c.close(fd);
        } else {
            var buf: [64 * 1024]u8 = undefined;
            outer: while (true) {
                const read_n = c.read(fd, &buf, buf.len);
                if (read_n < 0) {
                    if (std.posix.errno(read_n) == .INTR) continue;
                    sent_ok = false;
                    break;
                }
                const got: usize = @intCast(read_n);
                var off: usize = 0;
                while (off < got) {
                    if (monotonicMs() >= deadline) {
                        sent_ok = false;
                        break :outer;
                    }
                    const wrote = if (comptime @hasDecl(c, "MSG_NOSIGNAL"))
                        c.send(pair[0], &buf[off], got - off, c.MSG_NOSIGNAL)
                    else
                        c.write(pair[0], &buf[off], got - off);
                    if (wrote > 0) {
                        off += @intCast(wrote);
                    } else if (wrote < 0 and std.posix.errno(wrote) == .INTR) {
                        continue;
                    } else if (wrote < 0 and std.posix.errno(wrote) == .AGAIN) {
                        var pfd = c.struct_pollfd{ .fd = pair[0], .events = c.POLLOUT, .revents = 0 };
                        _ = c.poll(&pfd, 1, 100);
                    } else {
                        sent_ok = false;
                        break :outer;
                    }
                }
                if (got == 0) break;
            }
            _ = c.close(fd);
        }
    }
    _ = c.shutdown(pair[0], c.SHUT_WR);
    _ = c.close(pair[0]);
    const status = reapChild(pid, deadline) orelse return 255;
    return if (sent_ok) status else 255;
}

const FakeRunner = struct {
    statuses: [2]u8,
    calls: usize = 0,
    uploads: usize = 0,

    fn run(raw: ?*anyopaque, _: [*:0]const u8, _: []const u8, _: [:0]const u8, input: ?[]const u8) u8 {
        const self: *FakeRunner = @ptrCast(@alignCast(raw.?));
        if (input != null) self.uploads += 1;
        const status = self.statuses[@min(self.calls, self.statuses.len - 1)];
        self.calls += 1;
        return status;
    }
};

fn fakeArtifact(fill: u8) Artifact {
    return .{
        .path = "/tmp/mux-portable",
        .arch = .x86_64,
        .hash = .{ .hex = [_]u8{fill} ** 64, .size = 1234 },
    };
}

test "deployment reuses a current content-addressed mux" {
    var fake = FakeRunner{ .statuses = .{ 0, 0 } };
    var result = ensureUsing(std.testing.allocator, "box", "ssh", fakeArtifact('a'), .{ .ctx = &fake, .run = FakeRunner.run }).?;
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.uploads);
    try std.testing.expect(std.mem.endsWith(u8, result.path, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
}

test "deployment uploads an absent or stale mux" {
    var fake = FakeRunner{ .statuses = .{ CHECK_MISSING, 0 } };
    var result = ensureUsing(std.testing.allocator, "box", "ssh", fakeArtifact('b'), .{ .ctx = &fake, .run = FakeRunner.run }).?;
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), fake.uploads);
}

test "deployment leaves unsupported hosts and failed checks untouched" {
    var unsupported = FakeRunner{ .statuses = .{ CHECK_UNSUPPORTED, 0 } };
    try std.testing.expect(ensureUsing(std.testing.allocator, "box", "ssh", fakeArtifact('c'), .{ .ctx = &unsupported, .run = FakeRunner.run }) == null);
    try std.testing.expectEqual(@as(usize, 1), unsupported.calls);
    var failed = FakeRunner{ .statuses = .{ 255, 0 } };
    try std.testing.expect(ensureUsing(std.testing.allocator, "box", "ssh", fakeArtifact('d'), .{ .ctx = &failed, .run = FakeRunner.run }) == null);
    try std.testing.expectEqual(@as(usize, 1), failed.calls);
}

test "deployment falls back when an upload fails" {
    var fake = FakeRunner{ .statuses = .{ CHECK_MISSING, 74 } };
    try std.testing.expect(ensureUsing(std.testing.allocator, "box", "ssh", fakeArtifact('e'), .{ .ctx = &fake, .run = FakeRunner.run }) == null);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), fake.uploads);
}

test "portable artifact architecture comes from its ELF header" {
    var header = [_]u8{0} ** 20;
    @memcpy(header[0..4], "\x7fELF");
    header[4] = 2;
    header[5] = 1;
    std.mem.writeInt(u16, header[18..20], 62, .little);
    try std.testing.expectEqual(Arch.x86_64, elfArch(&header).?);
    std.mem.writeInt(u16, header[18..20], 183, .little);
    try std.testing.expectEqual(Arch.aarch64, elfArch(&header).?);
    std.mem.writeInt(u16, header[18..20], 3, .little);
    try std.testing.expect(elfArch(&header) == null);
}
