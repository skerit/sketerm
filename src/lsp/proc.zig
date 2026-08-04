//! Spawning a language server as a child process with non-blocking
//! stdio pipes. libc only (fork/exec/pipe/fcntl) — no GLib, no
//! std.process.Child (gone in Zig 0.16), so this compiles into the
//! GTK-free test root as readily as into the GUI.
//!
//! Both pipe ends are opened CLOEXEC and the child re-dup2s the ones it
//! needs, so an LSP server never inherits sketerm's sockets (a leaked
//! mux socket fd in a long-lived clangd would keep a daemon connection
//! alive forever).
//!
//! The child is put in its OWN process group: language servers spawn
//! build tools, and killing the group is the only way to be sure a
//! `zls` that forked a `zig build` leaves nothing behind.

const std = @import("std");
const c = @import("../c.zig").c;

pub const Error = error{
    PipeFailed,
    ForkFailed,
    OutOfMemory,
};

pub const Child = struct {
    pid: c.pid_t = -1,
    /// Server's stdin (we write requests here). Non-blocking.
    stdin: c_int = -1,
    /// Server's stdout (we read responses here). Non-blocking.
    stdout: c_int = -1,
    /// Server's stderr (human-readable logging). Non-blocking.
    stderr: c_int = -1,

    pub fn alive(self: *const Child) bool {
        return self.pid > 0;
    }

    /// Close our ends of the pipes. Safe to call twice.
    pub fn closePipes(self: *Child) void {
        for ([_]*c_int{ &self.stdin, &self.stdout, &self.stderr }) |fd| {
            if (fd.* >= 0) _ = c.close(fd.*);
            fd.* = -1;
        }
    }

    /// SIGTERM the process group. `kill` (SIGKILL) is the follow-up a
    /// caller makes after giving the server a moment to exit.
    pub fn terminate(self: *Child) void {
        if (self.pid <= 0) return;
        _ = c.kill(-self.pid, c.SIGTERM);
    }

    pub fn killHard(self: *Child) void {
        if (self.pid <= 0) return;
        _ = c.kill(-self.pid, c.SIGKILL);
    }

    /// Non-blocking reap. Returns true once the child is gone.
    pub fn reap(self: *Child) bool {
        if (self.pid <= 0) return true;
        var status: c_int = 0;
        const r = c.waitpid(self.pid, &status, c.WNOHANG);
        if (r == self.pid) {
            self.pid = -1;
            return true;
        }
        // ECHILD: somebody else reaped it (or it never existed).
        if (r < 0) {
            self.pid = -1;
            return true;
        }
        return false;
    }
};

fn setNonBlocking(fd: c_int) void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0) return;
    _ = c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);
}

fn setCloexec(fd: c_int) void {
    _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
}

/// Split a whitespace-separated argument string into an argv tail.
/// Quoting is deliberately NOT supported: a server argument needing
/// shell quoting is a sign the user wants a wrapper script, and a
/// half-implemented quoting dialect is worse than none.
pub fn splitArgs(alloc: std.mem.Allocator, args: []const u8, out: *std.ArrayList([]const u8)) !void {
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |a| try out.append(alloc, a);
}

/// Fork+exec `command` with `args`, `cwd` as its working directory.
/// The parent gets non-blocking pipe ends.
pub fn spawn(
    alloc: std.mem.Allocator,
    command: []const u8,
    args: []const []const u8,
    cwd: []const u8,
) Error!Child {
    var in_fds: [2]c_int = .{ -1, -1 };
    var out_fds: [2]c_int = .{ -1, -1 };
    var err_fds: [2]c_int = .{ -1, -1 };
    errdefer {
        for ([_][2]c_int{ in_fds, out_fds, err_fds }) |pair| {
            if (pair[0] >= 0) _ = c.close(pair[0]);
            if (pair[1] >= 0) _ = c.close(pair[1]);
        }
    }
    if (c.pipe(&in_fds) != 0) return Error.PipeFailed;
    if (c.pipe(&out_fds) != 0) return Error.PipeFailed;
    if (c.pipe(&err_fds) != 0) return Error.PipeFailed;
    for ([_]c_int{ in_fds[0], in_fds[1], out_fds[0], out_fds[1], err_fds[0], err_fds[1] }) |fd| setCloexec(fd);

    // argv/cwd must be NUL-terminated BEFORE the fork: allocating
    // between fork and exec is undefined in a multi-threaded process.
    var argv_store: std.ArrayList([:0]u8) = .empty;
    defer {
        for (argv_store.items) |s| alloc.free(s);
        argv_store.deinit(alloc);
    }
    var argv: std.ArrayList(?[*:0]u8) = .empty;
    defer argv.deinit(alloc);
    const cmd_z = alloc.dupeZ(u8, command) catch return Error.OutOfMemory;
    argv_store.append(alloc, cmd_z) catch return Error.OutOfMemory;
    argv.append(alloc, cmd_z.ptr) catch return Error.OutOfMemory;
    for (args) |a| {
        const z = alloc.dupeZ(u8, a) catch return Error.OutOfMemory;
        argv_store.append(alloc, z) catch return Error.OutOfMemory;
        argv.append(alloc, z.ptr) catch return Error.OutOfMemory;
    }
    argv.append(alloc, null) catch return Error.OutOfMemory;
    const cwd_z = alloc.dupeZ(u8, cwd) catch return Error.OutOfMemory;
    defer alloc.free(cwd_z);

    const pid = c.fork();
    if (pid < 0) return Error.ForkFailed;
    if (pid == 0) {
        // Child. Nothing here may allocate or touch libc state that a
        // parent thread could hold a lock on.
        _ = c.setpgid(0, 0);
        _ = c.chdir(cwd_z.ptr);
        _ = c.dup2(in_fds[0], 0);
        _ = c.dup2(out_fds[1], 1);
        _ = c.dup2(err_fds[1], 2);
        // The dup2 targets are the only fds the server may keep; every
        // original (CLOEXEC) end goes away at exec.
        _ = c.execvp(cmd_z.ptr, @ptrCast(argv.items.ptr));
        // exec failed: the parent sees stdout close immediately, which
        // is exactly the "server not installed" degradation path.
        c._exit(127);
    }

    _ = c.close(in_fds[0]);
    _ = c.close(out_fds[1]);
    _ = c.close(err_fds[1]);
    setNonBlocking(in_fds[1]);
    setNonBlocking(out_fds[0]);
    setNonBlocking(err_fds[0]);
    return .{
        .pid = pid,
        .stdin = in_fds[1],
        .stdout = out_fds[0],
        .stderr = err_fds[0],
    };
}

