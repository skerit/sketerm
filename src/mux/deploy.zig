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
//!
//! One install can carry several artifacts (`portable.zig`: a Linux one
//! plus macOS); the ONE check script cases on the remote `uname` over all
//! of them and answers which it matched through its exit code, so picking
//! the artifact costs no extra round trip. Every generated line must parse
//! under macOS's bash 3.2 as well as dash: case arms are `(pattern)`, the
//! hasher falls back to `shasum -a 256`, and `wc -c` output (space-padded
//! on BSD) is compared unquoted.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const pathZ = @import("../util/pathz.zig").pathZ;
const filehash = @import("../util/filehash.zig");
const sshroute = @import("sshroute.zig");
const portable = @import("portable.zig");

const CHECK_UNSUPPORTED: u8 = 65;
/// Check exit = base + index of the matched artifact: present and current.
const CHECK_READY_BASE: u8 = 80;
/// Check exit = base + index of the matched artifact: absent/stale, uploader staged.
const CHECK_MISSING_BASE: u8 = 90;
const SSH_TIMEOUT_MS: i64 = 20_000;

const MAX_ARTIFACTS = portable.targets.len;
comptime {
    std.debug.assert(CHECK_READY_BASE + MAX_ARTIFACTS <= CHECK_MISSING_BASE);
    std.debug.assert(CHECK_MISSING_BASE + MAX_ARTIFACTS < 126); // below the shell's own codes
}

const Artifact = struct {
    path: []const u8,
    target: *const portable.Target,
    hash: filehash.Sha256 = undefined,
};

/// The artifacts of the first install location that has any, classified by header.
const Found = struct {
    path_bufs: [MAX_ARTIFACTS][4096:0]u8 = undefined,
    items: [MAX_ARTIFACTS]Artifact = undefined,
    len: usize = 0,

    fn slice(self: *const Found) []const Artifact {
        return self.items[0..self.len];
    }

    /// Add `path` if it is a recognized artifact for a target not yet found.
    fn add(self: *Found, path: []const u8) void {
        if (self.len == MAX_ARTIFACTS) return;
        const target = classify(path) orelse return;
        for (self.slice()) |a| if (a.target == target) return;
        const buf = &self.path_bufs[self.len];
        const owned = std.fmt.bufPrintZ(buf, "{s}", .{path}) catch return;
        self.items[self.len] = .{ .path = owned, .target = target };
        self.len += 1;
    }

    /// Hash every artifact, dropping any that cannot be read.
    fn hashAll(self: *Found) void {
        var kept: usize = 0;
        for (0..self.len) |i| {
            const hash = filehash.sha256File(self.items[i].path) orelse continue;
            if (kept != i) {
                self.path_bufs[kept] = self.path_bufs[i];
                const len = self.items[i].path.len;
                self.items[kept] = self.items[i];
                self.items[kept].path = self.path_bufs[kept][0..len];
            }
            self.items[kept].hash = hash;
            kept += 1;
        }
        self.len = kept;
    }
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
    run: *const fn (?*anyopaque, *const sshroute.Plan, [*:0]const u8, [:0]const u8, ?[]const u8) u8,
};

/// How long a verified remote deployment is trusted before it is
/// re-checked over ssh. Every helper process (mount, cross-copy job)
/// used to pay the check round trip on every single dial.
const DEPLOY_MEMO_TTL_S: i64 = 600;

fn deployMemoPath(buf: []u8, plan: *const sshroute.Plan, hash: []const u8) ?[:0]const u8 {
    var route_buf: [1024]u8 = undefined;
    const route_key = plan.memoKey(&route_buf) orelse return null;
    const h = std.hash.Wyhash.hash(0, route_key);
    const tail = hash[0..@min(hash.len, 16)];
    if (c.getenv("XDG_CACHE_HOME")) |raw| {
        const base = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        return std.fmt.bufPrintZ(buf, "{s}/sketerm/mux/deployed-{x:0>16}-{s}", .{ base, h, tail }) catch null;
    }
    const home_raw = c.getenv("HOME") orelse return null;
    const home = std.mem.span(@as([*:0]const u8, @ptrCast(home_raw)));
    return std.fmt.bufPrintZ(buf, "{s}/.cache/sketerm/mux/deployed-{x:0>16}-{s}", .{ home, h, tail }) catch null;
}

