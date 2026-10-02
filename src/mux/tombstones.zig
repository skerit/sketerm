//! The broker's short memory of ended sessions: why each one ended, so a
//! client that finds a session gone can say whether it expired, exited or
//! was closed. Bounded by count and age; nothing is persisted (a broker
//! restart forgets them, and a lookup then answers "not found").

const std = @import("std");
const wire = @import("wire.zig");

/// At most this many ended sessions are remembered; the oldest go first.
pub const MAX_ENTRIES: usize = 256;
/// An entry older than this is forgotten (wall-clock ms).
pub const MAX_AGE_MS: i64 = 48 * 3600 * 1000;

/// Why a session ended. Wire names are the tags (append-only).
pub const Reason = enum {
    /// No client was attached for its `ttl_secs` and the daemon ended it.
    expired,
    /// Its child exited on its own (`exit_status`, or `signal`).
    exited,
    /// A client killed it.
    closed,
    /// The session's worker ended without saying why (a crash, or a worker
    /// that predates the report).
    unknown,
};

pub const Entry = struct {
    name_buf: [wire.MAX_SESSION_NAME]u8 = undefined,
    name_len: u8 = 0,
    /// Its fixed title (`SpawnReq.title`, an MCP agent's name), if any.
    title_buf: [wire.MAX_SESSION_NAME]u8 = undefined,
    title_len: u8 = 0,
    origin_id: wire.SessionOriginId = undefined,
    ended_ms: i64,
    reason: Reason,
    /// `exited` with a normal exit: its status.
    exit_status: ?i32 = null,
    /// `exited` by a signal: its number.
    signal: ?i32 = null,

    pub fn name(self: *const Entry) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn title(self: *const Entry) []const u8 {
        return self.title_buf[0..self.title_len];
    }
};

/// What a worker reports about its session's end ('T' control datagram),
/// and the JSON body of one `tombstone_reply` entry.
pub const End = struct {
    reason: Reason,
    exit_status: ?i32 = null,
    signal: ?i32 = null,

    /// From a `Pty.decodeStatus` value: negative = killed by that signal.
    pub fn exited(decoded: i32) End {
        if (decoded < 0) return .{ .reason = .exited, .signal = -decoded };
        return .{ .reason = .exited, .exit_status = decoded };
    }
};

pub const Ring = struct {
    entries: [MAX_ENTRIES]Entry = undefined,
    len: usize = 0,
    /// Index of the oldest entry once the ring is full.
    head: usize = 0,

    /// Remember that session `name` (lifetime `origin_id`, fixed title
    /// `title`) ended at `now_wall_ms`.
    pub fn add(self: *Ring, name: []const u8, title: []const u8, origin_id: wire.SessionOriginId, end: End, now_wall_ms: i64) void {
        var e = Entry{ .ended_ms = now_wall_ms, .reason = end.reason, .exit_status = end.exit_status, .signal = end.signal, .origin_id = origin_id };
        const n = @min(name.len, e.name_buf.len);
        @memcpy(e.name_buf[0..n], name[0..n]);
        e.name_len = @intCast(n);
        const tn = @min(title.len, e.title_buf.len);
        @memcpy(e.title_buf[0..tn], title[0..tn]);
        e.title_len = @intCast(tn);
        if (self.len < MAX_ENTRIES) {
            self.entries[self.len] = e;
            self.len += 1;
        } else {
            self.entries[self.head] = e;
            self.head = (self.head + 1) % MAX_ENTRIES;
        }
    }

    /// The newest entry for `origin_id` when given (a lifetime is unique),
    /// else the newest one named or titled `name`; null when none is
    /// younger than `MAX_AGE_MS`.
    pub fn find(self: *const Ring, name: []const u8, origin_id: ?[]const u8, now_wall_ms: i64) ?Entry {
        var best: ?Entry = null;
        for (self.entries[0..self.len]) |e| {
            if (now_wall_ms - e.ended_ms > MAX_AGE_MS) continue;
            const hit = if (origin_id) |o| std.mem.eql(u8, &e.origin_id, o) else std.mem.eql(u8, e.name(), name) or (e.title_len > 0 and std.mem.eql(u8, e.title(), name));
            if (!hit) continue;
            if (best == null or e.ended_ms >= best.?.ended_ms) best = e;
        }
        return best;
    }
};

/// `tombstone_get` request body.
pub const Query = struct {
    req: u32 = 0,
    name: []const u8 = "",
    /// A lifetime id narrows the lookup to exactly that session.
    origin_id: []const u8 = "",
};

/// `tombstone_reply` body: `found` false = this daemon remembers no such end.
pub const Reply = struct {
    req: u32 = 0,
    found: bool = false,
    name: []const u8 = "",
    origin_id: []const u8 = "",
    ended_ms: i64 = 0,
    reason: ?Reason = null,
    exit_status: ?i32 = null,
    signal: ?i32 = null,
};

const t = std.testing;

fn oid(ch: u8) wire.SessionOriginId {
    return @splat(ch);
}

test "a tombstone is found by lifetime first, then by name, and forgotten when old" {
    var r: Ring = .{};
    r.add("agent-claude-k3f9", "probe", oid('a'), .{ .reason = .closed }, 1000);
    r.add("agent-claude-k3f9", "", oid('b'), End.exited(-9), 2000);
    r.add("other", "", oid('c'), End.exited(3), 3000);
    // By name: the newest of that name.
    const by_name = r.find("agent-claude-k3f9", null, 4000).?;
    try t.expectEqual(Reason.exited, by_name.reason);
    try t.expectEqual(@as(?i32, 9), by_name.signal);
    try t.expectEqual(@as(?i32, null), by_name.exit_status);
    // By lifetime: exactly that one, whatever its name.
    const a = oid('a');
    try t.expectEqual(Reason.closed, r.find("ignored", &a, 4000).?.reason);
    try t.expectEqual(@as(?i32, 3), r.find("other", null, 4000).?.exit_status);
    try t.expect(r.find("nope", null, 4000) == null);
    // A fixed title (an agent's name) finds it too.
    try t.expectEqual(Reason.closed, r.find("probe", null, 4000).?.reason);
    // Older than the age bound: gone.
    try t.expect(r.find("other", null, 3000 + MAX_AGE_MS + 1) == null);
}

test "the ring keeps the newest MAX_ENTRIES" {
    var r: Ring = .{};
    var buf: [16]u8 = undefined;
    for (0..MAX_ENTRIES + 10) |i| {
        const name = try std.fmt.bufPrint(&buf, "s{d}", .{i});
        r.add(name, "", oid('x'), .{ .reason = .expired }, @intCast(i));
    }
    try t.expectEqual(MAX_ENTRIES, r.len);
    try t.expect(r.find("s0", null, 0) == null);
    try t.expect(r.find("s9", null, 0) == null);
    try t.expect(r.find("s10", null, 100) != null);
    try t.expect(r.find(try std.fmt.bufPrint(&buf, "s{d}", .{MAX_ENTRIES + 9}), null, 300) != null);
}

test "the reply round-trips its reason by wire name" {
    const out = try std.json.Stringify.valueAlloc(t.allocator, Reply{ .req = 7, .found = true, .name = "n", .reason = .expired }, .{ .emit_null_optional_fields = false });
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, "\"reason\":\"expired\"") != null);
    const back = try std.json.parseFromSlice(Reply, t.allocator, out, .{ .ignore_unknown_fields = true });
    defer back.deinit();
    try t.expectEqual(Reason.expired, back.value.reason.?);
}
