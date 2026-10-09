//! A daemon whose socket path was removed binds it again, and clients find such an orphan
//! before they start a second daemon.
//!
//! logind removes `$XDG_RUNTIME_DIR` when a user's last login session ends (no linger), and
//! with it `sketerm/mux.sock`, while the daemon keeps listening on the unlinked inode: its
//! sessions live on, nothing can reach them, and the next client autostarts another daemon.
//!
//! Daemon side. Every `CHECK_INTERVAL_MS`, and at once on `PROMPT_SIGNAL`, a broker compares
//! its socket path with the inode it bound (`Keeper.checkListener`). A missing path is bound
//! again by `bindListener`, the routine `Daemon.init` binds with, as soon as the path's parent
//! directory exists (the runtime dir itself is root's to create). A path another live daemon
//! answers is never taken over; it is looked at again only when its inode changes. A worker
//! re-creates its adoption listener the same way (`daemon_adopt.workerRelisten`), so a later
//! broker restart can still adopt a session that lived through the removal.
//!
//! The capability fact. A broker publishes `<state dir>/mux-daemons/<pid>.json` and holds a
//! POSIX write lock on it for life. The state dir survives runtime-dir removal, and the lock
//! is the liveness proof: `F_GETLK` names the holding pid, so a record a dead daemon left, or
//! one a reused pid would inherit, never reads as support. Gotchas: POSIX locks are dropped
//! when the holder closes ANY descriptor of the file, so the broker must never open its own
//! record a second time; they are not inherited by `fork`, so a worker never holds one; and
//! `F_GETLK` never reports the caller's own lock, so a record is unreadable as support from
//! inside the process that holds it.
//!
//! Client side. `reclaim` runs before every autostart: it finds daemons that should serve the
//! path but do not through `procinv` (the facts `sketerm doctor` reports), signals only those
//! whose record proves support, and waits `RECLAIM_WAIT_MS` for the path to answer.
//! `PROMPT_SIGNAL` is SIGURG, whose default disposition is to ignore it, so even a misdirected
//! prompt cannot end an old daemon's shells; the record gate is what keeps an old orphan from
//! costing every client that wait. Linux only: elsewhere `procinv` cannot scan and `reclaim`
//! returns at once, while the daemon side works everywhere.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const pathz = @import("../util/pathz.zig");
const xdg = @import("../util/xdg.zig");
const clock = @import("../util/clock.zig");
const sockpath = @import("sockpath.zig");
const log = @import("log.zig");
const procinv = @import("../procinv.zig");

/// The record's `relisten` value this build writes: SIGURG prompts an immediate re-bind.
pub const VERSION: u32 = 1;
pub const PROMPT_SIGNAL = std.posix.SIG.URG;
pub const CHECK_INTERVAL_MS: i64 = 1000;
pub const RECLAIM_WAIT_MS: i64 = 3000;
/// How long a foreign listener at our path is trusted to be live before it is probed again.
pub const DECLINED_RECHECK_MS: i64 = 30_000;
/// Under the state dir; one `<pid>.json` per live broker.
pub const RECORD_DIR = "mux-daemons";

// ── binding ─────────────────────────────────────────────────────────

/// The filesystem object a path names, by device and inode.
pub const Identity = struct {
    dev: u128 = 0,
    ino: u128 = 0,

    pub fn of(path: []const u8) ?Identity {
        var z_buf: [4096]u8 = undefined;
        const z = pathz.pathZ(&z_buf, path) catch return null;
        var st: c.struct_stat = undefined;
        if (c.lstat(z, &st) != 0) return null;
        return fromStat(&st);
    }

    fn fromStat(st: *const c.struct_stat) Identity {
        return .{ .dev = @intCast(st.st_dev), .ino = @intCast(st.st_ino) };
    }

    pub fn eql(a: Identity, b: Identity) bool {
        return a.dev == b.dev and a.ino == b.ino;
    }
};

pub const PathState = enum { ours, missing, replaced, unknown };

