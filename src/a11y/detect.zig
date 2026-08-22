//! Is a screen reader actually present on this desktop?
//!
//! WHY THIS EXISTS: engine-side accessibility is not free — it makes
//! the renderer build and serialize a full AX tree for every document.
//! Paying that for the overwhelming majority of users who run no
//! assistive technology is the reason the web a11y path shipped behind
//! an env var. It is also the reason the answer must never be implied:
//! handing an engine an accessibility handler while leaving its state
//! at "default" lets Chromium decide FOR ITSELF that a session bus
//! means a reader is present, and it then serializes every page. That
//! regression is what commit 669f208 fixed, so the state is set
//! explicitly in BOTH directions and this module is what decides which.
//!
//! WHAT IT KEYS ON: `org.a11y.Status`, the freedesktop interface the
//! accessibility bus itself exposes on the SESSION bus. Two booleans:
//!
//!   - `ScreenReaderEnabled` — a reader (Orca, and anything following
//!     the same convention) sets this when it starts. This is the
//!     strong signal: it means a reader is running NOW.
//!   - `IsEnabled` — the desktop's "toolkit accessibility" switch,
//!     which is what `org.gnome.desktop.interface toolkit-accessibility`
//!     is wired to. A deliberate user/desktop choice to publish
//!     accessibility, so it counts too.
//!
//! Reading them over D-Bus rather than through GSettings is deliberate:
//! it needs no schema to exist (a missing GSettings schema ABORTS the
//! process), it is desktop-agnostic, and it keeps this module GTK-free
//! so both test roots can compile it.
//!
//! HOW IT FAILS SAFE: the probe asks `NameHasOwner` FIRST and gives up
//! when nothing owns `org.a11y.Bus`. That matters because the name is
//! D-Bus ACTIVATABLE — a bare property read would launch
//! at-spi-bus-launcher on a desktop that has no accessibility running
//! at all, which is both a side effect we have no business causing and
//! a way to talk ourselves into a false positive. Every failure (no
//! session bus, no owner, a refused read, a malformed reply, a
//! timeout) resolves to OFF. The only way to get ON is an explicit
//! true from a bus that was already there.

const std = @import("std");
const c = @import("../c.zig").c;
const dbus = @import("../mux/dbus.zig");
const dbusconn = @import("../mux/dbusconn.zig");
const nowMs = @import("../util/clock.zig").nowMs;

/// Total wall-clock budget. A desktop whose a11y bus needs longer than
/// this to answer is treated as absent rather than stalling a browser
/// face's startup.
const PROBE_BUDGET_MS: i64 = 2_000;

pub const Reason = enum {
    /// `SKETERM_WEB_A11Y` forced the answer.
    forced_on,
    forced_off,
    /// A reader announced itself via `ScreenReaderEnabled`.
    screen_reader,
    /// The desktop's toolkit-accessibility switch is on.
    toolkit_accessibility,
    /// Nothing owns `org.a11y.Bus`: no accessibility stack running.
    no_a11y_bus,
    /// The bus is there and says accessibility is off.
    disabled,
    /// No session bus, or the probe failed/timed out. Fails to OFF.
    unavailable,

    pub fn enabled(self: Reason) bool {
        return switch (self) {
            .forced_on, .screen_reader, .toolkit_accessibility => true,
            .forced_off, .no_a11y_bus, .disabled, .unavailable => false,
        };
    }

    /// Stable token for logs and the smoke rigs.
    pub fn token(self: Reason) []const u8 {
        return @tagName(self);
    }
};

/// The env override, in BOTH directions: "0"/"" force off, anything
/// else forces on. Absent = defer to the desktop.
pub fn override() ?Reason {
    const v = c.getenv("SKETERM_WEB_A11Y") orelse return null;
    const s = std.mem.sliceTo(v, 0);
    if (s.len == 0 or std.mem.eql(u8, s, "0")) return .forced_off;
    return .forced_on;
}

/// Should the web accessibility path run? Blocking D-Bus IO, bounded
/// by `PROBE_BUDGET_MS` — call it off the main loop, or once at face
/// construction where a 2s worst case is already the connect budget.
pub fn detect(gpa: std.mem.Allocator) Reason {
    if (override()) |o| return o;
    return probe(gpa) catch .unavailable;
}

