//! What a peer's session runs besides its main turn (subagents, background
//! shells and monitors), read by the session's worker off the `Screen` it
//! owns, with the agent tools' own reader (`screen_source.workOf` over
//! `grammar.work`; there is no second parser). The broker tells a worker
//! which peer runs in its session (`SessionPeer`, with the peer's app);
//! only an app whose adapter names it (`adapter.Spec.mcp_client`) and
//! reads a screen is read, so a session outside sketerm, or an app with
//! no screen reader, gets nothing rather than a guess.
//!
//! Cost: one read of the visible rows at most every `READ_EVERY_MS`, and
//! only after the session printed something since the last read; a
//! report goes to the broker (control `'W'`) only when the counts change.

const std = @import("std");
const adapter = @import("../agent/adapter.zig");
const screen_source = @import("../agent/screen_source.zig");
const vocab = @import("../agent/vocab.zig");
const Screen = @import("../grid/screen.zig").Screen;

/// A session's screen is read at most this often (monotonic ms).
pub const READ_EVERY_MS: i64 = 1000;

pub const Reader = struct {
    /// Loaded on the first peer whose app might have a reader.
    adapters: ?adapter.Set = null,
    /// The adapter reading the current peer's screen; null = none.
    loaded: ?*const adapter.Loaded = null,
    /// What was last reported for the current peer; null = nothing yet.
    sent: ?vocab.PeerWork = null,
    read_ms: i64 = 0,
    /// The session's `last_activity_ms` at the last read; null = never read.
    read_activity: ?i64 = null,

    pub fn deinit(self: *Reader) void {
        if (self.adapters) |*s| s.deinit();
        self.* = .{};
    }

    /// A report did not reach the broker: read and report again when due.
    pub fn retry(self: *Reader) void {
        self.sent = null;
        self.read_activity = null;
    }

    /// The session's peer is now one of `app` ("" = none): what was
    /// reported is forgotten, and the adapter that reads its screen chosen.
    pub fn setApp(self: *Reader, allocator: std.mem.Allocator, app: []const u8) void {
        self.sent = null;
        self.read_activity = null;
        self.read_ms = 0;
        self.loaded = null;
        if (app.len == 0) return;
        if (self.adapters == null) self.adapters = adapter.Set.loadDefault(allocator) catch null;
        const set = if (self.adapters) |*s| s else return;
        self.loaded = set.byMcpClient(app);
    }

    /// Read `screen` when it is due and the session printed since the last
    /// read (`activity_ms`, its `last_activity_ms`).
    /// @return the counts to report, null when no read was due or they
    /// did not change.
    pub fn poll(self: *Reader, allocator: std.mem.Allocator, screen: *const Screen, activity_ms: i64, now_ms: i64) ?vocab.PeerWork {
        const l = self.loaded orelse return null;
        if (self.read_activity) |seen| if (seen == activity_ms) return null;
        if (self.read_activity != null and now_ms - self.read_ms < READ_EVERY_MS) return null;
        self.read_ms = now_ms;
        self.read_activity = activity_ms;
        const w = screen_source.workOf(allocator, &l.screen.?, screen) catch return null;
        if (self.sent) |s| if (s.eql(w)) return null;
        self.sent = w;
        return w;
    }
};

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;
const Parser = @import("../parser/vt.zig").Parser;
const Event = @import("../parser/event.zig").Event;
const StylePool = @import("../grid/style_pool.zig").Pool;

const Term = struct {
    pool: StylePool,
    screen: *Screen,
    parser: Parser,

    fn init(self: *Term, cols: u16, rows: u16) !void {
        self.pool = try StylePool.init(t.allocator);
        self.screen = try Screen.init(t.allocator, &self.pool, cols, rows);
        self.parser = Parser.init(t.allocator);
    }

    fn deinit(self: *Term) void {
        self.parser.deinit();
        self.screen.deinit();
        self.pool.deinit();
    }

    fn emit(user: ?*anyopaque, ev: Event) void {
        const self: *Term = @ptrCast(@alignCast(user.?));
        var e = ev;
        self.screen.apply(ev);
        e.deinit(t.allocator);
    }

    fn write(self: *Term, bytes: []const u8) void {
        self.parser.advance(bytes, emit, @ptrCast(self));
    }
};

