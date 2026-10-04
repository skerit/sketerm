//! Sub-agents at a glance: the attention tally `sketerm mcp agents`, the
//! pane titlebar chip and the tab badge all render, which pane session an
//! MCP server runs in, and the badge palette.
//!
//! GTK-free so both test roots cover it; the widgets are `ui/agentbadge.zig`.

const std = @import("std");
const vocab = @import("../agent/vocab.zig");
const sshroute = @import("../mux/sshroute.zig");
const Attention = vocab.Attention;

/// Agents counted by attention. An agent whose attention is unknown (a
/// server that predates publishing it) counts in `total` only.
pub const Tally = struct {
    total: u32 = 0,
    by_attention: std.EnumArray(Attention, u32) = .initFill(0),

    pub fn add(self: *Tally, attention: ?Attention) void {
        self.total += 1;
        if (attention) |a| self.by_attention.getPtr(a).* += 1;
    }

    pub fn merge(self: *Tally, other: Tally) void {
        self.total += other.total;
        for (std.enums.values(Attention)) |a| self.by_attention.getPtr(a).* += other.by_attention.get(a);
    }

    pub fn count(self: Tally, attention: Attention) u32 {
        return self.by_attention.get(attention);
    }

    /// The most urgent attention any agent has; null when none is known.
    pub fn mostUrgent(self: Tally) ?Attention {
        for (std.enums.values(Attention)) |a| if (self.by_attention.get(a) > 0) return a;
        return null;
    }

    /// Agents counted in `total` whose attention is unknown.
    pub fn unknown(self: Tally) u32 {
        var known: u32 = 0;
        for (std.enums.values(Attention)) |a| known += self.by_attention.get(a);
        return self.total - known;
    }

    pub fn eql(self: Tally, other: Tally) bool {
        return std.meta.eql(self, other);
    }
};

/// Where an MCP server was started, as its registry record says.
pub const Origin = struct {
    /// The host spec of the remote per-user daemon whose report named the
    /// server; null = this machine's registry.
    reached: ?[]const u8 = null,
    /// `SKETERM_SESSION` / `SKETERM_MUX_SOCKET` of the server; null =
    /// not started from a pane, or a server too old to say.
    session: ?[]const u8 = null,
    session_socket: ?[]const u8 = null,
};

/// The session a pane shows and the daemon serving it.
pub const PaneSession = struct {
    /// `Terminal.Remote.host`: null = this machine's per-user daemon.
    host: ?[]const u8,
    session: []const u8,
};

/// Whether `host`'s list reply describes ANOTHER machine's registry, i.e.
/// it reaches a remote per-user daemon. Null and `sock:` are this machine;
/// a route ending in an instance is a private MCP daemon, not a per-user one.
pub fn remotePerUser(host: ?[]const u8) bool {
    const h = host orelse return false;
    if (h.len == 0 or std.mem.startsWith(u8, h, "sock:")) return false;
    if (sshroute.RouteSpec.isRoute(h)) {
        const r = sshroute.RouteSpec.parse(h) catch return false;
        return r.instance == null;
    }
    return true;
}

/// A socket of a private MCP instance daemon (`.../mcp-<key>/mux.sock`).
fn instanceSocket(path: []const u8) bool {
    const dir = std.fs.path.dirname(path) orelse return false;
    return std.mem.startsWith(u8, std.fs.path.basename(dir), "mcp-");
}

/// Whether the server `o` runs in the pane session `p`. `default_socket`
/// is this machine's per-user daemon socket (what a pane with no host is
/// attached to). Without a recorded session there is no answer (false).
/// A remote server matches a pane on the per-user daemon of the machine
/// that reported it, however the two specs spell that machine; the remote
/// daemon's socket path is not known here, so only a server inside a
/// private instance's session (`mcp-*`) is told apart by its socket.
pub fn runsIn(o: Origin, p: PaneSession, default_socket: []const u8) bool {
    const session = o.session orelse return false;
    if (session.len == 0 or !std.mem.eql(u8, session, p.session)) return false;
    const socket = o.session_socket orelse return false;
    if (socket.len == 0) return false;
    if (o.reached) |reached| {
        if (!remotePerUser(p.host) or instanceSocket(socket)) return false;
        var want_buf: [512]u8 = undefined;
        var got_buf: [512]u8 = undefined;
        const want = sshroute.watchSpec(&want_buf, reached, "", "", .user) catch return false;
        const got = sshroute.watchSpec(&got_buf, p.host.?, "", "", .user) catch return false;
        return std.mem.eql(u8, want, got);
    }
    const pane_socket = if (p.host) |h|
        (if (std.mem.startsWith(u8, h, "sock:")) h["sock:".len..] else return false)
    else
        default_socket;
    return std.mem.eql(u8, socket, pane_socket);
}

