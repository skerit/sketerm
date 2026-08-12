//! The `chrome-extension://<host>/` origin table, published by the main
//! thread and read by CEF's IO thread.
//!
//! Same shape and same reasoning as `webrequest.slots`, and for the same
//! reason: a scheme handler factory is called on the IO THREAD, which
//! cannot walk `Host.exts` (an ArrayList that reallocates under the main
//! thread's feet). The main thread publishes fixed-width copies here.
//!
//! Unlike the webRequest table this stores the directory BY VALUE rather
//! than a pointer. A scheme request outlives nothing and needs only a
//! path, so copying 512 bytes at publish time removes the entire "is the
//! pointer still alive" question from the IO thread.
//!
//! Pure std: no CEF, no GTK, in both test roots.

const std = @import("std");
const manifest = @import("manifest.zig");

pub const MAX_ORIGINS = 16;
pub const HOST_LEN = 16;
pub const MAX_DIR = 512;
/// `web_accessible_resources` patterns, NUL-separated in one buffer.
pub const MAX_WAR = 512;

pub const Slot = struct {
    used: bool = false,
    host: [HOST_LEN]u8 = @splat(0),
    id: [manifest.MAX_ID_LEN]u8 = @splat(0),
    id_len: usize = 0,
    dir: [MAX_DIR]u8 = @splat(0),
    dir_len: usize = 0,
    war: [MAX_WAR]u8 = @splat(0),
    war_len: usize = 0,

    pub fn hostSlice(self: *const Slot) []const u8 {
        return self.host[0..];
    }
    pub fn idSlice(self: *const Slot) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn dirSlice(self: *const Slot) []const u8 {
        return self.dir[0..self.dir_len];
    }
};

pub var lock: std.atomic.Value(u8) = .init(0);
pub var slots: [MAX_ORIGINS]Slot = @splat(.{});
/// Non-zero when any origin is published, so the IO thread can refuse a
/// request without taking the lock at all.
pub var any: std.atomic.Value(bool) = .init(false);

