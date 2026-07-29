//! Automatic FUSE mounts of remote hosts, so opening a remote file
//! hands the application a PATH instead of a downloaded copy.
//!
//! `sketerm mount <host>:/ <point>` is the existing pure-Zig FUSE
//! client (src/fsmount.zig): ranged reads, write-through, backed by the
//! same mux file service every other remote verb uses. This module is
//! only its lifecycle -- one child per host, spawned on demand, reused
//! by every pane and window in the process, unmounted at exit. That is
//! the gvfs shape, and it is why opening a 3 GB video from a remote
//! pane starts playing instead of copying.
//!
//! Mounts live under `$XDG_RUNTIME_DIR/sketerm/mnt/<pid>/<host>`: one
//! owner per mount point means no stacking when two sketerm processes
//! browse the same host, and no live mount ripped away when one of them
//! exits. Directories left by a process that died without unmounting
//! are swept on the next start.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");

/// How long a freshly spawned mount is given to come up before the
/// caller falls back to downloading. A local daemon answers in
/// milliseconds; an SSH host has to authenticate first.
pub const READY_TIMEOUT_MS: i64 = 20_000;
/// Readiness poll interval.
pub const POLL_MS: c.guint = 150;

pub const State = enum {
    /// Mounted and usable now.
    ready,
    /// Child spawned, mount not visible yet.
    starting,
    /// No FUSE here, or the child refused to start. Callers fall back
    /// to the download path and say so.
    unavailable,
};

const Mount = struct {
    host: []u8,
    point: []u8,
    pid: c.GPid = 0,
    /// The child watch, so teardown can drop it: a watch that fired
    /// after `shutdownAll` freed this struct would run against it.
    watch: c.guint = 0,
    state: State = .starting,
    /// Monotonic ms when the child was spawned, for the ready timeout.
    started_ms: i64 = 0,
    /// Why it is unavailable, for the status line (static text).
    reason: []const u8 = "",
};

var g_allocator: ?std.mem.Allocator = null;
var g_mounts: std.ArrayList(*Mount) = .empty;
var g_swept: bool = false;

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

/// A host string as one path component. Everything a host string can
/// contain is legal in a filename except the separator itself, so only
/// that is rewritten.
pub fn sanitizeHost(buf: []u8, host: []const u8) []const u8 {
    const n = @min(host.len, buf.len);
    for (host[0..n], 0..) |ch, i| buf[i] = if (ch == '/') '_' else ch;
    return buf[0..n];
}

/// `$XDG_RUNTIME_DIR/sketerm/mnt/<pid>`.
fn ownDir(buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/sketerm/mnt/{d}", .{ platform.runtimeDir(), c.getpid() }) catch null;
}

/// Is `path` a mount point? Its device differs from its parent's the
/// moment something is mounted there, and matches again once it is
/// gone -- which is also how a mount that died is detected.
fn isMounted(path: []const u8) bool {
    var pz: [4096:0]u8 = undefined;
    const p = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return false;
    var st: c.struct_stat = undefined;
    if (c.stat(p.ptr, &st) != 0) return false;
    const parent = std.fs.path.dirname(path) orelse return false;
    var qz: [4096:0]u8 = undefined;
    const q = std.fmt.bufPrintZ(&qz, "{s}", .{parent}) catch return false;
    var pst: c.struct_stat = undefined;
    if (c.stat(q.ptr, &pst) != 0) return false;
    return st.st_dev != pst.st_dev;
}

fn mkdirp(path: []const u8) bool {
    var z: [4096:0]u8 = undefined;
    const p = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return false;
    return c.g_mkdir_with_parents(p.ptr, 0o700) == 0;
}