/// The pane titlebar chip, derived from a tally.
pub const Chip = struct {
    /// "2 agents working", "3 agents", "3 agents idle".
    text: []const u8,
    /// The leading glyph: working, else idle, else the pill's attention;
    /// null = nothing known (a neutral dot).
    glyph: ?Attention,
    /// The pill beside the text: needs input outranks disconnected.
    pill: ?Pill,

    pub const Pill = struct {
        attention: Attention,
        n: u32,

        /// "1 needs input", "2 disconnected".
        pub fn text(self: Pill, buf: []u8) []const u8 {
            return std.fmt.bufPrint(buf, "{d} {s}", .{ self.n, self.attention.label() }) catch self.attention.label();
        }
    };
};

/// Null when there are no agents (the chip is hidden).
pub fn chip(t: Tally, buf: []u8) ?Chip {
    if (t.total == 0) return null;
    const pill: ?Chip.Pill = if (t.count(.needs_input) > 0)
        .{ .attention = .needs_input, .n = t.count(.needs_input) }
    else if (t.count(.lost) > 0)
        .{ .attention = .lost, .n = t.count(.lost) }
    else
        null;
    const glyph: ?Attention = if (t.count(.working) > 0)
        .working
    else if (t.count(.idle) > 0)
        .idle
    else if (pill) |p| p.attention else null;
    const noun = if (t.total == 1) "agent" else "agents";
    const all: ?Attention = if (pill != null) null else if (t.count(.working) == t.total) .working else if (t.count(.idle) == t.total) .idle else null;
    const text = if (all) |a|
        std.fmt.bufPrint(buf, "{d} {s} {s}", .{ t.total, noun, a.label() }) catch noun
    else
        std.fmt.bufPrint(buf, "{d} {s}", .{ t.total, noun }) catch noun;
    return .{ .text = text, .glyph = glyph, .pill = pill };
}

pub const Rgb = [3]u8;

/// A badge's background and text colours.
pub const Swatch = struct { bg: Rgb, fg: Rgb };

/// The tab badge and the chip's pill for an attention; null = unknown
/// (an older server), drawn neutral like idle.
pub fn swatch(a: ?Attention) Swatch {
    const at = a orelse return .{ .bg = .{ 0x4a, 0x4a, 0x4a }, .fg = .{ 0xd0, 0xd0, 0xd0 } };
    return switch (at) {
        .working => .{ .bg = .{ 0x3d, 0x5a, 0x80 }, .fg = .{ 0xe6, 0xf0, 0xff } },
        .needs_input => .{ .bg = .{ 0xf6, 0xc4, 0x53 }, .fg = .{ 0x2b, 0x1d, 0x00 } },
        .lost => .{ .bg = .{ 0xa5, 0x1d, 0x2d }, .fg = .{ 0xff, 0xff, 0xff } },
        .idle => .{ .bg = .{ 0x4a, 0x4a, 0x4a }, .fg = .{ 0xd0, 0xd0, 0xd0 } },
    };
}

/// The chip is white on every titlebar colour (the active bar is a
/// configurable red, the inactive one light grey), so its text never
/// depends on the bar.
pub const CHIP_BG: Rgb = .{ 0xff, 0xff, 0xff };
pub const CHIP_FG: Rgb = .{ 0x1d, 0x1d, 0x1d };
/// The all-idle chip reads quieter.
pub const CHIP_FG_IDLE: Rgb = .{ 0x55, 0x55, 0x55 };

/// The chip's leading glyph colour on its white background.
pub fn glyphOnChip(a: ?Attention) Rgb {
    const at = a orelse return CHIP_FG_IDLE;
    return switch (at) {
        .working => .{ 0x1c, 0x71, 0xd8 },
        // The badge amber is unreadable on white; a dark amber is not.
        .needs_input => .{ 0x8a, 0x5a, 0x00 },
        .lost => .{ 0xa5, 0x1d, 0x2d },
        .idle => CHIP_FG_IDLE,
    };
}

/// WCAG 2 contrast ratio of two sRGB colours.
pub fn contrast(a: Rgb, b: Rgb) f64 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

