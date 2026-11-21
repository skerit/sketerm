//! A view-only attach that proves a session can still be attached, for
//! `sketerm doctor`. A session whose worker cannot serve this build's
//! clients (an adopted worker of an older binary rejecting a negotiated
//! version, a snapshot no client can decode) lists fine and attaches
//! never, so only an actual attach finds it.
//!
//! The probe never drives the session: it attaches read-only and
//! view-only (no seat lease, input and resize dropped), sends no input or
//! resize of its own, waits for the snapshot under one deadline, restores
//! it, then detaches and closes, so it is never a lingering viewer. A
//! broker hands the connection itself to the session's worker, so every
//! probe needs a connection of its own.

const std = @import("std");
const c = @import("../c.zig").c;
const wire = @import("wire.zig");
const snapshot = @import("snapshot.zig");
const mux_client = @import("client.zig");
const nowMs = @import("../util/clock.zig").nowMs;

const Conn = mux_client.Conn;

/// How long a probe waits for the detach acknowledgement before closing anyway.
const DETACH_MS: i64 = 1_000;

pub const Outcome = enum {
    /// The snapshot arrived and restored.
    attached,
    /// The daemon answered the attach with an error.
    refused,
    /// The connection closed before the snapshot arrived.
    dropped,
    /// No snapshot within the deadline.
    no_snapshot,
    /// A snapshot arrived that no client of this build can restore.
    bad_snapshot,
    /// The daemon could not be reached or greeted, or the attach not sent.
    unreachable_daemon,

    pub fn healthy(self: Outcome) bool {
        return self == .attached;
    }

    pub fn describe(self: Outcome) []const u8 {
        return switch (self) {
            .attached => "attached",
            .refused => "attach refused",
            .dropped => "connection dropped during the attach",
            .no_snapshot => "no screen snapshot arrived",
            .bad_snapshot => "the screen snapshot does not restore",
            .unreachable_daemon => "daemon not reachable for the probe",
        };
    }
};

/// The outcome an attach-handshake error stands for.
pub fn classify(err: anyerror) Outcome {
    return switch (err) {
        error.DaemonError => .refused,
        error.Disconnected => .dropped,
        error.Timeout => .no_snapshot,
        // A frame past the reader's bound: refused at the header.
        error.TooLong, error.Malformed => .bad_snapshot,
        else => .unreachable_daemon,
    };
}

pub const Result = struct {
    outcome: Outcome,
    why_buf: [192]u8 = undefined,
    why_len: usize = 0,

    fn init(outcome: Outcome, why: []const u8) Result {
        var r = Result{ .outcome = outcome };
        r.why_len = @min(why.len, r.why_buf.len);
        @memcpy(r.why_buf[0..r.why_len], why[0..r.why_len]);
        return r;
    }

    /// The daemon's or transport's own words, or the outcome's description.
    pub fn reason(self: *const Result) []const u8 {
        if (self.why_len > 0) return self.why_buf[0..self.why_len];
        return self.outcome.describe();
    }
};

/// Attach `name` view-only on a greeted `conn` and verify its snapshot;
/// the connection is detached but left open for the caller to close.
pub fn attachViewOnly(conn: *Conn, name: []const u8, origin_id: []const u8, timeout_ms: i64) Result {
    const deadline = nowMs() + timeout_ms;
    conn.setNonBlocking();
    conn.sendAttach(name, (mux_client.AttachOptions{
        .kind = "cli",
        .origin_id = origin_id,
    }).withLease(.read_only)) catch |err| return Result.init(.unreachable_daemon, @errorName(err));
    const snap = conn.recvExpectFor(&.{.snapshot}, @max(deadline - nowMs(), 1)) catch |err| {
        const outcome = classify(err);
        return Result.init(outcome, if (outcome == .refused) conn.lastErr() else conn.attachFailure(err));
    };
    defer snap.deinit(conn.allocator);
    const restored = snapshot.restoreOwned(conn.allocator, snap.payload) catch |err|
        return Result.init(.bad_snapshot, @errorName(err));
    restored.deinit(conn.allocator);
    // Best effort: the close that follows ends the attachment regardless.
    if (conn.sendFrame(.detach, "")) {
        if (conn.recvExpectFor(&.{.ok}, DETACH_MS)) |ok| ok.deinit(conn.allocator) else |_| {}
    } else |_| {}
    return Result.init(.attached, "");
}

/// Connect to the daemon at `sock_path`, probe `name`, and close again.
pub fn probeAt(allocator: std.mem.Allocator, sock_path: []const u8, name: []const u8, origin_id: []const u8, timeout_ms: i64) Result {
    const deadline = nowMs() + timeout_ms;
    const raw = Conn.connect(allocator, sock_path) catch |err| return Result.init(.unreachable_daemon, @errorName(err));
    var conn = Conn.probeWithin(allocator, raw, timeout_ms) catch |err| return Result.init(.unreachable_daemon, @errorName(err));
    defer conn.deinit();
    return attachViewOnly(&conn, name, origin_id, @max(deadline - nowMs(), 1));
}

const t = std.testing;
const platform = @import("../util/platform.zig");

