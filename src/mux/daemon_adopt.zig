//! Worker adoption: session workers outlive their broker.
//!
//! A worker used to exit on broker control EOF, so replacing the broker
//! binary (an upgrade) or losing it to a crash ended every session. Now a
//! worker that could open an ADOPTION LISTENER treats that EOF as being
//! orphaned: its session keeps running, clients it already serves keep
//! being served, and the next broker on the same socket adopts it.
//!
//! Rendezvous. The listener is a stream socket at
//! `<broker socket>.w/<origin_id>` (directory mode 0700, so only the
//! owning user can connect). A broker scans that directory at startup
//! (waiting, bounded, for the answers before it serves anyone, so the
//! first `list` after an upgrade already shows every session) and every
//! `SCAN_INTERVAL_MS` after, and offers each worker it does not already
//! hold a FRESH `platform.controlSocketpair` end over the stream: one
//! `'B' <offer version>` message carrying the fd in SCM_RIGHTS. The
//! stream is only the doorbell; the control channel itself is the same
//! datagram pair a fork creates, so every opcode, every size limit and
//! the Darwin `n <= 0` rule stay exactly as they are.
//!
//! The worker accepts an offer only while it has no live broker (it first
//! drains a pending control EOF, since the old broker's exit and the new
//! broker's scan can race), then answers on the new channel with one
//! `'D'` JSON record (`WorkerAdopt`): name, identity, pids and hub paths,
//! i.e. everything the adopting broker did not see at fork time. From
//! there it is an ordinary worker: `'M'` pushes resume, `'A'`/`'K'`/`'R'`
//! work. A worker with a live broker refuses by closing the offered fd,
//! which the offering broker reads as control EOF and forgets.
//!
//! Version skew. The control opcodes and the `'A'` handoff encoding are
//! append-only, `'D'` is parsed with unknown fields ignored, and the
//! offer carries a version a worker may ignore, so a broker adopts
//! workers built by older binaries and an older broker adopts newer
//! ones. A record the broker cannot use leaves the worker running and
//! serving the clients it has (never killed). Workers from before this
//! mechanism have no listener and exit with their broker, as they always
//! did; that is why a handover (`quit_idle` + `handover`) refuses while
//! the broker holds a worker that did not report `adopt`.
//!
//! Backstops. An orphaned worker is not anyone's child, so PDEATHSIG is
//! not what bounds it: workers keep the inherited lifetime fence
//! (`lifetime.zig`) and exit when it trips, which is what reaps orphans
//! under a test harness. The per-user daemon is never fenced, and there
//! an orphan lives exactly as long as its session: that is the point.

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("log.zig");
const platform = @import("../util/platform.zig");
const sockpath = @import("sockpath.zig");
const build_options = @import("build_options");
const dmod = @import("daemon.zig");
const daemon_control = @import("daemon_control.zig");
const nowMs = @import("../util/clock.zig").nowMs;
const Daemon = dmod.Daemon;
const Worker = dmod.Worker;
const WorkerAdopt = dmod.WorkerAdopt;

/// The offer layout this build sends. A worker accepts any version: the
/// offer carries nothing but the channel, and the answer is its own
/// versioned record.
pub const OFFER_VERSION: u8 = 1;
/// Directory beside the broker socket that holds the worker listeners.
pub const DIR_SUFFIX = ".w";
/// How often a running broker looks for orphans it has not adopted yet.
pub const SCAN_INTERVAL_MS: i64 = 2000;
/// How long a starting broker waits for the adoption answers before it
/// serves clients.
pub const STARTUP_WAIT_MS: i64 = 1500;
/// A listener file younger than this is never removed as stale: its
/// worker may sit between `bind` and `listen`.
const STALE_MIN_AGE_S: i64 = 10;

fn dirPath(buf: []u8, broker_sock: []const u8) ?[:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}" ++ DIR_SUFFIX, .{broker_sock}) catch null;
}

fn listenerPath(buf: []u8, broker_sock: []const u8, origin_id: []const u8) ?[:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}" ++ DIR_SUFFIX ++ "/{s}", .{ broker_sock, origin_id }) catch null;
}