fn luminance(rgb: Rgb) f64 {
    var out: f64 = 0;
    const weights = [3]f64{ 0.2126, 0.7152, 0.0722 };
    for (rgb, weights) |ch, w| {
        const s = @as(f64, @floatFromInt(ch)) / 255.0;
        const lin = if (s <= 0.04045) s / 12.92 else std.math.pow(f64, (s + 0.055) / 1.055, 2.4);
        out += w * lin;
    }
    return out;
}

// ── tests ────────────────────────────────────────────────────────

const testing = std.testing;

fn tallyOf(atts: []const ?Attention) Tally {
    var out: Tally = .{};
    for (atts) |a| out.add(a);
    return out;
}

test "tally: most urgent wins, unknown agents count in the total only" {
    const s = tallyOf(&.{ .working, .idle, null, .needs_input, .working });
    try testing.expectEqual(@as(u32, 5), s.total);
    try testing.expectEqual(@as(u32, 2), s.count(.working));
    try testing.expectEqual(@as(u32, 1), s.unknown());
    try testing.expectEqual(@as(?Attention, .needs_input), s.mostUrgent());
    try testing.expectEqual(@as(?Attention, null), tallyOf(&.{ null, null }).mostUrgent());
    try testing.expectEqual(@as(?Attention, .lost), tallyOf(&.{ .idle, .lost }).mostUrgent());
    var m = tallyOf(&.{.working});
    m.merge(tallyOf(&.{ .lost, null }));
    try testing.expect(m.eql(tallyOf(&.{ .working, .lost, null })));
    try testing.expect(!m.eql(tallyOf(&.{ .working, .lost, .idle })));
}

test "chip text, glyph and pill follow the mockup" {
    var buf: [64]u8 = undefined;
    var pbuf: [32]u8 = undefined;
    try testing.expect(chip(.{}, &buf) == null);

    const working = chip(tallyOf(&.{ .working, .working }), &buf).?;
    try testing.expectEqualStrings("2 agents working", working.text);
    try testing.expectEqual(@as(?Attention, .working), working.glyph);
    try testing.expect(working.pill == null);

    const one = chip(tallyOf(&.{.working}), &buf).?;
    try testing.expectEqualStrings("1 agent working", one.text);

    const asks = chip(tallyOf(&.{ .working, .needs_input, .lost }), &buf).?;
    try testing.expectEqualStrings("3 agents", asks.text);
    try testing.expectEqual(@as(?Attention, .working), asks.glyph);
    try testing.expectEqualStrings("1 needs input", asks.pill.?.text(&pbuf));

    const lost = chip(tallyOf(&.{ .idle, .lost }), &buf).?;
    try testing.expectEqualStrings("2 agents", lost.text);
    try testing.expectEqual(@as(?Attention, .idle), lost.glyph);
    try testing.expectEqualStrings("1 disconnected", lost.pill.?.text(&pbuf));

    const idle = chip(tallyOf(&.{ .idle, .idle, .idle }), &buf).?;
    try testing.expectEqualStrings("3 agents idle", idle.text);
    try testing.expectEqual(@as(?Attention, .idle), idle.glyph);

    // Only a question pending: its own glyph leads.
    try testing.expectEqual(@as(?Attention, .needs_input), chip(tallyOf(&.{.needs_input}), &buf).?.glyph);
    // Mixed busy and idle, or an older server's unknown agents: neutral words.
    try testing.expectEqualStrings("2 agents", chip(tallyOf(&.{ .working, .idle }), &buf).?.text);
    const old = chip(tallyOf(&.{ null, null }), &buf).?;
    try testing.expectEqualStrings("2 agents", old.text);
    try testing.expectEqual(@as(?Attention, null), old.glyph);
    try testing.expect(old.pill == null);
}

test "every badge colour pair is readable" {
    for ([_]?Attention{ null, .needs_input, .lost, .working, .idle }) |a| {
        const s = swatch(a);
        try testing.expect(contrast(s.fg, s.bg) >= 4.5);
        // Glyphs are graphics: 3:1 is the bar.
        try testing.expect(contrast(glyphOnChip(a), CHIP_BG) >= 3.0);
    }
    try testing.expect(contrast(CHIP_FG, CHIP_BG) >= 4.5);
    try testing.expect(contrast(CHIP_FG_IDLE, CHIP_BG) >= 4.5);
    // The palette the plan approved.
    try testing.expectEqual(Rgb{ 0xf6, 0xc4, 0x53 }, swatch(.needs_input).bg);
    try testing.expectEqual(Rgb{ 0x3d, 0x5a, 0x80 }, swatch(.working).bg);
    try testing.expectEqual(Rgb{ 0xa5, 0x1d, 0x2d }, swatch(.lost).bg);
    try testing.expectEqual(Rgb{ 0x4a, 0x4a, 0x4a }, swatch(.idle).bg);
}