/// Seconds since this route last verified `hash`, or null when it never did.
fn deployMemoAge(plan: *const sshroute.Plan, hash: []const u8) ?i64 {
    var buf: [4096]u8 = undefined;
    const path = deployMemoPath(&buf, plan, hash) orelse return null;
    var st: c.struct_stat = undefined;
    if (c.stat(path.ptr, &st) != 0) return null;
    const mtime = if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim.tv_sec else st.st_mtimespec.tv_sec;
    return @divTrunc(wallMs(), 1000) - @as(i64, mtime);
}

fn deployMemoFresh(plan: *const sshroute.Plan, hash: []const u8) bool {
    const age = deployMemoAge(plan, hash) orelse return false;
    return age <= DEPLOY_MEMO_TTL_S;
}

fn remotePathFor(allocator: std.mem.Allocator, artifact: *const Artifact) ?Prepared {
    const remote_path = std.fmt.allocPrintSentinel(
        allocator,
        "$HOME/.cache/sketerm/mux/sketerm-mux-{s}",
        .{&artifact.hash.hex},
        0,
    ) catch return null;
    return .{ .allocator = allocator, .path = remote_path };
}

fn deployMemoStamp(plan: *const sshroute.Plan, hash: []const u8) void {
    var buf: [4096]u8 = undefined;
    const path = deployMemoPath(&buf, plan, hash) orelse return;
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

/// What the last `prepare` on this thread did.
pub const Outcome = enum {
    /// Deployment is off for this transport (a `$SKETERM_SSH` wrapper).
    not_attempted,
    /// This install has no usable portable artifact to deploy.
    no_portable,
    /// The host is not a platform the portable daemon is built for.
    unsupported_platform,
    /// The current portable daemon is in place on the host.
    ready,
    /// The check or the upload failed.
    failed,
};

threadlocal var last_outcome: Outcome = .not_attempted;

/// What the last `prepare` on this thread did, for a caller explaining a failed connect.
pub fn lastOutcome() Outcome {
    return last_outcome;
}

/// Reset `lastOutcome` before a connect that may not reach `prepare`.
pub fn forgetOutcome() void {
    last_outcome = .not_attempted;
}

/// Ensure the matching portable mux exists remotely; null preserves PATH fallback.
pub fn prepare(allocator: std.mem.Allocator, plan: *const sshroute.Plan) ?Prepared {
    last_outcome = .not_attempted;
    // Existing test/transport wrappers expect only the historical proxy argv.
    // An explicit artifact opts a wrapper into deployment testing or use.
    if (c.getenv("SKETERM_SSH") != null and c.getenv("SKETERM_MUX_PORTABLE") == null) return null;

    last_outcome = .no_portable;
    var found: Found = .{};
    findArtifacts(&found);
    found.hashAll();
    if (found.len == 0) return null;
    // A recent verified deploy of one of these exact artifacts skips the
    // ssh check leg entirely (content-addressed path, so a stale memo can
    // only name a binary that once passed its own --help probe).
    for (found.slice()) |*artifact| {
        if (!deployMemoFresh(plan, &artifact.hash.hex)) continue;
        const prepared = remotePathFor(allocator, artifact) orelse return null;
        last_outcome = .ready;
        return prepared;
    }
    const deployed = ensureUsing(allocator, plan, sshroute.sshBinary(), found.slice(), .{ .run = runSshCommand }) orelse return null;
    deployMemoStamp(plan, &found.items[deployed.index].hash.hex);
    return deployed.prepared;
}

/// Whether this install can auto-deploy a daemon at all.
///
/// False on a Linux architecture with no portable musl target: the installer
/// packaged everything else and warned, so the remote host must already have
/// sketerm-mux. Callers use this to say that instead of leaving the user with
/// ssh's bare "command not found".
pub fn portableAvailable() bool {
    var found: Found = .{};
    findArtifacts(&found);
    return found.len > 0;
}

/// Resolve the expected content-addressed path without touching the network.
///
/// With several artifacts the remote platform is unknown here, so the one
/// this route last verified wins; a never-deployed route gets the first.
pub fn localPath(allocator: std.mem.Allocator, plan: *const sshroute.Plan) ?Prepared {
    if (c.getenv("SKETERM_SSH") != null and c.getenv("SKETERM_MUX_PORTABLE") == null) return null;
    var found: Found = .{};
    findArtifacts(&found);
    found.hashAll();
    if (found.len == 0) return null;
    for (found.slice()) |*artifact| {
        if (deployMemoAge(plan, &artifact.hash.hex) != null) return remotePathFor(allocator, artifact);
    }
    return remotePathFor(allocator, &found.items[0]);
}

/// `$SKETERM_MUX_PORTABLE` (one file), else the first of the sibling, the
/// relative install and the system install directory holding any artifact.
fn findArtifacts(found: *Found) void {
    if (c.getenv("SKETERM_MUX_PORTABLE")) |raw| {
        found.add(std.mem.span(@as([*:0]const u8, @ptrCast(raw))));
        return;
    }
    var exe_buf: [4096]u8 = undefined;
    if (platform.exePath(&exe_buf)) |exe| {
        if (std.mem.lastIndexOfScalar(u8, exe, '/')) |slash| {
            var dir_buf: [4096]u8 = undefined;
            addFromDir(found, exe[0..slash]);
            if (found.len > 0) return;
            const installed = std.fmt.bufPrint(&dir_buf, "{s}/../lib/sketerm", .{exe[0..slash]}) catch return;
            addFromDir(found, installed);
            if (found.len > 0) return;
        }
    }
    addFromDir(found, "/usr/lib/sketerm");
}

fn addFromDir(found: *Found, dir: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    for (portable.artifact_names) |name| {
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;
        found.add(path);
    }
}

/// The table row a readable regular file's executable header names.
fn classify(path: []const u8) ?*const portable.Target {
    var path_buf: [4096]u8 = undefined;
    const fd = c.open(pathZ(&path_buf, path) catch return null, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG) return null;
    var header: [portable.HEADER_LEN]u8 = undefined;
    if (c.read(fd, &header, header.len) != header.len) return null;
    return portable.ofHeader(&header);
}

/// Body of the check script after the per-artifact `case` set i/h/n.
///
/// The uploader's first lines are printf'd (they carry this host's h/n/s),
/// the rest is a quoted heredoc so $HOME/$$ expand at ITS runtime; the
/// staging mv is atomic, so concurrent connects write identical bytes.
const CHECK_BODY =
    "if command -v sha256sum >/dev/null 2>&1; then s=sha256sum\n" ++
    "elif command -v shasum >/dev/null 2>&1; then s='shasum -a 256'\n" ++
    "else exit 67; fi\n" ++
    "p=\"$HOME/.cache/sketerm/mux/sketerm-mux-$h\"\n" ++
    "if [ -x \"$p\" ]; then c=$($s \"$p\" 2>/dev/null) && [ \"${{c%% *}}\" = \"$h\" ] && \"$p\" --help >/dev/null 2>&1 && exit $(({d}+i)); fi\n" ++
    "umask 077; d=\"$HOME/.cache/sketerm/mux\"; mkdir -p \"$d\" || exit 68\n" ++
    "chmod 700 \"$HOME/.cache/sketerm\" \"$d\" 2>/dev/null || true\n" ++
    "u=\"$d/.upload-$h\"; ut=\"$u.$$\"\n" ++
    "printf '%s\\n' '#!/bin/sh' \"h=$h n=$n s='$s'\" >\"$ut\" || exit 76\n" ++
    "cat >>\"$ut\" <<'SKETERM_UPLOADER'\n" ++
    "umask 077\n" ++
    "p=\"$HOME/.cache/sketerm/mux/sketerm-mux-$h\"; t=\"$p.part.$$\"\n" ++
    "trap 'rm -f \"$t\"' EXIT HUP INT TERM\n" ++
    "head -c \"$n\" >\"$t\" || exit 69\n" ++
    "[ $(wc -c <\"$t\") = \"$n\" ] || exit 70\n" ++
    "c=$($s \"$t\") || exit 71\n" ++
    "[ \"${{c%% *}}\" = \"$h\" ] || exit 72\n" ++
    "chmod 700 \"$t\" || exit 73\n" ++
    "mv -f \"$t\" \"$p\" || exit 74\n" ++
    "\"$p\" --help >/dev/null 2>&1 || exit 75\n" ++
    "trap - EXIT\n" ++
    "SKETERM_UPLOADER\n" ++
    "chmod 700 \"$ut\" || exit 76; mv -f \"$ut\" \"$u\" || exit 77\n" ++
    "exit $(({d}+i))\n";

/// The check-and-stage script riding stdin into `sh` (no payload follows,
/// so shell read-ahead is harmless).
fn checkScript(allocator: std.mem.Allocator, artifacts: []const Artifact) ![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "case \"$(uname -s 2>/dev/null):$(uname -m 2>/dev/null)\" in\n");
    for (artifacts, 0..) |a, i| {
        try out.print(allocator, "({s}) i={d} h={s} n={d};;\n", .{ a.target.uname, i, &a.hash.hex, a.hash.size });
    }
    try out.print(allocator, "(*) exit {d};;\nesac\n", .{CHECK_UNSUPPORTED});
    try out.print(allocator, CHECK_BODY, .{ CHECK_READY_BASE, CHECK_MISSING_BASE });
    return out.toOwnedSliceSentinel(allocator, 0);
}