/// A Claude Code screen after a turn that started two background
/// subagents, two shells and a monitor, built from the rows claude 2.1.287
/// draws (measured at 120 columns, `screen_source`'s background tests): its
/// footer, then the live block (status rows, the mode line with the shells
/// and the monitor, one `◯` row per background subagent under `● main`, the
/// input box). Smoke peers step 45 prints it in a real session.
pub const fixture_claude_busy =
    "you: start two subagents, two shells and a monitor\r\n" ++
    "claude: Started them all.\r\n" ++
    "Brewed for 44s \xc2\xb7 done 10:29 AM \xc2\xb7 2 shells still running\r\n" ++
    "[Haiku 4.5] repo:master\r\n[\xe2\x96\xa0\xe2\x96\xa1] 21%\r\n" ++
    "manual mode on  \xc2\xb7  2 shells, 1 monitor\r\n" ++
    "  \xe2\x97\x8f main\r\n" ++
    "   \xe2\x97\xaf  general-purpose Subagent sleep 60 then answer 6s \xc2\xb7 \xe2\x86\x93 32.7k tokens\r\n" ++
    "   \xe2\x97\xaf  Explore find the parser 3s \xc2\xb7 \xe2\x86\x93 1.2k tokens\r\n" ++
    "$";

/// The same session once everything ended: the live block alone.
const claude_settled = "\x1b[2J\x1b[H" ++
    "claude: All done.\r\n" ++
    "[Haiku 4.5] repo:master\r\n[\xe2\x96\xa0\xe2\x96\xa1] 21%\r\n" ++
    "manual mode on\r\n" ++
    "$";

/// A reader whose adapters are the shipped ones only (never the user's).
fn shippedReader() !Reader {
    var set = adapter.Set.init(t.allocator);
    errdefer set.deinit();
    try set.loadShipped();
    return .{ .adapters = set };
}

test "the worker reads a Claude Code screen's subagents, shells and monitor, throttled and only on change" {
    var term: Term = undefined;
    try term.init(120, 20);
    defer term.deinit();
    var r = try shippedReader();
    defer r.deinit();
    // An app without a screen reader is never read.
    r.setApp(t.allocator, "opencode");
    term.write(fixture_claude_busy);
    try t.expect(r.poll(t.allocator, term.screen, 1, 0) == null);
    // Claude Code: its shipped adapter reads the screen.
    r.setApp(t.allocator, "claude-code");
    const w = r.poll(t.allocator, term.screen, 1, 0) orelse return error.TestUnexpectedResult;
    try t.expectEqual(vocab.PeerWork{ .subagents = 2, .shells = 2, .monitors = 1 }, w);
    var buf: [64]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&buf);
    try w.write(&fw);
    try t.expectEqualStrings("2 subagents, 2 shells, 1 monitor", fw.buffered());
    // Nothing printed since: no read. Printed within the throttle: not yet.
    try t.expect(r.poll(t.allocator, term.screen, 1, 5_000) == null);
    term.write(claude_settled);
    try t.expect(r.poll(t.allocator, term.screen, 2, 500) == null);
    // Past it: the settled screen reports nothing running, once.
    try t.expectEqual(vocab.PeerWork{}, r.poll(t.allocator, term.screen, 2, 1_500) orelse return error.TestUnexpectedResult);
    try t.expect(r.poll(t.allocator, term.screen, 3, 3_000) == null);
    // A new peer in the session is reported afresh.
    r.setApp(t.allocator, "claude-code");
    try t.expectEqual(vocab.PeerWork{}, r.poll(t.allocator, term.screen, 3, 3_000) orelse return error.TestUnexpectedResult);
}

test "a subagent wait line counts its agents; a background line without a known noun is other work" {
    var term: Term = undefined;
    try term.init(100, 12);
    defer term.deinit();
    var r = try shippedReader();
    defer r.deinit();
    r.setApp(t.allocator, "claude-code");
    term.write("you: use subagents\r\nclaude: waiting\r\nWaiting for 3 background agents to finish\r\n" ++
        "[Haiku 4.5] repo:master\r\n[\xe2\x96\xa0\xe2\x96\xa1] 21%\r\nmanual mode on  \xc2\xb7  1 shell, 2 crons\r\n$");
    try t.expectEqual(vocab.PeerWork{ .subagents = 3, .shells = 1, .other_tasks = 2 }, r.poll(t.allocator, term.screen, 1, 0) orelse return error.TestUnexpectedResult);
}
