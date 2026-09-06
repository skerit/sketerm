//! Shared smoke stage: client input outrunning a child that is not
//! reading its PTY.
//!
//! The slave's input queue holds a few KiB and the kernel's flip buffers
//! about 64 KiB more; everything a client sends past that while the
//! child is busy must be held by the daemon and delivered IN ORDER once
//! the child reads again. The regression this guards: the daemon-side
//! `Pty.queueBytes` used to spin for about a second on a full queue and
//! then silently drop the rest of the frame, so a large paste or a
//! `sketerm mux send` into a slow child was truncated with no message.
//!
//! Oracle: the child sleeps (so nothing is reading), then runs `md5sum`
//! over its tty until EOF. We send 512 KiB of lines followed by ^D and
//! compare the hash it prints against the one computed here — a missing,
//! reordered or duplicated byte changes the digest.
//!
//! Run by BOTH smoke-mux (monolith) and smoke-broker (the worker owns
//! the PTY there; same poll loop, different process).

const std = @import("std");
const c = @import("c.zig").c;
const client_mod = @import("mux/client.zig");
const wire = @import("mux/wire.zig");
const snapshot = @import("mux/snapshot.zig");
const Screen = @import("grid/screen.zig").Screen;
const Pool = @import("grid/style_pool.zig").Pool;

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("smoke input-backlog stage: FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

/// Total bytes sent while the child sleeps. Well past the kernel's
/// buffering (about 68 KiB) and well under `WRITE_QUEUE_CAP` (1 MiB).
pub const PAYLOAD_BYTES: usize = 512 * 1024;
const LINE_LEN: usize = 64;
/// One `.input` frame per chunk; several frames so the daemon's
/// per-frame path is exercised with a non-empty queue already pending.
const FRAME_BYTES: usize = 128 * 1024;

const Mirror = struct {
    allocator: std.mem.Allocator,
    pool: *Pool,
    screen: ?*Screen = null,

    fn applySnapshot(self: *Mirror, payload: []const u8) !void {
        if (payload.len < 9) return error.Truncated;
        if (self.screen) |s| s.deinit();
        self.screen = null;
        self.pool.deinit();
        self.pool.* = try Pool.init(self.allocator);
        self.screen = try snapshot.restore(self.allocator, self.pool, (try snapshot.peelEnvelope(payload)).body);
    }

    fn applyEvents(self: *Mirror, payload: []const u8) !void {
        const screen = self.screen orelse return error.NoScreen;
        if (payload.len < 12) return error.Truncated;
        var r = wire.Reader.init(payload[12..]);
        while (!r.atEnd()) {
            var ev = try r.getEvent(self.allocator);
            screen.apply(ev);
            ev.deinit(self.allocator);
        }
    }

    fn screenText(self: *Mirror) ![]u8 {
        return (self.screen orelse return error.NoScreen).extractScreen(self.allocator);
    }
};

/// Deterministic printable payload: 64-byte lines (canonical mode caps a
/// single line at 4095 bytes; complete lines then throttle the master
/// write, which is exactly the backpressure under test). No control
/// bytes, so ISIG/IXON cannot reinterpret anything.
pub fn fillPayload(buf: []u8) void {
    for (buf, 0..) |*b, i| {
        if (i % LINE_LEN == LINE_LEN - 1) {
            b.* = '\n';
        } else {
            const line = i / LINE_LEN;
            b.* = 'a' + @as(u8, @intCast((i * 7 + line) % 26));
        }
    }
}

fn waitForText(allocator: std.mem.Allocator, conn: *client_mod.Conn, mirror: *Mirror, needle: []const u8, timeout_ms: i64) bool {
    const deadline = @import("util/clock.zig").nowMs() + timeout_ms;
    while (@import("util/clock.zig").nowMs() < deadline) {
        const f = conn.recvFrameFor(500) catch |err| switch (err) {
            error.Timeout => continue,
            else => fail("stream read"),
        };
        defer f.deinit(allocator);
        if (f.ftype == .events) mirror.applyEvents(f.payload) catch fail("events apply");
        if (f.ftype == .snapshot) mirror.applySnapshot(f.payload) catch fail("snapshot apply");
        const txt = mirror.screenText() catch fail("extract");
        defer allocator.free(txt);
        if (std.mem.indexOf(u8, txt, needle) != null) return true;
    }
    return false;
}

pub fn run(allocator: std.mem.Allocator, sock_path: []const u8) void {
    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("connect");
    defer conn.deinit();
    conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("hello");
    (conn.recvExpect(&.{.welcome}) catch fail("welcome")).deinit(allocator);

    // Echo off so the payload does not scroll through the screen (and
    // the daemon's output path is not what we are measuring); canonical
    // mode stays on so the trailing ^D is an EOF for md5sum.
    conn.sendJson(.spawn, .{
        .name = "inbacklog",
        .argv = [_][]const u8{ "/bin/sh", "-c", "stty -echo; echo READY; sleep 3; md5sum; echo DONE" },
        .rows = @as(u16, 10),
        .cols = @as(u16, 80),
    }) catch fail("spawn send");
    (conn.recvExpect(&.{.ok}) catch fail("spawn ok")).deinit(allocator);

    var mirror = Mirror{ .allocator = allocator, .pool = allocator.create(Pool) catch fail("pool") };
    mirror.pool.* = Pool.init(allocator) catch fail("pool init");
    defer {
        if (mirror.screen) |s| s.deinit();
        mirror.pool.deinit();
        allocator.destroy(mirror.pool);
    }
    conn.sendJson(.attach, .{ .name = "inbacklog" }) catch fail("attach");
    const snap = conn.recvExpect(&.{.snapshot}) catch fail("snapshot");
    mirror.applySnapshot(snap.payload) catch fail("snapshot apply");
    snap.deinit(allocator);

    if (!waitForText(allocator, &conn, &mirror, "READY", 10_000)) fail("child never reported READY");

    const payload = allocator.alloc(u8, PAYLOAD_BYTES) catch fail("oom");
    defer allocator.free(payload);
    fillPayload(payload);
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(payload, &digest, .{});
    var hex_buf: [32]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{&digest}) catch unreachable;

    // The child is asleep for the whole send: every byte past the
    // kernel's buffering has to be held by the daemon.
    var off: usize = 0;
    while (off < payload.len) {
        const end = @min(payload.len, off + FRAME_BYTES);
        conn.sendFrame(.input, payload[off..end]) catch fail("input send (daemon stopped reading its client?)");
        off = end;
    }
    conn.sendFrame(.input, "\x04") catch fail("eof send");

    if (!waitForText(allocator, &conn, &mirror, "DONE", 30_000)) {
        fail("md5sum never finished: the daemon lost the EOF or bytes before it (truncated input)");
    }
    const txt = mirror.screenText() catch fail("extract");
    defer allocator.free(txt);
    if (std.mem.indexOf(u8, txt, hex) == null) {
        std.debug.print("expected md5 {s}\nscreen:\n{s}\n", .{ hex, txt });
        fail("md5 mismatch: client input was truncated or reordered on its way to the child");
    }

    conn.sendJson(.kill, .{ .name = "inbacklog" }) catch fail("kill");
    (conn.recvExpect(&.{ .ok, .gone }) catch fail("kill ok")).deinit(allocator);
    std.debug.print("smoke input-backlog stage: {d} KiB queued past a sleeping child arrived intact\n", .{PAYLOAD_BYTES / 1024});
}
