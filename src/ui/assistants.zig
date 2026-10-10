//! Ambient visibility of running assistants: what every `sketerm mcp`
//! this window can reach is doing, watchable from here by default.
//!
//! One discovery home, two sources. The LOCAL MCP registry
//! (`ipc/mcp_registry.zig`, flock liveness) is watched with a
//! GFileMonitor plus a slow fallback tick, and each live instance's
//! private daemon is polled for its sessions on every tick. REMOTE
//! assistants come from the `assistants` report in the list reply of
//! every remote per-user daemon the window already talks to (a pane's or
//! app session's host; capability `assistants`, absent = none): polled
//! every `HOST_POLL_MS` over that pane's own session connection
//! (`Terminal.requestHostList`), never a dial of its own; the Session
//! Overview feeds its list replies in through `applyHostReport`. A
//! remote server is keyed by the route to its instance daemon (`sshroute.watchSpec`,
//! `route:A#key`), so two specs reaching one machine report it once,
//! and the local daemon's report is never read (the registry covers this
//! machine). A remote instance's OWN daemon is polled through its route
//! only while the popover is open (the Overview polls it itself while
//! open); otherwise its rows are the agents its report publishes. Each
//! agent's sessions attach where `watchSpec` says: the instance daemon,
//! or `route:A/B` for one placed on B.
//!
//! The result feeds four surfaces: the chip at the end of the tab bar
//! with its popover, the per-pane "AI attached" chip's click, the
//! Session Overview's assistant daemons and agent rows, and the agent
//! glance: each pane whose session an assistant runs in gets its
//! agents' tally (titlebar chip + popover, `agentbadge.zig`), each tab
//! the sum over its panes (`refreshGlances`, `ipc/agentglance.zig`).
//!
//! Disappearance is normal, not an error: an isolated instance's
//! daemon retires after 120 s idle and a web session has a 60 s
//! no-client TTL, so entries simply leave the roster. A remote
//! instance that died leaves with its host's next report; an attach
//! that still races it fails with the route's named refusal, as a toast.
//!
//! Lifetimes: heap row contexts are owned by their button (mechanism
//! 1, `GDestroyNotify`); the popover is unparented by the chip's own
//! destroy handler; every worker handback and timer resolves through
//! the `dead` fence, and `stop` frees the watcher only once the last
//! worker has reported.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const clock = @import("../util/clock.zig");
const mcp_registry = @import("../ipc/mcp_registry.zig");
const mux_client = @import("../mux/client.zig");
const sshroute = @import("../mux/sshroute.zig");
const mux_cli = @import("../ipc/mux_cli.zig");
const muxtabs = @import("muxtabs.zig");
const editorio = @import("editorio.zig");
const webwatch = @import("webwatch.zig");
const webpresence = @import("../web/webpresence.zig");
const sockpath = @import("../mux/sockpath.zig");
const strz = @import("../util/strz.zig");
const vocab = @import("../agent/vocab.zig");
const glance = @import("../ipc/agentglance.zig");
const agentbadge = @import("agentbadge.zig");
const a11y = @import("../a11y/atspi.zig");
const winmod = @import("window.zig");
const Window = winmod.Window;
const Pane = @import("pane.zig").Pane;
const Terminal = @import("../terminal.zig").Terminal;

/// Slow fallback for a registry change the monitor missed (no GIO
/// backend, a lost inotify event) and the roster refresh cadence.
const TICK_MS: c_uint = 3000;
/// `TICK_MS`, or the test hook `SKETERM_ASSISTANTS_TICK_MS=<ms>` (at
/// least 50), which lets a rig land ticks inside a window's teardown.
fn tickMs() c_uint {
    const raw = c.getenv("SKETERM_ASSISTANTS_TICK_MS") orelse return TICK_MS;
    const ms = std.fmt.parseInt(c_uint, std.mem.span(raw), 10) catch return TICK_MS;
    return @max(ms, 50);
}
/// Coalesces the CREATED + CHANGED + lock events one registration emits.
const RESCAN_DEBOUNCE_MS: c_uint = 150;
/// Bound on one daemon's `list` reply; past it the daemon reads as
/// unavailable until the next tick.
const LIST_TIMEOUT_MS: i64 = 5_000;
/// A remote daemon's assistants report, over a session connection to it.
const HOST_POLL_MS: i64 = 6_000;
/// A daemon without the `assistants` capability is asked again only
/// this rarely (it may be upgraded and restarted).
const HOST_UNSUPPORTED_MS: i64 = 120_000;

/// What a session on an assistant's daemon is, for the icon and the
/// aggregate label. Derived from the daemon's own facts, never from
/// the assistant.
pub const Kind = enum {
    web,
    app,
    terminal,

    /// Bundled icons (data/icons): theme icons such as
    /// utilities-terminal-symbolic sit in Adwaita's legacy set, which a
    /// Breeze theme chain never reaches, and rendered as placeholders.
    pub fn icon(self: Kind) [*:0]const u8 {
        return switch (self) {
            .web => "sketerm-web-symbolic",
            .app => "sketerm-app-symbolic",
            .terminal => "sketerm-terminal-symbolic",
        };
    }

    fn noun(self: Kind, plural: bool) []const u8 {
        return switch (self) {
            .web => if (plural) "browsers" else "browser",
            .app => if (plural) "apps" else "app",
            .terminal => if (plural) "terminals" else "terminal",
        };
    }
};

/// `webdrive` names its browser session `web-<pid>-<hex>` and it is an
/// app session; every other app session is a launched application.
pub fn kindOf(name: []const u8, app: bool) Kind {
    if (!app) return .terminal;
    if (std.mem.startsWith(u8, name, "web-")) return .web;
    return .app;
}

/// One sub-agent as the server's registry record publishes it.
pub const Agent = struct {
    id: []u8,
    /// The registry's app id (`claude`, `opencode`).
    app: []u8,
    sessions: [][]u8,
    /// Host spec its sessions attach at (`sshroute.watchSpec`).
    watch: []u8,
    /// Null = unknown (a server that predates publishing it).
    attention: ?vocab.Attention = null,
    state: ?vocab.State = null,

    fn deinit(self: *Agent, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.app);
        for (self.sessions) |s| allocator.free(s);
        allocator.free(self.sessions);
        allocator.free(self.watch);
    }
};

pub const Session = struct {
    name: []u8,
    title: []u8,
    origin_id: []u8,
    kind: Kind,
    viewers: u32,
    browser: webpresence.Metadata = .{},
    /// Attach host when the session is NOT on the assistant's own
    /// daemon (an agent placed on another host); null = `Assistant.host`.
    host: ?[]u8 = null,
    /// Index into the assistant's `agents` for a sub-agent's session.
    agent: ?u16 = null,

    fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.title);
        allocator.free(self.origin_id);
        if (self.host) |h| allocator.free(h);
    }

    pub fn attachHost(self: *const Session, a: *const Assistant) []const u8 {
        return self.host orelse a.host;
    }
};

/// One instance-daemon list poll, owned on the C heap like the worker
/// that produced it.
const Listing = struct {
    parsed: std.json.Parsed(mux_cli.Welcome),
    browsers: []webpresence.Metadata,

    fn deinit(self: *Listing) void {
        self.parsed.deinit();
        std.heap.c_allocator.free(self.browsers);
    }
};

/// How the last poll of an instance's own daemon went.
pub const Reach = enum {
    pending,
    ok,
    /// The server is live but its private daemon is not running: it
    /// retires after a while without sessions, which is normal.
    idle,
    /// Unreachable: no answer, or a refusal other than "not running".
    failed,
};

pub const Assistant = struct {
    pid: c.pid_t,
    mode: mcp_registry.Mode,
    /// Never empty: the registry's display name, else `mcp <pid>`; a
    /// remote one also says where (`tmp-12 on box`).
    name: []u8,
    /// Where it logs, or its profile; may be empty.
    detail: []u8,
    /// The host spec of its own daemon and its identity in the roster:
    /// `sock:<mux socket>` here, `route:<host>#<instance>` remotely.
    host: []u8,
    /// The host spec of the daemon whose report named it; null = the
    /// local registry.
    reached: ?[]u8 = null,
    /// The instance key (`route:...#key`); empty for a local one.
    instance: []const u8 = &.{},
    agents: std.ArrayList(Agent) = .empty,
    agents_fp: u64 = 0,
    /// The pane session it was started from and that session's daemon
    /// socket (on its own host); null = none, or a server or daemon
    /// too old to say (then no pane shows its agents).
    session: ?[]u8 = null,
    session_socket: ?[]u8 = null,
    /// The last poll of its own daemon; for a remote one only while a
    /// surface that shows it is open.
    listing: ?Listing = null,
    listing_fp: u64 = 0,
    /// Rows: its daemon's sessions plus its agents' sessions elsewhere.
    sessions: std.ArrayList(Session) = .empty,
    /// A worker thread owns the connection; polls are serialized.
    busy: bool = false,
    /// Idle persistent connection reused by every poll and handed to an
    /// attach, exactly like the Overview's per-daemon connection. Local
    /// only: a remote instance's idles in `editorio.pool`.
    conn: ?mux_client.Conn = null,
    reach: Reach = .pending,
    /// Why the last poll failed (a route names the refusing hop).
    why_buf: [160]u8 = undefined,
    why_len: usize = 0,
    /// Mark-and-sweep flag for a rescan or a host report.
    seen: bool = true,

    pub fn label(self: *const Assistant) []const u8 {
        return self.name;
    }

    /// Whether it has a session row to act on; the rest are listed apart.
    pub fn usable(self: *const Assistant) bool {
        return self.sessions.items.len > 0;
    }

    /// Why an instance without sessions has none, for people.
    pub fn absence(self: *const Assistant, buf: []u8) []const u8 {
        return switch (self.reach) {
            .failed => if (self.why().len > 0)
                std.fmt.bufPrint(buf, "unreachable: {s}", .{self.why()}) catch "unreachable"
            else
                "unreachable: its daemon did not answer",
            .idle => "idle: its daemon is not running (it stops after a while without sessions)",
            .pending, .ok => "no sessions yet",
        };
    }

    /// The browser `session` of this assistant as a watch target: through the reporting daemon when it is remote.
    pub fn watchTarget(self: *const Assistant, session: []const u8) webwatch.Target {
        if (self.reached) |reached| return .{ .remote = .{ .host = reached, .instance = self.instance, .session = session } };
        return .{ .local = .{ .mux_socket = self.host["sock:".len..], .session = session } };
    }

    pub fn why(self: *const Assistant) []const u8 {
        return self.why_buf[0..self.why_len];
    }

    fn noteFailure(self: *Assistant, text: []const u8) void {
        const n = @min(text.len, self.why_buf.len);
        @memcpy(self.why_buf[0..n], text[0..n]);
        self.why_len = n;
    }

    fn deinit(self: *Assistant, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.detail);
        allocator.free(self.host);
        if (self.reached) |r| allocator.free(r);
        allocator.free(self.instance);
        if (self.session) |v| allocator.free(v);
        if (self.session_socket) |v| allocator.free(v);
        self.clearAgents(allocator);
        self.agents.deinit(allocator);
        if (self.listing) |*l| l.deinit();
        self.clearSessions(allocator);
        self.sessions.deinit(allocator);
        if (self.conn) |*conn| conn.deinit();
    }

    pub fn origin(self: *const Assistant) glance.Origin {
        return .{ .reached = self.reached, .session = self.session, .session_socket = self.session_socket };
    }

    /// Record where the server was started. @return whether it changed.
    fn setOrigin(self: *Assistant, allocator: std.mem.Allocator, session: ?[]const u8, socket: ?[]const u8) bool {
        if (strEqOpt(self.session, session) and strEqOpt(self.session_socket, socket)) return false;
        const new_session = if (session) |v| allocator.dupe(u8, v) catch return false else null;
        const new_socket = if (socket) |v| allocator.dupe(u8, v) catch {
            if (new_session) |ns| allocator.free(ns);
            return false;
        } else null;
        if (self.session) |v| allocator.free(v);
        if (self.session_socket) |v| allocator.free(v);
        self.session = new_session;
        self.session_socket = new_socket;
        return true;
    }

    fn clearSessions(self: *Assistant, allocator: std.mem.Allocator) void {
        for (self.sessions.items) |*s| s.deinit(allocator);
        self.sessions.clearRetainingCapacity();
    }

    fn clearAgents(self: *Assistant, allocator: std.mem.Allocator) void {
        for (self.agents.items) |*ag| ag.deinit(allocator);
        self.agents.clearRetainingCapacity();
    }

    fn findSession(self: *Assistant, name: []const u8) ?*Session {
        for (self.sessions.items) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }

    /// The agent owning `session` at `host`, if any.
    fn agentAt(self: *const Assistant, host: []const u8, session: []const u8) ?u16 {
        for (self.agents.items, 0..) |ag, i| {
            if (!std.mem.eql(u8, ag.watch, host)) continue;
            for (ag.sessions) |s| if (std.mem.eql(u8, s, session)) return @intCast(i);
        }
        return null;
    }

    /// Replace the agents from a registry record or report (`null` =
    /// a server that predates publishing them). @return whether they changed.
    fn setAgents(self: *Assistant, allocator: std.mem.Allocator, src: ?[]const mcp_registry.Agent) bool {
        const fp = agentsFingerprint(src);
        if (fp == self.agents_fp) return false;
        self.clearAgents(allocator);
        self.agents_fp = fp;
        const local_socket = if (self.reached == null and std.mem.startsWith(u8, self.host, "sock:")) self.host["sock:".len..] else "";
        const list: []const mcp_registry.Agent = src orelse &.{};
        for (list) |ag| {
            self.appendAgent(allocator, ag, local_socket) catch {
                // Show what fit; a later record retries from scratch.
                self.agents_fp = 0;
                break;
            };
        }
        return true;
    }

    fn appendAgent(self: *Assistant, allocator: std.mem.Allocator, ag: mcp_registry.Agent, local_socket: []const u8) !void {
        if (self.agents.items.len >= std.math.maxInt(u16)) return;
        // An agent at a location this build cannot read, or one no
        // route can name, has nowhere to be watched: skip it.
        const where = sshroute.Location.parse(ag.location) orelse return;
        var buf: [512]u8 = undefined;
        const watch_src = sshroute.watchSpec(&buf, self.reached, self.instance, local_socket, where) catch return;
        const watch = try allocator.dupe(u8, watch_src);
        errdefer allocator.free(watch);
        const id = try allocator.dupe(u8, ag.id);
        errdefer allocator.free(id);
        const app = try allocator.dupe(u8, ag.app);
        errdefer allocator.free(app);
        const sessions = try allocator.alloc([]u8, ag.sessions.len);
        var n: usize = 0;
        errdefer {
            for (sessions[0..n]) |s| allocator.free(s);
            allocator.free(sessions);
        }
        for (ag.sessions) |s| {
            sessions[n] = try allocator.dupe(u8, s);
            n += 1;
        }
        try self.agents.append(allocator, .{
            .id = id,
            .app = app,
            .sessions = sessions,
            .watch = watch,
            .attention = ag.attentionOrState(),
            .state = ag.stateFact(),
        });
    }

    /// Rebuild the rows from the last listing and the agents: the
    /// listing's live sessions (an agent's labelled as such), then every
    /// agent session the listing cannot hold (placed elsewhere, or no
    /// listing yet). Out of memory leaves what fit.
    fn rebuildRows(self: *Assistant, allocator: std.mem.Allocator) void {
        self.clearSessions(allocator);
        if (self.listing) |*l| {
            for (l.parsed.value.sessions, 0..) |info, index| {
                if (info.exited) continue;
                const meta: webpresence.Metadata = if (index < l.browsers.len) l.browsers[index] else .{};
                self.appendRow(allocator, info.name, info.title, info.origin_id, kindOf(info.name, info.app), info.viewerCount(), meta, null, self.agentAt(self.host, info.name)) catch return;
            }
        }
        for (self.agents.items, 0..) |ag, i| {
            const own = std.mem.eql(u8, ag.watch, self.host);
            // A fresh listing of its own daemon is the truth there.
            if (own and self.listing != null) continue;
            for (ag.sessions) |s| {
                if (self.hasRow(s, if (own) null else ag.watch)) continue;
                self.appendRow(allocator, s, "", "", .terminal, 0, .{}, if (own) null else ag.watch, @intCast(i)) catch return;
            }
        }
    }

    fn hasRow(self: *const Assistant, name: []const u8, host: ?[]const u8) bool {
        for (self.sessions.items) |s| {
            if (std.mem.eql(u8, s.name, name) and strEqOpt(s.host, host)) return true;
        }
        return false;
    }

    fn appendRow(
        self: *Assistant,
        allocator: std.mem.Allocator,
        name_src: []const u8,
        title_src: []const u8,
        origin_src: []const u8,
        kind: Kind,
        viewers: u32,
        browser: webpresence.Metadata,
        host_src: ?[]const u8,
        agent: ?u16,
    ) !void {
        const name = try allocator.dupe(u8, name_src);
        errdefer allocator.free(name);
        const title = try allocator.dupe(u8, title_src);
        errdefer allocator.free(title);
        const origin_id = try allocator.dupe(u8, origin_src);
        errdefer allocator.free(origin_id);
        const host = if (host_src) |h| try allocator.dupe(u8, h) else null;
        errdefer if (host) |h| allocator.free(h);
        try self.sessions.append(allocator, .{
            .name = name,
            .title = title,
            .origin_id = origin_id,
            .kind = kind,
            .viewers = viewers,
            .browser = browser,
            .host = host,
            .agent = agent,
        });
    }
};