/// Whether `path` still names `ours`.
pub fn pathState(path: []const u8, ours: Identity) PathState {
    var z_buf: [4096]u8 = undefined;
    const z = pathz.pathZ(&z_buf, path) catch return .unknown;
    var st: c.struct_stat = undefined;
    if (c.lstat(z, &st) != 0) return if (std.c._errno().* == c.ENOENT) .missing else .unknown;
    return if (Identity.fromStat(&st).eql(ours)) .ours else .replaced;
}

pub const SocketPathState = enum { live, stale, unknown };

/// Probe a socket path with a nonblocking connect; a full backlog reads as `unknown`, never `stale`.
pub fn socketPathState(sock_path: []const u8) SocketPathState {
    const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return .unknown;
    defer _ = c.close(fd);
    const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
    var addr: c.struct_sockaddr_un = undefined;
    sockpath.fillSockaddrUn(&addr, sock_path) catch return .unknown;
    const rc = c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un));
    if (rc == 0) return .live;
    return switch (std.posix.errno(rc)) {
        .CONNREFUSED, .NOENT => .stale,
        else => .unknown,
    };
}

pub const Bound = struct { fd: c_int, id: Identity };

pub const BindError = error{
    BadPath,
    /// The socket directory's parent is gone; nothing may create it but its owner.
    NoParentDir,
    LockFailed,
    /// `try_once` only: another starter holds the startup lock.
    LockBusy,
    SocketFailed,
    AlreadyRunning,
    BindFailed,
    ListenFailed,
    StatFailed,
};

pub const LockMode = enum { wait, try_once };

