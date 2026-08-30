//! The `web_gui` permission: the user lets the `web_*` tools of an
//! isolated `sketerm mcp` use THEIR OWN browser (a running sketerm GUI,
//! or `sketerm web` spawned for it) instead of the server's private
//! headless engine with its own empty cookie jar.
//!
//! This is deliberately NOT `--shared`: the grant scopes the GUI to the
//! web tools alone. Terminal, app, file and panel tools keep the
//! private daemon, so the web tools carry their OWN socket state here
//! rather than flipping `mcp.guiSocketAttached()` for everyone.
//!
//! Three rules a consumer can rely on. The transport is LAZY: nothing
//! is discovered or spawned until the first web call, so a session that
//! never browses never starts a browser. It is RE-CHECKED per call: a
//! GUI that went away is re-discovered or re-spawned on the next web
//! call. And it FAILS CLOSED: when no GUI can be reached the call
//! answers `unavailable`, never a private headless view -- a quietly
//! not-logged-in browser is the bug this permission exists to fix.

const std = @import("std");
const c = @import("../c.zig").c;
const clock = @import("../util/clock.zig");
const platform = @import("../util/platform.zig");
const muxclient = @import("../mux/client.zig");
const config = @import("../config.zig");
const mcp = @import("mcp.zig");

/// Where the grant came from, lowest to highest precedence; THE
/// vocabulary behind the `web_gui_source` capability fact.
pub const Source = enum {
    none,
    config,
    env,
    flag,

    pub fn name(self: Source) []const u8 {
        return @tagName(self);
    }
};

/// Which GUI socket the web tools hold right now; THE vocabulary behind
/// the `web_gui_transport` capability fact.
pub const Transport = enum {
    /// No socket yet (lazy: nothing browsed so far) or the last attempt
    /// failed.
    none,
    /// A GUI that was already running was found.
    discovered,
    /// `sketerm web` was started for this server and its socket found.
    spawned,
    /// The server-wide `--socket`/`--shared` socket serves the web tools
    /// as it always did.
    explicit,

    pub fn name(self: Transport) []const u8 {
        return @tagName(self);
    }
};

pub const Grant = struct {
    granted: bool = false,
    source: Source = .none,
    /// `[mcp.<name>]` when a named section decided it; "" otherwise.
    profile: []const u8 = "",
};

/// The env switch (`SKETERM_MCP_WEB_GUI`), the flag (`--web-gui`) and
/// the config key (`web_gui` in `[mcp]` / `[mcp.<name>]`) share one name.
pub const ENV = "SKETERM_MCP_WEB_GUI";
pub const FLAG = "--web-gui";
/// Executable spawned as `<exe> web` when no GUI is running; defaults
/// to this process's own image. An explicit, documented override so a
/// test can stand in a fake GUI -- never a hidden hook.
pub const EXE_ENV = "SKETERM_GUI_BIN";

/// Bounded wait for a spawned GUI's control socket.
pub const SPAWN_WAIT_MS: i64 = 15_000;

/// Resolve the grant from its sources, lowest precedence first: the
/// bare `[mcp]` config key, the `[mcp.<name>]` key of `--profile`, the
/// env switch, the flag. Pure, so the precedence unit-tests.
/// @throws BadEnvValue when the env holds neither a true nor a false
/// word (a typo must not silently mean "off").
pub fn resolveGrant(cfg_default: ?bool, cfg_profile: ?bool, profile_name: []const u8, env: ?[]const u8, flag: bool) error{BadEnvValue}!Grant {
    var g = Grant{};
    if (cfg_default) |v| {
        g.granted = v;
        g.source = .config;
    }
    if (cfg_profile) |v| {
        g.granted = v;
        g.source = .config;
        g.profile = profile_name;
    }
    if (env) |raw| {
        const v = std.mem.trim(u8, raw, " \t\r\n");
        if (v.len > 0) {
            g.granted = config.parseBool(v) catch return error.BadEnvValue;
            g.source = .env;
            g.profile = "";
        }
    }
    if (flag) {
        g.granted = true;
        g.source = .flag;
        g.profile = "";
    }
    // A source that decided "false" is still the deciding source: the
    // fact says where the verdict came from, not only when it is yes.
    return g;
}