const strEqOpt = @import("../util/strz.zig").eqOpt;

fn agentsFingerprint(src: ?[]const mcp_registry.Agent) u64 {
    const agents = src orelse return 1;
    var hash: u64 = 2;
    for (agents) |ag| {
        hash = std.hash.Wyhash.hash(hash, ag.id);
        hash = std.hash.Wyhash.hash(hash, ag.app);
        hash = std.hash.Wyhash.hash(hash, ag.location);
        for (ag.sessions) |s| hash = std.hash.Wyhash.hash(hash, s);
        // Absent and empty must differ: an older server's agent is unknown.
        hash = std.hash.Wyhash.hash(hash, ag.attention orelse "\x00");
        hash = std.hash.Wyhash.hash(hash, ag.state orelse "\x00");
    }
    return hash;
}

/// Whether `host`'s list reply describes ANOTHER machine's registry.
pub const reportsRemote = glance.remotePerUser;

/// The machine a host spec reaches, for people: `box`, `b via a`, or
/// `this machine`; a route's instance is not a place.
pub fn placeLabel(buf: []u8, spec: []const u8) []const u8 {
    if (std.mem.startsWith(u8, spec, "sock:")) return "this machine";
    if (!sshroute.RouteSpec.isRoute(spec)) return sshroute.RemoteSpec.parse(spec).host;
    const r = sshroute.RouteSpec.parse(spec) catch return spec;
    const hops = r.hops();
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll(hops[hops.len - 1]) catch return spec;
    if (hops.len > 1) {
        w.writeAll(" via ") catch return spec;
        for (hops[0 .. hops.len - 1], 0..) |hop, i| {
            if (i > 0) w.writeByte('/') catch return spec;
            w.writeAll(hop) catch return spec;
        }
    }
    return w.buffered();
}

/// A sub-agent row's title: `claude-1 (claude)`, plus `on b via a` when
/// its sessions live on another machine than its server's daemon.
pub fn agentRowLabel(buf: []u8, id: []const u8, app: []const u8, elsewhere: ?[]const u8) []const u8 {
    var place_buf: [256]u8 = undefined;
    if (elsewhere) |spec| {
        return std.fmt.bufPrint(buf, "{s} ({s}) on {s}", .{ id, app, placeLabel(&place_buf, spec) }) catch id;
    }
    return std.fmt.bufPrint(buf, "{s} ({s})", .{ id, app }) catch id;
}

/// The title a roster row shows, shared by the popover and the Overview.
pub fn rowTitle(buf: []u8, a: *const Assistant, s: *const Session) []const u8 {
    if (s.agent) |i| {
        if (i < a.agents.items.len) {
            const ag = a.agents.items[i];
            return agentRowLabel(buf, ag.id, ag.app, s.host);
        }
    }
    if (s.kind == .web) return s.browser.title();
    return if (s.title.len > 0) s.title else s.name;
}

/// Fold remote daemon `host`'s `assistants` report into `roster`: add
/// new servers, refresh known ones, drop those `host` no longer reports
/// (busy ones wait for their worker). A server another host already
/// reported, i.e. the same derived instance route, stays that host's.
/// @return whether anything a surface shows changed.
pub fn mergeReport(allocator: std.mem.Allocator, roster: *std.ArrayList(Assistant), host: []const u8, reports: []const mcp_registry.Report) bool {
    var changed = false;
    for (roster.items) |*a| {
        if (a.reached) |r| if (std.mem.eql(u8, r, host)) {
            a.seen = false;
        };
    }
    for (reports) |rep| {
        var key_buf: [512]u8 = undefined;
        const key = sshroute.watchSpec(&key_buf, host, rep.instance, "", .instance) catch continue;
        if (findIn(roster.items, key)) |a| {
            const mine = if (a.reached) |r| std.mem.eql(u8, r, host) else false;
            if (!mine) continue;
            a.seen = true;
            if (refreshRemote(allocator, a, host, rep)) changed = true;
            continue;
        }
        addRemote(allocator, roster, host, key, rep) catch continue;
        changed = true;
    }
    var i: usize = 0;
    while (i < roster.items.len) {
        const a = &roster.items[i];
        const mine = if (a.reached) |r| std.mem.eql(u8, r, host) else false;
        if (!mine or a.seen or a.busy) {
            i += 1;
            continue;
        }
        var gone = roster.swapRemove(i);
        gone.deinit(allocator);
        changed = true;
    }
    return changed;
}

fn findIn(items: []Assistant, host: []const u8) ?*Assistant {
    for (items) |*a| if (std.mem.eql(u8, a.host, host)) return a;
    return null;
}

/// `<label> on <place>`; a server known only by its pid reads `mcp <pid>`,
/// exactly as a local one does.
fn remoteName(allocator: std.mem.Allocator, host: []const u8, rep: mcp_registry.Report) ![]u8 {
    var place_buf: [256]u8 = undefined;
    var pid_buf: [24]u8 = undefined;
    const pid_text = std.fmt.bufPrint(&pid_buf, "{d}", .{rep.pid}) catch "";
    const place = placeLabel(&place_buf, host);
    if (rep.label.len == 0 or std.mem.eql(u8, rep.label, pid_text)) {
        return std.fmt.allocPrint(allocator, "mcp {d} on {s}", .{ rep.pid, place });
    }
    return std.fmt.allocPrint(allocator, "{s} on {s}", .{ rep.label, place });
}

fn modeOf(text: []const u8) mcp_registry.Mode {
    return std.meta.stringToEnum(mcp_registry.Mode, text) orelse .isolated;
}

fn refreshRemote(allocator: std.mem.Allocator, a: *Assistant, host: []const u8, rep: mcp_registry.Report) bool {
    var changed = false;
    a.pid = rep.pid;
    a.mode = modeOf(rep.mode);
    if (a.setOrigin(allocator, rep.session, rep.session_socket)) changed = true;
    if (remoteName(allocator, host, rep)) |name| {
        if (std.mem.eql(u8, name, a.name)) allocator.free(name) else {
            allocator.free(a.name);
            a.name = name;
            changed = true;
        }
    } else |_| {}
    if (a.setAgents(allocator, rep.agents)) {
        a.rebuildRows(allocator);
        changed = true;
    }
    return changed;
}

fn addRemote(allocator: std.mem.Allocator, roster: *std.ArrayList(Assistant), host: []const u8, key: []const u8, rep: mcp_registry.Report) !void {
    const name = try remoteName(allocator, host, rep);
    errdefer allocator.free(name);
    const detail = try allocator.dupe(u8, "");
    errdefer allocator.free(detail);
    const own_host = try allocator.dupe(u8, key);
    errdefer allocator.free(own_host);
    const reached = try allocator.dupe(u8, host);
    errdefer allocator.free(reached);
    const instance = try allocator.dupe(u8, rep.instance);
    errdefer allocator.free(instance);
    try roster.append(allocator, .{
        .pid = rep.pid,
        .mode = modeOf(rep.mode),
        .name = name,
        .detail = detail,
        .host = own_host,
        .reached = reached,
        .instance = instance,
    });
    const a = &roster.items[roster.items.len - 1];
    _ = a.setOrigin(allocator, rep.session, rep.session_socket);
    _ = a.setAgents(allocator, rep.agents);
    a.rebuildRows(allocator);
}

/// Session counts by kind across every live assistant.
pub const Counts = struct {
    web: usize = 0,
    app: usize = 0,
    terminal: usize = 0,

    pub fn total(self: Counts) usize {
        return self.web + self.app + self.terminal;
    }

    pub fn add(self: *Counts, kind: Kind) void {
        switch (kind) {
            .web => self.web += 1,
            .app => self.app += 1,
            .terminal => self.terminal += 1,
        }
    }

    fn of(kind: Kind, counts: Counts) usize {
        return switch (kind) {
            .web => counts.web,
            .app => counts.app,
            .terminal => counts.terminal,
        };
    }

    /// `1 browser, 2 terminals` with zero kinds omitted; empty when
    /// nothing is running.
    pub fn describe(self: Counts, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        var first = true;
        inline for (.{ Kind.web, Kind.app, Kind.terminal }) |kind| {
            const n = of(kind, self);
            if (n > 0) {
                if (!first) w.writeAll(", ") catch return w.buffered();
                first = false;
                w.print("{d} {s}", .{ n, kind.noun(n != 1) }) catch return w.buffered();
            }
        }
        return w.buffered();
    }
};

