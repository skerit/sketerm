//! Transport half of the in-tree D-Bus client: socket connect, SASL
//! EXTERNAL auth, the `Hello` message, and deadline-aware poll/write
//! primitives.
//!
//! WHY IT IS NOT IN `dbus.zig`: that module's whole property is "pure
//! std + slices, no libdbus, no GLib" -- it marshals bytes and can be
//! tested with no libc at all. A transport needs libc sockets, so
//! folding it in would quietly cost the codec that property. Keeping
//! them as siblings means the codec stays byte-only and this module is
//! the one place that knows about file descriptors.
//!
//! WHY IT LIVES UNDER `src/mux/`: it must be importable from BOTH
//! dependency sets. `mux/a11yhub.zig` is daemon-side (the lean
//! libc-only core set) and `a11y/webproj.zig` + `a11y/detect.zig` are
//! GUI-side; libc + `util/platform.zig` + `util/clock.zig` is all this
//! needs, so the daemon's ELF dependency invariant is unaffected.
//!
//! What is deliberately NOT here: the request/reply loop. `webproj`
//! must keep ANSWERING incoming method calls while it waits for its
//! own reply (it is a server too) while the other two simply discard
//! unrelated traffic, so `call` stays with each consumer.

const std = @import("std");
const c = @import("../c.zig").c;
const dbus = @import("dbus.zig");
const platform = @import("../util/platform.zig");
const nowMs = @import("../util/clock.zig").nowMs;

/// The bus handshake every client sends first after BEGIN. One
/// declaring home for the message; the reply (our unique name) is
/// read by whoever cares.
pub const hello_call = dbus.Message{
    .mtype = .method_call,
    .path = "/org/freedesktop/DBus",
    .interface = "org.freedesktop.DBus",
    .member = "Hello",
    .destination = "org.freedesktop.DBus",
};

/// Milliseconds still left before `deadline`, clamped to what `poll`
/// can take. Zero means "expired" and every caller turns it into a
/// timeout rather than an infinite wait -- a negative `poll` timeout
/// blocks forever, which is exactly what this clamp prevents.
pub fn pollMs(deadline: i64, now: i64) c_int {
    return @intCast(@max(0, @min(deadline - now, std.math.maxInt(c_int))));
}

/// Block until `fd` is ready for `events` or the deadline passes.
/// EINTR retries; `poll` reporting nothing is `error.Timeout`; any
/// other outcome (POLLERR/POLLHUP or a hard failure) is
/// `error.Closed`.
pub fn waitFd(fd: c_int, events: c_short, deadline: i64) !void {
    while (true) {
        const left = pollMs(deadline, nowMs());
        if (left == 0) return error.Timeout;
        var pfd = c.struct_pollfd{ .fd = fd, .events = events, .revents = 0 };
        const rc = c.poll(&pfd, 1, left);
        if (rc > 0 and pfd.revents & events != 0) return;
        if (rc < 0 and std.posix.errno(rc) == .INTR) continue;
        if (rc == 0) return error.Timeout;
        return error.Closed;
    }
}

/// Write every byte, waiting on POLLOUT whenever the socket is full.
pub fn writeAll(fd: c_int, bytes: []const u8, deadline: i64) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        const e = std.posix.errno(n);
        if (e == .INTR) continue;
        if (e == .AGAIN) {
            try waitFd(fd, c.POLLOUT, deadline);
            continue;
        }
        return error.Write;
    }
}

/// Connect a non-blocking cloexec stream socket to a bus path. A
/// leading '@' selects the Linux abstract namespace, matching what
/// `parseUnixPath` emits.
pub fn busConnect(path: []const u8) !c_int {
    const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.Socket;
    errdefer _ = c.close(fd);
    var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    const dst = std.mem.asBytes(&addr.sun_path);
    if (path.len == 0 or path.len >= dst.len) return error.BadPath;
    if (path[0] == '@') {
        dst[0] = 0; // abstract namespace
        @memcpy(dst[1..path.len], path[1..]);
    } else {
        @memcpy(dst[0..path.len], path);
    }
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return error.Connect;
    const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (fl >= 0) _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
    return fd;
}

/// "unix:path=/x,guid=..." or "unix:abstract=x" -> a connectable path
/// ('@' marks abstract, matching `busConnect`), copied into `buf`.
/// A D-Bus address is a ';'-separated list of alternatives, so every
/// segment is examined, not just the first.
pub fn parseUnixPath(addr: []const u8, buf: []u8) ?[]const u8 {
    var seg = std.mem.splitScalar(u8, addr, ';');
    while (seg.next()) |part| {
        if (!std.mem.startsWith(u8, part, "unix:")) continue;
        var kv = std.mem.splitScalar(u8, part["unix:".len..], ',');
        while (kv.next()) |pair| {
            if (std.mem.startsWith(u8, pair, "path=")) {
                const p = pair["path=".len..];
                if (p.len > buf.len) return null;
                @memcpy(buf[0..p.len], p);
                return buf[0..p.len];
            }
            if (std.mem.startsWith(u8, pair, "abstract=")) {
                const p = pair["abstract=".len..];
                if (p.len + 1 > buf.len) return null;
                buf[0] = '@';
                @memcpy(buf[1 .. 1 + p.len], p);
                return buf[0 .. 1 + p.len];
            }
        }
    }
    return null;
}