fn probe(gpa: std.mem.Allocator) !Reason {
    const deadline = nowMs() + PROBE_BUDGET_MS;
    var path_buf: [256]u8 = undefined;
    const env = c.getenv("DBUS_SESSION_BUS_ADDRESS") orelse return .unavailable;
    const sess = dbusconn.parseUnixPath(std.mem.sliceTo(env, 0), &path_buf) orelse
        return .unavailable;

    var conn = Conn{ .client = try dbusconn.Client.connect(gpa, sess) };
    defer conn.deinit();
    try conn.authAndHello(deadline);

    // Ask before activating: `org.a11y.Bus` is activatable, so reading
    // a property straight away would START the accessibility stack on
    // a desktop that has none.
    if (!try conn.nameHasOwner("org.a11y.Bus", deadline)) return .no_a11y_bus;

    if (conn.statusBool("ScreenReaderEnabled", deadline) catch null) |on| {
        if (on) return .screen_reader;
    }
    if (conn.statusBool("IsEnabled", deadline) catch null) |on| {
        if (on) return .toolkit_accessibility;
    }
    return .disabled;
}

/// The a11y-status probe's domain calls on top of the shared blocking
/// client. Deliberately not `webproj.Proj`'s client: that one must keep
/// ANSWERING calls while it waits (it is a server too), and this one has
/// nothing to serve.
const Conn = struct {
    client: dbusconn.Client,

    fn deinit(self: *Conn) void {
        self.client.deinit();
    }

    fn authAndHello(self: *Conn, deadline: i64) !void {
        return self.client.authAndHello(deadline);
    }

    fn nameHasOwner(self: *Conn, name: []const u8, deadline: i64) !bool {
        const gpa = self.client.allocator;
        var bw = dbus.Writer.init(gpa);
        defer bw.deinit();
        try bw.putString(name);
        const r = try self.client.call(.{
            .mtype = .method_call,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "NameHasOwner",
            .destination = "org.freedesktop.DBus",
            .signature = "s",
            .body = bw.buf.items,
        }, deadline);
        defer gpa.free(r.body);
        var rd = dbus.Reader.init(r.body);
        return (rd.u32v() catch 0) != 0;
    }

    /// `org.a11y.Status.<prop>` as a bool. Null when the property is
    /// absent or not a boolean — an older bus without it must read as
    /// "unknown", never as "on".
    fn statusBool(self: *Conn, prop: []const u8, deadline: i64) !?bool {
        const gpa = self.client.allocator;
        var bw = dbus.Writer.init(gpa);
        defer bw.deinit();
        try bw.putString("org.a11y.Status");
        try bw.putString(prop);
        const r = try self.client.call(.{
            .mtype = .method_call,
            .path = "/org/a11y/bus",
            .interface = "org.freedesktop.DBus.Properties",
            .member = "Get",
            .destination = "org.a11y.Bus",
            .signature = "ss",
            .body = bw.buf.items,
        }, deadline);
        defer gpa.free(r.body);
        var rd = dbus.Reader.init(r.body);
        const vsig = rd.sig() catch return null;
        if (vsig.len != 1 or vsig[0] != 'b') return null;
        return (rd.u32v() catch return null) != 0;
    }
};

// ── tests ────────────────────────────────────────────────────────────

const t = std.testing;

test "only an explicit desktop signal enables; every failure is off" {
    try t.expect(Reason.screen_reader.enabled());
    try t.expect(Reason.toolkit_accessibility.enabled());
    try t.expect(Reason.forced_on.enabled());
    // The whole point: absence, refusal and breakage all read as off.
    try t.expect(!Reason.no_a11y_bus.enabled());
    try t.expect(!Reason.disabled.enabled());
    try t.expect(!Reason.unavailable.enabled());
    try t.expect(!Reason.forced_off.enabled());
}

test "reason tokens are stable and distinct" {
    try t.expectEqualStrings("screen_reader", Reason.screen_reader.token());
    try t.expectEqualStrings("no_a11y_bus", Reason.no_a11y_bus.token());
    try t.expectEqualStrings("unavailable", Reason.unavailable.token());
}