pub fn summarize(roster: []const Assistant) Counts {
    var counts: Counts = .{};
    for (roster) |a| for (a.sessions.items) |s| counts.add(s.kind);
    return counts;
}

/// The tab-bar chip text: `AI: 1 browser, 2 terminals`; an assistant
/// with no sessions yet still counts as present.
pub fn chipLabel(buf: []u8, live: usize, counts: Counts) []const u8 {
    if (live == 0) return "";
    var desc_buf: [96]u8 = undefined;
    const desc = counts.describe(&desc_buf);
    if (desc.len == 0) {
        return std.fmt.bufPrint(buf, "AI: {d} idle", .{live}) catch "AI";
    }
    return std.fmt.bufPrint(buf, "AI: {s}", .{desc}) catch "AI";
}

/// An instance's one header line name: its label, plus its pid when
/// another instance in `roster` carries the same label (two servers
/// started with one `--log` directory read alike otherwise).
pub fn headerName(buf: []u8, roster: []const Assistant, a: *const Assistant) []const u8 {
    for (roster) |*other| {
        if (other == a or !std.mem.eql(u8, other.label(), a.label())) continue;
        return std.fmt.bufPrint(buf, "{s} (pid {d})", .{ a.label(), a.pid }) catch a.label();
    }
    return a.label();
}

/// The collapsed line for the instances without sessions:
/// `2 idle, 1 unreachable`; empty when every instance is usable.
pub fn restSummary(buf: []u8, roster: []const Assistant) []const u8 {
    var idle: usize = 0;
    var unreachable_n: usize = 0;
    for (roster) |*a| {
        if (a.usable()) continue;
        if (a.reach == .failed) unreachable_n += 1 else idle += 1;
    }
    var w: std.Io.Writer = .fixed(buf);
    if (idle > 0) w.print("{d} idle", .{idle}) catch return w.buffered();
    if (unreachable_n > 0) w.print("{s}{d} unreachable", .{ if (idle > 0) ", " else "", unreachable_n }) catch return w.buffered();
    return w.buffered();
}

/// An instance's tooltip: everything its one header line leaves out.
pub fn instanceTip(buf: []u8, a: *const Assistant) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var place_buf: [256]u8 = undefined;
    w.print("{s}\n{s} mode, pid {d}, on {s}", .{ a.label(), a.mode.text(), a.pid, placeLabel(&place_buf, a.reached orelse a.host) }) catch return w.buffered();
    if (a.detail.len > 0) w.print("\n{s}", .{a.detail}) catch return w.buffered();
    if (a.session) |session| w.print("\nstarted in session {s}", .{session}) catch return w.buffered();
    var why_buf: [224]u8 = undefined;
    if (!a.usable()) w.print("\n{s}", .{a.absence(&why_buf)}) catch return w.buffered();
    return w.buffered();
}

/// The tallest the popovers' scrolled list grows: about 60% of the window.
pub fn listCap(window_height: c_int) c_int {
    return if (window_height > 0) @divTrunc(window_height * 3, 5) else 480;
}

/// An action button's accessible name: its verb and the row it acts
/// on (`Watch claude-1 (claude)`), so a screen reader (and a rig) can
/// tell one row's Watch from the next.
pub fn accessibleName(buf: []u8, action: AttachAction, row: []const u8) [:0]const u8 {
    const text = std.mem.span(action.verb().text);
    if (row.len == 0) return std.fmt.bufPrintZ(buf, "{s}", .{text}) catch "";
    return std.fmt.bufPrintZ(buf, "{s} {s}", .{ text, row }) catch std.fmt.bufPrintZ(buf, "{s}", .{text}) catch "";
}

/// Icon and tooltip for each attach intent, shared by the tab-bar
/// popover and the Session Overview so the two never disagree. The
/// icons are bundled: the buttons are icon-only, so a theme without
/// them would leave empty buttons.
pub const AttachVerb = struct { icon: [*:0]const u8, tip: [*:0]const u8, text: [*:0]const u8 };

/// The attach actions a session row offers, in display order: the one
/// list the tab-bar popover and the Session Overview both iterate.
pub const AttachAction = enum {
    watch,
    control,
    /// Open or move a browser watch next to the selected pane.
    beside,

    pub fn lease(self: AttachAction) muxtabs.Lease {
        return switch (self) {
            .watch, .beside => .read_only,
            .control => .control,
        };
    }

    /// Whether a row of `kind` offers it: only a browser watch has a placement of its own.
    pub fn appliesTo(self: AttachAction, kind: Kind) bool {
        return self != .beside or kind == .web;
    }

    pub fn verb(self: AttachAction) AttachVerb {
        return switch (self) {
            .watch, .control => attachVerb(self.lease()),
            .beside => .{
                .icon = "sketerm-split-left-right-symbolic",
                .text = "Show beside pane",
                .tip = "Open or move this browser next to the selected pane. Starts read-only for a new viewer; keeps your current mode when moving.",
            },
        };
    }
};

pub fn attachVerb(lease: muxtabs.Lease) AttachVerb {
    return switch (lease) {
        .read_only => .{
            .icon = "sketerm-watch-symbolic",
            .tip = "View without sending keyboard or mouse input; also gives up control if you were controlling this session",
            .text = "Watch",
        },
        .control, .default => .{
            .icon = "sketerm-control-symbolic",
            .tip = "Use your keyboard and mouse in this session, for example to sign in",
            .text = "Take control",
        },
    };
}

/// A remote daemon whose `assistants` report this window reads.
const ReportHost = struct {
    spec: []u8,
    seen: bool = true,
    next_ms: i64 = 0,
    /// The `Terminal.hostList` reply number last read.
    list_seq: u32 = 0,
};