const Deployed = struct {
    prepared: Prepared,
    /// Which of the offered artifacts the host matched.
    index: usize,
};

fn ensureUsing(
    allocator: std.mem.Allocator,
    plan: *const sshroute.Plan,
    ssh_bin: [*:0]const u8,
    artifacts: []const Artifact,
    runner: Runner,
) ?Deployed {
    last_outcome = .failed;
    std.debug.assert(artifacts.len > 0 and artifacts.len <= MAX_ARTIFACTS);
    const check = checkScript(allocator, artifacts) catch return null;
    defer allocator.free(check);

    const checked = runner.run(runner.ctx, plan, ssh_bin, check, null);
    if (checked == CHECK_UNSUPPORTED) last_outcome = .unsupported_platform;
    const ready = checked >= CHECK_READY_BASE and checked < CHECK_READY_BASE + artifacts.len;
    const missing = checked >= CHECK_MISSING_BASE and checked < CHECK_MISSING_BASE + artifacts.len;
    if (!ready and !missing) return null;
    const index: usize = checked - if (ready) CHECK_READY_BASE else CHECK_MISSING_BASE;
    const artifact = &artifacts[index];

    if (missing) {
        // Upload: the remote command is the staged uploader as one bare
        // word (no shell has anything to parse; bare-word $HOME expands
        // in every login shell), and stdin carries ONLY the raw binary —
        // `head -c` reads the exact byte count, wc cross-checks it (head
        // exits 0 on a truncated stream), the hash proves integrity
        // before the atomic publish, and the --help probe proves the
        // published file actually executes.
        const upload_word = std.fmt.allocPrintSentinel(
            allocator,
            "$HOME/.cache/sketerm/mux/.upload-{s}",
            .{&artifact.hash.hex},
            0,
        ) catch return null;
        defer allocator.free(upload_word);
        if (runner.run(runner.ctx, plan, ssh_bin, upload_word, artifact.path) != 0) return null;
    }
    const prepared = remotePathFor(allocator, artifact) orelse return null;
    last_outcome = .ready;
    return .{ .prepared = prepared, .index = index };
}