/// A greeted client end and the fake daemon end of a socketpair.
const TestPair = struct {
    conn: Conn,
    daemon: c_int,

    fn init() !TestPair {
        var fds: [2]c_int = undefined;
        try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&fds));
        var conn = Conn{ .allocator = t.allocator, .fd = fds[0], .proto = wire.PROTO_VERSION };
        conn.caps.view_only = true;
        return .{ .conn = conn, .daemon = fds[1] };
    }

    fn deinit(self: *TestPair) void {
        self.conn.deinit();
        if (self.daemon >= 0) _ = c.close(self.daemon);
    }

    fn send(self: *TestPair, ftype: wire.FrameType, payload: []const u8) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(t.allocator);
        try wire.appendFrame(&out, t.allocator, ftype, payload);
        try t.expectEqual(@as(isize, @intCast(out.items.len)), c.write(self.daemon, out.items.ptr, out.items.len));
    }

    /// Every frame the probe sent, in order.
    fn sent(self: *TestPair, frames: *std.ArrayList(wire.FrameType), attach: *std.ArrayList(u8)) !void {
        var buf: [4096]u8 = undefined;
        const n = c.recv(self.daemon, &buf, buf.len, c.MSG_DONTWAIT);
        if (n <= 0) return;
        var rest: []const u8 = buf[0..@intCast(n)];
        while (try wire.peelFrame(rest)) |p| {
            try frames.append(t.allocator, p.frame.ftype);
            if (p.frame.ftype == .attach) try attach.appendSlice(t.allocator, p.frame.payload);
            rest = rest[p.consumed..];
        }
    }
};

fn testSnapshotPayload() ![]u8 {
    const Pool = @import("../grid/style_pool.zig").Pool;
    const Screen = @import("../grid/screen.zig").Screen;
    var pool = try Pool.init(t.allocator);
    defer pool.deinit();
    const screen = try Screen.init(t.allocator, &pool, 8, 3);
    defer screen.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(t.allocator);
    var hdr: [9]u8 = @splat(0);
    std.mem.writeInt(u64, hdr[0..8], 7, .little);
    try out.appendSlice(t.allocator, &hdr);
    try snapshot.serialize(screen, &out, t.allocator);
    return out.toOwnedSlice(t.allocator);
}

test "a view-only probe attaches without driving the session, restores the snapshot and detaches" {
    var pair = try TestPair.init();
    defer pair.deinit();
    const payload = try testSnapshotPayload();
    defer t.allocator.free(payload);
    try pair.send(.snapshot, payload);
    try pair.send(.ok, "{\"ok\":true}");
    const r = attachViewOnly(&pair.conn, "Mail", "10000000000000000000000000000001", 2_000);
    try t.expectEqual(Outcome.attached, r.outcome);

    var frames: std.ArrayList(wire.FrameType) = .empty;
    defer frames.deinit(t.allocator);
    var attach: std.ArrayList(u8) = .empty;
    defer attach.deinit(t.allocator);
    try pair.sent(&frames, &attach);
    // Exactly attach then detach: no input, no resize, no control request.
    try t.expectEqualSlices(wire.FrameType, &.{ .attach, .detach }, frames.items);
    const req = try std.json.parseFromSlice(wire.AttachReq, t.allocator, attach.items, .{ .ignore_unknown_fields = true });
    defer req.deinit();
    try t.expect(req.value.view_only and req.value.read_only and !req.value.control);
    try t.expectEqualStrings("10000000000000000000000000000001", req.value.origin_id);
}

test "a probe names a refusal, a drop, a missing and an undecodable snapshot" {
    {
        var pair = try TestPair.init();
        defer pair.deinit();
        try pair.send(.err, "{\"error\":\"session worker did not accept the client handoff\"}");
        const r = attachViewOnly(&pair.conn, "Mail", "", 2_000);
        try t.expectEqual(Outcome.refused, r.outcome);
        try t.expectEqualStrings("session worker did not accept the client handoff", r.reason());
    }
    {
        var pair = try TestPair.init();
        defer pair.deinit();
        // Half-close: the probe reads EOF while its own writes still land.
        _ = c.shutdown(pair.daemon, c.SHUT_WR);
        try t.expectEqual(Outcome.dropped, attachViewOnly(&pair.conn, "Mail", "", 2_000).outcome);
    }
    {
        var pair = try TestPair.init();
        defer pair.deinit();
        try t.expectEqual(Outcome.no_snapshot, attachViewOnly(&pair.conn, "Mail", "", 50).outcome);
    }
    {
        var pair = try TestPair.init();
        defer pair.deinit();
        const payload = try testSnapshotPayload();
        defer t.allocator.free(payload);
        // A body version past this build's.
        std.mem.writeInt(u32, payload[9..13], snapshot.SNAPSHOT_VERSION + 1, .little);
        try pair.send(.snapshot, payload);
        try t.expectEqual(Outcome.bad_snapshot, attachViewOnly(&pair.conn, "Mail", "", 2_000).outcome);
    }
}

test "handshake errors classify, and only an attach is healthy" {
    try t.expectEqual(Outcome.refused, classify(error.DaemonError));
    try t.expectEqual(Outcome.dropped, classify(error.Disconnected));
    try t.expectEqual(Outcome.no_snapshot, classify(error.Timeout));
    try t.expectEqual(Outcome.bad_snapshot, classify(error.TooLong));
    try t.expectEqual(Outcome.unreachable_daemon, classify(error.ConnectionRefused));
    for (std.enums.values(Outcome)) |o| try t.expectEqual(o == .attached, o.healthy());
}