fn unmount(point: []const u8) void {
    var z: [4096:0]u8 = undefined;
    const p = std.fmt.bufPrintZ(&z, "{s}", .{point}) catch return;
    const pid = c.fork();
    if (pid == 0) {
        // Lazy: an application still holding a file must not make the
        // GUI's exit hang on it.
        const argv = [_:null]?[*:0]const u8{ "fusermount3", "-u", "-z", "--", p.ptr, null };
        _ = c.execvp("fusermount3", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    if (pid > 0) {
        var st: c_int = 0;
        _ = c.waitpid(pid, &st, 0);
    }
    _ = c.rmdir(p.ptr);
}

/// Clear mount directories left by processes that are gone. A SIGKILL
/// leaves both the mount and its directory behind; the kernel keeps
/// serving a dead FUSE mount as ENOTCONN forever, so it has to be
/// taken down explicitly rather than reused.
fn sweepOrphans() void {
    var base_buf: [4096]u8 = undefined;
    const base = std.fmt.bufPrint(&base_buf, "{s}/sketerm/mnt", .{platform.runtimeDir()}) catch return;
    var bz: [4096:0]u8 = undefined;
    const bp = std.fmt.bufPrintZ(&bz, "{s}", .{base}) catch return;
    const dir = c.opendir(bp.ptr) orelse return;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (name.len == 0 or name[0] == '.') continue;
        const pid = std.fmt.parseInt(c_int, name, 10) catch continue;
        if (pid == c.getpid()) continue;
        // Signal 0: does that process still exist?
        if (c.kill(pid, 0) == 0) continue;
        var owner_buf: [4096]u8 = undefined;
        const owner = std.fmt.bufPrint(&owner_buf, "{s}/{s}", .{ base, name }) catch continue;
        var oz: [4096:0]u8 = undefined;
        const op = std.fmt.bufPrintZ(&oz, "{s}", .{owner}) catch continue;
        const od = c.opendir(op.ptr) orelse {
            _ = c.rmdir(op.ptr);
            continue;
        };
        while (c.readdir(od)) |sub| {
            const sname = std.mem.span(@as([*:0]const u8, @ptrCast(&sub.*.d_name)));
            if (sname.len == 0 or sname[0] == '.') continue;
            var pt_buf: [4096]u8 = undefined;
            const pt = std.fmt.bufPrint(&pt_buf, "{s}/{s}", .{ owner, sname }) catch continue;
            unmount(pt);
        }
        _ = c.closedir(od);
        _ = c.rmdir(op.ptr);
    }
}

fn find(host: []const u8) ?*Mount {
    for (g_mounts.items) |m| {
        if (std.mem.eql(u8, m.host, host)) return m;
    }
    return null;
}

/// Spawn `sketerm mount <host>:/ <point>`. The child inherits this
/// process's environment, so an isolated test rig keeps its own XDG
/// dirs and ssh overrides.
fn spawn(m: *Mount) bool {
    var exe_buf: [4096:0]u8 = undefined;
    const exe = platform.exePathZ(&exe_buf) orelse {
        m.reason = "own executable path unknown";
        return false;
    };
    var spec_buf: [4200:0]u8 = undefined;
    const spec = std.fmt.bufPrintZ(&spec_buf, "{s}:/", .{m.host}) catch {
        m.reason = "host name too long";
        return false;
    };
    var point_buf: [4096:0]u8 = undefined;
    const point = std.fmt.bufPrintZ(&point_buf, "{s}", .{m.point}) catch {
        m.reason = "mount path too long";
        return false;
    };
    var argv = [_][*c]u8{
        @constCast(@as([*c]const u8, exe.ptr)),
        @constCast(@as([*c]const u8, "mount")),
        @constCast(@as([*c]const u8, spec.ptr)),
        @constCast(@as([*c]const u8, point.ptr)),
        null,
    };
    var pid: c.GPid = 0;
    var gerr: [*c]c.GError = null;
    // DO_NOT_REAP_CHILD so the pid stays valid for teardown; GLib
    // watches it and reaps on child-exit.
    const ok = c.g_spawn_async(
        null,
        &argv,
        null,
        @intCast(c.G_SPAWN_DO_NOT_REAP_CHILD),
        null,
        null,
        &pid,
        &gerr,
    );
    if (ok == 0) {
        if (gerr != null) c.g_error_free(gerr);
        m.reason = "could not start the mount helper";
        return false;
    }
    m.pid = pid;
    m.watch = c.g_child_watch_add(pid, @ptrCast(&onMountExited), @ptrCast(m));
    return true;
}

/// The helper died: fusermount3 missing, the host refused, or a plain
/// unmount. Either way this host has no mount any more.
fn onMountExited(pid: c.GPid, status: c_int, user: ?*anyopaque) callconv(.c) void {
    _ = status;
    c.g_spawn_close_pid(pid);
    const m: *Mount = @ptrCast(@alignCast(user.?));
    m.pid = 0;
    // One-shot: it has fired, so teardown must not remove it again.
    m.watch = 0;
    if (m.state != .ready) m.reason = "the mount helper exited (is fuse3 installed?)";
    m.state = .unavailable;
}

/// Where `host` is mounted, mounting it if necessary.
///
/// Never blocks: a mount that is still coming up answers `.starting`,
/// and the caller either waits with `whenReady` or falls back.
pub fn ensure(allocator: std.mem.Allocator, host: []const u8) State {
    if (comptime !platform.is_linux) return .unavailable;
    g_allocator = allocator;
    if (!g_swept) {
        g_swept = true;
        sweepOrphans();
    }
    if (find(host)) |m| {
        if (m.state == .starting and isMounted(m.point)) m.state = .ready;
        // A helper that died leaves a stale mount the kernel answers
        // with ENOTCONN; clear it so the next open can try again.
        if (m.state == .ready and m.pid == 0) {
            unmount(m.point);
            m.state = .unavailable;
        }
        if (m.state == .starting and nowMs() - m.started_ms > READY_TIMEOUT_MS) {
            m.reason = "the mount did not come up in time";
            m.state = .unavailable;
        }
        return m.state;
    }

    var own_buf: [4096]u8 = undefined;
    const own = ownDir(&own_buf) orelse return .unavailable;
    var name_buf: [512]u8 = undefined;
    const name = sanitizeHost(&name_buf, host);
    var point_buf: [4096]u8 = undefined;
    const point = std.fmt.bufPrint(&point_buf, "{s}/{s}", .{ own, name }) catch return .unavailable;
    if (!mkdirp(point)) return .unavailable;

    const m = allocator.create(Mount) catch return .unavailable;
    m.* = .{
        .host = allocator.dupe(u8, host) catch {
            allocator.destroy(m);
            return .unavailable;
        },
        .point = allocator.dupe(u8, point) catch {
            allocator.free(m.host);
            allocator.destroy(m);
            return .unavailable;
        },
        .started_ms = nowMs(),
    };
    g_mounts.append(allocator, m) catch {
        allocator.free(m.host);
        allocator.free(m.point);
        allocator.destroy(m);
        return .unavailable;
    };
    if (!spawn(m)) {
        m.state = .unavailable;
        return .unavailable;
    }
    // A local daemon can be up before the first poll tick.
    if (isMounted(m.point)) m.state = .ready;
    return m.state;
}

/// Why `host` has no mount, for a status line. "" when it has one.
pub fn reasonFor(host: []const u8) []const u8 {
    const m = find(host) orelse return "FUSE mounts are Linux-only";
    return if (m.reason.len > 0) m.reason else "";
}

/// The local path a remote path is reachable at, or null when `host`
/// is not mounted. `remote` is absolute on the host.
pub fn localPath(buf: []u8, host: []const u8, remote: []const u8) ?[]const u8 {
    const m = find(host) orelse return null;
    if (m.state != .ready) return null;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ m.point, remote }) catch null;
}