/// Window-level registry watcher plus the tab-bar chip it drives.
pub const Watcher = struct {
    win: *Window,
    allocator: std.mem.Allocator,
    roster: std.ArrayList(Assistant) = .empty,
    hosts: std.ArrayList(ReportHost) = .empty,
    monitor: ?*c.GFileMonitor = null,
    tick_id: c.guint = 0,
    rescan_id: c.guint = 0,
    pending_ops: usize = 0,
    dead: bool = false,
    chip: *c.GtkWidget,
    chip_label: *c.GtkWidget,
    popover: *c.GtkWidget,
    /// The assistant (by `Assistant.host`) a pane chip asked for;
    /// ordered first in the popover.
    preferred_buf: [512]u8 = undefined,
    preferred_len: usize = 0,
    /// The window's widgets are being disposed (`sever`, or the chip's
    /// own destroy): no label, popover, tooltip or tab may be touched
    /// again. `Window.deinit` (and so `stop`) runs on a LATER idle than
    /// the widget destroy chain, which is why this is a flag and not an
    /// ordering rule.
    widgets_dead: bool = false,

    /// Create the chip at the end of the window's tab bar and start
    /// watching. Null when the registry directory cannot exist or the
    /// chip cannot be built; the window then simply has no ambient
    /// assistant surface.
    pub fn start(win: *Window) ?*Watcher {
        const allocator = win.allocator;
        const self = allocator.create(Watcher) catch return null;
        const chip = c.gtk_button_new() orelse {
            allocator.destroy(self);
            return null;
        };
        const chip_label = c.gtk_label_new("").?;
        c.gtk_button_set_child(@ptrCast(chip), chip_label);
        c.gtk_widget_add_css_class(chip, "flat");
        c.gtk_widget_add_css_class(chip, "sketerm-assistant-chip");
        c.gtk_widget_set_valign(chip, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_can_focus(chip, 0);
        c.gtk_widget_set_visible(chip, 0);
        const popover = c.gtk_popover_new() orelse {
            _ = c.g_object_ref_sink(chip);
            c.g_object_unref(chip);
            allocator.destroy(self);
            return null;
        };
        c.gtk_widget_set_parent(popover, chip);
        c.gtk_popover_set_position(@ptrCast(popover), c.GTK_POS_BOTTOM);
        self.* = .{
            .win = win,
            .allocator = allocator,
            .chip = chip,
            .chip_label = chip_label,
            .popover = popover,
        };
        // The popover is a child of the chip and must be unparented in
        // the chip's dispose; a tiny context owned by that connection
        // (GDestroyNotify) does it whether the window or a theme swap
        // destroys the strip, without needing the watcher alive.
        const unparent = allocator.create(UnparentCtx) catch {
            c.gtk_widget_unparent(popover);
            _ = c.g_object_ref_sink(chip);
            c.g_object_unref(chip);
            allocator.destroy(self);
            return null;
        };
        unparent.* = .{ .allocator = allocator, .popover = popover, .watcher = self };
        _ = c.g_signal_connect_data(chip, "destroy", @ptrCast(&onChipDestroy), @ptrCast(unparent), @ptrCast(cast.destroyCtx(UnparentCtx)), c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(chip, "clicked", @ptrCast(&onChipClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        win.tabbar.appendEnd(chip);
        // Our own reference: `stop` runs from the deferred window free,
        // after the tab bar has disposed the chip, and the disconnect
        // there must target a live GObject, never a finalized one.
        _ = c.g_object_ref(@ptrCast(chip));
        self.arm();
        self.tick_id = c.g_timeout_add(tickMs(), @ptrCast(&onTick), @ptrCast(self));
        self.rescan();
        return self;
    }

    /// Stop every source that walks the window's widgets: called from
    /// `Window.beginDestroy`, since the struct lives on until the deferred
    /// window free while GTK disposes those widgets. The chip's own
    /// destroy cannot raise `widgets_dead` in time: our reference keeps
    /// the chip undisposed until `stop`.
    pub fn sever(self: *Watcher) void {
        self.widgets_dead = true;
        if (self.tick_id != 0) {
            _ = c.g_source_remove(self.tick_id);
            self.tick_id = 0;
        }
        if (self.rescan_id != 0) {
            _ = c.g_source_remove(self.rescan_id);
            self.rescan_id = 0;
        }
        self.disarm();
    }

    /// Stop watching. Widgets are left to the window's own teardown;
    /// the struct is freed once no worker can still report into it.
    pub fn stop(self: *Watcher) void {
        self.dead = true;
        self.sever();
        _ = c.g_signal_handlers_disconnect_matched(@ptrCast(self.chip), @intCast(c.G_SIGNAL_MATCH_DATA), 0, 0, null, null, @ptrCast(self));
        c.g_object_unref(@ptrCast(self.chip));
        self.freeRoster();
        if (self.pending_ops == 0) self.allocator.destroy(self);
    }

    fn freeRoster(self: *Watcher) void {
        for (self.roster.items) |*a| a.deinit(self.allocator);
        self.roster.deinit(self.allocator);
        self.roster = .empty;
        for (self.hosts.items) |h| self.allocator.free(h.spec);
        self.hosts.deinit(self.allocator);
        self.hosts = .empty;
    }

    fn opDone(self: *Watcher) bool {
        self.pending_ops -= 1;
        if (self.dead and self.pending_ops == 0) {
            self.allocator.destroy(self);
            return false;
        }
        return true;
    }

    fn arm(self: *Watcher) void {
        const dir = mcp_registry.ensureDir() catch return;
        var z: [4096:0]u8 = undefined;
        const path = std.fmt.bufPrintZ(&z, "{s}", .{dir}) catch return;
        const file = c.g_file_new_for_path(path.ptr) orelse return;
        defer c.g_object_unref(@ptrCast(file));
        const mon = c.g_file_monitor_directory(file, c.G_FILE_MONITOR_NONE, null, null) orelse return;
        self.monitor = mon;
        _ = c.g_signal_connect_data(@ptrCast(mon), "changed", @ptrCast(&onDirChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    }

    fn disarm(self: *Watcher) void {
        const mon = self.monitor orelse return;
        _ = c.g_signal_handlers_disconnect_matched(@ptrCast(mon), @intCast(c.G_SIGNAL_MATCH_DATA), 0, 0, null, null, @ptrCast(self));
        _ = c.g_file_monitor_cancel(mon);
        c.g_object_unref(@ptrCast(mon));
        self.monitor = null;
    }

    fn findByPid(self: *Watcher, pid: c.pid_t) ?*Assistant {
        for (self.roster.items) |*a| if (a.reached == null and a.pid == pid) return a;
        return null;
    }

    pub fn findByHost(self: *Watcher, host: []const u8) ?*Assistant {
        return findIn(self.roster.items, host);
    }

    /// The roster row an attachment at `host` of `session` is, if any:
    /// the assistant's own daemon or an agent's session elsewhere.
    pub fn findRow(self: *Watcher, host: []const u8, session: []const u8) ?struct { a: *Assistant, s: *Session } {
        for (self.roster.items) |*a| {
            for (a.sessions.items) |*s| {
                if (std.mem.eql(u8, s.name, session) and std.mem.eql(u8, s.attachHost(a), host)) return .{ .a = a, .s = s };
            }
        }
        return null;
    }

    fn surfaceOpen(self: *Watcher) bool {
        return !self.widgets_dead and c.gtk_widget_get_visible(self.popover) != 0;
    }

    /// Re-list the registry: add newcomers, drop the departed, refresh
    /// the remote hosts' reports, then poll every idle daemon whose
    /// sessions a surface needs.
    fn rescan(self: *Watcher) void {
        if (self.dead) return;
        // Past `beginDestroy` GTK is disposing the window's widgets, and a
        // rescan walks them (`refreshTabGlances`): `sever` must have
        // stopped every source that leads here.
        if (self.win.destroying and c.getenv("SKETERM_VERIFY_WINDOW_TEARDOWN") != null) {
            std.debug.print("sketerm: assistants watcher rescanned a destroying window\n", .{});
            c.abort();
        }
        var changed = false;
        if (mcp_registry.list(self.allocator, true)) |entries| {
            defer mcp_registry.freeEntries(self.allocator, entries);
            if (self.applyRegistry(entries)) changed = true;
        } else |_| {}
        self.pollHosts();
        const open_now = self.surfaceOpen();
        for (self.roster.items) |*a| {
            if (a.reached == null or open_now) {
                self.startFetch(a);
            } else if (a.listing != null and !a.busy) {
                // Nothing shows its daemon's sessions any more: fall back
                // to what the report publishes rather than keep a stale view.
                a.listing.?.deinit();
                a.listing = null;
                a.listing_fp = 0;
                a.rebuildRows(self.allocator);
                changed = true;
            }
        }
        // Every tick, changed or not: a pane opened since the last one
        // needs its tally, and an unchanged one costs no widget work.
        if (changed) self.refreshChip() else self.refreshGlances();
    }

    fn applyRegistry(self: *Watcher, entries: []const mcp_registry.Entry) bool {
        var changed = false;
        for (self.roster.items) |*a| {
            if (a.reached == null) a.seen = false;
        }
        for (entries) |entry| {
            if (self.findByPid(entry.pid)) |a| {
                a.seen = true;
                if (a.setOrigin(self.allocator, entry.session, entry.session_socket)) changed = true;
                if (a.setAgents(self.allocator, entry.agents)) {
                    a.rebuildRows(self.allocator);
                    changed = true;
                }
                continue;
            }
            if (self.addAssistant(entry)) changed = true;
        }
        var i: usize = 0;
        while (i < self.roster.items.len) {
            const a = &self.roster.items[i];
            if (a.reached != null or a.seen or a.busy) {
                i += 1;
                continue;
            }
            var gone = self.roster.swapRemove(i);
            gone.deinit(self.allocator);
            changed = true;
        }
        return changed;
    }

    fn addAssistant(self: *Watcher, entry: mcp_registry.Entry) bool {
        self.addAssistantOrError(entry) catch return false;
        return true;
    }

    fn addAssistantOrError(self: *Watcher, entry: mcp_registry.Entry) !void {
        const allocator = self.allocator;
        var name_buf: [48]u8 = undefined;
        const shown = entry.displayName();
        const name_src = if (shown.len > 0) shown else std.fmt.bufPrint(&name_buf, "mcp {d}", .{entry.pid}) catch "mcp";
        const name = try allocator.dupe(u8, name_src);
        errdefer allocator.free(name);
        const detail_src = if (entry.log_dir.len > 0) entry.log_dir else entry.profile;
        const detail = try allocator.dupe(u8, detail_src);
        errdefer allocator.free(detail);
        const host = try std.fmt.allocPrint(allocator, "sock:{s}", .{entry.mux_socket});
        errdefer allocator.free(host);
        try self.roster.append(allocator, .{
            .pid = entry.pid,
            .mode = entry.mode,
            .name = name,
            .detail = detail,
            .host = host,
        });
        const a = &self.roster.items[self.roster.items.len - 1];
        _ = a.setOrigin(allocator, entry.session, entry.session_socket);
        _ = a.setAgents(allocator, entry.agents);
        a.rebuildRows(allocator);
    }

    // ── remote reports ──────────────────────────────────────────

    fn findHost(self: *Watcher, spec: []const u8) ?*ReportHost {
        for (self.hosts.items) |*h| if (std.mem.eql(u8, h.spec, spec)) return h;
        return null;
    }

    fn noteHost(self: *Watcher, spec: ?[]const u8) void {
        if (!reportsRemote(spec)) return;
        if (self.findHost(spec.?)) |h| {
            h.seen = true;
            return;
        }
        const owned = self.allocator.dupe(u8, spec.?) catch return;
        self.hosts.append(self.allocator, .{ .spec = owned }) catch self.allocator.free(owned);
    }

    /// Track every remote daemon a pane or app session talks to, drop
    /// the hosts (and their assistants) the window left, and poll the
    /// due ones over a session connection that host already carries.
    fn pollHosts(self: *Watcher) void {
        for (self.hosts.items) |*h| h.seen = false;
        for (self.win.panes.items) |pane| {
            const remote = pane.terminal.remote orelse continue;
            self.noteHost(remote.host);
        }
        for (self.win.app_sessions.items) |as| {
            const remote = as.terminal.remote orelse continue;
            self.noteHost(remote.host);
        }
        var i: usize = 0;
        while (i < self.hosts.items.len) {
            const h = &self.hosts.items[i];
            if (h.seen) {
                i += 1;
                continue;
            }
            _ = mergeReport(self.allocator, &self.roster, h.spec, &.{});
            self.allocator.free(h.spec);
            _ = self.hosts.swapRemove(i);
        }
        const now = clock.nowMs();
        for (self.hosts.items) |*h| {
            const term = self.hostTerminal(h.spec) orelse continue;
            if (term.hostList(h.list_seq)) |reply| {
                h.list_seq = reply.seq;
                self.applyListReply(h.spec, reply.payload);
            }
            if (now < h.next_ms) continue;
            if (!term.remote.?.conn.caps.assistants) {
                // An older daemon says nothing about assistants: none known.
                h.next_ms = now + HOST_UNSUPPORTED_MS;
                if (mergeReport(self.allocator, &self.roster, h.spec, &.{})) self.refreshChip();
                continue;
            }
            if (term.requestHostList()) h.next_ms = now + HOST_POLL_MS;
        }
    }

    /// A live session connection to `spec`, which its pane or app session
    /// already holds: the report rides it instead of a dial of its own.
    fn hostTerminal(self: *Watcher, spec: []const u8) ?*Terminal {
        for (self.win.panes.items) |pane| {
            if (liveOn(pane.terminal, spec)) return pane.terminal;
        }
        for (self.win.app_sessions.items) |as| {
            if (liveOn(as.terminal, spec)) return as.terminal;
        }
        return null;
    }

    fn liveOn(term: *Terminal, spec: []const u8) bool {
        const remote = term.remote orelse return false;
        const host = remote.host orelse return false;
        return remote.canSend() and std.mem.eql(u8, host, spec);
    }

    fn applyListReply(self: *Watcher, spec: []const u8, payload: []const u8) void {
        const parsed = std.json.parseFromSlice(ReportListing, self.allocator, payload, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return;
        defer parsed.deinit();
        self.applyHostReport(spec, parsed.value.assistants);
    }

    /// A list reply from `host` that someone (this watcher or the
    /// Session Overview) already fetched over a connection advertising
    /// `assistants`. Hosts the window does not track are ignored.
    pub fn applyHostReport(self: *Watcher, host: ?[]const u8, reports: []const mcp_registry.Report) void {
        if (self.dead) return;
        const spec = host orelse return;
        const h = self.findHost(spec) orelse return;
        h.next_ms = clock.nowMs() + HOST_POLL_MS;
        if (mergeReport(self.allocator, &self.roster, spec, reports)) self.refreshChip();
    }

    // ── surfaces ────────────────────────────────────────────────

    /// Paint the chip from the roster. Hidden while nothing is live.
    fn refreshChip(self: *Watcher) void {
        if (self.dead or self.widgets_dead) return;
        self.refreshGlances();
        var buf: [128:0]u8 = undefined;
        const text = chipLabel(buf[0 .. buf.len - 1], self.roster.items.len, summarize(self.roster.items));
        if (text.len == 0) {
            c.gtk_widget_set_visible(self.chip, 0);
            if (c.gtk_widget_get_visible(self.popover) != 0) c.gtk_popover_popdown(@ptrCast(self.popover));
            return;
        }
        buf[text.len] = 0;
        c.gtk_label_set_text(@ptrCast(self.chip_label), buf[0..text.len :0].ptr);
        var tip: [1024:0]u8 = undefined;
        var w: std.Io.Writer = .fixed(tip[0 .. tip.len - 1]);
        for (self.roster.items) |a| {
            var counts: Counts = .{};
            for (a.sessions.items) |s| counts.add(s.kind);
            var desc_buf: [96]u8 = undefined;
            const desc = counts.describe(&desc_buf);
            w.print("{s}: {s}{s}\n", .{ a.label(), if (desc.len > 0) desc else "idle", if (a.reach == .failed) " (unreachable)" else "" }) catch break;
        }
        const n = w.buffered().len;
        tip[n] = 0;
        c.gtk_widget_set_tooltip_text(self.chip, tip[0..n :0].ptr);
        c.gtk_widget_set_visible(self.chip, 1);
        if (c.gtk_widget_get_visible(self.popover) != 0) self.buildPopover();
    }

    // ── agent glance (pane chips, tab badges) ──────────────────

    /// Hand every pane its session's agent tally and every tab the sum
    /// over its panes; only a changed tally or badge touches a widget.
    fn refreshGlances(self: *Watcher) void {
        if (self.dead or self.widgets_dead) return;
        var sock_buf: [640]u8 = undefined;
        const default_socket = defaultSocket(&sock_buf);
        for (self.win.panes.items) |pane| pane.setAgentTally(self.tallyFor(pane, default_socket));
        self.refreshTabGlances();
    }

    fn refreshTabGlances(self: *Watcher) void {
        var leaves: std.ArrayList(*Pane) = .empty;
        defer leaves.deinit(self.allocator);
        const n = c.adw_tab_view_get_n_pages(self.win.tab_view);
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const page = c.adw_tab_view_get_nth_page(self.win.tab_view, i) orelse continue;
            const tree = Window.tabTreeOf(page) orelse continue;
            leaves.clearRetainingCapacity();
            tree.appendLeaves(self.allocator, &leaves) catch continue;
            var total: glance.Tally = .{};
            for (leaves.items, 0..) |pane, k| {
                // Two panes viewing one session show its agents once.
                if (viewsSameSession(leaves.items[0..k], pane)) continue;
                total.merge(pane.agent_tally);
            }
            if (agentbadge.setPageGlance(page, .of(total))) {
                self.win.tabbar.refreshAgents(page);
                if (self.win.tab_sidebar) |sb| sb.refreshAgents(page);
            }
        }
    }

    /// The agents of every server running in `pane`'s session.
    fn tallyFor(self: *Watcher, pane: *Pane, default_socket: []const u8) glance.Tally {
        const at = paneSession(pane) orelse return .{};
        var tally: glance.Tally = .{};
        for (self.roster.items) |*a| {
            if (!glance.runsIn(a.origin(), at, default_socket)) continue;
            for (a.agents.items) |ag| tally.add(ag.attention);
        }
        return tally;
    }

    /// Fill a pane's agents popover: each server running in its session
    /// as one header line, its agents as session rows, and the way to
    /// the whole roster.
    fn buildPaneAgents(self: *Watcher, pane: *Pane, popover: *c.GtkWidget) void {
        if (self.dead or self.widgets_dead) return;
        const pop: *c.GtkPopover = @ptrCast(popover);
        c.gtk_popover_set_child(pop, null);
        const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4).?;
        setMargins(root, 6);
        const head = c.gtk_label_new("Agents of this pane").?;
        c.gtk_label_set_xalign(@ptrCast(head), 0);
        c.gtk_widget_add_css_class(head, "heading");
        c.gtk_box_append(@ptrCast(root), head);
        const content = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2).?;
        var sock_buf: [640]u8 = undefined;
        const default_socket = defaultSocket(&sock_buf);
        var rows: usize = 0;
        var first_key: []const u8 = "";
        if (paneSession(pane)) |at| {
            for (self.roster.items) |*a| {
                if (!glance.runsIn(a.origin(), at, default_socket)) continue;
                if (first_key.len == 0) first_key = a.host;
                self.appendHeader(content, a);
                const list = newSessionList();
                for (a.agents.items, 0..) |*ag, i| {
                    self.appendAgentRow(list, a, ag, @intCast(i));
                    rows += 1;
                }
                c.gtk_box_append(@ptrCast(content), list);
            }
        }
        if (rows == 0) {
            const none = c.gtk_label_new("No agents are running in this session.").?;
            c.gtk_label_set_xalign(@ptrCast(none), 0);
            c.gtk_widget_add_css_class(none, "dim-label");
            c.gtk_box_append(@ptrCast(content), none);
        }
        const sw = self.scroller(content);
        c.gtk_box_append(@ptrCast(root), sw);
        c.gtk_box_append(@ptrCast(root), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL).?);
        const foot = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8).?;
        const all = c.gtk_button_new_with_label("All assistants and agents").?;
        c.gtk_widget_add_css_class(all, "flat");
        c.gtk_widget_set_hexpand(all, 1);
        c.gtk_widget_set_halign(all, c.GTK_ALIGN_START);
        if (RosterCtx.create(self.allocator, self, popover, first_key)) |ctx| {
            _ = c.g_signal_connect_data(all, "clicked", @ptrCast(&onRosterClicked), @ptrCast(ctx), @ptrCast(cast.destroyCtx(RosterCtx)), c.G_CONNECT_DEFAULT);
        }
        c.gtk_box_append(@ptrCast(foot), all);
        const note = c.gtk_label_new("Watching never sends input").?;
        c.gtk_widget_set_valign(note, c.GTK_ALIGN_CENTER);
        c.gtk_widget_add_css_class(note, "dim-label");
        c.gtk_widget_add_css_class(note, "caption");
        c.gtk_box_append(@ptrCast(foot), note);
        c.gtk_box_append(@ptrCast(root), foot);
        c.gtk_popover_set_child(pop, root);
        fitScroller(sw);
    }

    /// One agent as a session row: its state glyph, `id on place`, its
    /// attention as the chip's own pill (palette colours, so it reads on
    /// any theme), and the actions of its first session (its app;
    /// opencode's server is the second).
    fn appendAgentRow(self: *Watcher, list: *c.GtkWidget, a: *Assistant, ag: *const Agent, index: u16) void {
        const glyph = agentbadge.newGlyph(ag.attention, .theme);
        c.gtk_widget_set_size_request(glyph, 16, 16);
        var place_buf: [256]u8 = undefined;
        var title_buf: [400]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "{s} on {s}", .{ ag.id, placeLabel(&place_buf, ag.watch) }) catch ag.id;
        var status_buf: [64:0]u8 = undefined;
        const status = statusText(&status_buf, ag.attention);
        var first: ?*Session = null;
        for (a.sessions.items) |*s| {
            if (s.agent != index) continue;
            first = s;
            break;
        }
        self.appendSessionRow(list, glyph, title, .{ .pill = .{ .text = status, .attention = ag.attention } }, null, a, first);
    }

    fn preferred(self: *const Watcher) []const u8 {
        return self.preferred_buf[0..self.preferred_len];
    }

    /// Open the popover, ordering the assistant whose host is
    /// `preferred` first. Falls back to the Session Overview when the
    /// tab bar (and so the chip) is hidden.
    pub fn open(self: *Watcher, preferred_host: []const u8) void {
        if (self.dead or self.widgets_dead) return;
        const n = @min(preferred_host.len, self.preferred_buf.len);
        @memcpy(self.preferred_buf[0..n], preferred_host[0..n]);
        self.preferred_len = n;
        if (c.gtk_widget_get_mapped(self.chip) == 0) {
            @import("app_switcher.zig").open(self.win);
            return;
        }
        self.buildPopover();
        c.gtk_popover_popup(@ptrCast(self.popover));
        // Remote instances are listed only while this is open: start now
        // rather than on the next tick.
        for (self.roster.items) |*a| if (a.reached != null) self.startFetch(a);
    }

    /// The badge popover: usable instances first (the preferred one at
    /// the top), each a header line over its session rows; the rest as
    /// one collapsed line at the bottom; all inside the capped scroller.
    fn buildPopover(self: *Watcher) void {
        const pop: *c.GtkPopover = @ptrCast(self.popover);
        c.gtk_popover_set_child(pop, null);
        const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 8).?;
        setMargins(root, 6);
        const content = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 10).?;
        const first = self.findByHost(self.preferred());
        if (first) |a| if (a.usable()) self.appendAssistant(content, a);
        for (self.roster.items) |*a| {
            if (first == a or !a.usable()) continue;
            self.appendAssistant(content, a);
        }
        const rest = self.appendRest(content);
        if (self.roster.items.len == 0) {
            const none = c.gtk_label_new("No assistant is running.").?;
            c.gtk_widget_add_css_class(none, "dim-label");
            c.gtk_box_append(@ptrCast(content), none);
        }
        const sw = self.scroller(content);
        c.gtk_box_append(@ptrCast(root), sw);
        // Expanding the rest grows the list without a rebuild.
        if (rest) |expander| _ = c.g_signal_connect_data(expander, "notify::expanded", @ptrCast(&onRestExpanded), @ptrCast(sw), null, c.G_CONNECT_DEFAULT);
        if (summarize(self.roster.items).web != 0) {
            const help = c.gtk_label_new("Watch is read-only. Take control to type or sign in.\nFor side by side, select a destination pane first.").?;
            c.gtk_label_set_xalign(@ptrCast(help), 0);
            c.gtk_label_set_wrap(@ptrCast(help), 1);
            c.gtk_label_set_max_width_chars(@ptrCast(help), 44);
            c.gtk_widget_add_css_class(help, "dim-label");
            c.gtk_widget_add_css_class(help, "caption");
            c.gtk_box_append(@ptrCast(root), help);
        }
        c.gtk_popover_set_child(pop, root);
        fitScroller(sw);
    }

    /// The scrolled area both popovers list into: natural size up to
    /// `listCap` of the window's height, so a long roster scrolls
    /// instead of running off screen.
    fn scroller(self: *Watcher, child: *c.GtkWidget) *c.GtkWidget {
        const sw = c.gtk_scrolled_window_new().?;
        c.gtk_scrolled_window_set_policy(@ptrCast(sw), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(sw), 1);
        c.gtk_scrolled_window_set_propagate_natural_width(@ptrCast(sw), 1);
        c.gtk_scrolled_window_set_max_content_height(@ptrCast(sw), listCap(c.gtk_widget_get_height(self.win.app_window)));
        c.gtk_scrolled_window_set_child(@ptrCast(sw), child);
        return sw;
    }

    fn appendAssistant(self: *Watcher, content: *c.GtkWidget, a: *Assistant) void {
        const section = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2).?;
        self.appendHeader(section, a);
        const list = newSessionList();
        for (a.sessions.items) |*s| {
            const icon = c.gtk_image_new_from_icon_name(s.kind.icon()).?;
            var title_buf: [320]u8 = undefined;
            const title = rowTitle(&title_buf, a, s);
            var tip_buf: [400]u8 = undefined;
            const tip = if (s.kind == .web)
                s.browser.title()
            else
                std.fmt.bufPrint(&tip_buf, "{s} ({s}) at {s}, {d} viewer(s)", .{ s.name, @tagName(s.kind), s.attachHost(a), s.viewers }) catch s.name;
            const sub: RowSubtitle = if (s.kind == .web) .{ .text = s.browser.subtitle() } else .none;
            self.appendSessionRow(list, icon, title, sub, tip, a, s);
        }
        c.gtk_box_append(@ptrCast(section), list);
        c.gtk_box_append(@ptrCast(content), section);
    }

    /// An instance's one header line: its name, what it runs, and its
    /// mode only when that is not the default; the rest is the tooltip.
    fn appendHeader(self: *Watcher, box: *c.GtkWidget, a: *const Assistant) void {
        const line = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8).?;
        var name_buf: [320]u8 = undefined;
        var name_z: [320:0]u8 = undefined;
        const name = headingLabel(strz.copyZ(&name_z, headerName(&name_buf, self.roster.items, a)));
        c.gtk_label_set_xalign(@ptrCast(name), 0);
        c.gtk_label_set_ellipsize(@ptrCast(name), c.PANGO_ELLIPSIZE_END);
        c.gtk_widget_add_css_class(name, "heading");
        c.gtk_box_append(@ptrCast(line), name);
        var counts: Counts = .{};
        for (a.sessions.items) |s| counts.add(s.kind);
        var desc_buf: [96]u8 = undefined;
        const desc = counts.describe(&desc_buf);
        var facts_z: [160:0]u8 = undefined;
        const facts = std.fmt.bufPrintZ(&facts_z, "{s}{s}{s}", .{
            if (desc.len > 0) desc else "no sessions",
            if (a.mode.isDefault()) "" else ", ",
            if (a.mode.isDefault()) "" else a.mode.text(),
        }) catch "";
        const facts_label = c.gtk_label_new(facts.ptr).?;
        c.gtk_label_set_xalign(@ptrCast(facts_label), 0);
        c.gtk_widget_set_hexpand(facts_label, 1);
        c.gtk_widget_add_css_class(facts_label, "dim-label");
        c.gtk_widget_add_css_class(facts_label, "caption");
        c.gtk_box_append(@ptrCast(line), facts_label);
        var tip_buf: [1024]u8 = undefined;
        var tip_z: [1024:0]u8 = undefined;
        c.gtk_widget_set_tooltip_text(line, strz.copyZ(&tip_z, instanceTip(&tip_buf, a)));
        c.gtk_box_append(@ptrCast(box), line);
    }

    /// The instances without sessions (idle or unreachable) as ONE
    /// collapsed line; expanded, a name per instance, the reason in its
    /// tooltip. Never `error` styling: nothing here needs the reader.
    fn appendRest(self: *Watcher, content: *c.GtkWidget) ?*c.GtkWidget {
        var sum_buf: [64]u8 = undefined;
        var sum_z: [64:0]u8 = undefined;
        const summary = restSummary(&sum_buf, self.roster.items);
        if (summary.len == 0) return null;
        const expander = c.gtk_expander_new(strz.copyZ(&sum_z, summary)).?;
        c.gtk_widget_add_css_class(expander, "dim-label");
        const inner = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2).?;
        c.gtk_widget_set_margin_start(inner, 18);
        for (self.roster.items) |*a| {
            if (a.usable()) continue;
            var name_buf: [320]u8 = undefined;
            var name_z: [320:0]u8 = undefined;
            const name = c.gtk_label_new(strz.copyZ(&name_z, headerName(&name_buf, self.roster.items, a))).?;
            c.gtk_label_set_xalign(@ptrCast(name), 0);
            c.gtk_label_set_ellipsize(@ptrCast(name), c.PANGO_ELLIPSIZE_END);
            c.gtk_widget_add_css_class(name, "caption");
            var tip_buf: [1024]u8 = undefined;
            var tip_z: [1024:0]u8 = undefined;
            c.gtk_widget_set_tooltip_text(name, strz.copyZ(&tip_z, instanceTip(&tip_buf, a)));
            c.gtk_box_append(@ptrCast(inner), name);
        }
        c.gtk_expander_set_child(@ptrCast(expander), inner);
        c.gtk_box_append(@ptrCast(content), expander);
        return expander;
    }

    /// The one session row layout every popover uses: icon, title and
    /// subtitle, then the icon-only actions that apply; activating the
    /// row itself is Watch. `s` null = nothing to attach (no buttons).
    fn appendSessionRow(self: *Watcher, list: *c.GtkWidget, icon: *c.GtkWidget, title: []const u8, sub: RowSubtitle, tip: ?[]const u8, a: *Assistant, s: ?*Session) void {
        const body = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8).?;
        c.gtk_widget_set_margin_top(body, 3);
        c.gtk_widget_set_margin_bottom(body, 3);
        c.gtk_widget_set_valign(icon, c.GTK_ALIGN_CENTER);
        c.gtk_box_append(@ptrCast(body), icon);
        const text = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 1).?;
        c.gtk_widget_set_hexpand(text, 1);
        c.gtk_widget_set_valign(text, c.GTK_ALIGN_CENTER);
        var title_z: [400:0]u8 = undefined;
        const title_label = c.gtk_label_new(strz.copyZ(&title_z, title)).?;
        c.gtk_label_set_xalign(@ptrCast(title_label), 0);
        c.gtk_label_set_ellipsize(@ptrCast(title_label), c.PANGO_ELLIPSIZE_END);
        c.gtk_label_set_max_width_chars(@ptrCast(title_label), 36);
        c.gtk_box_append(@ptrCast(text), title_label);
        switch (sub) {
            .none => {},
            .text => |line| {
                var sub_z: [320:0]u8 = undefined;
                const label = c.gtk_label_new(strz.copyZ(&sub_z, line)).?;
                c.gtk_label_set_xalign(@ptrCast(label), 0);
                c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
                c.gtk_label_set_max_width_chars(@ptrCast(label), 36);
                c.gtk_widget_add_css_class(label, "dim-label");
                c.gtk_widget_add_css_class(label, "caption");
                c.gtk_box_append(@ptrCast(text), label);
            },
            .pill => |p| {
                const label = c.gtk_label_new(p.text.ptr).?;
                c.gtk_widget_set_halign(label, c.GTK_ALIGN_START);
                c.gtk_widget_add_css_class(label, "caption");
                c.gtk_widget_add_css_class(label, "sketerm-agents-pill");
                c.gtk_widget_add_css_class(label, agentbadge.attentionClass(p.attention));
                agentbadge.installCss(label);
                c.gtk_box_append(@ptrCast(text), label);
            },
        }
        c.gtk_box_append(@ptrCast(body), text);
        const row = c.gtk_list_box_row_new().?;
        c.gtk_list_box_row_set_child(@ptrCast(row), body);
        if (tip) |words| {
            var tip_z: [400:0]u8 = undefined;
            c.gtk_widget_set_tooltip_text(text, strz.copyZ(&tip_z, words));
        }
        var watchable = false;
        if (s) |session| {
            watchable = self.appendAttachButtons(body, a, session, title);
            if (watchable) {
                if (RowCtx.create(self.allocator, self, a.host, session.name, session.attachHost(a), .watch)) |ctx| {
                    c.g_object_set_data_full(@ptrCast(row), ROW_ATTACH_KEY, @ptrCast(ctx), &destroyRowCtx);
                } else watchable = false;
            }
        }
        c.gtk_list_box_row_set_activatable(@ptrCast(row), @intFromBool(watchable));
        c.gtk_list_box_append(@ptrCast(list), row);
    }

    /// Whether `action` may run on row `s`: browser actions focus,
    /// escalate or relocate the existing watch; other session kinds keep
    /// their attachment policy.
    fn actionSensitive(self: *Watcher, a: *Assistant, s: *Session, action: AttachAction) bool {
        if (s.kind == .web) return true;
        return switch (self.win.sessionPlacement(s.name, s.attachHost(a))) {
            .none => true,
            .tabless => action.lease() == .control,
            .pane => false,
        };
    }

    /// The `AttachAction`s that apply to one row, icon-only, each owning
    /// its `RowCtx`. @return whether Watch is available on it.
    fn appendAttachButtons(self: *Watcher, controls: *c.GtkWidget, a: *Assistant, s: *Session, row_title: []const u8) bool {
        var watchable = false;
        for (std.enums.values(AttachAction)) |action| {
            if (!action.appliesTo(s.kind)) continue;
            const sensitive = self.actionSensitive(a, s, action);
            if (action == .watch) watchable = sensitive;
            const btn = attachButton(action, row_title);
            c.gtk_widget_set_sensitive(btn, @intFromBool(sensitive));
            const ctx = RowCtx.create(self.allocator, self, a.host, s.name, s.attachHost(a), action) orelse continue;
            _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onRowClicked), @ptrCast(ctx), @ptrCast(&freeRowCtx), c.G_CONNECT_DEFAULT);
            c.gtk_box_append(@ptrCast(controls), btn);
        }
        return watchable;
    }

    /// Attach `session` of the assistant keyed `key` (at `attach_host`)
    /// into this window as `action`, off-thread; the popover closes
    /// when the attach lands, and a failure is a toast naming why.
    fn startAttach(self: *Watcher, key: []const u8, session: []const u8, attach_host: []const u8, action: AttachAction) void {
        if (self.dead) return;
        const a = self.findByHost(key) orelse return;
        const lease = action.lease();
        // The assistant's browser opens as a browser: a second client
        // of its own helper, its pages as web pages (webwatch.zig).
        // The mux app session behind it is never attached from here.
        if (kindOf(session, true) == .web) {
            const row = a.findSession(session) orelse return;
            const label = if (a.reached != null) a.label() else row.browser.title();
            const target = a.watchTarget(session);
            const opened = if (action == .beside)
                webwatch.openBeside(self.win, label, target)
            else
                webwatch.open(self.win, label, target, lease);
            if (opened)
                c.gtk_popover_popdown(@ptrCast(self.popover));
            return;
        }
        // Already here as a tabless app session: escalate that viewer
        // rather than dialing a second attach onto the same session.
        if (self.win.sessionPlacement(session, attach_host) == .tabless) {
            if (muxtabs.escalateTablessSession(self.win, session, attach_host, lease == .control)) {
                c.gtk_popover_popdown(@ptrCast(self.popover));
                return;
            }
        }
        const target = self.findRow(attach_host, session) orelse return;
        var reuse: ?mux_client.Conn = null;
        if (a.reached == null and target.s.host == null) {
            if (!a.busy) {
                if (a.conn) |conn| {
                    reuse = conn;
                    a.conn = null;
                }
            }
        } else reuse = takeIdle(attach_host);
        if (!muxtabs.AttachJob.start(self.win, attach_host, session, target.s.origin_id, lease, .tab, reuse, onAttachReady, @ptrCast(self))) {
            if (reuse) |*conn| conn.deinit();
            return;
        }
        self.pending_ops += 1;
    }

    /// Poll one assistant's own daemon for its sessions (worker thread).
    fn startFetch(self: *Watcher, a: *Assistant) void {
        if (a.busy) return;
        const allocator = std.heap.c_allocator;
        const op = allocator.create(FetchOp) catch return;
        op.* = .{ .watcher = self, .key = null, .local = a.reached == null };
        op.key = allocator.dupe(u8, a.host) catch {
            allocator.destroy(op);
            return;
        };
        if (op.local) {
            if (a.conn) |conn| {
                op.conn = conn;
                a.conn = null;
            }
        } else op.conn = takeIdle(a.host);
        const thread = std.Thread.spawn(.{}, fetchThreadMain, .{op}) catch {
            // Nothing started: hand the connection back untouched.
            if (op.conn) |conn| {
                if (op.local) a.conn = conn else editorio.returnConn(a.host, conn);
            }
            op.conn = null;
            op.destroy();
            return;
        };
        thread.detach();
        a.busy = true;
        self.pending_ops += 1;
    }

    /// Apply a finished poll. `changed` drives one chip repaint.
    fn applyFetch(self: *Watcher, op: *FetchOp) void {
        const a = self.findByHost(op.key.?) orelse return;
        a.busy = false;
        if (op.ok) {
            if (op.conn) |conn| {
                if (op.local) a.conn = conn else editorio.returnConn(a.host, conn);
                op.conn = null;
            }
        }
        const reach: Reach = if (op.ok) .ok else if (op.idle) .idle else .failed;
        var changed = a.reach != reach;
        a.reach = reach;
        if (reach == .failed) a.noteFailure(op.why_buf[0..op.why_len]);
        if (reach == .idle and a.listing != null) {
            // A retired daemon took its sessions with it.
            a.listing.?.deinit();
            a.listing = null;
            a.listing_fp = 0;
            a.rebuildRows(self.allocator);
            changed = true;
        }
        if (op.parsed) |parsed| {
            const fp = std.hash.Wyhash.hash(rosterFingerprint(parsed.value.sessions), std.mem.sliceAsBytes(op.browsers));
            if (fp != a.listing_fp or a.listing == null) {
                if (a.listing) |*old| old.deinit();
                a.listing = .{ .parsed = parsed, .browsers = op.browsers };
                op.parsed = null;
                op.browsers = &.{};
                a.listing_fp = fp;
                a.rebuildRows(self.allocator);
                changed = true;
            }
        }
        if (changed) self.refreshChip();
    }
};