/// The side effects `State.ensure` needs, injectable so the state
/// machine unit-tests with no sockets and no fork.
pub const Ops = struct {
    ctx: *anyopaque,
    /// Is there a listener on this socket path?
    alive: *const fn (ctx: *anyopaque, path: [:0]const u8) bool,
    /// Any live GUI control socket (caller frees), or null.
    discover: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) ?[:0]u8,
    /// Start `sketerm web` detached; false when it could not be started.
    spawn: *const fn (ctx: *anyopaque) bool,
    sleepMs: *const fn (ctx: *anyopaque, ms: u32) void,
    nowMs: *const fn (ctx: *anyopaque) i64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    grant: Grant = .{},
    transport: Transport = .none,
    sock: ?[:0]u8 = null,
    /// The sentence a failed `ensure` leaves for the tool's error.
    reason: []const u8 = "",
    /// How many times `spawn` ran, for the capabilities text and tests.
    spawns: u32 = 0,
    ops: Ops,
    backend_impl: mcp.RealBackend = .{ .sock_path = "" },

    /// Make sure a live GUI socket is held; the fail-closed core.
    pub fn ensure(self: *State) error{Unavailable}!void {
        if (self.sock) |s| {
            if (self.ops.alive(self.ops.ctx, s)) return;
            // The GUI went away: forget it and start over. The
            // transport is re-decided below, never left reading
            // "discovered" for a socket nobody answers.
            self.allocator.free(s);
            self.sock = null;
            self.transport = .none;
        }
        if (self.ops.discover(self.ops.ctx, self.allocator)) |found| {
            self.adopt(found, .discovered);
            return;
        }
        if (!self.ops.spawn(self.ops.ctx)) {
            self.reason = "no sketerm GUI is running and `sketerm web` could not be started for the web tools; nothing was opened headlessly (web_gui is granted, so a private not-logged-in browser is refused). Start the sketerm GUI and retry";
            return error.Unavailable;
        }
        self.spawns += 1;
        const deadline = self.ops.nowMs(self.ops.ctx) + SPAWN_WAIT_MS;
        while (self.ops.nowMs(self.ops.ctx) < deadline) {
            self.ops.sleepMs(self.ops.ctx, 200);
            if (self.ops.discover(self.ops.ctx, self.allocator)) |found| {
                self.adopt(found, .spawned);
                return;
            }
        }
        self.reason = "no sketerm GUI was running, so `sketerm web` was started for the web tools, but no GUI control socket appeared within 15s; nothing was opened headlessly (web_gui is granted, so a private not-logged-in browser is refused). Check that the GUI can start on this display (SKETERM_GUI_BIN names the executable) and retry";
        return error.Unavailable;
    }

    fn adopt(self: *State, sock: [:0]u8, how: Transport) void {
        self.sock = sock;
        self.transport = how;
        self.reason = "";
        self.backend_impl = .{ .sock_path = sock };
    }

    /// The GUI backend over the held socket; `ensure` first.
    pub fn backend(self: *State) mcp.Backend {
        return mcp.RealBackend.asBackend(&self.backend_impl);
    }

    pub fn deinit(self: *State) void {
        if (self.sock) |s| self.allocator.free(s);
        self.sock = null;
        self.transport = .none;
    }
};

// ---------------------------------------------------------------------
// The real side effects
// ---------------------------------------------------------------------

fn realAlive(_: *anyopaque, path: [:0]const u8) bool {
    return @import("client.zig").socketAlive(path);
}

fn realDiscover(_: *anyopaque, allocator: std.mem.Allocator) ?[:0]u8 {
    // $SKETERM_SOCKET (this server runs inside a sketerm pane) names the
    // GUI exactly; otherwise any live one will do.
    if (c.getenv("SKETERM_SOCKET")) |env| {
        const path = allocator.dupeZ(u8, std.mem.span(env)) catch return null;
        if (realAlive(undefined, path)) return path;
        allocator.free(path);
    }
    return @import("client.zig").discoverGuiSocket(allocator, .any);
}

