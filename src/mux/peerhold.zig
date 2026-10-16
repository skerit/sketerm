//! Which far daemon holds a federation link, and whether it is still
//! there: the one home of the rule every link end applies (`peermail`'s
//! routes hold a `Holder` each, whichever side dialed).
//!
//! A link names its far host, not the daemon process behind it, and a
//! host can run several daemons that link under one name (an older build
//! federated from every private broker). When each new call-in simply
//! replaced the older link, two of them evicted each other every 2 s
//! forever. So each hello names its daemon (`Instance`, a random id
//! minted per broker), and `admit` decides: no live link, take it; the
//! same daemon again (a reconnect) or a holder that predates instance
//! ids, replace it; any other daemon while the holder is live is refused
//! (`peermail.LinkRefused.link_held`), and it retries after
//! `HELD_RETRY_MS`, never at the 2 s floor. A holder is live only while
//! it is heard: both ends that say `beat` (welcome `peer_link_beat`, or
//! the hello) send `peer_link_beat` every `BEAT_MS`, and a holder silent
//! for `SILENCE_MS` (whatever it sent counts) is closed, so a
//! half-dead link frees itself within a bounded time. Replacements are
//! still counted (`Flap`): past `FLAP_MAX` within `FLAP_WINDOW_MS` the
//! link is flapping, warned about once and listed `flapping`.

const std = @import("std");

/// A beat goes out after this long without one (monotonic ms).
pub const BEAT_MS: i64 = 15_000;
/// A beating far side not heard for this long is gone.
pub const SILENCE_MS: i64 = 3 * BEAT_MS;
/// A daemon refused because another one holds its link dials again
/// after at least this long.
pub const HELD_RETRY_MS: i64 = 20_000;
/// More replacements than `FLAP_MAX` within one window is a flapping link.
pub const FLAP_WINDOW_MS: i64 = 60_000;
pub const FLAP_MAX: u32 = 3;

/// Longest instance id kept; a hello's longer id is cut.
pub const ID_MAX: usize = 32;
/// Longest socket path kept (a `sockaddr_un` path is shorter).
pub const SOCKET_MAX: usize = 128;
/// Longest flap detail kept.
pub const DETAIL_MAX: usize = 400;

/// The daemon process behind one end of a link, as its hello names it
/// (`HubHello.instance`, `MemberHello.instance`). All empty from a daemon
/// that predates it.
pub const Instance = struct {
    /// Random, minted when its broker started; "" = an older build.
    id: []const u8 = "",
    pid: i32 = 0,
    /// Its listening socket.
    socket: []const u8 = "",

    /// "pid 12, /run/user/1000/sketerm/mux.sock, instance k3f9", or what
    /// an older build that names nothing reads as.
    pub fn describe(self: Instance, buf: []u8) []const u8 {
        if (self.id.len == 0) return "a daemon that names no instance (an older build)";
        return std.fmt.bufPrint(buf, "pid {d}, {s}, instance {s}", .{ self.pid, if (self.socket.len > 0) self.socket else "socket unnamed", self.id }) catch self.id;
    }

    pub fn same(self: Instance, other: Instance) bool {
        return self.pid == other.pid and std.mem.eql(u8, self.id, other.id) and std.mem.eql(u8, self.socket, other.socket);
    }
};

/// An `Instance` kept by value.
pub const Held = struct {
    id_buf: [ID_MAX]u8 = undefined,
    id_len: usize = 0,
    pid: i32 = 0,
    socket_buf: [SOCKET_MAX]u8 = undefined,
    socket_len: usize = 0,

    pub fn set(self: *Held, i: Instance) void {
        self.id_len = @min(i.id.len, ID_MAX);
        @memcpy(self.id_buf[0..self.id_len], i.id[0..self.id_len]);
        self.pid = i.pid;
        self.socket_len = @min(i.socket.len, SOCKET_MAX);
        @memcpy(self.socket_buf[0..self.socket_len], i.socket[0..self.socket_len]);
    }

    pub fn view(self: *const Held) Instance {
        return .{ .id = self.id_buf[0..self.id_len], .pid = self.pid, .socket = self.socket_buf[0..self.socket_len] };
    }
};