// ── worker side ─────────────────────────────────────────────────────

/// Open this worker's adoption listener. Failure is logged and leaves the
/// worker non-adoptable (it then exits with its broker, as before).
pub fn workerListen(self: *Daemon, origin_id: []const u8) void {
    const broker_sock = self.broker_sock orelse return;
    var dir_buf: [512]u8 = undefined;
    const dir = dirPath(&dir_buf, broker_sock) orelse return;
    if (c.mkdir(dir.ptr, 0o700) != 0 and std.posix.errno(-1) != .EXIST) {
        log.warn("worker: cannot create adoption dir {s}; session ends with its broker", .{dir});
        return;
    }
    var path_buf: [512]u8 = undefined;
    const path = listenerPath(&path_buf, broker_sock, origin_id) orelse return;
    var addr: c.struct_sockaddr_un = undefined;
    sockpath.fillSockaddrUn(&addr, path) catch {
        log.warn("worker: adoption socket path too long ({d} bytes); session ends with its broker", .{path.len});
        return;
    };
    const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return;
    _ = c.unlink(path.ptr); // the origin id is ours alone; a leftover is dead
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0 or c.listen(fd, 4) != 0) {
        log.warn("worker: adoption listener {s} failed; session ends with its broker", .{path});
        _ = c.close(fd);
        return;
    }
    _ = c.chmod(path.ptr, 0o600);
    const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
    var st: c.struct_stat = undefined;
    if (c.lstat(path.ptr, &st) == 0) {
        self.adopt_dev = @intCast(st.st_dev);
        self.adopt_ino = @intCast(st.st_ino);
    }
    self.adopt_path = self.allocator.dupe(u8, path) catch {
        _ = c.close(fd);
        _ = c.unlink(path.ptr);
        return;
    };
    self.adopt_fd = fd;
}

/// Close the listener and unlink it, but only while the path is still the
/// inode this worker bound.
pub fn closeListener(self: *Daemon) void {
    if (self.adopt_fd >= 0) _ = c.close(self.adopt_fd);
    self.adopt_fd = -1;
    const p = self.adopt_path orelse return;
    self.adopt_path = null;
    defer self.allocator.free(p);
    var z: [512]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&z, "{s}", .{p}) catch return;
    var st: c.struct_stat = undefined;
    if (c.lstat(pz.ptr, &st) == 0 and
        @as(u128, @intCast(st.st_dev)) == self.adopt_dev and
        @as(u128, @intCast(st.st_ino)) == self.adopt_ino)
        _ = c.unlink(pz.ptr);
}

/// Control EOF on an adoptable worker: the broker is gone. Keep the
/// session and every attached client; wait for the next broker.
pub fn workerOrphaned(self: *Daemon) void {
    if (self.control_fd >= 0) _ = c.close(self.control_fd);
    self.control_fd = -1;
    // A rename the old broker never answered can no longer be answered.
    if (self.worker_rename_request) |pending| {
        self.worker_rename_request = null;
        for (self.clients.items) |cl| {
            if (cl.id == pending.requester_id and !cl.dead) cl.queueErr("session rename lost: the broker restarted");
        }
    }
    log.info("worker pid={d}: broker gone; session kept, waiting for adoption", .{c.getpid()});
}