/// Start `<exe> web` DETACHED: double-forked so init reaps it and it
/// outlives this server, in its own session, with stdio on /dev/null
/// -- this process's stdin/stdout ARE the JSON-RPC stream, and a GUI
/// writing a warning there would corrupt it. The daemon idle-exit hint
/// this server set for its private instances must not reach the GUI's
/// real per-user daemon.
fn realSpawn(_: *anyopaque) bool {
    var exe_buf: [4096:0]u8 = undefined;
    const exe: [*:0]const u8 = if (c.getenv(EXE_ENV)) |v|
        @ptrCast(v)
    else
        (platform.exePathZ(&exe_buf) orelse return false).ptr;
    const pid = c.fork();
    if (pid < 0) return false;
    if (pid == 0) {
        _ = c.setsid();
        const inner = c.fork();
        if (inner != 0) c._exit(if (inner < 0) 1 else 0);
        const devnull = c.open("/dev/null", c.O_RDWR);
        if (devnull >= 0) {
            _ = c.dup2(devnull, 0);
            _ = c.dup2(devnull, 1);
            _ = c.dup2(devnull, 2);
            if (devnull > 2) _ = c.close(devnull);
        }
        _ = c.unsetenv(muxclient.Conn.IDLE_EXIT_ENV);
        var argv: [3:null]?[*:0]const u8 = .{ exe, "web", null };
        _ = c.execv(exe, @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    return status == 0;
}

fn realSleep(_: *anyopaque, ms: u32) void {
    _ = c.usleep(ms * 1000);
}

fn realNow(_: *anyopaque) i64 {
    return clock.nowMs();
}

var real_ops_ctx: u8 = 0;
pub const REAL_OPS = Ops{
    .ctx = @ptrCast(&real_ops_ctx),
    .alive = realAlive,
    .discover = realDiscover,
    .spawn = realSpawn,
    .sleepMs = realSleep,
    .nowMs = realNow,
};

// ---------------------------------------------------------------------
// Process-wide state (module-level, like `mcp.policy`)
// ---------------------------------------------------------------------

var g_state: ?State = null;

/// Arm the grant for this server. Only a granted permission is armed;
/// `ops` is injectable for tests.
pub fn configure(allocator: std.mem.Allocator, g: Grant, ops: Ops) void {
    shutdown();
    if (!g.granted) return;
    g_state = .{ .allocator = allocator, .grant = g, .ops = ops };
}

pub fn shutdown() void {
    if (g_state) |*s| s.deinit();
    g_state = null;
}

/// Whether the web tools are permitted the user's own browser.
pub fn granted() bool {
    return g_state != null;
}

pub fn grant() Grant {
    return if (g_state) |s| s.grant else .{};
}

pub fn transport() Transport {
    return if (g_state) |s| s.transport else .none;
}

pub fn socketPath() ?[]const u8 {
    return if (g_state) |s| s.sock else null;
}

pub fn spawnCount() u32 {
    return if (g_state) |s| s.spawns else 0;
}

/// The sentence the last failed `ensureBackend` left.
pub fn reason() []const u8 {
    return if (g_state) |s| s.reason else "";
}

/// The GUI backend for a web call: lazily discovers or spawns the GUI.
/// @throws Unavailable when no GUI can be reached (`reason()` says why).
pub fn ensureBackend() error{Unavailable}!mcp.Backend {
    const s = &(g_state orelse return error.Unavailable);
    try s.ensure();
    return s.backend();
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

test "web_gui grant precedence: config [mcp] < [mcp.<name>] < env < flag" {
    const t = std.testing;
    const none = try resolveGrant(null, null, "", null, false);
    try t.expect(!none.granted);
    try t.expectEqual(Source.none, none.source);

    const bare = try resolveGrant(true, null, "", null, false);
    try t.expect(bare.granted);
    try t.expectEqual(Source.config, bare.source);
    try t.expectEqualStrings("", bare.profile);

    // A named section overrides the bare one only when it says so.
    const unstated = try resolveGrant(true, null, "work", null, false);
    try t.expect(unstated.granted);
    const named_off = try resolveGrant(true, false, "work", null, false);
    try t.expect(!named_off.granted);
    try t.expectEqual(Source.config, named_off.source);
    try t.expectEqualStrings("work", named_off.profile);
    const named_on = try resolveGrant(null, true, "work", null, false);
    try t.expect(named_on.granted);
    try t.expectEqualStrings("work", named_on.profile);

    // Env beats config in both directions; an empty value is unset.
    const env_on = try resolveGrant(false, false, "work", "1", false);
    try t.expect(env_on.granted);
    try t.expectEqual(Source.env, env_on.source);
    try t.expectEqualStrings("", env_on.profile);
    const env_off = try resolveGrant(true, true, "work", "no", false);
    try t.expect(!env_off.granted);
    try t.expectEqual(Source.env, env_off.source);
    const env_empty = try resolveGrant(true, null, "", "  ", false);
    try t.expectEqual(Source.config, env_empty.source);
    try t.expectError(error.BadEnvValue, resolveGrant(null, null, "", "maybe", false));

    // The flag beats everything.
    const flag = try resolveGrant(false, false, "work", "0", true);
    try t.expect(flag.granted);
    try t.expectEqual(Source.flag, flag.source);
}

/// Scripted side effects: what the state machine may and may not do.
const FakeOps = struct {
    alive: bool = true,
    /// Sockets `discover` answers, in order; null = nothing running.
    discoveries: []const ?[]const u8 = &.{},
    discover_calls: usize = 0,
    spawn_ok: bool = true,
    spawn_calls: usize = 0,
    clock_ms: i64 = 0,
    allocator: std.mem.Allocator,

    fn aliveFn(ctx: *anyopaque, _: [:0]const u8) bool {
        const self: *FakeOps = @ptrCast(@alignCast(ctx));
        return self.alive;
    }
    fn discoverFn(ctx: *anyopaque, allocator: std.mem.Allocator) ?[:0]u8 {
        const self: *FakeOps = @ptrCast(@alignCast(ctx));
        defer self.discover_calls += 1;
        const i = @min(self.discover_calls, self.discoveries.len -| 1);
        if (self.discoveries.len == 0) return null;
        const d = self.discoveries[i] orelse return null;
        return allocator.dupeZ(u8, d) catch null;
    }
    fn spawnFn(ctx: *anyopaque) bool {
        const self: *FakeOps = @ptrCast(@alignCast(ctx));
        self.spawn_calls += 1;
        return self.spawn_ok;
    }
    fn sleepFn(ctx: *anyopaque, ms: u32) void {
        const self: *FakeOps = @ptrCast(@alignCast(ctx));
        self.clock_ms += ms;
    }
    fn nowFn(ctx: *anyopaque) i64 {
        const self: *FakeOps = @ptrCast(@alignCast(ctx));
        return self.clock_ms;
    }
    fn ops(self: *FakeOps) Ops {
        return .{ .ctx = @ptrCast(self), .alive = aliveFn, .discover = discoverFn, .spawn = spawnFn, .sleepMs = sleepFn, .nowMs = nowFn };
    }
};

test "ensure discovers a running GUI without spawning, and keeps it while alive" {
    const t = std.testing;
    var fo = FakeOps{ .discoveries = &.{"/run/gui-1.sock"}, .allocator = t.allocator };
    var s = State{ .allocator = t.allocator, .grant = .{ .granted = true, .source = .flag }, .ops = fo.ops() };
    defer s.deinit();
    try s.ensure();
    try t.expectEqual(Transport.discovered, s.transport);
    try t.expectEqualStrings("/run/gui-1.sock", s.sock.?);
    try t.expectEqual(@as(usize, 0), fo.spawn_calls);
    // A second call re-checks liveness and does not re-discover.
    try s.ensure();
    try t.expectEqual(@as(usize, 1), fo.discover_calls);
    try t.expectEqual(Transport.discovered, s.transport);
}

test "ensure spawns when nothing runs and adopts the socket that appears" {
    const t = std.testing;
    // Nothing on the first look, the spawned GUI's socket on the third.
    var fo = FakeOps{ .discoveries = &.{ null, null, "/run/gui-2.sock" }, .allocator = t.allocator };
    var s = State{ .allocator = t.allocator, .grant = .{ .granted = true, .source = .env }, .ops = fo.ops() };
    defer s.deinit();
    try s.ensure();
    try t.expectEqual(Transport.spawned, s.transport);
    try t.expectEqual(@as(usize, 1), fo.spawn_calls);
    try t.expectEqual(@as(u32, 1), s.spawns);
    try t.expectEqualStrings("/run/gui-2.sock", s.sock.?);
}

test "a GUI that went away is re-discovered or re-spawned on the next call" {
    const t = std.testing;
    var fo = FakeOps{ .discoveries = &.{ "/run/gui-1.sock", "/run/gui-3.sock" }, .allocator = t.allocator };
    var s = State{ .allocator = t.allocator, .grant = .{ .granted = true, .source = .config }, .ops = fo.ops() };
    defer s.deinit();
    try s.ensure();
    try t.expectEqualStrings("/run/gui-1.sock", s.sock.?);
    fo.alive = false;
    try s.ensure();
    try t.expectEqualStrings("/run/gui-3.sock", s.sock.?);
    try t.expectEqual(Transport.discovered, s.transport);
    try t.expectEqual(@as(usize, 0), fo.spawn_calls);
}

test "ensure fails CLOSED: no GUI, spawn refused or no socket appears" {
    const t = std.testing;
    // Spawn itself fails.
    var refused = FakeOps{ .discoveries = &.{null}, .spawn_ok = false, .allocator = t.allocator };
    var s1 = State{ .allocator = t.allocator, .grant = .{ .granted = true, .source = .flag }, .ops = refused.ops() };
    defer s1.deinit();
    try t.expectError(error.Unavailable, s1.ensure());
    try t.expectEqual(Transport.none, s1.transport);
    try t.expect(s1.sock == null);
    try t.expect(std.mem.indexOf(u8, s1.reason, "nothing was opened headlessly") != null);

    // Spawn runs but no socket ever appears: bounded by SPAWN_WAIT_MS.
    var silent = FakeOps{ .discoveries = &.{null}, .allocator = t.allocator };
    var s2 = State{ .allocator = t.allocator, .grant = .{ .granted = true, .source = .flag }, .ops = silent.ops() };
    defer s2.deinit();
    try t.expectError(error.Unavailable, s2.ensure());
    try t.expectEqual(Transport.none, s2.transport);
    try t.expect(silent.clock_ms >= SPAWN_WAIT_MS);
    try t.expect(std.mem.indexOf(u8, s2.reason, "within 15s") != null);
    try t.expect(std.mem.indexOf(u8, s2.reason, EXE_ENV) != null);

    // The previously held socket died and nothing replaces it: the
    // stale transport must not survive as "discovered".
    var dying = FakeOps{ .discoveries = &.{ "/run/gui-1.sock", null }, .spawn_ok = false, .allocator = t.allocator };
    var s3 = State{ .allocator = t.allocator, .grant = .{ .granted = true, .source = .flag }, .ops = dying.ops() };
    defer s3.deinit();
    try s3.ensure();
    dying.alive = false;
    try t.expectError(error.Unavailable, s3.ensure());
    try t.expectEqual(Transport.none, s3.transport);
    try t.expect(s3.sock == null);
}

test "module state: not granted means nothing is armed and ensureBackend refuses" {
    const t = std.testing;
    configure(t.allocator, .{ .granted = false, .source = .config }, REAL_OPS);
    defer shutdown();
    try t.expect(!granted());
    try t.expectEqual(Transport.none, transport());
    try t.expectError(error.Unavailable, ensureBackend());
}

test "capabilities schema: web_gui_source and web_gui_transport enums are drift-tested" {
    const t = std.testing;
    const mcp_tools = @import("mcp_tools.zig");
    const tool = for (mcp_tools.TOOLS) |tool| {
        if (std.mem.eql(u8, tool.name, "capabilities")) break tool;
    } else return error.MissingCapabilitiesTool;
    const schema = tool.output_schema.?;
    inline for (.{ .{ "web_gui_source", Source }, .{ "web_gui_transport", Transport } }) |pair| {
        const key = "\"" ++ pair[0] ++ "\":{\"type\":\"string\",\"enum\":[";
        const start = (std.mem.indexOf(u8, schema, key) orelse return error.MissingEnum) + key.len;
        const end = std.mem.indexOfPos(u8, schema, start, "]") orelse return error.MissingEnum;
        const listed = schema[start..end];
        var n: usize = 0;
        for (std.enums.values(pair[1])) |m| {
            const quoted = try std.fmt.allocPrint(t.allocator, "\"{s}\"", .{m.name()});
            defer t.allocator.free(quoted);
            try t.expect(std.mem.indexOf(u8, listed, quoted) != null);
            n += 1;
        }
        try t.expectEqual(n, std.mem.count(u8, listed, "\"") / 2);
    }
    try t.expect(std.mem.indexOf(u8, schema, "\"web_gui\":{\"type\":\"boolean\"") != null);
}