/// Bind and listen at `path` under the `<path>.lock` startup lock, replacing only a refused stale socket.
/// @throws AlreadyRunning when a live (or unprobeable) listener answers the path.
pub fn bindListener(path: []const u8, mode: LockMode) BindError!Bound {
    var addr: c.struct_sockaddr_un = undefined;
    sockpath.fillSockaddrUn(&addr, path) catch return error.BadPath;
    var z_buf: [4096]u8 = undefined;
    const dir_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.BadPath;
    // One level only: the runtime dir exists, the sketerm dir is ours to make.
    if (dir_end > 0) {
        const dir_z = pathz.pathZ(&z_buf, path[0..dir_end]) catch return error.BadPath;
        if (c.mkdir(dir_z, 0o700) != 0 and std.c._errno().* == c.ENOENT) return error.NoParentDir;
    }

    // Serialize stale-socket recovery. Without this lock, two starters can
    // both observe the same stale inode and one can unlink the other's new
    // listener between its bind and listen calls.
    var lock_buf: [4096:0]u8 = undefined;
    const lock_path = std.fmt.bufPrintZ(&lock_buf, "{s}.lock", .{path}) catch return error.BadPath;
    const lock_fd = c.open(lock_path.ptr, c.O_CREAT | c.O_RDWR | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (lock_fd < 0) return error.LockFailed;
    defer _ = c.close(lock_fd);
    var lock = std.mem.zeroes(c.struct_flock);
    lock.l_type = c.F_WRLCK;
    lock.l_whence = c.SEEK_SET;
    if (c.fcntl(lock_fd, if (mode == .wait) c.F_SETLKW else c.F_SETLK, &lock) < 0) {
        const e = std.c._errno().*;
        return if (mode == .try_once and (e == c.EAGAIN or e == c.EACCES)) error.LockBusy else error.LockFailed;
    }

    const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    bindSocket(fd, &addr) catch |err| switch (err) {
        error.AlreadyRunning => switch (socketPathState(path)) {
            .live, .unknown => return error.AlreadyRunning,
            .stale => {
                var st: c.struct_stat = undefined;
                const path_z = pathz.pathZ(&z_buf, path) catch return error.BadPath;
                if (c.lstat(path_z, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFSOCK)
                    return error.BindFailed;
                if (c.unlink(path_z) != 0 and std.c._errno().* != c.ENOENT)
                    return error.BindFailed;
                try bindSocket(fd, &addr);
            },
        },
        else => return err,
    };
    if (c.listen(fd, 8) != 0) return error.ListenFailed;
    const id = Identity.of(path) orelse return error.StatFailed;
    return .{ .fd = fd, .id = id };
}

fn bindSocket(fd: c_int, addr: *c.struct_sockaddr_un) BindError!void {
    if (c.bind(fd, @ptrCast(addr), @sizeOf(c.struct_sockaddr_un)) == 0) return;
    return if (std.c._errno().* == c.EADDRINUSE) error.AlreadyRunning else error.BindFailed;
}

/// Directory part of `path`, or null when it has none.
fn dirName(path: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    return if (slash == 0) "/" else path[0..slash];
}

/// Whether the directory that must exist before `path`'s own directory can be made does.
pub fn parentReady(path: []const u8) bool {
    const dir = dirName(path) orelse return false;
    const parent = dirName(dir) orelse return false;
    return pathz.isDir(parent);
}

// ── the capability record ───────────────────────────────────────────

pub const Record = struct {
    relisten: u32 = 0,
    pid: i64 = 0,
    socket: []const u8 = "",
};

/// `<state dir>/mux-daemons/<pid>.json`, resolved from `environ` (another process's block) or,
/// when null, from this process's environment.
fn recordPath(buf: []u8, pid: c.pid_t, environ: ?[]const u8) ?[:0]u8 {
    var dir_buf: [4096]u8 = undefined;
    const dir = recordDir(&dir_buf, environ) orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/{d}.json", .{ dir, pid }) catch null;
}

fn recordDir(buf: []u8, environ: ?[]const u8) ?[]const u8 {
    var state_buf: [4096]u8 = undefined;
    const state = if (environ) |block|
        xdg.stateDirFrom(&state_buf, platform.environBlockValue(block, "XDG_STATE_HOME"), platform.environBlockValue(block, "HOME"))
    else
        xdg.stateDir(&state_buf);
    return std.fmt.bufPrint(buf, "{s}/" ++ RECORD_DIR, .{state orelse return null}) catch null;
}

/// The record `pid` holds locked, or null when there is none or nobody holds it.
pub fn readRecord(buf: []u8, pid: c.pid_t, environ: ?[]const u8) ?Record {
    var path_buf: [4096]u8 = undefined;
    const path = recordPath(&path_buf, pid, environ) orelse return null;
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var probe = std.mem.zeroes(c.struct_flock);
    probe.l_type = c.F_WRLCK;
    probe.l_whence = c.SEEK_SET;
    if (c.fcntl(fd, c.F_GETLK, &probe) != 0) return null;
    if (probe.l_type == c.F_UNLCK or probe.l_pid != pid) return null;
    var text: [1024]u8 = undefined;
    const n = c.read(fd, &text, text.len);
    if (n <= 0) return null;
    var fba = std.heap.FixedBufferAllocator.init(buf);
    return std.json.parseFromSliceLeaky(Record, fba.allocator(), text[0..@intCast(n)], .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

pub const Support = enum {
    /// Publishes the fact: re-binds by itself and on `PROMPT_SIGNAL`.
    recovers,
    /// No live record: a build before this mechanism, or one that cannot be identified.
    old_build,
};

/// The gate every prompt passes: only a record held by `pid` itself, at a version that answers the signal.
pub fn supportOf(pid: c.pid_t, record: ?Record) Support {
    const r = record orelse return .old_build;
    return if (r.relisten >= 1 and r.pid == pid) .recovers else .old_build;
}

pub fn support(pid: c.pid_t, environ: ?[]const u8) Support {
    var buf: [2048]u8 = undefined;
    return supportOf(pid, readRecord(&buf, pid, environ));
}

/// Signal `pid` to re-bind now, but only when its record proves it understands the signal.
/// @return whether a prompt was sent.
pub fn prompt(pid: c.pid_t, environ: ?[]const u8) bool {
    if (support(pid, environ) != .recovers) return false;
    return c.kill(pid, @intFromEnum(PROMPT_SIGNAL)) == 0;
}

// ── daemon side ─────────────────────────────────────────────────────

/// Read by the signal handler; written only while the handler cannot observe a half-set pair.
var g_wake: platform.Wakeup = .{ .read_fd = -1, .write_fd = -1 };
var g_owner: c.pid_t = 0;

fn onPrompt(_: @TypeOf(PROMPT_SIGNAL)) callconv(.c) void {
    // A forked worker inherits this handler but not the broker's wakeup descriptor.
    if (@atomicLoad(c.pid_t, &g_owner, .seq_cst) != c.getpid()) return;
    if (g_wake.write_fd < 0) return;
    const saved = std.c._errno().*;
    g_wake.signal();
    std.c._errno().* = saved;
}

pub const Phase = enum { bound, waiting_parent, lock_busy, taken, failed };

/// A daemon's half: the prompt wakeup, the published record and the re-bind state.
pub const Keeper = struct {
    wake: ?platform.Wakeup = null,
    old_action: std.posix.Sigaction = undefined,
    record_fd: c_int = -1,
    record_path: [4096]u8 = undefined,
    record_path_len: usize = 0,
    record_id: Identity = .{},
    next_check_ms: i64 = 0,
    /// A foreign live listener at our path, left alone until its inode changes or the recheck is due.
    declined: Identity = .{},
    declined_until_ms: i64 = 0,
    phase: Phase = .bound,

    /// Arm the prompt signal and publish the record; a broker calls this once it serves `sock_path`.
    pub fn startBroker(self: *Keeper, sock_path: []const u8) void {
        if (self.wake == null) {
            if (platform.Wakeup.init()) |w| {
                self.wake = w;
                g_wake = w;
                @atomicStore(c.pid_t, &g_owner, c.getpid(), .seq_cst);
                const action = std.posix.Sigaction{
                    .handler = .{ .handler = &onPrompt },
                    .mask = std.posix.sigemptyset(),
                    .flags = std.posix.SA.RESTART,
                };
                std.posix.sigaction(PROMPT_SIGNAL, &action, &self.old_action);
            } else |_| log.warn("relisten: no wakeup descriptor; re-binding only on the {d}ms check", .{CHECK_INTERVAL_MS});
        }
        self.publish(sock_path);
    }

    pub fn stop(self: *Keeper) void {
        if (self.wake) |w| {
            std.posix.sigaction(PROMPT_SIGNAL, &self.old_action, null);
            @atomicStore(c.pid_t, &g_owner, 0, .seq_cst);
            g_wake = .{ .read_fd = -1, .write_fd = -1 };
            w.close();
            self.wake = null;
        }
        if (self.record_fd >= 0) {
            const path = self.recordPathSlice();
            if (pathState(path, self.record_id) == .ours) pathz.unlinkPath(path);
            _ = c.close(self.record_fd);
            self.record_fd = -1;
        }
    }

    /// Descriptor for the poll set (-1 when unarmed).
    pub fn pollFd(self: *const Keeper) c_int {
        return if (self.wake) |w| w.read_fd else -1;
    }

    /// Consume a prompt, if `revents` carries one, and report whether a check is due now.
    pub fn due(self: *Keeper, now: i64, revents: c_short) bool {
        var prompted = false;
        if (self.wake) |w| {
            if (revents & c.POLLIN != 0) {
                var scratch: [64]u8 = undefined;
                while (c.read(w.read_fd, &scratch, scratch.len) > 0) {}
                prompted = true;
            }
        }
        if (!prompted and now < self.next_check_ms) return false;
        self.next_check_ms = now + CHECK_INTERVAL_MS;
        return true;
    }

    fn recordPathSlice(self: *const Keeper) []const u8 {
        return self.record_path[0..self.record_path_len];
    }

    /// Write and lock this process's record, replacing one that vanished or was replaced.
    fn publish(self: *Keeper, sock_path: []const u8) void {
        var dir_buf: [4096]u8 = undefined;
        const dir = recordDir(&dir_buf, null) orelse return;
        pathz.makeDirs(dir, 0o700) catch return;
        const pid = c.getpid();
        var tmp_buf: [4096:0]u8 = undefined;
        const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}/.{d}.tmp", .{ dir, pid }) catch return;
        const final = std.fmt.bufPrintZ(&self.record_path, "{s}/{d}.json", .{ dir, pid }) catch return;
        self.record_path_len = final.len;
        const fd = c.open(tmp.ptr, c.O_CREAT | c.O_TRUNC | c.O_WRONLY | c.O_CLOEXEC, @as(c_uint, 0o600));
        if (fd < 0) return;
        var lock = std.mem.zeroes(c.struct_flock);
        lock.l_type = c.F_WRLCK;
        lock.l_whence = c.SEEK_SET;
        var json_buf: [4096 + 128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&json_buf);
        const ok = c.fcntl(fd, c.F_SETLK, &lock) == 0 and
            if (std.json.Stringify.value(Record{ .relisten = VERSION, .pid = pid, .socket = sock_path }, .{}, &w)) |_| true else |_| false;
        var st: c.struct_stat = undefined;
        const body = w.buffered();
        if (!ok or c.write(fd, body.ptr, body.len) != @as(isize, @intCast(body.len)) or
            c.fstat(fd, &st) != 0 or c.rename(tmp.ptr, final.ptr) != 0)
        {
            _ = c.close(fd);
            _ = c.unlink(tmp.ptr);
            log.warn("relisten: cannot publish {s}; clients will not prompt this daemon", .{final});
            return;
        }
        // The old record is another inode: closing it drops only that file's lock.
        if (self.record_fd >= 0) _ = c.close(self.record_fd);
        self.record_fd = fd;
        self.record_id = Identity.fromStat(&st);
        sweep(dir, pid);
    }

    /// Republish when the record file was removed or replaced under us.
    pub fn keepRecord(self: *Keeper, sock_path: []const u8) void {
        if (self.record_fd < 0) return;
        if (pathState(self.recordPathSlice(), self.record_id) == .ours) return;
        log.info("relisten: record {s} vanished; publishing it again", .{self.recordPathSlice()});
        self.publish(sock_path);
    }

    /// Check the broker's socket path against the inode it bound.
    /// @return a fresh listener the caller swaps in, or null when nothing changed.
    pub fn checkListener(self: *Keeper, now: i64, sock_path: []const u8, bound: Identity) ?Bound {
        switch (pathState(sock_path, bound)) {
            .ours => {
                self.enter(.bound, sock_path, null);
                return null;
            },
            .unknown => return null,
            .replaced => {
                const now_id = Identity.of(sock_path) orelse return null;
                if (self.phase == .taken and now_id.eql(self.declined) and now < self.declined_until_ms) return null;
                if (socketPathState(sock_path) != .stale) {
                    self.decline(now, now_id, sock_path);
                    return null;
                }
            },
            .missing => {},
        }
        if (!parentReady(sock_path)) {
            self.enter(.waiting_parent, sock_path, null);
            return null;
        }
        const fresh = bindListener(sock_path, .try_once) catch |err| {
            switch (err) {
                error.LockBusy => self.enter(.lock_busy, sock_path, null),
                error.AlreadyRunning => self.decline(now, Identity.of(sock_path) orelse .{}, sock_path),
                error.NoParentDir => self.enter(.waiting_parent, sock_path, null),
                else => self.enter(.failed, sock_path, err),
            }
            return null;
        };
        self.enter(.bound, sock_path, null);
        log.info("relisten: re-bound {s} after it was removed; sessions are reachable again", .{sock_path});
        return fresh;
    }

    fn decline(self: *Keeper, now: i64, id: Identity, sock_path: []const u8) void {
        self.declined = id;
        self.declined_until_ms = now + DECLINED_RECHECK_MS;
        self.enter(.taken, sock_path, null);
    }

    /// Log each transition once, so a path absent for days costs one line, not one per second.
    fn enter(self: *Keeper, phase: Phase, sock_path: []const u8, err: ?anyerror) void {
        if (self.phase == phase) return;
        self.phase = phase;
        switch (phase) {
            .bound => {},
            .waiting_parent => log.warn("relisten: {s} was removed and its parent directory is gone; re-binding once it exists", .{sock_path}),
            .lock_busy => log.info("relisten: {s} is being bound by another starter; retrying", .{sock_path}),
            .taken => log.warn("relisten: another daemon now serves {s}; not taking it over (sessions here stay unreachable until it exits)", .{sock_path}),
            .failed => log.warn("relisten: re-binding {s} failed: {s}; retrying", .{ sock_path, if (err) |e| @errorName(e) else "?" }),
        }
    }
};

/// Remove records whose writer is gone; a locked record belongs to a live broker and stays.
fn sweep(dir: []const u8, self_pid: c.pid_t) void {
    var dir_z_buf: [4096]u8 = undefined;
    const dir_z = pathz.pathZ(&dir_z_buf, dir) catch return;
    const d = c.opendir(dir_z) orelse return;
    defer _ = c.closedir(d);
    while (c.readdir(d)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        const pid = std.fmt.parseInt(c.pid_t, name[0 .. name.len - ".json".len], 10) catch continue;
        if (pid == self_pid) continue;
        var path_buf: [4096:0]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;
        const fd = c.open(path.ptr, c.O_RDWR | c.O_CLOEXEC);
        if (fd < 0) continue;
        defer _ = c.close(fd);
        var lock = std.mem.zeroes(c.struct_flock);
        lock.l_type = c.F_WRLCK;
        lock.l_whence = c.SEEK_SET;
        if (c.fcntl(fd, c.F_SETLK, &lock) != 0) continue;
        var st: c.struct_stat = undefined;
        if (c.fstat(fd, &st) != 0) continue;
        if (pathState(path, Identity.fromStat(&st)) == .ours) _ = c.unlink(path.ptr);
    }
}

// ── client side ─────────────────────────────────────────────────────

/// Before autostarting a daemon at `path`, prompt every same-uid daemon that should serve it
/// but does not, then wait (bounded) for the path to answer.
/// @return whether the path answers now; the caller connects as usual, and autostarts when false.
pub fn reclaim(allocator: std.mem.Allocator, path: []const u8) bool {
    if (!platform.can_inspect_processes) return false;
    // A daemon cannot bind under a directory that does not exist; neither could an autostart.
    if (!parentReady(path)) return false;
    var inv = procinv.scan(allocator, c.getpid()) catch return false;
    defer inv.deinit();
    const env_buf = allocator.alloc(u8, 1 << 16) catch return false;
    defer allocator.free(env_buf);
    var prompted: [8]c.pid_t = undefined;
    var n: usize = 0;
    for (inv.procs) |*p| {
        if (!p.isDaemon() or n == prompted.len) continue;
        const environ = platform.environOfPid(p.pid, env_buf);
        const sock = (procinv.daemonSocket(allocator, p, environ) catch null) orelse continue;
        defer allocator.free(sock);
        if (!std.mem.eql(u8, sock, path)) continue;
        if (!prompt(p.pid, environ)) continue;
        prompted[n] = p.pid;
        n += 1;
    }
    if (n == 0) return false;
    const deadline = clock.nowMs() + RECLAIM_WAIT_MS;
    while (clock.nowMs() < deadline) {
        if (socketPathState(path) == .live) return true;
        const any_alive = for (prompted[0..n]) |pid| {
            if (c.kill(pid, 0) == 0) break true;
        } else false;
        if (!any_alive) return false;
        _ = c.usleep(25_000);
    }
    return false;
}

// ── tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "the prompt gate refuses every orphan that does not hold a current record" {
    try t.expectEqual(Support.old_build, supportOf(42, null));
    try t.expectEqual(Support.old_build, supportOf(42, .{ .relisten = 0, .pid = 42 }));
    try t.expectEqual(Support.old_build, supportOf(42, .{ .relisten = VERSION, .pid = 43 }));
    try t.expectEqual(Support.recovers, supportOf(42, .{ .relisten = VERSION, .pid = 42 }));
}

test "an old or unknown orphan is never signalled; a publishing one is" {
    var root_buf: [64:0]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&root_buf, "/tmp/sk-relisten-{d}", .{c.getpid()});
    defer pathz.removeTree(root);
    var env_buf: [128]u8 = undefined;
    const environ = try std.fmt.bufPrint(&env_buf, "HOME=/nonexistent\x00XDG_STATE_HOME={s}\x00", .{root});

    var report: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.pipe(&report));
    defer _ = c.close(report[0]);
    // Each child exits 42 on SIGURG, so a prompt that was sent is observable.
    const Child = struct {
        fn onUrg(_: @TypeOf(PROMPT_SIGNAL)) callconv(.c) void {
            c._exit(42);
        }
        fn spawn(publish: bool, state: [:0]const u8, ready_fd: c_int) c.pid_t {
            const pid = c.fork();
            if (pid != 0) return pid;
            const act = std.posix.Sigaction{ .handler = .{ .handler = &onUrg }, .mask = std.posix.sigemptyset(), .flags = 0 };
            std.posix.sigaction(PROMPT_SIGNAL, &act, null);
            if (publish) {
                _ = c.setenv("XDG_STATE_HOME", state.ptr, 1);
                var k: Keeper = .{};
                k.publish("/tmp/sk-relisten-test.sock");
            }
            _ = c.write(ready_fd, "r", 1);
            while (true) _ = c.pause();
        }
    };
    const reap = struct {
        fn f(pid: c.pid_t) c_int {
            _ = c.kill(pid, c.SIGKILL);
            var st: c_int = 0;
            _ = c.waitpid(pid, &st, 0);
            return st;
        }
    }.f;
    var ready: [1]u8 = undefined;

    // No record: an old build. The gate must not send anything.
    const old = Child.spawn(false, root, report[1]);
    try t.expect(c.read(report[0], &ready, 1) == 1);
    try t.expectEqual(Support.old_build, support(old, environ));
    try t.expect(!prompt(old, environ));
    _ = c.usleep(100_000);
    var st: c_int = 0;
    try t.expectEqual(@as(c.pid_t, 0), c.waitpid(old, &st, c.WNOHANG));
    _ = reap(old);

    // A record whose writer died (or whose pid was reused) reads as no support either.
    const gone = Child.spawn(true, root, report[1]);
    try t.expect(c.read(report[0], &ready, 1) == 1);
    try t.expectEqual(Support.recovers, support(gone, environ));
    _ = reap(gone);
    try t.expectEqual(Support.old_build, support(gone, environ));

    // A live publisher gets the prompt.
    const fresh = Child.spawn(true, root, report[1]);
    try t.expect(c.read(report[0], &ready, 1) == 1);
    try t.expect(prompt(fresh, environ));
    _ = c.waitpid(fresh, &st, 0);
    try t.expect(c.WIFEXITED(st) and c.WEXITSTATUS(st) == 42);
    _ = c.close(report[1]);
}