/// Owned by the chip's destroy connection; unparents the popover at
/// the only correct moment, the chip's own dispose.
const UnparentCtx = struct {
    allocator: std.mem.Allocator,
    popover: *c.GtkWidget,
    /// Alive whenever the chip is: the watcher holds a reference on
    /// the chip and releases it only inside `stop`, before freeing itself.
    watcher: *Watcher,
};

fn onChipDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(UnparentCtx, user);
    ctx.watcher.widgets_dead = true;
    c.gtk_widget_unparent(ctx.popover);
}

fn onChipClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Watcher, user);
    self.open("");
}

const RowCtx = struct {
    allocator: std.mem.Allocator,
    watcher: *Watcher,
    /// The assistant's roster key (`Assistant.host`).
    key: []u8,
    session: []u8,
    attach_host: []u8,
    action: AttachAction,

    fn create(allocator: std.mem.Allocator, watcher: *Watcher, key: []const u8, session: []const u8, attach_host: []const u8, action: AttachAction) ?*RowCtx {
        const ctx = allocator.create(RowCtx) catch return null;
        const key_owned = allocator.dupe(u8, key) catch {
            allocator.destroy(ctx);
            return null;
        };
        const session_owned = allocator.dupe(u8, session) catch {
            allocator.free(key_owned);
            allocator.destroy(ctx);
            return null;
        };
        const host_owned = allocator.dupe(u8, attach_host) catch {
            allocator.free(session_owned);
            allocator.free(key_owned);
            allocator.destroy(ctx);
            return null;
        };
        ctx.* = .{
            .allocator = allocator,
            .watcher = watcher,
            .key = key_owned,
            .session = session_owned,
            .attach_host = host_owned,
            .action = action,
        };
        return ctx;
    }
};

