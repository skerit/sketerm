//! Bounded, best-effort helper stderr capture. Datagram stderr never blocks
//! a helper and closing its reader cannot deliver SIGPIPE to a lingering
//! engine. No files, threads, or extra processes; owners drain in their loop.
//! Only complete, sanitized lines enter the retained diagnostic.
const std = @import("std");
const c = @import("../c.zig").c;

pub const LIMIT = 8192;
pub const Stage = enum { launching_helper, connecting, creating_browser, navigating };
pub const Report = struct {
    id: []const u8 = "",
    stage: Stage = .launching_helper,
    exit_code: ?u8 = null,
    signal: ?u8 = null,
    stderr: []const u8 = "",
    truncated: bool = false,
    /// Nonblocking stderr can drop kernel datagrams under extreme log volume.
    /// Never interpret an empty excerpt as proof that nothing was written.
    best_effort: bool = true,
    stderr_available: bool = false,
};
pub const Capture = struct {
    id: [32]u8 = @splat(0),
    reader: c_int = -1,
    writer: c_int = -1,
    text: [LIMIT]u8 = undefined,
    len: usize = 0,
    line: [2048]u8 = undefined,
    line_len: usize = 0,
    line_overflow: bool = false,
    truncated: bool = false,
    stage: Stage = .launching_helper,
    exit_code: ?u8 = null,
    signal: ?u8 = null,
    stderr_available: bool = false,

    pub fn init() !Capture {
        var fds: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_DGRAM, 0, &fds) != 0) return error.CaptureUnavailable;
        for (fds) |fd| {
            if (c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC) < 0 or c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK) < 0) {
                _ = c.close(fds[0]);
                _ = c.close(fds[1]);
                return error.CaptureUnavailable;
            }
        }
        var out = record() catch {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
            return error.CaptureUnavailable;
        };
        out.reader = fds[0];
        out.writer = fds[1];
        out.stderr_available = true;
        return out;
    }

    pub fn record() !Capture {
        var out: Capture = .{};
        var nonce: [16]u8 = undefined;
        if (c.getentropy(&nonce, nonce.len) != 0) {
            out.deinit();
            return error.CaptureUnavailable;
        }
        out.id = std.fmt.bytesToHex(nonce, .lower);
        return out;
    }

    pub fn report(self: *Capture) Report {
        self.drain();
        return .{ .id = if (self.id[0] == 0) "" else &self.id, .stage = self.stage, .exit_code = self.exit_code, .signal = self.signal, .stderr = self.excerpt(), .truncated = self.truncated, .stderr_available = self.stderr_available };
    }

    /// A remote capture uses the same bounded representation, no remote fds.
    pub fn adoptReport(self: *Capture, r: Report) void {
        self.deinit();
        self.* = .{};
        if (r.id.len == self.id.len) @memcpy(&self.id, r.id);
        self.stage = r.stage;
        self.exit_code = r.exit_code;
        self.signal = r.signal;
        self.len = @min(r.stderr.len, LIMIT);
        @memcpy(self.text[0..self.len], r.stderr[0..self.len]);
        self.truncated = r.truncated or r.stderr.len > LIMIT;
        self.stderr_available = r.stderr_available;
    }

    /// Child-only, between fork and exec. No allocation or locks.
    pub fn child(self: *const Capture) void {
        _ = c.close(self.reader);
        if (self.writer != 2) {
            _ = c.dup2(self.writer, 2);
            _ = c.close(self.writer);
        } else _ = c.fcntl(2, c.F_SETFD, @as(c_int, 0));
    }

    /// Shared fork/exec failure evidence; async-child-safe stack formatting.
    pub fn execFailed() void {
        const err = std.posix.errno(@as(c_int, -1));
        var buf: [128]u8 = undefined;
        const note = std.fmt.bufPrint(&buf, "browser helper execv failed: errno={d} ({s})\n", .{ @intFromEnum(err), @tagName(err) }) catch "browser helper execv failed\n";
        _ = c.write(2, note.ptr, note.len);
    }

    pub fn parent(self: *Capture) void {
        if (self.writer >= 0) _ = c.close(self.writer);
        self.writer = -1;
        self.stage = .connecting;
    }

    pub fn deinit(self: *Capture) void {
        if (self.reader >= 0) _ = c.close(self.reader);
        if (self.writer >= 0) _ = c.close(self.writer);
        self.reader = -1;
        self.writer = -1;
    }

    /// Bound work as well as storage: logging cannot monopolize a daemon tick.
    pub fn drain(self: *Capture) void {
        if (self.reader < 0) return;
        var buf: [4096]u8 = undefined;
        for (0..32) |_| {
            const n = c.recv(self.reader, &buf, buf.len, c.MSG_DONTWAIT | c.MSG_TRUNC);
            if (n <= 0) break;
            if (n >= buf.len) {
                self.truncated = true;
                self.line_len = 0;
                self.line_overflow = true;
                // Never inspect a prefix whose unseen suffix could contain a
                // secret key or newline. Drop through the next line boundary.
                continue;
            }
            self.feed(buf[0..@min(@as(usize, @intCast(n)), buf.len)]);
        }
    }

    pub fn exited(self: *Capture, status: c_int) void {
        self.drain();
        if (c.WIFEXITED(status)) self.exit_code = @intCast(c.WEXITSTATUS(status));
        if (c.WIFSIGNALED(status)) self.signal = @intCast(c.WTERMSIG(status));
        // A final unterminated line is safe to sanitize only once the writer
        // exited; don't expose a prefix while a secret is still arriving.
        self.finishLine();
        if (std.mem.indexOf(u8, self.excerpt(), "browser helper execv failed:") != null) self.stage = .launching_helper;
    }

    pub fn excerpt(self: *const Capture) []const u8 {
        return self.text[0..self.len];
    }

    fn feed(self: *Capture, bytes: []const u8) void {
        for (bytes) |b| {
            if (b == '\n') {
                self.finishLine();
            } else if (self.line_len < self.line.len) {
                self.line[self.line_len] = if (b >= 32 and b < 127) b else ' ';
                self.line_len += 1;
            } else self.line_overflow = true;
        }
    }

    fn finishLine(self: *Capture) void {
        const line = self.line[0..self.line_len];
        const safe = if (self.line_overflow) "[oversized diagnostic line omitted]" else if (sensitive(line)) "[sensitive diagnostic line redacted]" else line;
        self.truncated = self.truncated or self.line_overflow;
        if (safe.len != 0) {
            const need = safe.len + 1;
            if (self.len + need > LIMIT) {
                // Discard whole oldest lines, never preserve a secret's tail.
                const min_drop = self.len + need - LIMIT;
                const end = std.mem.indexOfScalarPos(u8, self.excerpt(), min_drop, '\n');
                const drop = if (end) |i| i + 1 else self.len;
                std.mem.copyForwards(u8, self.text[0 .. self.len - drop], self.text[drop..self.len]);
                self.len -= drop;
                self.truncated = true;
            }
            @memcpy(self.text[self.len..][0..safe.len], safe);
            self.len += safe.len;
            self.text[self.len] = '\n';
            self.len += 1;
        }
        self.line_len = 0;
        self.line_overflow = false;
    }
};