const nowMs = @import("../util/clock.zig").nowMs;
const wallMs = @import("../util/clock.zig").wallMs;

fn reapChild(pid: c.pid_t, deadline: i64) ?u8 {
    var status: c_int = 0;
    while (nowMs() < deadline) {
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
        if (nowMs() >= deadline) return false;
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

fn runSshCommand(_: ?*anyopaque, plan: *const sshroute.Plan, ssh_bin: [*:0]const u8, command: [:0]const u8, input_path: ?[]const u8) u8 {
    var host_buf: [256:0]u8 = undefined;
    const host_z = std.fmt.bufPrintZ(&host_buf, "{s}", .{plan.destination}) catch return 255;
    // OpenSSH 10.5 can detach a new ControlPersist master while this
    // process is still feeding the upload on stdin. The mux channel then
    // stops draining after its window fills, poisoning later proxy dials.
    // Deployment is infrequent and correctness matters more than reuse.
    var route_args = plan.args(.{ .multiplex = false }) catch return 255;
    var pair: [2]c_int = undefined;
    if (platform.socketpairCloexec(&pair) != 0) return 255;
    const devnull = c.open("/dev/null", c.O_WRONLY | c.O_CLOEXEC);
    if (devnull < 0) {
        _ = c.close(pair[0]);
        _ = c.close(pair[1]);
        return 255;
    }
    var argv: [sshroute.Args.MAX_OPTIONS + 8:null]?[*:0]const u8 = .{null} ** (sshroute.Args.MAX_OPTIONS + 8);
    var n: usize = 0;
    argv[n] = ssh_bin;
    n += 1;
    route_args.append(&argv, &n) catch return 255;
    // `append` bounds itself; the destination and command slots below do
    // not, so keep the room for them a checked fact rather than a count
    // someone re-derives after adding another `-o` pair.
    if (n + 3 > argv.len) return 255;
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
    const deadline = nowMs() + SSH_TIMEOUT_MS;
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
    expected_route: ?sshroute.Route = null,
    calls: usize = 0,
    uploads: usize = 0,
    uploaded: ?[]const u8 = null,
    upload_script_ok: bool = false,
    check_script_ok: bool = false,
    arch_guard_ok: bool = false,
    route_ok: bool = true,

    fn run(raw: ?*anyopaque, plan: *const sshroute.Plan, _: [*:0]const u8, command: [:0]const u8, input: ?[]const u8) u8 {
        const self: *FakeRunner = @ptrCast(@alignCast(raw.?));
        if (self.expected_route) |route| self.route_ok = self.route_ok and plan.route == route;
        if (input) |path| {
            self.uploads += 1;
            self.uploaded = path;
            // The upload command must be ONE bare word (dialect-proof)
            // naming the staged uploader — never script text, which
            // would put the payload behind a shell's stdin buffering.
            self.upload_script_ok = std.mem.indexOf(u8, command, ".upload-") != null and
                std.mem.indexOfAny(u8, command, " \t\n") == null;
        } else {
            // The check script stages an uploader with an exact-count
            // payload read, and ends in a newline.
            self.check_script_ok = std.mem.indexOf(u8, command, " n=1234;;") != null and
                std.mem.indexOf(u8, command, "head -c \"$n\" ") != null and
                command.len > 0 and command[command.len - 1] == '\n';
            self.arch_guard_ok = self.expected_arch_case.len == 0 or
                std.mem.indexOf(u8, command, self.expected_arch_case) != null;
        }
        const status = self.statuses[@min(self.calls, self.statuses.len - 1)];
        self.calls += 1;
        return status;
    }
};

fn targetOf(triple: []const u8) *const portable.Target {
    for (&portable.targets) |*t| if (std.mem.eql(u8, t.triple, triple)) return t;
    unreachable;
}

fn fakeArtifact(fill: u8) Artifact {
    return .{
        .path = "/tmp/mux-portable",
        .target = targetOf("x86_64-linux-musl"),
        .hash = .{ .hex = [_]u8{fill} ** 64, .size = 1234 },
    };
}

fn testPlan(host: []const u8) sshroute.Plan {
    return sshroute.Plan.init(host, .direct, @import("socks5_client.zig").DEFAULT_ENDPOINT) catch unreachable;
}

test "deployment reuses a current content-addressed mux" {
    var fake = FakeRunner{ .statuses = .{ CHECK_READY_BASE, 0 } };
    const plan = testPlan("box");
    var result = ensureUsing(std.testing.allocator, &plan, "ssh", &.{fakeArtifact('a')}, .{ .ctx = &fake, .run = FakeRunner.run }).?;
    defer result.prepared.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.uploads);
    try std.testing.expect(std.mem.endsWith(u8, result.prepared.path, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
}

test "deployment uploads an absent or stale mux" {
    var fake = FakeRunner{ .statuses = .{ CHECK_MISSING_BASE, 0 } };
    const plan = testPlan("box");
    var result = ensureUsing(std.testing.allocator, &plan, "ssh", &.{fakeArtifact('b')}, .{ .ctx = &fake, .run = FakeRunner.run }).?;
    defer result.prepared.deinit();
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), fake.uploads);
    try std.testing.expect(fake.upload_script_ok);
    try std.testing.expect(fake.check_script_ok);
}

test "deployment picks the artifact the host's platform matched" {
    const linux = fakeArtifact('1');
    const mac = Artifact{
        .path = "/tmp/mux-portable-mac",
        .target = targetOf("aarch64-macos"),
        .hash = .{ .hex = [_]u8{'2'} ** 64, .size = 1234 },
    };
    const plan = testPlan("mac");
    var missing = FakeRunner{ .statuses = .{ CHECK_MISSING_BASE + 1, 0 }, .expected_arch_case = "(Darwin:arm64) i=1 h=" };
    var result = ensureUsing(std.testing.allocator, &plan, "ssh", &.{ linux, mac }, .{ .ctx = &missing, .run = FakeRunner.run }).?;
    defer result.prepared.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.index);
    try std.testing.expect(missing.arch_guard_ok);
    try std.testing.expectEqualStrings(mac.path, missing.uploaded.?);
    try std.testing.expect(std.mem.endsWith(u8, result.prepared.path, &mac.hash.hex));

    var ready = FakeRunner{ .statuses = .{ CHECK_READY_BASE, 0 }, .expected_arch_case = "(Linux:x86_64|Linux:amd64) i=0 h=" };
    var first = ensureUsing(std.testing.allocator, &plan, "ssh", &.{ linux, mac }, .{ .ctx = &ready, .run = FakeRunner.run }).?;
    defer first.prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), first.index);
    try std.testing.expect(ready.arch_guard_ok);
    try std.testing.expectEqual(@as(usize, 0), ready.uploads);

    // An index past the offered artifacts (or a bare 0) is a failure, not a pick.
    for ([_]u8{ CHECK_READY_BASE + 2, CHECK_MISSING_BASE + 2, 0 }) |status| {
        var stray = FakeRunner{ .statuses = .{ status, 0 } };
        try std.testing.expect(ensureUsing(std.testing.allocator, &plan, "ssh", &.{ linux, mac }, .{ .ctx = &stray, .run = FakeRunner.run }) == null);
        try std.testing.expectEqual(@as(usize, 0), stray.uploads);
        try std.testing.expectEqual(Outcome.failed, lastOutcome());
    }
}