pub fn acquire() void {
    while (lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

pub fn release() void {
    lock.store(0, .release);
}

fn refreshAnyLocked() void {
    for (&slots) |*s| {
        if (s.used) {
            any.store(true, .release);
            return;
        }
    }
    any.store(false, .release);
}

/// Publish (or re-point) one extension's origin. MAIN THREAD. Returns
/// false when the table is full or the directory does not fit, in which
/// case the extension simply has no origin — a degradation that shows up
/// as a background page that will not load, never as a wrong file.
pub fn publish(host: []const u8, id: []const u8, dir: []const u8, war: []const []const u8) bool {
    if (host.len != HOST_LEN) return false;
    if (id.len > manifest.MAX_ID_LEN) return false;
    if (dir.len > MAX_DIR or dir.len == 0) return false;
    acquire();
    defer release();
    const s = findLocked(host) orelse freeLocked() orelse return false;
    s.* = .{ .used = true };
    @memcpy(&s.host, host);
    @memcpy(s.id[0..id.len], id);
    s.id_len = id.len;
    @memcpy(s.dir[0..dir.len], dir);
    s.dir_len = dir.len;
    var n: usize = 0;
    for (war) |pat| {
        if (n + pat.len + 1 > MAX_WAR) break;
        @memcpy(s.war[n..][0..pat.len], pat);
        n += pat.len;
        s.war[n] = 0;
        n += 1;
    }
    s.war_len = n;
    refreshAnyLocked();
    return true;
}

/// Drop an origin. MAIN THREAD.
pub fn unpublish(host: []const u8) void {
    acquire();
    defer release();
    if (findLocked(host)) |s| s.* = .{};
    refreshAnyLocked();
}

fn findLocked(host: []const u8) ?*Slot {
    if (host.len != HOST_LEN) return null;
    for (&slots) |*s| {
        if (s.used and std.mem.eql(u8, s.hostSlice(), host)) return s;
    }
    return null;
}

fn freeLocked() ?*Slot {
    for (&slots) |*s| {
        if (!s.used) return s;
    }
    return null;
}

/// What the IO thread copies out under the lock: everything one request
/// needs, by value, so the lock is released before any file is touched.
pub const Lookup = struct {
    id: [manifest.MAX_ID_LEN]u8 = @splat(0),
    id_len: usize = 0,
    dir: [MAX_DIR]u8 = @splat(0),
    dir_len: usize = 0,
    war: [MAX_WAR]u8 = @splat(0),
    war_len: usize = 0,

    pub fn idSlice(self: *const Lookup) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn dirSlice(self: *const Lookup) []const u8 {
        return self.dir[0..self.dir_len];
    }

    /// Iterate the NUL-separated `web_accessible_resources` patterns.
    pub fn warPatterns(self: *const Lookup, out: [][]const u8) [][]const u8 {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.war_len and n < out.len) {
            const end = std.mem.indexOfScalarPos(u8, self.war[0..self.war_len], i, 0) orelse break;
            out[n] = self.war[i..end];
            n += 1;
            i = end + 1;
        }
        return out[0..n];
    }
};

/// Resolve an origin host. IO THREAD SAFE: takes the lock, copies, and
/// releases before returning.
pub fn lookup(host: []const u8) ?Lookup {
    if (!any.load(.acquire)) return null;
    acquire();
    defer release();
    const s = findLocked(host) orelse return null;
    var out = Lookup{};
    @memcpy(out.id[0..s.id_len], s.idSlice());
    out.id_len = s.id_len;
    @memcpy(out.dir[0..s.dir_len], s.dirSlice());
    out.dir_len = s.dir_len;
    @memcpy(out.war[0..s.war_len], s.war[0..s.war_len]);
    out.war_len = s.war_len;
    return out;
}

/// Drop every origin. Shutdown only.
pub fn clear() void {
    acquire();
    defer release();
    for (&slots) |*s| s.* = .{};
    any.store(false, .release);
}

// ─── tests ──────────────────────────────────────────────────────────

const t = std.testing;

test "publish / lookup / unpublish round trip" {
    clear();
    defer clear();
    try t.expect(lookup("0123456789abcdef") == null);
    const war = [_][]const u8{ "/war/*", "/other.js" };
    try t.expect(publish("0123456789abcdef", "uBlock0@raymondhill.net", "/tmp/ext", &war));
    const got = lookup("0123456789abcdef") orelse return error.Missing;
    try t.expectEqualStrings("uBlock0@raymondhill.net", got.idSlice());
    try t.expectEqualStrings("/tmp/ext", got.dirSlice());
    var pats: [8][]const u8 = undefined;
    const list = got.warPatterns(&pats);
    try t.expectEqual(@as(usize, 2), list.len);
    try t.expectEqualStrings("/war/*", list[0]);
    try t.expectEqualStrings("/other.js", list[1]);
    unpublish("0123456789abcdef");
    try t.expect(lookup("0123456789abcdef") == null);
}

test "re-publishing the same host re-points rather than duplicating" {
    clear();
    defer clear();
    try t.expect(publish("aaaaaaaaaaaaaaaa", "x", "/one", &.{}));
    try t.expect(publish("aaaaaaaaaaaaaaaa", "x", "/two", &.{}));
    var used: usize = 0;
    for (&slots) |*s| {
        if (s.used) used += 1;
    }
    try t.expectEqual(@as(usize, 1), used);
    const got = lookup("aaaaaaaaaaaaaaaa") orelse return error.Missing;
    try t.expectEqualStrings("/two", got.dirSlice());
}

test "a wrong-length host never matches" {
    clear();
    defer clear();
    try t.expect(!publish("short", "x", "/one", &.{}));
    try t.expect(publish("bbbbbbbbbbbbbbbb", "x", "/one", &.{}));
    try t.expect(lookup("bbbbbbbbbbbbbbb") == null);
    try t.expect(lookup("bbbbbbbbbbbbbbbbb") == null);
    try t.expect(lookup("bbbbbbbbbbbbbbbb") != null);
}

test "the table fills rather than overruns" {
    clear();
    defer clear();
    var i: usize = 0;
    while (i < MAX_ORIGINS) : (i += 1) {
        var host: [HOST_LEN]u8 = @splat('0');
        _ = std.fmt.bufPrint(&host, "{x:0>16}", .{i}) catch unreachable;
        try t.expect(publish(&host, "x", "/d", &.{}));
    }
    try t.expect(!publish("ffffffffffffffff", "x", "/d", &.{}));
}