/// A session row's Watch context, owned by the row (qdata).
const ROW_ATTACH_KEY = "sketerm-row-attach";

fn destroyRowCtx(user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RowCtx, user);
    ctx.allocator.free(ctx.key);
    ctx.allocator.free(ctx.session);
    ctx.allocator.free(ctx.attach_host);
    ctx.allocator.destroy(ctx);
}

fn freeRowCtx(user: ?*anyopaque, _: ?*c.GClosure) callconv(.c) void {
    destroyRowCtx(user);
}

fn onRowClicked(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    fireRow(@ptrCast(btn), cast.userData(RowCtx, user));
}

/// Activating a session row itself (click or Enter) is its Watch.
fn onSessionRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, _: ?*anyopaque) callconv(.c) void {
    const data = c.g_object_get_data(@ptrCast(row), ROW_ATTACH_KEY) orelse return;
    fireRow(@ptrCast(row), cast.userData(RowCtx, data));
}

fn fireRow(widget: *c.GtkWidget, ctx: *RowCtx) void {
    // The popover is rebuilt while it is open, which frees this row's
    // widgets and with them this context: copy what the attach needs
    // before anything can rebuild.
    const watcher = ctx.watcher;
    const action = ctx.action;
    var key_buf: [512]u8 = undefined;
    var name_buf: [256]u8 = undefined;
    var host_buf: [512]u8 = undefined;
    const key = copyInto(&key_buf, ctx.key) orelse return;
    const name = copyInto(&name_buf, ctx.session) orelse return;
    const host = copyInto(&host_buf, ctx.attach_host) orelse return;
    // A pane's agents popover is not the watcher's own: close it now
    // (the watcher's closes when the attach lands, a failure is a toast).
    if (c.gtk_widget_get_ancestor(widget, c.gtk_popover_get_type())) |pop| {
        const w: *c.GtkWidget = @ptrCast(pop);
        if (w != watcher.popover) c.gtk_popover_popdown(@ptrCast(w));
    }
    watcher.startAttach(key, name, host, action);
}

/// What a session row shows under its title.
const RowSubtitle = union(enum) {
    none,
    text: []const u8,
    /// An agent's attention in the chip's own palette.
    pill: struct { text: [:0]const u8, attention: ?vocab.Attention },
};

/// A label screen readers (and rigs) find as a heading: an instance's
/// name, one per instance.
fn headingLabel(text: [*:0]const u8) *c.GtkWidget {
    const obj = c.g_object_new(c.gtk_label_get_type(), "accessible-role", @as(c_int, c.GTK_ACCESSIBLE_ROLE_HEADING), "label", text, @as(?*anyopaque, null));
    return @ptrCast(@alignCast(obj));
}

/// Scroll only once the list outgrows its cap: an AUTOMATIC vertical
/// policy makes the scrollbar's own minimum height the list's, which
/// padded a one-line list with empty space.
fn fitScroller(sw: *c.GtkWidget) void {
    const child = c.gtk_scrolled_window_get_child(@ptrCast(sw)) orelse return;
    var min: c_int = 0;
    var nat: c_int = 0;
    c.gtk_widget_measure(child, c.GTK_ORIENTATION_VERTICAL, -1, &min, &nat, null, null);
    const scroll = nat > c.gtk_scrolled_window_get_max_content_height(@ptrCast(sw));
    c.gtk_scrolled_window_set_policy(@ptrCast(sw), c.GTK_POLICY_NEVER, if (scroll) c.GTK_POLICY_AUTOMATIC else c.GTK_POLICY_NEVER);
}

/// The scroller is an ancestor of the expander, so it outlives this
/// connection: no context to own.
fn onRestExpanded(_: *c.GObject, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    fitScroller(@ptrCast(@alignCast(user.?)));
}

fn setMargins(w: *c.GtkWidget, px: c_int) void {
    c.gtk_widget_set_margin_start(w, px);
    c.gtk_widget_set_margin_end(w, px);
    c.gtk_widget_set_margin_top(w, px);
    c.gtk_widget_set_margin_bottom(w, px);
}