test "Tor deployment keeps check and upload on the forced route" {
    var fake = FakeRunner{ .statuses = .{ CHECK_MISSING_BASE, 0 }, .expected_route = .tor };
    const plan = sshroute.Plan.init("work-alias", .tor, "127.0.0.1:9150") catch unreachable;
    var result = ensureUsing(std.testing.allocator, &plan, "ssh", &.{fakeArtifact('7')}, .{ .ctx = &fake, .run = FakeRunner.run }).?;
    defer result.prepared.deinit();
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expect(fake.route_ok);
    try std.testing.expect(fake.upload_script_ok);
}

test "check and upload run through a real sh with the payload on stdin" {
    // Full-fidelity dialect proof: the REAL runSshCommand streams the
    // REAL scripts + payload into a real `sh` (the fake ssh ignores
    // every argument — a login shell has nothing to parse when the
    // remote command is one word), against an isolated $HOME. The
    // remote-platform case runs on THIS host, so the test needs a table
    // row for it; /usr/bin/true stands in for the payload because its
    // `--help` probe exits 0.
    const builtin = @import("builtin");
    const host_os: portable.Target.Os = switch (builtin.os.tag) {
        .linux => .linux,
        .macos => .macos,
        else => return error.SkipZigTest,
    };
    const host_target = for (&portable.targets) |*t| {
        if (t.os == host_os and std.mem.startsWith(u8, t.triple, @tagName(builtin.cpu.arch))) break t;
    } else return error.SkipZigTest;
    const other_target = for (&portable.targets) |*t| {
        if (t != host_target) break t;
    } else unreachable;

    var home_buf: [128:0]u8 = undefined;
    const home = std.fmt.bufPrintZ(&home_buf, "/tmp/sketerm-deploy-home-{d}", .{c.getpid()}) catch unreachable;
    _ = c.mkdir(home.ptr, 0o700);
    defer @import("../util/pathz.zig").removeTree(home);
    var ssh_buf: [160:0]u8 = undefined;
    const ssh = std.fmt.bufPrintZ(&ssh_buf, "{s}/fake-ssh", .{home}) catch unreachable;
    var script_buf: [320:0]u8 = undefined;
    const script = std.fmt.bufPrintZ(
        &script_buf,
        "#!/bin/sh\nHOME={s}; export HOME\n" ++
            "for a in \"$@\"; do case \"$a\" in (ControlMaster=*|ControlPath=*|ControlPersist=*) exit 78;; esac; cmd=\"$a\"; done\n" ++
            "exec sh -c \"$cmd\"\n",
        .{home},
    ) catch unreachable;
    {
        const f = c.fopen(ssh.ptr, "w") orelse return error.SkipZigTest;
        _ = c.fputs(script.ptr, f);
        _ = c.fclose(f);
        if (c.chmod(ssh.ptr, 0o755) != 0) return error.SkipZigTest;
    }

    const payload = "/usr/bin/true";
    const hash = filehash.sha256File(payload) orelse return error.SkipZigTest;
    // The host's artifact sits SECOND, behind one for another platform:
    // the script must select it by the host's uname, not by position.
    const artifacts = [_]Artifact{
        .{ .path = payload, .target = other_target, .hash = .{ .hex = [_]u8{'0'} ** 64, .size = 1 } },
        .{ .path = payload, .target = host_target, .hash = hash },
    };

    // Round 1: check misses and stages the uploader, upload streams
    // the raw payload into it and publishes.
    const plan = testPlan("box");
    var first = ensureUsing(std.testing.allocator, &plan, ssh.ptr, &artifacts, .{ .run = runSshCommand }) orelse
        return error.TestUnexpectedResult;
    first.prepared.deinit();
    try std.testing.expectEqual(@as(usize, 1), first.index);
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
    var second = ensureUsing(std.testing.allocator, &plan, ssh.ptr, &artifacts, .{ .run = runSshCommand }) orelse
        return error.TestUnexpectedResult;
    second.prepared.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.index);

    // Only an other-platform artifact: refused by the remote case guard
    // before any payload flows.
    try std.testing.expect(ensureUsing(std.testing.allocator, &plan, ssh.ptr, artifacts[0..1], .{ .run = runSshCommand }) == null);
    try std.testing.expectEqual(Outcome.unsupported_platform, lastOutcome());
}