/// Conservative by design: keep error evidence, not arbitrary credentials.
/// Whole-line suppression also handles quoted/space-separated secret values.
fn sensitive(line: []const u8) bool {
    const keys = [_][]const u8{ "password", "passwd", "token", "secret", "authorization", "cookie", "credential", "bearer", "private key" };
    for (keys) |key| {
        if (std.ascii.indexOfIgnoreCase(line, key) != null) return true;
    }
    // URLs can embed userinfo, query credentials, or fragment tokens.
    if (std.mem.indexOf(u8, line, "://") != null and std.mem.indexOfAny(u8, line, "@?#") != null) return true;
    return false;
}

pub fn redact(text: []const u8) []const u8 {
    return if (sensitive(text)) "[sensitive text redacted]" else text;
}

test "helper diagnostics redact split secrets and retain fatal evidence with bounds" {
    var cap: Capture = .{};
    cap.feed("Authoriz");
    cap.feed("ation: Bearer never-store-me\nFATAL: shutdown: Operation not permitted (1)\n");
    try std.testing.expect(std.mem.indexOf(u8, cap.excerpt(), "never-store-me") == null);
    try std.testing.expect(std.mem.indexOf(u8, cap.excerpt(), "Operation not permitted") != null);
    for (0..1000) |_| cap.feed("bounded log line\n");
    try std.testing.expect(cap.len <= LIMIT);
    try std.testing.expect(cap.truncated);
}

test "helper stderr reader teardown cannot kill a lingering helper" {
    var cap = try Capture.init();
    defer cap.deinit();
    const pid = c.fork();
    try std.testing.expect(pid >= 0);
    if (pid == 0) {
        cap.child();
        // Prove default SIGPIPE behaviour, not an inherited ignored signal.
        _ = c.signal(c.SIGPIPE, c.SIG_DFL);
        _ = c.usleep(50_000);
        _ = c.write(2, "after reader close\n", 19);
        c._exit(23);
    }
    cap.deinit();
    var status: c_int = 0;
    try std.testing.expectEqual(pid, c.waitpid(pid, &status, 0));
    try std.testing.expect(c.WIFEXITED(status));
    try std.testing.expectEqual(@as(c_int, 23), c.WEXITSTATUS(status));
}