pub const Admission = enum {
    /// No live link: the newcomer takes it.
    take,
    /// The newcomer replaces the live link: the same daemon again, or a
    /// holder whose liveness is not bounded (it names no instance or
    /// does not beat), as before instances existed.
    replace,
    /// Another daemon holds a live link: the newcomer is refused.
    refuse,
};

/// The one rule. `live`: a link is held now; `holder`/`holder_beats`:
/// who holds it and whether its silence is detected. An incoming hello
/// that names no instance is refused by a holder that does, so a stray
/// older build cannot evict the current daemon either.
pub fn admit(live: bool, holder: Instance, holder_beats: bool, incoming: Instance) Admission {
    if (!live) return .take;
    if (holder.id.len == 0 or !holder_beats) return .replace;
    if (std.mem.eql(u8, holder.id, incoming.id)) return .replace;
    return .refuse;
}

/// What is due on a held link at a given moment.
pub const Due = enum { none, beat, silent };

/// One link end's far daemon, its liveness and its replacement history.
pub const Holder = struct {
    who: Held = .{},
    /// The far side says `beat`: it beats, and it takes beats.
    beats: bool = false,
    /// Monotonic ms it was last heard, and a beat (or anything) last sent.
    heard_ms: i64 = 0,
    sent_ms: i64 = 0,
    flap: Flap = .{},
    /// The last daemon refused while this holder held the link (null: none).
    refused: ?Held = null,

    /// A link is held from `mono` on, by `far`.
    pub fn hold(self: *Holder, far: Instance, beats: bool, mono: i64) void {
        self.who.set(far);
        self.beats = beats;
        self.heard_ms = mono;
        self.sent_ms = mono;
        self.refused = null;
    }

    pub fn heard(self: *Holder, mono: i64) void {
        self.heard_ms = mono;
    }

    pub fn sent(self: *Holder, mono: i64) void {
        self.sent_ms = mono;
    }

    /// `far` is refused. @return whether it is not the one refused last.
    pub fn refusing(self: *Holder, far: Instance) bool {
        if (self.refused) |*last| if (last.view().same(far)) return false;
        self.refused = .{};
        self.refused.?.set(far);
        return true;
    }

    /// Silence wins over a beat: a dead link is closed, not beaten at.
    pub fn due(self: *const Holder, mono: i64) Due {
        if (!self.beats) return .none;
        if (mono - self.heard_ms > SILENCE_MS) return .silent;
        if (mono - self.sent_ms >= BEAT_MS) return .beat;
        return .none;
    }
};

/// Replacements of one link within a window.
pub const Flap = struct {
    window_ms: i64 = 0,
    count: u32 = 0,
    last_ms: i64 = 0,
    flapping: bool = false,
    detail_buf: [DETAIL_MAX]u8 = undefined,
    detail_len: usize = 0,

    /// The link was replaced at `mono`, `old` by `new`.
    /// @return true when this replacement starts the flapping (warn once).
    pub fn replaced(self: *Flap, mono: i64, old: Instance, new: Instance) bool {
        if (self.count == 0 or mono - self.window_ms > FLAP_WINDOW_MS) {
            self.window_ms = mono;
            self.count = 0;
        }
        self.count += 1;
        self.last_ms = mono;
        if (self.flapping or self.count <= FLAP_MAX) return false;
        self.flapping = true;
        var ob: [256]u8 = undefined;
        var nb: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&self.detail_buf, "replaced {d} times within {d} s, between {s} and {s}", .{ self.count, @divTrunc(FLAP_WINDOW_MS, 1000), old.describe(&ob), new.describe(&nb) }) catch self.detail_buf[0..];
        self.detail_len = text.len;
        return true;
    }

    /// @return true when a flapping link has been left alone a whole
    /// window: it stopped (say so once).
    pub fn settle(self: *Flap, mono: i64) bool {
        if (!self.flapping or mono - self.last_ms < FLAP_WINDOW_MS) return false;
        self.flapping = false;
        self.count = 0;
        return true;
    }

    pub fn detail(self: *const Flap) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }
};