/// A broker knocked on the adoption listener.
pub fn workerOnAdopt(self: *Daemon) void {
    const conn = c.accept(self.adopt_fd, null, null);
    if (conn < 0) return;
    defer _ = c.close(conn);
    var pfd = c.struct_pollfd{ .fd = conn, .events = c.POLLIN, .revents = 0 };
    if (c.poll(&pfd, 1, 500) <= 0) return;
    var buf: [16]u8 = undefined;
    var passed: c_int = -1;
    const n = daemon_control.controlRecv(conn, &buf, &passed);
    if (n < 1 or buf[0] != 'B' or passed < 0) {
        if (passed >= 0) _ = c.close(passed);
        return;
    }
    // The previous broker's exit and this offer race: settle any control
    // traffic already queued (its EOF included) before deciding.
    var rounds: usize = 0;
    while (self.control_fd >= 0 and self.running and rounds < 16) : (rounds += 1) {
        var cp = c.struct_pollfd{ .fd = self.control_fd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&cp, 1, 0) <= 0 or cp.revents & (c.POLLIN | c.POLLHUP | c.POLLERR) == 0) break;
        daemon_control.workerOnControl(self);
    }
    if (self.control_fd >= 0 or !self.running or self.sessions.items.len == 0) {
        // A live broker already holds us (or we are on our way out):
        // closing the offered end is the refusal.
        _ = c.close(passed);
        return;
    }
    _ = c.fcntl(passed, c.F_SETFD, c.FD_CLOEXEC);
    self.control_fd = passed;
    if (!sendAdoptRecord(self)) {
        // The new broker hears EOF and forgets the offer; we stay an
        // orphan for its next scan.
        _ = c.close(passed);
        self.control_fd = -1;
        return;
    }
    // A full metadata push follows on the next tick.
    self.wpush = .{};
    log.info("worker pid={d}: adopted by a restarted broker (offer v{d})", .{ c.getpid(), if (n >= 2) buf[1] else 0 });
}

fn sendAdoptRecord(self: *Daemon) bool {
    const s = self.sessions.items[0];
    const rec = WorkerAdopt{
        .wpid = c.getpid(),
        .name = s.name,
        .origin_name = s.origin_name,
        .origin_id = &s.origin_id,
        .build = build_options.commit,
        .pid = s.childPid(),
        .app = s.app,
        .display = s.display,
        .ttl_secs = @intCast(@max(@divTrunc(s.ttl_ms, 1000), 0)),
        .wl = if (s.wl_display_path) |p| p else "",
        .pa = if (s.pa_socket_path) |p| p else "",
        .rt = if (s.runtime_dir_path) |p| p else "",
        .x = if (s.xwayland) |*xwl| xwl.display_name else "",
        .xa = if (s.xwayland) |*xwl| xwl.auth_path else "",
        .xwayland = s.xwayland != null,
        .gpu = s.gpu,
        .output_width = s.output_width,
        .output_height = s.output_height,
    };
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    aw.writer.writeByte('D') catch return false;
    std.json.Stringify.value(rec, .{}, &aw.writer) catch return false;
    return daemon_control.controlSend(self.control_fd, aw.written(), -1);
}

// ── broker side ─────────────────────────────────────────────────────

/// Scan for orphans when the interval has passed (the first call scans).
pub fn brokerMaybeScan(self: *Daemon, now: i64) void {
    if (self.adopt_scan_ms != 0 and now - self.adopt_scan_ms < SCAN_INTERVAL_MS) return;
    self.adopt_scan_ms = now;
    brokerScan(self);
}

/// Startup: offer every orphan a channel and wait, bounded, for the
/// answers, so the first client this broker serves sees every session.
pub fn brokerAdoptAtStartup(self: *Daemon) void {
    self.adopt_scan_ms = nowMs();
    brokerScan(self);
    const deadline = nowMs() + STARTUP_WAIT_MS;
    while (nowMs() < deadline) {
        var fds: [64]c.struct_pollfd = undefined;
        var owners: [64]*Worker = undefined;
        var n: usize = 0;
        for (self.workers.items) |w| {
            if (!w.adopting or w.dead or n == fds.len) continue;
            fds[n] = .{ .fd = w.control_fd, .events = c.POLLIN, .revents = 0 };
            owners[n] = w;
            n += 1;
        }
        if (n == 0) break;
        const left: c_int = @intCast(@max(deadline - nowMs(), 1));
        if (c.poll(&fds, @intCast(n), left) <= 0) continue;
        for (fds[0..n], owners[0..n]) |pfd, w| {
            if (pfd.revents & c.POLLIN != 0) {
                daemon_control.brokerOnWorkerControl(self, w);
            } else if (pfd.revents & (c.POLLHUP | c.POLLERR) != 0) {
                w.dead = true;
            }
        }
    }
}

