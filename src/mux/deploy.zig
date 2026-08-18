//! Automatic content-addressed deployment of the portable remote mux.
//!
//! Dialect-proof by construction: the remote ssh command is either the
//! single word `sh` (script rides stdin) or a single bare word the
//! check phase staged — the user's login shell, fish/csh/anything,
//! has nothing to parse either way.
//!
//! The payload deliberately never shares a stream with script text:
//! dash (Debian/Ubuntu /bin/sh) BUFFERS stdin scripts, so the classic
//! append-the-binary-after-the-script trick silently loses the
//! payload prefix there (caught by the real-sh test below). Instead
//! the check phase stages a content-addressed uploader script via a
//! quoted heredoc — heredocs are parsed as script text, read-ahead
//! safe — and the upload phase runs that uploader as a bare word
//! whose stdin is purely the raw binary, `head -c <size>` exact.

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

/// How long a verified remote deployment is trusted before it is
/// re-checked over ssh. Every helper process (mount, cross-copy job)
/// used to pay the check round trip on every single dial.
const DEPLOY_MEMO_TTL_S: i64 = 600;

fn deployMemoPath(buf: []u8, host: []const u8, hash: []const u8) ?[:0]const u8 {
    const h = std.hash.Wyhash.hash(0, host);
    const tail = hash[0..@min(hash.len, 16)];
    if (c.getenv("XDG_CACHE_HOME")) |raw| {
        const base = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        return std.fmt.bufPrintZ(buf, "{s}/sketerm/mux/deployed-{x:0>16}-{s}", .{ base, h, tail }) catch null;
    }
    const home_raw = c.getenv("HOME") orelse return null;
    const home = std.mem.span(@as([*:0]const u8, @ptrCast(home_raw)));
    return std.fmt.bufPrintZ(buf, "{s}/.cache/sketerm/mux/deployed-{x:0>16}-{s}", .{ home, h, tail }) catch null;
}

fn deployMemoFresh(host: []const u8, hash: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const path = deployMemoPath(&buf, host, hash) orelse return false;
    var st: c.struct_stat = undefined;
    if (c.stat(path.ptr, &st) != 0) return false;
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    const mtime = if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim.tv_sec else st.st_mtimespec.tv_sec;
    return @as(i64, ts.tv_sec) - @as(i64, mtime) <= DEPLOY_MEMO_TTL_S;
}

fn deployMemoStamp(host: []const u8, hash: []const u8) void {
    var buf: [4096]u8 = undefined;
    const path = deployMemoPath(&buf, host, hash) orelse return;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        var dir_buf: [4096:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&dir_buf, "{s}", .{path[0..slash]})) |dir| {
            var i: usize = 1;
            while (i <= dir.len) : (i += 1) {
                if (i == dir.len or dir[i] == '/') {
                    const save = dir[i];
                    dir_buf[i] = 0;
                    _ = c.mkdir(dir.ptr, 0o700);
                    dir_buf[i] = save;
                }
            }
        } else |_| {}
    }
    const fp = c.fopen(path.ptr, "we") orelse return;
    _ = c.fclose(fp);
}

/// Ensure the matching portable mux exists remotely; null preserves PATH fallback.
pub fn prepare(allocator: std.mem.Allocator, host: []const u8) ?Prepared {
    // Existing test/transport wrappers expect only the historical proxy argv.
    // An explicit artifact opts a wrapper into deployment testing or use.
    if (c.getenv("SKETERM_SSH") != null and c.getenv("SKETERM_MUX_PORTABLE") == null) return null;

    var artifact_path_buf: [4096:0]u8 = undefined;
    const artifact_path = findPortable(&artifact_path_buf) orelse return null;
    const artifact = inspectArtifact(artifact_path) orelse return null;
    // A recent verified deploy of this exact artifact skips the ssh
    // check leg entirely (content-addressed path, so a stale memo can
    // only name a binary that once passed its own --help probe).
    if (deployMemoFresh(host, &artifact.hash.hex)) {
        const remote_path = std.fmt.allocPrintSentinel(
            allocator,
            "$HOME/.cache/sketerm/mux/sketerm-mux-{s}",
            .{&artifact.hash.hex},
            0,
        ) catch return null;
        return .{ .allocator = allocator, .path = remote_path };
    }
    const ssh_env = c.getenv("SKETERM_SSH");
    const ssh_bin: [*:0]const u8 = if (ssh_env) |p| p else "ssh";
    const prepared = ensureUsing(allocator, host, ssh_bin, artifact, .{ .run = runSshCommand });
    if (prepared != null) deployMemoStamp(host, &artifact.hash.hex);
    return prepared;
}