test "deployment leaves unsupported hosts and failed checks untouched" {
    const plan = testPlan("box");
    var unsupported = FakeRunner{ .statuses = .{ CHECK_UNSUPPORTED, 0 } };
    try std.testing.expect(ensureUsing(std.testing.allocator, &plan, "ssh", &.{fakeArtifact('c')}, .{ .ctx = &unsupported, .run = FakeRunner.run }) == null);
    try std.testing.expectEqual(@as(usize, 1), unsupported.calls);
    try std.testing.expectEqual(Outcome.unsupported_platform, lastOutcome());
    var failed = FakeRunner{ .statuses = .{ 255, 0 } };
    try std.testing.expect(ensureUsing(std.testing.allocator, &plan, "ssh", &.{fakeArtifact('d')}, .{ .ctx = &failed, .run = FakeRunner.run }) == null);
    try std.testing.expectEqual(@as(usize, 1), failed.calls);
    try std.testing.expectEqual(Outcome.failed, lastOutcome());
}

test "deployment falls back when an upload fails" {
    const plan = testPlan("box");
    var fake = FakeRunner{ .statuses = .{ CHECK_MISSING_BASE, 74 } };
    try std.testing.expect(ensureUsing(std.testing.allocator, &plan, "ssh", &.{fakeArtifact('e')}, .{ .ctx = &fake, .run = FakeRunner.run }) == null);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), fake.uploads);
    try std.testing.expectEqual(Outcome.failed, lastOutcome());
}