/// The SASL EXTERNAL greeting line, CRLF-terminated. The uid goes out
/// as DECIMAL ascii whose BYTES are then hex-encoded (1000 -> "1000"
/// -> "31303030"); hex-encoding the number itself is the classic way
/// to get rejected by every bus.
pub fn saslLine(buf: []u8, uid: u32) ![]const u8 {
    const head = "AUTH EXTERNAL ";
    if (buf.len < head.len) return error.Auth;
    @memcpy(buf[0..head.len], head);
    var n: usize = head.len;
    var idbuf: [32]u8 = undefined;
    const dec = try std.fmt.bufPrint(&idbuf, "{d}", .{uid});
    for (dec) |ch| {
        if (n + 2 > buf.len) return error.Auth;
        _ = std.fmt.bufPrint(buf[n..], "{x:0>2}", .{ch}) catch return error.Auth;
        n += 2;
    }
    if (n + 2 > buf.len) return error.Auth;
    @memcpy(buf[n..][0..2], "\r\n");
    n += 2;
    return buf[0..n];
}

/// The pre-`Hello` half of the handshake: the mandatory leading NUL,
/// SASL EXTERNAL, the OK check, and BEGIN. `Hello` itself is left to
/// the caller, whose reply loop this module deliberately does not own.
pub fn authExternal(fd: c_int, deadline: i64) !void {
    try writeAll(fd, &.{0}, deadline);
    var line: [128]u8 = undefined;
    try writeAll(fd, try saslLine(&line, c.getuid()), deadline);
    var buf: [256]u8 = undefined;
    try waitFd(fd, c.POLLIN, deadline);
    const got = c.read(fd, &buf, buf.len);
    if (got <= 0) return error.Auth;
    if (!std.mem.startsWith(u8, buf[0..@intCast(got)], "OK")) return error.AuthRejected;
    try writeAll(fd, "BEGIN\r\n", deadline);
}

// -- tests -----------------------------------------------------------

const t = std.testing;

test "parseUnixPath extracts path and abstract forms" {
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("/run/x", parseUnixPath("unix:path=/run/x,guid=ab", &buf).?);
    const abs = parseUnixPath("unix:abstract=/tmp/dbus-XYZ,guid=1", &buf).?;
    try t.expect(abs[0] == '@');
    try t.expectEqualStrings("/tmp/dbus-XYZ", abs[1..]);
    // A non-unix transport has no socket path to hand back.
    try t.expect(parseUnixPath("tcp:host=x", &buf) == null);
    try t.expect(parseUnixPath("", &buf) == null);
    try t.expect(parseUnixPath("unix:guid=nopath", &buf) == null);
    // An address is a ';'-separated list of alternatives: the unix
    // one is taken wherever it sits.
    try t.expectEqualStrings("/run/y", parseUnixPath("tcp:host=x;unix:path=/run/y", &buf).?);
    // A path that does not fit the caller's buffer is refused rather
    // than truncated into a connect against the wrong socket.
    var tiny: [4]u8 = undefined;
    try t.expect(parseUnixPath("unix:path=/run/toolong", &tiny) == null);
    try t.expect(parseUnixPath("unix:abstract=abcd", &tiny) == null);
}

test "SASL EXTERNAL hex-encodes the decimal uid" {
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("AUTH EXTERNAL 31303030\r\n", try saslLine(&buf, 1000));
    // uid 0 is one digit, not an empty string.
    try t.expectEqualStrings("AUTH EXTERNAL 30\r\n", try saslLine(&buf, 0));
    // Two lowercase zero-padded hex digits per ascii byte.
    try t.expectEqualStrings("AUTH EXTERNAL 3939393939\r\n", try saslLine(&buf, 99999));
    // Too small a buffer fails instead of writing a partial greeting.
    var tiny: [16]u8 = undefined;
    try t.expectError(error.Auth, saslLine(&tiny, 1000));
}

test "pollMs clamps the remaining budget and never blocks forever" {
    try t.expectEqual(@as(c_int, 500), pollMs(1_500, 1_000));
    // Expired and overshot both read as zero, which callers turn into
    // error.Timeout -- never a negative timeout, which poll takes as
    // "wait indefinitely".
    try t.expectEqual(@as(c_int, 0), pollMs(1_000, 1_000));
    try t.expectEqual(@as(c_int, 0), pollMs(1_000, 9_999));
    // A deadline further out than poll's int timeout is clamped, so
    // the wait is re-armed rather than overflowing.
    try t.expectEqual(@as(c_int, std.math.maxInt(c_int)), pollMs(std.math.maxInt(i64), 0));
}