fn knownOrigin(self: *Daemon, origin: []const u8) bool {
    for (self.workers.items) |w| {
        if (!w.dead and std.mem.eql(u8, &w.origin_id, origin)) return true;
    }
    return false;
}

/// Offer a control channel to every listener this broker does not hold.
pub fn brokerScan(self: *Daemon) void {
    if (self.sock_path.len == 0 or self.handing_over) return;
    var dir_buf: [512]u8 = undefined;
    const dir_z = dirPath(&dir_buf, self.sock_path) orelse return;
    const dir = c.opendir(dir_z.ptr) orelse return;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!@import("wire.zig").validSessionOriginId(name)) continue;
        if (knownOrigin(self, name)) continue;
        offer(self, name);
    }
}

fn offer(self: *Daemon, origin: []const u8) void {
    var path_buf: [512]u8 = undefined;
    const path = listenerPath(&path_buf, self.sock_path, origin) orelse return;
    var addr: c.struct_sockaddr_un = undefined;
    sockpath.fillSockaddrUn(&addr, path) catch return;
    const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return;
    defer _ = c.close(fd);
    const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) {
        if (std.posix.errno(-1) == .CONNREFUSED) removeIfStale(path);
        return; // EAGAIN (backlog full) and the rest: next scan
    }
    var sp: [2]c_int = undefined;
    if (platform.controlSocketpair(&sp, daemon_control.WORKER_META_BUF) != 0) return;
    const msg = [_]u8{ 'B', OFFER_VERSION };
    const sent = daemon_control.controlSend(fd, &msg, sp[1]);
    _ = c.close(sp[1]);
    if (!sent) {
        _ = c.close(sp[0]);
        return;
    }
    _ = c.fcntl(sp[0], c.F_SETFD, c.FD_CLOEXEC);
    const w = newAdoptingWorker(self, origin, sp[0]) catch {
        _ = c.close(sp[0]);
        return;
    };
    self.workers.append(self.allocator, w) catch w.deinit();
}

fn newAdoptingWorker(self: *Daemon, origin: []const u8, control_fd: c_int) !*Worker {
    const name = try self.allocator.dupe(u8, "");
    errdefer self.allocator.free(name);
    const origin_name = try self.allocator.dupe(u8, "");
    errdefer self.allocator.free(origin_name);
    const w = try self.allocator.create(Worker);
    w.* = .{
        .allocator = self.allocator,
        .name = name,
        .origin_name = origin_name,
        .origin_id = origin[0..dmod.SESSION_ORIGIN_ID_LEN].*,
        .pid = 0,
        .control_fd = control_fd,
        .adopted = true,
        .adopting = true,
    };
    return w;
}

/// A refused connect means nobody listens: the worker is gone. Remove its
/// leftover file, unless it is young enough to be a worker mid-setup.
fn removeIfStale(path: [:0]const u8) void {
    var st: c.struct_stat = undefined;
    if (c.lstat(path.ptr, &st) != 0) return;
    const now_s: i64 = @divTrunc(@import("../util/clock.zig").wallMs(), 1000);
    const ts = if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim else st.st_mtimespec;
    if (now_s - @as(i64, @intCast(ts.tv_sec)) < STALE_MIN_AGE_S) return;
    _ = c.unlink(path.ptr);
}