/// One deferred open, waiting for its mount to finish coming up.
const Waiter = struct {
    allocator: std.mem.Allocator,
    host: []u8,
    ctx: ?*anyopaque,
    on_ready: *const fn (ctx: ?*anyopaque, mounted: bool) void,
    deadline_ms: i64,

    fn destroy(self: *Waiter) void {
        self.allocator.free(self.host);
        self.allocator.destroy(self);
    }
};

fn onWaiterTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const w: *Waiter = @ptrCast(@alignCast(user.?));
    const state = ensure(w.allocator, w.host);
    if (state == .starting and nowMs() < w.deadline_ms) return 1;
    const mounted = state == .ready;
    const cb = w.on_ready;
    const ctx = w.ctx;
    w.destroy();
    cb(ctx, mounted);
    return 0;
}

/// Call `on_ready` once the host is mounted (or once it is clear it
/// will not be). Returns immediately; the callback may fire from this
/// call when the mount is already up.
pub fn whenReady(
    allocator: std.mem.Allocator,
    host: []const u8,
    ctx: ?*anyopaque,
    on_ready: *const fn (ctx: ?*anyopaque, mounted: bool) void,
) void {
    const state = ensure(allocator, host);
    if (state != .starting) return on_ready(ctx, state == .ready);
    const w = allocator.create(Waiter) catch return on_ready(ctx, false);
    w.* = .{
        .allocator = allocator,
        .host = allocator.dupe(u8, host) catch {
            allocator.destroy(w);
            return on_ready(ctx, false);
        },
        .ctx = ctx,
        .on_ready = on_ready,
        .deadline_ms = nowMs() + READY_TIMEOUT_MS,
    };
    _ = c.g_timeout_add(POLL_MS, @ptrCast(&onWaiterTick), @ptrCast(w));
}

/// Unmount everything this process mounted. Called from the
/// application's shutdown handler; a crash instead leaves the sweep
/// above to clean up on the next start.
pub fn shutdownAll() void {
    const allocator = g_allocator orelse return;
    for (g_mounts.items) |m| {
        if (m.watch != 0) {
            _ = c.g_source_remove(m.watch);
            m.watch = 0;
        }
        if (m.pid != 0) {
            _ = c.kill(m.pid, c.SIGTERM);
            c.g_spawn_close_pid(m.pid);
            m.pid = 0;
        }
        unmount(m.point);
        allocator.free(m.host);
        allocator.free(m.point);
        allocator.destroy(m);
    }
    g_mounts.deinit(allocator);
    g_mounts = .empty;
    var own_buf: [4096]u8 = undefined;
    if (ownDir(&own_buf)) |own| {
        var z: [4096:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&z, "{s}", .{own})) |p| {
            _ = c.rmdir(p.ptr);
        } else |_| {}
    }
}

test "sanitizeHost keeps a host usable as one path component" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("dalaran", sanitizeHost(&buf, "dalaran"));
    try t.expectEqualStrings("user@box", sanitizeHost(&buf, "user@box"));
    try t.expectEqualStrings("udp:box", sanitizeHost(&buf, "udp:box"));
    // A separator would silently create a nested directory.
    try t.expectEqualStrings("a_b", sanitizeHost(&buf, "a/b"));
}