/// Whether this install can auto-deploy a daemon at all.
///
/// False on a Linux architecture with no portable musl target: the installer
/// packaged everything else and warned, so the remote host must already have
/// sketerm-mux. Callers use this to say that instead of leaving the user with
/// ssh's bare "command not found".
pub fn portableAvailable() bool {
    var buf: [4096:0]u8 = undefined;
    return findPortable(&buf) != null;
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

    // Check-and-stage, riding stdin into `sh` (no payload follows, so
    // shell read-ahead is harmless). Exit 0 = current binary present.
    // Exit CHECK_MISSING = absent/stale AND the uploader script for
    // this exact artifact is now staged at a content-addressed path.
    // The quoted heredoc keeps $HOME/$$ literal in the uploader so
    // they expand at ITS runtime; the staging mv is atomic, so
    // concurrent connects write identical bytes and cannot corrupt.
    const check = std.fmt.allocPrintSentinel(
        allocator,
        "case \"$(uname -s 2>/dev/null):$(uname -m 2>/dev/null)\" in {s}) ;; *) exit {d};; esac\n" ++
            "command -v sha256sum >/dev/null 2>&1 || exit 67\n" ++
            "p=\"{s}\"\n" ++
            "if [ -x \"$p\" ]; then h=$(sha256sum \"$p\" 2>/dev/null) && [ \"${{h%% *}}\" = \"{s}\" ] && \"$p\" --help >/dev/null 2>&1 && exit 0; fi\n" ++
            "umask 077; d=\"$HOME/.cache/sketerm/mux\"; mkdir -p \"$d\" || exit 68\n" ++
            "chmod 700 \"$HOME/.cache/sketerm\" \"$d\" 2>/dev/null || true\n" ++
            "u=\"$d/.upload-{s}\"; ut=\"$u.$$\"\n" ++
            "cat >\"$ut\" <<'SKETERM_UPLOADER'\n" ++
            "#!/bin/sh\n" ++
            "umask 077\n" ++
            "p=\"$HOME/.cache/sketerm/mux/sketerm-mux-{s}\"; t=\"$p.part.$$\"\n" ++
            "trap 'rm -f \"$t\"' EXIT HUP INT TERM\n" ++
            "head -c {d} >\"$t\" || exit 69\n" ++
            "[ \"$(wc -c <\"$t\")\" = \"{d}\" ] || exit 70\n" ++
            "h=$(sha256sum \"$t\") || exit 71\n" ++
            "[ \"${{h%% *}}\" = \"{s}\" ] || exit 72\n" ++
            "chmod 700 \"$t\" || exit 73\n" ++
            "mv -f \"$t\" \"$p\" || exit 74\n" ++
            "\"$p\" --help >/dev/null 2>&1 || exit 75\n" ++
            "trap - EXIT\n" ++
            "SKETERM_UPLOADER\n" ++
            "chmod 700 \"$ut\" || exit 76; mv -f \"$ut\" \"$u\" || exit 77\n" ++
            "exit {d}\n",
        .{ arch_case, CHECK_UNSUPPORTED, remote_path, hash, hash, hash, artifact.hash.size, artifact.hash.size, hash, CHECK_MISSING },
        0,
    ) catch return null;
    defer allocator.free(check);

    const checked = runner.run(runner.ctx, ssh_bin, host, check, null);
    if (checked == 0) {
        keep_remote_path = true;
        return .{ .allocator = allocator, .path = remote_path };
    }
    if (checked != CHECK_MISSING) return null;

    // Upload: the remote command is the staged uploader as one bare
    // word (no shell has anything to parse; bare-word $HOME expands
    // in every login shell), and stdin carries ONLY the raw binary —
    // `head -c` reads the exact byte count, wc cross-checks it (head
    // exits 0 on a truncated stream), sha256sum proves integrity
    // before the atomic publish, and the --help probe proves the
    // published file actually executes.
    const upload_word = std.fmt.allocPrintSentinel(
        allocator,
        "$HOME/.cache/sketerm/mux/.upload-{s}",
        .{hash},
        0,
    ) catch return null;
    defer allocator.free(upload_word);
    if (runner.run(runner.ctx, ssh_bin, host, upload_word, artifact.path) != 0) return null;
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

/// Bounded non-blocking write of the whole buffer; false on timeout,
/// EPIPE (remote script exited early — its exit code is the story),
/// or any other write failure.
fn sendBytes(fd: c_int, bytes: []const u8, deadline: i64) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        if (monotonicMs() >= deadline) return false;
        const wrote = if (comptime @hasDecl(c, "MSG_NOSIGNAL"))
            c.send(fd, bytes.ptr + off, bytes.len - off, c.MSG_NOSIGNAL)
        else
            c.write(fd, bytes.ptr + off, bytes.len - off);
        if (wrote > 0) {
            off += @intCast(wrote);
        } else if (wrote < 0 and std.posix.errno(wrote) == .INTR) {
            continue;
        } else if (wrote < 0 and std.posix.errno(wrote) == .AGAIN) {
            var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLOUT, .revents = 0 };
            _ = c.poll(&pfd, 1, 100);
        } else {
            return false;
        }
    }
    return true;
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
    // Either way the remote command is a SINGLE word — nothing for any
    // login shell dialect to misparse. Without a payload it is `sh`
    // and `command` is the script ridden in on stdin; with a payload
    // it is `command` itself (the staged uploader's bare-word path)
    // and stdin carries only the raw bytes.
    argv[n] = host_z.ptr;
    argv[n + 1] = if (input_path == null) "sh" else command.ptr;

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
    // Script mode: the script IS the stdin. Payload mode: stdin is
    // exclusively the raw bytes — script text and payload must never
    // share a stream (dash buffers stdin scripts and would eat the
    // payload prefix).
    var sent_ok = if (input_path == null) sendBytes(pair[0], command, deadline) else true;
    if (sent_ok) if (input_path) |path| {
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
            while (true) {
                const read_n = c.read(fd, &buf, buf.len);
                if (read_n < 0) {
                    if (std.posix.errno(read_n) == .INTR) continue;
                    sent_ok = false;
                    break;
                }
                if (read_n == 0) break;
                if (!sendBytes(pair[0], buf[0..@intCast(read_n)], deadline)) {
                    sent_ok = false;
                    break;
                }
            }
            _ = c.close(fd);
        }
    };
    _ = c.shutdown(pair[0], c.SHUT_WR);
    _ = c.close(pair[0]);
    const status = reapChild(pid, deadline) orelse return 255;
    return if (sent_ok) status else 255;
}