/// The list one instance's session rows go in; a row's activation is
/// its Watch (`onSessionRowActivated`).
fn newSessionList() *c.GtkWidget {
    const list = c.gtk_list_box_new().?;
    c.gtk_list_box_set_selection_mode(@ptrCast(list), c.GTK_SELECTION_NONE);
    c.gtk_list_box_set_activate_on_single_click(@ptrCast(list), 1);
    c.gtk_widget_add_css_class(list, "navigation-sidebar");
    _ = c.g_signal_connect_data(list, "row-activated", @ptrCast(&onSessionRowActivated), null, null, c.G_CONNECT_DEFAULT);
    return list;
}

/// An icon-only attach button: the verb's bundled icon, its words and
/// tip as the tooltip, and `accessibleName` as its accessible label.
/// The one builder the popovers and the Session Overview share.
pub fn attachButton(action: AttachAction, row: []const u8) *c.GtkWidget {
    const verb = action.verb();
    const btn = c.gtk_button_new_from_icon_name(verb.icon).?;
    c.gtk_widget_add_css_class(btn, "flat");
    c.gtk_widget_set_valign(btn, c.GTK_ALIGN_CENTER);
    var tip_buf: [400:0]u8 = undefined;
    const tip: [*:0]const u8 = if (std.fmt.bufPrintZ(&tip_buf, "{s}: {s}", .{ verb.text, verb.tip })) |z| z.ptr else |_| verb.tip;
    c.gtk_widget_set_tooltip_text(btn, tip);
    var name_buf: [400]u8 = undefined;
    a11y.setLabel(btn, accessibleName(&name_buf, action, row).ptr);
    return btn;
}

/// "All assistants and agents" in a pane's agents popover.
const RosterCtx = struct {
    allocator: std.mem.Allocator,
    watcher: *Watcher,
    /// The pane's agents popover; the button lives inside it.
    popover: *c.GtkWidget,
    /// The assistant to list first (`Assistant.host`), possibly empty.
    key_buf: [512]u8 = undefined,
    key_len: usize = 0,

    fn create(allocator: std.mem.Allocator, watcher: *Watcher, popover: *c.GtkWidget, key: []const u8) ?*RosterCtx {
        if (key.len > 512) return null;
        const ctx = allocator.create(RosterCtx) catch return null;
        ctx.* = .{ .allocator = allocator, .watcher = watcher, .popover = popover, .key_len = key.len };
        @memcpy(ctx.key_buf[0..key.len], key);
        return ctx;
    }
};

fn onRosterClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RosterCtx, user);
    const watcher = ctx.watcher;
    var key_buf: [512]u8 = undefined;
    const key = key_buf[0..ctx.key_len];
    @memcpy(key, ctx.key_buf[0..ctx.key_len]);
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
    watcher.open(key);
}

/// This machine's per-user daemon socket, into `buf`; empty when the
/// path cannot be formed (then no local pane matches).
fn defaultSocket(buf: []u8) []const u8 {
    var fba = std.heap.FixedBufferAllocator.init(buf);
    return sockpath.defaultSocketPath(fba.allocator()) catch "";
}

/// The session `pane` shows and its daemon; null = no daemon session.
fn paneSession(pane: *Pane) ?glance.PaneSession {
    const remote = pane.terminal.remote orelse return null;
    return .{ .host = remote.host, .session = remote.session };
}

fn viewsSameSession(earlier: []const *Pane, pane: *Pane) bool {
    const at = paneSession(pane) orelse return false;
    for (earlier) |p| {
        const other = paneSession(p) orelse continue;
        if (std.mem.eql(u8, other.session, at.session) and strEqOpt(other.host, at.host)) return true;
    }
    return false;
}

/// An agent row's status line: the attention's words, capitalized.
fn statusText(buf: [:0]u8, attention: ?vocab.Attention) [:0]const u8 {
    const words = if (attention) |a| a.label() else "state unknown (an older sketerm mcp)";
    const z = std.fmt.bufPrintZ(buf, "{s}", .{words}) catch return "";
    if (z.len > 0) z[0] = std.ascii.toUpper(z[0]);
    return z;
}

/// The pane's agents chip is opening its popover.
pub fn fillPaneAgents(win: *Window, pane: *Pane, popover: *c.GtkWidget) void {
    const watcher = win.assistants orelse return;
    watcher.buildPaneAgents(pane, popover);
}

/// A truncated key or host would name something else: refuse instead.
fn copyInto(buf: []u8, src: []const u8) ?[]const u8 {
    if (src.len > buf.len) return null;
    @memcpy(buf[0..src.len], src);
    return buf[0..src.len];
}

fn onAttachReady(user: ?*anyopaque, job: *muxtabs.AttachJob) void {
    const self = cast.userData(Watcher, user);
    const alive = !self.dead and !self.widgets_dead;
    if (alive) {
        if (job.finish()) {
            c.gtk_popover_popdown(@ptrCast(self.popover));
        } else {
            // Never a silent nothing: a dead instance or a refusing hop
            // is named by the route, everything else by the daemon.
            const why = job.failureReason();
            var msg: [400]u8 = undefined;
            const text = std.fmt.bufPrint(&msg, "{s} {s} failed: {s}", .{
                std.mem.span(attachVerb(job.lease).text),
                job.session,
                if (why.len > 0) why else "the session or its daemon is gone",
            }) catch "the attach failed";
            winmod.showToast(self.win, text);
        }
    }
    if (!self.opDone()) return;
    if (alive) self.refreshChip();
}

fn onDirChanged(_: ?*c.GFileMonitor, _: ?*c.GFile, _: ?*c.GFile, _: c.GFileMonitorEvent, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Watcher, user);
    if (self.dead) return;
    if (self.rescan_id != 0) _ = c.g_source_remove(self.rescan_id);
    self.rescan_id = c.g_timeout_add(RESCAN_DEBOUNCE_MS, @ptrCast(&onRescanTimer), @ptrCast(self));
}

fn onRescanTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Watcher, user);
    self.rescan_id = 0;
    if (!self.dead) self.rescan();
    return 0;
}

fn onTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Watcher, user);
    if (self.dead) return 0;
    self.rescan();
    return 1;
}

/// The host's idle pooled connection, never a dial (main thread).
fn takeIdle(host: []const u8) ?mux_client.Conn {
    var fs = editorio.pool.acquireIdle(host) orelse return null;
    return editorio.takeConn(&fs);
}

/// One roster poll of one assistant daemon; lives on the C heap so the
/// worker thread and the idle handback share it without the window
/// allocator.
const FetchOp = struct {
    watcher: *Watcher,
    /// The assistant's host spec (`sock:` path or route).
    key: ?[]u8,
    local: bool,
    conn: ?mux_client.Conn = null,
    parsed: ?std.json.Parsed(mux_cli.Welcome) = null,
    ok: bool = false,
    /// The dial found the server's daemon not running (`Reach.idle`).
    idle: bool = false,
    browsers: []webpresence.Metadata = &.{},
    why_buf: [160]u8 = undefined,
    why_len: usize = 0,

    fn destroy(self: *FetchOp) void {
        const allocator = std.heap.c_allocator;
        if (self.conn) |*conn| conn.deinit();
        if (self.parsed) |*parsed| parsed.deinit();
        if (self.key) |key| allocator.free(key);
        allocator.free(self.browsers);
        allocator.destroy(self);
    }

    fn dial(self: *FetchOp) ?mux_client.Conn {
        const key = self.key.?;
        self.idle = false;
        if (self.local) {
            return dialSocket(key["sock:".len..]) catch |err| {
                self.idle = err == error.NoDaemon;
                return null;
            };
        }
        // Connect only: a route ends in `--proxy --instance`, which never
        // starts a daemon; its refusal names the hop and why.
        if (mux_cli.muxConnect(std.heap.c_allocator, key)) |conn| {
            var cc = conn;
            cc.setNonBlocking();
            return cc;
        }
        self.idle = mux_client.routeRefusal() == .instance_down;
        const why = mux_client.routeFailure();
        const text = if (why.len > 0) why else "cannot connect";
        const n = @min(text.len, self.why_buf.len);
        @memcpy(self.why_buf[0..n], text[0..n]);
        self.why_len = n;
        return null;
    }
};

fn fetchThreadMain(op: *FetchOp) void {
    const reused = op.conn != null;
    if (op.conn == null) op.conn = op.dial();
    if (op.conn != null and !runList(op) and reused) {
        // The idle connection died between polls (daemon retired and
        // came back): one fresh dial, then give up until the next tick.
        op.conn.?.deinit();
        op.conn = op.dial();
        if (op.conn != null) _ = runList(op);
    }
    if (op.parsed) |parsed| {
        op.browsers = std.heap.c_allocator.alloc(webpresence.Metadata, parsed.value.sessions.len) catch &.{};
        for (op.browsers, 0..) |*metadata, i| {
            const info = parsed.value.sessions[i];
            // Presence files are read beside a LOCAL socket only; a
            // remote browser keeps the generic title.
            metadata.* = if (op.local and kindOf(info.name, info.app) == .web)
                webpresence.readMetadata(std.heap.c_allocator, op.key.?["sock:".len..], info.name)
            else
                .{};
        }
    }
    _ = c.g_idle_add(@ptrCast(&onFetchIdle), @ptrCast(op));
}

/// Connect-only: a retired assistant daemon is never resurrected by a
/// viewer; `error.NoDaemon` reads as an idle instance, not a broken one.
fn dialSocket(path: []const u8) !mux_client.Conn {
    var conn = try mux_client.Conn.connectProbed(std.heap.c_allocator, path);
    conn.setNonBlocking();
    return conn;
}

fn runList(op: *FetchOp) bool {
    const allocator = std.heap.c_allocator;
    const conn = &op.conn.?;
    conn.sendFrame(.list, "") catch return false;
    const f = conn.recvExpectFor(&.{.welcome}, LIST_TIMEOUT_MS) catch return false;
    defer f.deinit(allocator);
    if (op.parsed) |*old| {
        old.deinit();
        op.parsed = null;
    }
    op.parsed = std.json.parseFromSlice(mux_cli.Welcome, allocator, f.payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return false;
    op.ok = true;
    return true;
}

fn onFetchIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const op = cast.userData(FetchOp, user);
    const self = op.watcher;
    if (!self.dead) self.applyFetch(op);
    op.destroy();
    _ = self.opDone();
    return 0;
}

/// The `assistants` half of a list reply; the sessions are not read.
const ReportListing = struct { assistants: []const mcp_registry.Report = &.{} };

fn rosterFingerprint(sessions: []const mux_cli.SessionInfo) u64 {
    var hash: u64 = 0;
    for (sessions) |s| {
        hash = std.hash.Wyhash.hash(hash, s.name);
        hash = std.hash.Wyhash.hash(hash, s.title);
        hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&s.exited));
        hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&s.app));
        const viewers = s.viewerCount();
        hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&viewers));
    }
    return hash;
}

/// The per-pane "AI attached" chip was clicked: open the surface
/// scoped to the assistant whose daemon (or sub-agent) hosts that
/// pane's session when there is one, else unscoped.
pub fn openForPane(win: *Window, pane: *Pane) void {
    const watcher = win.assistants orelse {
        @import("app_switcher.zig").open(win);
        return;
    };
    var preferred: []const u8 = "";
    if (pane.terminal.remote) |remote| {
        if (remote.host) |host| {
            if (watcher.findByHost(host)) |a| {
                preferred = a.host;
            } else if (watcher.findRow(host, remote.session)) |row| {
                preferred = row.a.host;
            }
        }
    }
    watcher.open(preferred);
}

// --- tests ------------------------------------------------------

const t = std.testing;

test "session kinds derive from the daemon's facts" {
    try t.expectEqual(Kind.terminal, kindOf("s1234-1", false));
    try t.expectEqual(Kind.terminal, kindOf("web-1-abc", false));
    try t.expectEqual(Kind.web, kindOf("web-2888490-28c86295", true));
    try t.expectEqual(Kind.app, kindOf("launch-3", true));
}

test "chip label aggregates every assistant and omits zero kinds" {
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("", chipLabel(&buf, 0, .{}));
    try t.expectEqualStrings("AI: 1 idle", chipLabel(&buf, 1, .{}));
    try t.expectEqualStrings("AI: 1 browser", chipLabel(&buf, 1, .{ .web = 1 }));
    try t.expectEqualStrings("AI: 1 browser, 2 terminals", chipLabel(&buf, 2, .{ .web = 1, .terminal = 2 }));
    try t.expectEqualStrings("AI: 2 apps, 1 terminal", chipLabel(&buf, 1, .{ .app = 2, .terminal = 1 }));
}