/// The worker's 'D' answer to an offer: fill in the record, or forget
/// the offer when the answer is unusable (the worker keeps running).
pub fn brokerOnAdoptRecord(self: *Daemon, w: *Worker, payload: []const u8) void {
    if (!w.adopting) return;
    var parsed = std.json.parseFromSlice(WorkerAdopt, self.allocator, payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        log.warn("adoption: unreadable record from worker {s}; left running unadopted", .{&w.origin_id});
        w.dead = true;
        return;
    };
    defer parsed.deinit();
    const rec = parsed.value;
    if (!std.mem.eql(u8, rec.origin_id, &w.origin_id) or rec.name.len == 0 or
        rec.name.len > dmod.MAX_SESSION_NAME or rec.wpid <= 0)
    {
        log.warn("adoption: worker {s} answered for another identity; left running unadopted", .{&w.origin_id});
        w.dead = true;
        return;
    }
    var name_buf: [dmod.MAX_SESSION_NAME]u8 = undefined;
    var name: []const u8 = rec.name;
    if (nameInUse(self, rec.name, w)) {
        // A session took the name while this worker was orphaned. The
        // broker is the rename authority: suffix the origin id and tell
        // the worker, exactly like a rename.
        const keep = @min(rec.name.len, dmod.MAX_SESSION_NAME - 9);
        name = std.fmt.bufPrint(&name_buf, "{s}-{s}", .{ rec.name[0..keep], w.origin_id[0..8] }) catch rec.name;
        var msg: [1 + dmod.MAX_SESSION_NAME]u8 = undefined;
        msg[0] = 'R';
        @memcpy(msg[1..][0..name.len], name);
        _ = daemon_control.controlSend(w.control_fd, msg[0 .. 1 + name.len], -1);
    }
    w.renameTo(name) catch {
        w.dead = true;
        return;
    };
    const origin_name = self.allocator.dupe(u8, if (rec.origin_name.len > 0) rec.origin_name else rec.name) catch {
        w.dead = true;
        return;
    };
    self.allocator.free(w.origin_name);
    w.origin_name = origin_name;
    w.pid = rec.wpid;
    w.child_pid = rec.pid;
    w.app = rec.app;
    w.display = rec.display;
    w.ttl_secs = rec.ttl_secs;
    w.setOwned(&w.wl_display, rec.wl);
    w.setOwned(&w.pulse_server, rec.pa);
    w.setOwned(&w.runtime_dir, rec.rt);
    w.setOwned(&w.x_display, rec.x);
    w.setOwned(&w.xauthority, rec.xa);
    w.xwayland = rec.xwayland;
    w.gpu = rec.gpu;
    w.output_width = rec.output_width;
    w.output_height = rec.output_height;
    w.adopting = false;
    w.ready = true;
    w.adoptable = true;
    log.info("adopted worker pid={d} session='{s}' (record v{d}, build {s})", .{ w.pid, w.name, rec.v, rec.build });
}

fn nameInUse(self: *Daemon, name: []const u8, except: *Worker) bool {
    for (self.workers.items) |other| {
        if (other == except or other.dead or other.adopting) continue;
        if (other.matchesName(name)) return true;
    }
    return false;
}

/// Why a handover must not happen now, or null. Workers are what a
/// handover keeps, so they only block it when they could not be adopted;
/// everything else the broker itself holds would be lost.
pub fn handoverBlocker(self: *Daemon, buf: []u8) ?[]const u8 {
    for (self.workers.items) |w| {
        if (w.dead) continue;
        if (w.adopting or !w.ready)
            return std.fmt.bufPrint(buf, "busy: session '{s}' is still starting", .{w.name}) catch "busy";
        if (!w.adoptable)
            return std.fmt.bufPrint(buf, "busy: session '{s}' cannot be handed over (its worker predates adoption)", .{w.name}) catch "busy";
    }
    var jobs: usize = 0;
    for (self.fs_jobs.items) |j| {
        if (j.state == .running or j.state == .paused) jobs += 1;
    }
    const transfers = self.uploads.items.len + self.downloads.items.len;
    if (jobs == 0 and transfers == 0 and self.debug_jobs.items.len == 0 and self.channels.items.len == 0) return null;
    return std.fmt.bufPrint(buf, "busy: {d} running job(s), {d} transfer(s), {d} debugger job(s), {d} open channel(s)", .{
        jobs, transfers, self.debug_jobs.items.len, self.channels.items.len,
    }) catch "busy";
}

const t = std.testing;