test "every portable target's remote guard is in the check script" {
    for (&portable.targets) |*target| {
        var fake = FakeRunner{ .statuses = .{ CHECK_READY_BASE, 0 }, .expected_arch_case = target.uname };
        const plan = testPlan("box");
        var result = ensureUsing(std.testing.allocator, &plan, "ssh", &.{.{
            .path = "/tmp/mux-portable",
            .target = target,
            .hash = .{ .hex = [_]u8{'f'} ** 64, .size = 1234 },
        }}, .{ .ctx = &fake, .run = FakeRunner.run }).?;
        result.prepared.deinit();
        try std.testing.expect(fake.arch_guard_ok);
        try std.testing.expect(fake.check_script_ok);
    }
}

test "classify reads the artifact header from disk" {
    var path_buf: [128:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-deploy-classify-{d}", .{c.getpid()}) catch unreachable;
    defer _ = c.unlink(path.ptr);
    var header = [_]u8{0} ** 32;
    std.mem.writeInt(u32, header[0..4], 0xfeedfacf, .little);
    std.mem.writeInt(u32, header[4..8], 0x0100000c, .little);
    {
        const f = c.fopen(path.ptr, "w") orelse return error.SkipZigTest;
        _ = c.fwrite(&header, 1, header.len, f);
        _ = c.fclose(f);
    }
    try std.testing.expectEqualStrings("aarch64-macos", classify(path).?.triple);
    var found: Found = .{};
    found.add(path);
    found.add(path); // a second artifact for the same target is ignored
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expect(classify("/nonexistent/sketerm-mux-portable") == null);
}