test "summarize counts sessions across the roster" {
    const a = t.allocator;
    var roster: [2]Assistant = undefined;
    for (&roster, 0..) |*r, i| {
        r.* = .{
            .pid = @intCast(i + 1),
            .mode = .isolated,
            .name = try a.dupe(u8, "mcp"),
            .detail = try a.dupe(u8, ""),
            .host = try a.dupe(u8, "sock:/tmp/x"),
        };
    }
    defer for (&roster) |*r| r.deinit(a);
    const kinds = [_]struct { idx: usize, kind: Kind }{
        .{ .idx = 0, .kind = .web },
        .{ .idx = 1, .kind = .terminal },
        .{ .idx = 1, .kind = .terminal },
    };
    for (kinds) |k| try roster[k.idx].appendRow(a, "s", "", "", k.kind, 0, .{}, null, null);
    const counts = summarize(&roster);
    try t.expectEqual(@as(usize, 1), counts.web);
    try t.expectEqual(@as(usize, 0), counts.app);
    try t.expectEqual(@as(usize, 2), counts.terminal);
    try t.expectEqual(@as(usize, 3), counts.total());
}

test "attach verbs give watch and control distinct icons" {
    try t.expect(attachVerb(.read_only).icon != attachVerb(.control).icon);
    try t.expectEqualStrings("Watch", std.mem.span(attachVerb(.read_only).text));
    try t.expectEqualStrings("Take control", std.mem.span(attachVerb(.control).text));
}

test "show beside pane is a browser row's action alone, read-only for a new viewer" {
    try t.expect(AttachAction.beside.appliesTo(.web));
    try t.expect(!AttachAction.beside.appliesTo(.app));
    try t.expect(!AttachAction.beside.appliesTo(.terminal));
    for (std.enums.values(AttachAction)) |action| {
        if (action != .beside) try t.expect(action.appliesTo(.terminal));
    }
    try t.expectEqual(muxtabs.Lease.read_only, AttachAction.beside.lease());
    try t.expectEqualStrings("Show beside pane", std.mem.span(AttachAction.beside.verb().text));
}

test "place labels name the machine, through its hops" {
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("box", placeLabel(&buf, "box"));
    try t.expectEqualStrings("box", placeLabel(&buf, "ssh:box"));
    try t.expectEqualStrings("box", placeLabel(&buf, "route:box#tmp-4"));
    try t.expectEqualStrings("b via a", placeLabel(&buf, "route:a/b"));
    try t.expectEqualStrings("c via a/b", placeLabel(&buf, "route:tor:a/b/c#hub"));
    try t.expectEqualStrings("this machine", placeLabel(&buf, "sock:/x/mux.sock"));
    try t.expectEqualStrings("claude-1 (claude)", agentRowLabel(&buf, "claude-1", "claude", null));
    try t.expectEqualStrings("claude-2 (claude) on hostb via hosta", agentRowLabel(&buf, "claude-2", "claude", "route:hosta/hostb"));
}

fn testReport(instance: []const u8, label: []const u8, agents: ?[]const mcp_registry.Agent) mcp_registry.Report {
    return .{ .instance = instance, .label = label, .mode = "isolated", .pid = 77, .agents = agents };
}

fn freeTestRoster(roster: *std.ArrayList(Assistant)) void {
    for (roster.items) |*a| a.deinit(t.allocator);
    roster.deinit(t.allocator);
}

test "a remote report lists its server with routes for each agent location" {
    var roster: std.ArrayList(Assistant) = .empty;
    defer freeTestRoster(&roster);
    const agents = [_]mcp_registry.Agent{
        .{ .id = "claude-1", .app = "claude", .sessions = &.{"agent-claude-1"}, .location = "instance" },
        .{ .id = "claude-2", .app = "claude", .sessions = &.{"agent-claude-2"}, .location = "host:hostb" },
        .{ .id = "odd", .app = "claude", .sessions = &.{"agent-odd"}, .location = "moon" },
    };
    // An unnamed server's label is its pid: it reads like a local one.
    try t.expect(mergeReport(t.allocator, &roster, "ssh:hosta", &.{testReport("tmp-9", "77", &agents)}));
    try t.expectEqual(@as(usize, 1), roster.items.len);
    const a = &roster.items[0];
    try t.expectEqualStrings("route:hosta#tmp-9", a.host);
    try t.expectEqualStrings("mcp 77 on hosta", a.label());
    try t.expectEqualStrings("ssh:hosta", a.reached.?);
    // The unreadable location is skipped, never guessed.
    try t.expectEqual(@as(usize, 2), a.agents.items.len);
    try t.expectEqual(@as(usize, 2), a.sessions.items.len);
    const own = a.findSession("agent-claude-1").?;
    try t.expectEqualStrings("route:hosta#tmp-9", own.attachHost(a));
    try t.expect(own.host == null);
    const far = a.findSession("agent-claude-2").?;
    try t.expectEqualStrings("route:hosta/hostb", far.attachHost(a));
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("claude-2 (claude) on hostb via hosta", rowTitle(&buf, a, far));
    try t.expectEqual(@as(usize, 2), summarize(roster.items).terminal);
    // An unchanged report changes nothing; the server leaving drops it.
    try t.expect(!mergeReport(t.allocator, &roster, "ssh:hosta", &.{testReport("tmp-9", "77", &agents)}));
    try t.expect(mergeReport(t.allocator, &roster, "ssh:hosta", &.{}));
    try t.expectEqual(@as(usize, 0), roster.items.len);
}

test "two specs reaching one machine report its server once" {
    var roster: std.ArrayList(Assistant) = .empty;
    defer freeTestRoster(&roster);
    const reps = [_]mcp_registry.Report{testReport("hub", "hub", null)};
    try t.expect(mergeReport(t.allocator, &roster, "hosta", &reps));
    try t.expect(!mergeReport(t.allocator, &roster, "ssh:hosta", &reps));
    try t.expectEqual(@as(usize, 1), roster.items.len);
    try t.expectEqualStrings("hosta", roster.items[0].reached.?);
    try t.expectEqualStrings("hub on hosta", roster.items[0].label());
    // The second spec's empty report cannot drop the first one's server.
    try t.expect(!mergeReport(t.allocator, &roster, "ssh:hosta", &.{}));
    try t.expectEqual(@as(usize, 1), roster.items.len);
    // agents: null (an older server) contributes the server, no rows.
    try t.expectEqual(@as(usize, 0), roster.items[0].sessions.items.len);
}

test "an instance listing is the truth on its own daemon, agents elsewhere are added" {
    var roster: std.ArrayList(Assistant) = .empty;
    defer freeTestRoster(&roster);
    const agents = [_]mcp_registry.Agent{
        .{ .id = "claude-1", .app = "claude", .sessions = &.{"agent-claude-1"}, .location = "instance" },
        .{ .id = "claude-2", .app = "claude", .sessions = &.{"agent-claude-2"}, .location = "host:hostb" },
    };
    _ = mergeReport(t.allocator, &roster, "hosta", &.{testReport("tmp-9", "tmp-9", &agents)});
    const a = &roster.items[0];
    // A fresh listing without the instance agent's session (it ended)
    // and with a browser: the browser shows, the gone agent does not.
    const payload =
        \\{"sessions":[{"name":"web-1-ab","app":true},{"name":"old","exited":true}]}
    ;
    const parsed = try std.json.parseFromSlice(mux_cli.Welcome, std.heap.c_allocator, payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    a.listing = .{ .parsed = parsed, .browsers = try std.heap.c_allocator.alloc(webpresence.Metadata, 0) };
    a.rebuildRows(t.allocator);
    try t.expectEqual(@as(usize, 2), a.sessions.items.len);
    try t.expectEqual(Kind.web, a.findSession("web-1-ab").?.kind);
    try t.expect(a.findSession("agent-claude-1") == null);
    try t.expect(a.findSession("agent-claude-2").?.host != null);
}

test "local registry agents attach at the instance socket or the plain host" {
    var a: Assistant = .{
        .pid = 5,
        .mode = .isolated,
        .name = try t.allocator.dupe(u8, "mcp"),
        .detail = try t.allocator.dupe(u8, ""),
        .host = try t.allocator.dupe(u8, "sock:/run/x/mcp-tmp-5/mux.sock"),
    };
    defer a.deinit(t.allocator);
    const agents = [_]mcp_registry.Agent{
        .{ .id = "claude-1", .app = "claude", .sessions = &.{"agent-claude-1"}, .location = "instance" },
        .{ .id = "opencode-1", .app = "opencode", .sessions = &.{ "agent-opencode-1", "agent-opencode-1-server" }, .location = "host:build" },
    };
    try t.expect(a.setAgents(t.allocator, &agents));
    try t.expect(!a.setAgents(t.allocator, &agents));
    a.rebuildRows(t.allocator);
    try t.expectEqual(@as(usize, 3), a.sessions.items.len);
    try t.expectEqualStrings("sock:/run/x/mcp-tmp-5/mux.sock", a.findSession("agent-claude-1").?.attachHost(&a));
    try t.expectEqualStrings("build", a.findSession("agent-opencode-1-server").?.attachHost(&a));
    // null = a server predating published agents: none, and a change.
    try t.expect(a.setAgents(t.allocator, null));
    a.rebuildRows(t.allocator);
    try t.expectEqual(@as(usize, 0), a.sessions.items.len);
}

fn testAssistant(pid: c.pid_t, name: []const u8, host: []const u8) !Assistant {
    return .{
        .pid = pid,
        .mode = .isolated,
        .name = try t.allocator.dupe(u8, name),
        .detail = try t.allocator.dupe(u8, ""),
        .host = try t.allocator.dupe(u8, host),
    };
}

test "two servers sharing a name read apart by pid; one alone keeps its name" {
    var roster = [_]Assistant{
        try testAssistant(11, "claudehere", "sock:/r/mcp-tmp-11/mux.sock"),
        try testAssistant(12, "claudehere", "sock:/r/mcp-tmp-12/mux.sock"),
        try testAssistant(13, "sketerm", "sock:/r/mcp-tmp-13/mux.sock"),
    };
    defer for (&roster) |*r| r.deinit(t.allocator);
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("claudehere (pid 11)", headerName(&buf, &roster, &roster[0]));
    try t.expectEqualStrings("claudehere (pid 12)", headerName(&buf, &roster, &roster[1]));
    try t.expectEqualStrings("sketerm", headerName(&buf, &roster, &roster[2]));
}

test "instances without sessions collapse into one idle/unreachable line" {
    var roster = [_]Assistant{
        try testAssistant(1, "a", "sock:/r/a"),
        try testAssistant(2, "b", "sock:/r/b"),
        try testAssistant(3, "c", "sock:/r/c"),
        try testAssistant(4, "d", "sock:/r/d"),
    };
    defer for (&roster) |*r| r.deinit(t.allocator);
    var buf: [64]u8 = undefined;
    // Pending, idle and unreachable alike have nothing to act on.
    try t.expectEqualStrings("4 idle", restSummary(&buf, &roster));
    roster[0].reach = .idle;
    roster[1].reach = .failed;
    roster[1].noteFailure("box refused the route (bad_route): no");
    try roster[2].appendRow(t.allocator, "s", "", "", .terminal, 0, .{}, null, null);
    roster[2].reach = .ok;
    try t.expectEqualStrings("2 idle, 1 unreachable", restSummary(&buf, &roster));
    try t.expect(roster[2].usable());
    try t.expect(!roster[1].usable());
    var why: [224]u8 = undefined;
    try t.expectEqualStrings("unreachable: box refused the route (bad_route): no", roster[1].absence(&why));
    try t.expect(std.mem.startsWith(u8, roster[0].absence(&why), "idle:"));
    for (&roster) |*r| r.reach = .ok;
    roster[0].reach = .failed;
    roster[0].why_len = 0;
    try roster[1].appendRow(t.allocator, "s", "", "", .terminal, 0, .{}, null, null);
    try roster[3].appendRow(t.allocator, "s", "", "", .web, 0, .{}, null, null);
    try t.expectEqualStrings("1 unreachable", restSummary(&buf, &roster));
    roster[0].reach = .ok;
    try roster[0].appendRow(t.allocator, "s", "", "", .app, 0, .{}, null, null);
    try t.expectEqualStrings("", restSummary(&buf, &roster));
}

test "the tooltip carries the mode, the pid and why an instance is empty" {
    var a = try testAssistant(42, "claudehere", "sock:/r/mcp-tmp-42/mux.sock");
    defer a.deinit(t.allocator);
    a.reach = .idle;
    var buf: [512]u8 = undefined;
    const tip = instanceTip(&buf, &a);
    try t.expect(std.mem.indexOf(u8, tip, "isolated mode, pid 42, on this machine") != null);
    try t.expect(std.mem.indexOf(u8, tip, "idle:") != null);
}

test "action buttons are named by verb and row; the list caps at 60% of the window" {
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("Watch claude-1 (claude)", accessibleName(&buf, .watch, "claude-1 (claude)"));
    try t.expectEqualStrings("Take control", accessibleName(&buf, .control, ""));
    try t.expectEqualStrings("Show beside pane Login", accessibleName(&buf, .beside, "Login"));
    try t.expectEqual(@as(c_int, 600), listCap(1000));
    try t.expectEqual(@as(c_int, 480), listCap(0));
}