/// Full path `command` resolves to, or null. Caller frees.
pub fn resolveOnPath(alloc: std.mem.Allocator, command: []const u8) ?[]u8 {
    if (command.len == 0) return null;
    if (std.mem.indexOfScalar(u8, command, '/') != null) {
        const z = alloc.dupeZ(u8, command) catch return null;
        defer alloc.free(z);
        if (c.access(z.ptr, c.X_OK) != 0) return null;
        return alloc.dupe(u8, command) catch null;
    }
    const path = @import("../util/profile.zig").getenv("PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |dir| {
        var buf: [4096]u8 = undefined;
        const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, command }) catch continue;
        if (c.access(full.ptr, c.X_OK) == 0) return alloc.dupe(u8, full) catch null;
    }
    return null;
}

/// Whether `command` resolves on PATH (or is an existing absolute
/// path). Used to skip a server SILENTLY when it is not installed —
/// the one place we can tell "not configured" from "not present".
pub fn onPath(alloc: std.mem.Allocator, command: []const u8) bool {
    if (command.len == 0) return false;
    if (std.mem.indexOfScalar(u8, command, '/') != null) {
        const z = alloc.dupeZ(u8, command) catch return false;
        defer alloc.free(z);
        return c.access(z.ptr, c.X_OK) == 0;
    }
    const path = @import("../util/profile.zig").getenv("PATH") orelse return false;
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |dir| {
        var buf: [4096]u8 = undefined;
        const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, command }) catch continue;
        if (c.access(full.ptr, c.X_OK) == 0) return true;
    }
    return false;
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

test "proc: splitArgs tokenizes on whitespace" {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(testing.allocator);
    try splitArgs(testing.allocator, "  --background-index\t--log=error ", &list);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("--background-index", list.items[0]);
    try testing.expectEqualStrings("--log=error", list.items[1]);
}

test "proc: onPath finds a standard binary and rejects nonsense" {
    try testing.expect(onPath(testing.allocator, "sh"));
    try testing.expect(!onPath(testing.allocator, "sketerm-no-such-binary-xyz"));
    try testing.expect(!onPath(testing.allocator, ""));
    try testing.expect(!onPath(testing.allocator, "/nonexistent/path/binary"));
}

test "proc: spawn round-trips bytes through a child's stdio" {
    var child = try spawn(testing.allocator, "cat", &.{}, "/");
    defer {
        child.killHard();
        child.closePipes();
        _ = child.reap();
    }
    try testing.expect(child.alive());
    const msg = "hello lsp\n";
    try testing.expectEqual(@as(isize, msg.len), c.write(child.stdin, msg.ptr, msg.len));
    // Non-blocking: poll until the echo lands.
    var buf: [64]u8 = undefined;
    var got: usize = 0;
    var spins: usize = 0;
    while (got < msg.len and spins < 2000) : (spins += 1) {
        const n = c.read(child.stdout, buf[got..].ptr, buf.len - got);
        if (n > 0) got += @intCast(n) else _ = c.usleep(1000);
    }
    try testing.expectEqualStrings(msg, buf[0..got]);
}

test "proc: spawning a missing binary yields a child that dies immediately" {
    var child = try spawn(testing.allocator, "sketerm-no-such-binary-xyz", &.{}, "/");
    defer {
        child.closePipes();
        _ = child.reap();
    }
    // The fork succeeds; the exec does not, and the parent learns about
    // it as EOF on stdout — the degradation path the UI relies on.
    var buf: [16]u8 = undefined;
    var spins: usize = 0;
    var eof = false;
    while (spins < 2000) : (spins += 1) {
        const n = c.read(child.stdout, &buf, buf.len);
        if (n == 0) {
            eof = true;
            break;
        }
        _ = c.usleep(1000);
    }
    try testing.expect(eof);
}