test "a broker re-binds a removed socket path and leaves a live replacement alone" {
    var root_buf: [64:0]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&root_buf, "/tmp/sk-rebind-{d}", .{c.getpid()});
    _ = c.mkdir(root.ptr, 0o700);
    defer pathz.removeTree(root);
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/rt/sketerm/mux.sock", .{root});
    var rt_buf: [96:0]u8 = undefined;
    const rt = try std.fmt.bufPrintZ(&rt_buf, "{s}/rt", .{root});
    _ = c.mkdir(rt.ptr, 0o700);

    const first = try bindListener(path, .wait);
    defer _ = c.close(first.fd);
    var k: Keeper = .{};
    try t.expect(k.checkListener(clock.nowMs(), path, first.id) == null);

    // The runtime dir goes away entirely: nothing to bind under until it is back.
    pathz.removeTree(rt);
    try t.expect(k.checkListener(clock.nowMs(), path, first.id) == null);
    try t.expectEqual(Phase.waiting_parent, k.phase);
    _ = c.mkdir(rt.ptr, 0o700);
    const second = k.checkListener(clock.nowMs(), path, first.id) orelse return error.TestUnexpectedResult;
    defer _ = c.close(second.fd);
    try t.expectEqual(SocketPathState.live, socketPathState(path));
    try t.expectEqual(PathState.ours, pathState(path, second.id));

    // Someone else's live listener at the path is never replaced.
    var z_buf: [4096]u8 = undefined;
    _ = c.unlink(try pathz.pathZ(&z_buf, path));
    const other = try bindListener(path, .wait);
    defer _ = c.close(other.fd);
    try t.expect(k.checkListener(clock.nowMs(), path, second.id) == null);
    try t.expectEqual(Phase.taken, k.phase);
    try t.expectEqual(PathState.ours, pathState(path, other.id));
}