const FakeRunner = struct {
    statuses: [2]u8,
    expected_arch_case: []const u8 = "",
    calls: usize = 0,
    uploads: usize = 0,
    upload_script_ok: bool = false,
    check_script_ok: bool = false,
    arch_guard_ok: bool = false,

    fn run(raw: ?*anyopaque, _: [*:0]const u8, _: []const u8, command: [:0]const u8, input: ?[]const u8) u8 {
        const self: *FakeRunner = @ptrCast(@alignCast(raw.?));
        if (input != null) {
            self.uploads += 1;
            // The upload command must be ONE bare word (dialect-proof)
            // naming the staged uploader — never script text, which
            // would put the payload behind a shell's stdin buffering.
            self.upload_script_ok = std.mem.indexOf(u8, command, ".upload-") != null and
                std.mem.indexOfAny(u8, command, " \t\n") == null;
        } else {
            // The check script stages an uploader with an exact-count
            // payload read, and ends in a newline.
            self.check_script_ok = std.mem.indexOf(u8, command, "head -c 1234 ") != null and
                command.len > 0 and command[command.len - 1] == '\n';
            self.arch_guard_ok = self.expected_arch_case.len == 0 or
                std.mem.indexOf(u8, command, self.expected_arch_case) != null;
        }
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
    try std.testing.expect(fake.upload_script_ok);
    try std.testing.expect(fake.check_script_ok);
}

test "check and upload run through a real sh with the payload on stdin" {
    // Full-fidelity dialect proof: the REAL runSshCommand streams the
    // REAL scripts + payload into a real `sh` (the fake ssh ignores
    // every argument — a login shell has nothing to parse when the
    // remote command is one word), against an isolated $HOME.
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const arch: Arch = switch (builtin.cpu.arch) {
        .x86_64 => .x86_64,
        .aarch64 => .aarch64,
        else => return error.SkipZigTest,
    };

    var home_buf: [128:0]u8 = undefined;
    const home = std.fmt.bufPrintZ(&home_buf, "/tmp/sketerm-deploy-home-{d}", .{c.getpid()}) catch unreachable;
    _ = c.mkdir(home.ptr, 0o700);
    var ssh_buf: [160:0]u8 = undefined;
    const ssh = std.fmt.bufPrintZ(&ssh_buf, "{s}/fake-ssh", .{home}) catch unreachable;
    var script_buf: [320:0]u8 = undefined;
    const script = std.fmt.bufPrintZ(
        &script_buf,
        "#!/bin/sh\nHOME={s}; export HOME\nfor a in \"$@\"; do cmd=\"$a\"; done\nexec sh -c \"$cmd\"\n",
        .{home},
    ) catch unreachable;
    {
        const f = c.fopen(ssh.ptr, "w") orelse return error.SkipZigTest;
        _ = c.fputs(script.ptr, f);
        _ = c.fclose(f);
        if (c.chmod(ssh.ptr, 0o755) != 0) return error.SkipZigTest;
    }

    // /bin/true is a real executable whose `--help` probe exits 0, so
    // the deployed file passes the post-publish validation.
    const hash = filehash.sha256File("/bin/true") orelse return error.SkipZigTest;
    const artifact = Artifact{ .path = "/bin/true", .arch = arch, .hash = hash };

    // Round 1: check misses and stages the uploader, upload streams
    // the raw payload into it and publishes.
    var first = ensureUsing(std.testing.allocator, "box", ssh.ptr, artifact, .{ .run = runSshCommand }) orelse
        return error.TestUnexpectedResult;
    first.deinit();
    var deployed_buf: [256:0]u8 = undefined;
    const deployed = std.fmt.bufPrintZ(
        &deployed_buf,
        "{s}/.cache/sketerm/mux/sketerm-mux-{s}",
        .{ home, &hash.hex },
    ) catch unreachable;
    var st: c.struct_stat = undefined;
    try std.testing.expect(c.stat(deployed.ptr, &st) == 0);
    try std.testing.expectEqual(@as(u64, hash.size), @as(u64, @intCast(st.st_size)));
    try std.testing.expect(st.st_mode & 0o777 == 0o700);

    // Round 2: the check recognizes the deployed copy — no re-upload
    // (proven by mtime staying put would race; size+success suffices).
    var second = ensureUsing(std.testing.allocator, "box", ssh.ptr, artifact, .{ .run = runSshCommand }) orelse
        return error.TestUnexpectedResult;
    second.deinit();

    // Wrong-architecture artifact is refused by the remote case guard
    // before any payload flows.
    const other: Arch = if (arch == .x86_64) .aarch64 else .x86_64;
    const mismatched = Artifact{ .path = "/bin/true", .arch = other, .hash = hash };
    try std.testing.expect(ensureUsing(std.testing.allocator, "box", ssh.ptr, mismatched, .{ .run = runSshCommand }) == null);

    _ = c.unlink(deployed.ptr);
    _ = c.unlink(ssh.ptr);
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

test "deployment accepts supported portable ELF architectures" {
    const cases = [_]struct { machine: u16, arch: Arch, remote_names: []const u8 }{
        .{ .machine = 62, .arch = .x86_64, .remote_names = "Linux:x86_64|Linux:amd64" },
        .{ .machine = 183, .arch = .aarch64, .remote_names = "Linux:aarch64|Linux:arm64" },
    };
    for (cases) |case| {
        var header = [_]u8{0} ** 20;
        @memcpy(header[0..4], "\x7fELF");
        header[4] = 2;
        header[5] = 1;
        std.mem.writeInt(u16, header[18..20], case.machine, .little);
        const arch = elfArch(&header).?;
        try std.testing.expectEqual(case.arch, arch);

        var fake = FakeRunner{
            .statuses = .{ 0, 0 },
            .expected_arch_case = case.remote_names,
        };
        var result = ensureUsing(std.testing.allocator, "box", "ssh", .{
            .path = "/tmp/mux-portable",
            .arch = arch,
            .hash = .{ .hex = [_]u8{'f'} ** 64, .size = 1234 },
        }, .{ .ctx = &fake, .run = FakeRunner.run }).?;
        result.deinit();
        try std.testing.expect(fake.arch_guard_ok);
    }

    var header = [_]u8{0} ** 20;
    @memcpy(header[0..4], "\x7fELF");
    header[4] = 2;
    header[5] = 1;
    std.mem.writeInt(u16, header[18..20], 3, .little);
    try std.testing.expect(elfArch(&header) == null);
}