const t = std.testing;

test "the same daemon replaces its own link; another is refused while the holder is live" {
    const a = Instance{ .id = "k3f9", .pid = 10, .socket = "/r/a.sock" };
    const b = Instance{ .id = "zz21", .pid = 11, .socket = "/r/b.sock" };
    try t.expectEqual(Admission.take, admit(false, a, true, b));
    try t.expectEqual(Admission.replace, admit(true, a, true, a));
    try t.expectEqual(Admission.refuse, admit(true, a, true, b));
    // A newcomer that names no instance cannot evict one that does.
    try t.expectEqual(Admission.refuse, admit(true, a, true, .{}));
}

test "a holder from an older build is replaced as before" {
    // It names no instance, or its silence would never be noticed.
    try t.expectEqual(Admission.replace, admit(true, .{}, false, .{}));
    try t.expectEqual(Admission.replace, admit(true, .{}, false, .{ .id = "k3f9" }));
    try t.expectEqual(Admission.replace, admit(true, .{ .id = "k3f9" }, false, .{ .id = "zz21" }));
}

test "a beating holder is beaten at, and closed once silent past the bound" {
    var h: Holder = .{};
    h.hold(.{ .id = "k3f9", .pid = 10 }, true, 1000);
    try t.expectEqualStrings("k3f9", h.who.view().id);
    try t.expectEqual(Due.none, h.due(1000 + BEAT_MS - 1));
    try t.expectEqual(Due.beat, h.due(1000 + BEAT_MS));
    h.sent(1000 + BEAT_MS);
    h.heard(1000 + BEAT_MS + 5);
    try t.expectEqual(Due.none, h.due(1000 + BEAT_MS + 10));
    try t.expectEqual(Due.silent, h.due(1000 + BEAT_MS + 5 + SILENCE_MS + 1));
    // A far side that never said `beat` is neither beaten at nor timed out.
    var old: Holder = .{};
    old.hold(.{}, false, 0);
    try t.expectEqual(Due.none, old.due(10 * SILENCE_MS));
    // A refused daemon is news once, until another is refused or the
    // link changes hands.
    const b = Instance{ .id = "zz21", .pid = 11 };
    try t.expect(h.refusing(b));
    try t.expect(!h.refusing(b));
    try t.expect(h.refusing(.{}));
    try t.expect(h.refusing(b));
    h.hold(.{ .id = "k3f9", .pid = 10 }, true, 0);
    try t.expect(h.refusing(b));
}

test "a link replaced past the bound flaps once, naming both daemons, and settles" {
    var f: Flap = .{};
    const a = Instance{ .id = "k3f9", .pid = 10, .socket = "/r/a.sock" };
    const b = Instance{};
    var mono: i64 = 5_000;
    for (0..FLAP_MAX) |_| {
        try t.expect(!f.replaced(mono, a, b));
        mono += 2_200;
    }
    try t.expect(f.replaced(mono, b, a));
    try t.expect(f.flapping);
    try t.expect(std.mem.indexOf(u8, f.detail(), "pid 10, /r/a.sock, instance k3f9") != null);
    try t.expect(std.mem.indexOf(u8, f.detail(), "older build") != null);
    // Further replacements say nothing more.
    try t.expect(!f.replaced(mono + 2_200, a, b));
    try t.expect(!f.settle(mono + 2_200 + FLAP_WINDOW_MS - 1));
    try t.expect(f.settle(mono + 2_200 + FLAP_WINDOW_MS));
    try t.expect(!f.flapping);
    // Replacements spread wider than the window never flap.
    var slow: Flap = .{};
    for (0..10) |i| try t.expect(!slow.replaced(@as(i64, @intCast(i)) * (FLAP_WINDOW_MS / 2), a, b));
}