test "a local server runs in the pane on its exact daemon and session" {
    const def = "/run/user/1/sketerm/mux.sock";
    const o: Origin = .{ .session = "s12-1", .session_socket = def };
    try testing.expect(runsIn(o, .{ .host = null, .session = "s12-1" }, def));
    try testing.expect(!runsIn(o, .{ .host = null, .session = "s12-2" }, def));
    // An explicit local socket names the same daemon; another one does not.
    try testing.expect(runsIn(o, .{ .host = "sock:" ++ def, .session = "s12-1" }, def));
    try testing.expect(!runsIn(o, .{ .host = "sock:/run/user/1/sketerm/mcp-x/mux.sock", .session = "s12-1" }, def));
    try testing.expect(!runsIn(o, .{ .host = null, .session = "s12-1" }, "/other/mux.sock"));
    // A remote pane of the same name is another machine's session.
    try testing.expect(!runsIn(o, .{ .host = "dalaran", .session = "s12-1" }, def));
    // Old records: no session, or no socket, is no pane at all.
    try testing.expect(!runsIn(.{}, .{ .host = null, .session = "s12-1" }, def));
    try testing.expect(!runsIn(.{ .session = "s12-1" }, .{ .host = null, .session = "s12-1" }, def));
    try testing.expect(!runsIn(.{ .session = "", .session_socket = def }, .{ .host = null, .session = "" }, def));
}

test "a remote server runs in panes on the per-user daemon of the machine that reported it" {
    const def = "/run/user/1/sketerm/mux.sock";
    const o: Origin = .{ .reached = "dalaran", .session = "s7-3", .session_socket = "/run/user/1000/sketerm/mux.sock" };
    try testing.expect(runsIn(o, .{ .host = "dalaran", .session = "s7-3" }, def));
    // Another spelling of the same machine.
    try testing.expect(runsIn(o, .{ .host = "ssh:dalaran", .session = "s7-3" }, def));
    try testing.expect(runsIn(o, .{ .host = "udp:dalaran", .session = "s7-3" }, def));
    try testing.expect(!runsIn(o, .{ .host = "peregrin", .session = "s7-3" }, def));
    try testing.expect(!runsIn(o, .{ .host = null, .session = "s7-3" }, def));
    try testing.expect(!runsIn(o, .{ .host = "dalaran", .session = "s7-4" }, def));
    // A pane on a private instance there is not the per-user daemon.
    try testing.expect(!runsIn(o, .{ .host = "route:dalaran#tmp-4", .session = "s7-3" }, def));
    // A server started inside an instance's session is not a pane's.
    const inner: Origin = .{ .reached = "dalaran", .session = "s7-3", .session_socket = "/run/user/1000/sketerm/mcp-tmp-9/mux.sock" };
    try testing.expect(!runsIn(inner, .{ .host = "dalaran", .session = "s7-3" }, def));
    // Through a jump host.
    const far: Origin = .{ .reached = "route:a/b", .session = "x", .session_socket = "/r/sketerm/mux.sock" };
    try testing.expect(runsIn(far, .{ .host = "route:a/b", .session = "x" }, def));
    try testing.expect(!runsIn(far, .{ .host = "b", .session = "x" }, def));
}

test "only a remote per-user daemon's report describes another machine" {
    try testing.expect(!remotePerUser(null));
    try testing.expect(!remotePerUser(""));
    try testing.expect(!remotePerUser("sock:/run/user/1/sketerm/mcp-tmp-4/mux.sock"));
    try testing.expect(remotePerUser("box"));
    try testing.expect(remotePerUser("ssh:user@box"));
    try testing.expect(remotePerUser("udp:box"));
    try testing.expect(remotePerUser("route:a/b"));
    try testing.expect(!remotePerUser("route:a#tmp-4"));
    try testing.expect(!remotePerUser("route:a/b#hub"));
    try testing.expect(!remotePerUser("route:"));
}