test "an adoption record round-trips and tolerates old and new layouts" {
    const rec = WorkerAdopt{
        .wpid = 4242,
        .name = "work",
        .origin_name = "work",
        .origin_id = "0123456789abcdef0123456789abcdef",
        .build = "v1",
        .pid = 4243,
        .wl = "/run/wl",
        .display = true,
    };
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(rec, .{}, &aw.writer);
    const back = try std.json.parseFromSlice(WorkerAdopt, t.allocator, aw.written(), .{ .ignore_unknown_fields = true });
    defer back.deinit();
    try t.expectEqual(@as(i32, 4242), back.value.wpid);
    try t.expectEqualStrings("work", back.value.name);
    try t.expect(back.value.display);
    // A newer worker's extra fields are ignored; an older one's missing
    // fields default.
    const future = try std.json.parseFromSlice(WorkerAdopt, t.allocator,
        \\{"v":9,"wpid":7,"name":"n","origin_id":"x","future":{"a":1}}
    , .{ .ignore_unknown_fields = true });
    defer future.deinit();
    try t.expectEqual(@as(u32, 9), future.value.v);
    try t.expectEqualStrings("", future.value.wl);
}

test "a broker adopts an orphaned worker over a fresh control channel" {
    const a = t.allocator;
    var dir_tmpl = "/tmp/skadoptXXXXXX".*;
    const dir_ptr = c.mkdtemp(&dir_tmpl) orelse return error.SkipZigTest;
    const dir = std.mem.span(dir_ptr);
    var sock_buf: [128]u8 = undefined;
    const sock = try std.fmt.bufPrint(&sock_buf, "{s}/mux.sock", .{dir});
    defer {
        var b2: [160]u8 = undefined;
        const wd = std.fmt.bufPrintZ(&b2, "{s}" ++ DIR_SUFFIX, .{sock}) catch unreachable;
        _ = c.rmdir(wd.ptr);
        _ = c.rmdir(dir_ptr);
    }

    // The worker half, with a live "old broker" channel.
    var old_pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.controlSocketpair(&old_pair, 4096));
    var empty: [0]u8 = .{};
    var worker = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..], .role = .worker, .control_fd = old_pair[1] };
    worker.broker_sock = try a.dupe(u8, sock);
    defer a.free(worker.broker_sock.?);
    defer worker.sessions.deinit(a);
    const origin = "0123456789abcdef0123456789abcdef";
    workerListen(&worker, origin);
    try t.expect(worker.adopt_fd >= 0);
    defer closeListener(&worker);

    // The broker half.
    var broker = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = sock };
    defer {
        for (broker.workers.items) |w| w.deinit();
        broker.workers.deinit(a);
    }

    // The scan finds the listener and offers a channel; the worker still
    // has its old broker (and no session), so it refuses: the offered
    // channel reads EOF and the old one is untouched.
    brokerScan(&broker);
    try t.expectEqual(@as(usize, 1), broker.workers.items.len);
    try t.expect(broker.workers.items[0].adopting);
    workerOnAdopt(&worker);
    var buf: [256]u8 = undefined;
    var passed: c_int = -1;
    try t.expect(daemon_control.controlRecv(broker.workers.items[0].control_fd, &buf, &passed) <= 0);
    try t.expectEqual(old_pair[1], worker.control_fd);

    // The old broker dies: control EOF orphans an adoptable worker
    // instead of stopping it.
    _ = c.close(old_pair[0]);
    daemon_control.workerOnControl(&worker);
    try t.expect(worker.running);
    try t.expectEqual(@as(c_int, -1), worker.control_fd);
}

test "a handover refuses while a worker could not be adopted" {
    const a = t.allocator;
    var empty: [0]u8 = .{};
    var d = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..] };
    defer d.workers.deinit(a);
    var w = Worker{
        .allocator = a,
        .name = @constCast("legacy"),
        .origin_name = @constCast("legacy"),
        .origin_id = "10000000000000000000000000000001".*,
        .pid = 123,
        .control_fd = -1,
        .ready = true,
    };
    try d.workers.append(a, &w);
    var buf: [192]u8 = undefined;
    try t.expect(handoverBlocker(&d, &buf) != null);
    w.adoptable = true;
    try t.expect(handoverBlocker(&d, &buf) == null);
    w.ready = false;
    try t.expect(handoverBlocker(&d, &buf) != null);
}
