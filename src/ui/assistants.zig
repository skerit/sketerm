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
//! every `HOST_POLL_MS` over the host's pooled idle connection
//! (`editorio.pool`, the one the Session Overview uses, which also feeds
//! its own list replies in through `applyHostReport`). A remote server
//! is keyed by the route to its instance daemon (`sshroute.watchSpec`,
//! `route:A#key`), so two specs reaching one machine report it once,
//! and the local daemon's report is never read (the registry covers this
//! machine). A remote instance's OWN daemon is polled through its route
//! only while the popover is open (the Overview polls it itself while
//! open); otherwise its rows are the agents its report publishes. Each
//! agent's sessions attach where `watchSpec` says: the instance daemon,
//! or `route:A/B` for one placed on B.
//!
//! The result feeds three surfaces: the chip at the end of the tab bar
//! with its popover, the per-pane "AI attached" chip's click, and the
//! Session Overview's assistant daemons and agent rows.
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
const winmod = @import("window.zig");
const Window = winmod.Window;
const Pane = @import("pane.zig").Pane;

/// Slow fallback for a registry change the monitor missed (no GIO
/// backend, a lost inotify event) and the roster refresh cadence.
const TICK_MS: c_uint = 3000;
/// Coalesces the CREATED + CHANGED + lock events one registration emits.
const RESCAN_DEBOUNCE_MS: c_uint = 150;
/// Bound on one daemon's `list` reply; past it the daemon reads as
/// unavailable until the next tick.
const LIST_TIMEOUT_MS: i64 = 5_000;
/// A remote daemon's assistants report, over its pooled connection.
const HOST_POLL_MS: i64 = 6_000;
/// After a failed poll: a dead link must not spawn ssh every tick.
const HOST_RETRY_MS: i64 = 30_000;
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

    pub fn icon(self: Kind) [*:0]const u8 {
        return switch (self) {
            .web => "web-browser-symbolic",
            .app => "application-x-executable-symbolic",
            .terminal => "utilities-terminal-symbolic",
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
    failed: bool = false,
    /// Why the last poll failed (a route names the refusing hop).
    why_buf: [160]u8 = undefined,
    why_len: usize = 0,
    /// Mark-and-sweep flag for a rescan or a host report.
    seen: bool = true,

    pub fn label(self: *const Assistant) []const u8 {
        return self.name;
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
        self.clearAgents(allocator);
        self.agents.deinit(allocator);
        if (self.listing) |*l| l.deinit();
        self.clearSessions(allocator);
        self.sessions.deinit(allocator);
        if (self.conn) |*conn| conn.deinit();
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
        try self.agents.append(allocator, .{ .id = id, .app = app, .sessions = sessions, .watch = watch });
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
    }
    return hash;
}

/// Whether `host`'s list reply describes ANOTHER machine's registry, i.e.
/// a remote per-user daemon. Null and `sock:` are this machine (the
/// local registry already covers it); a route ending in an instance is
/// a daemon some report already led here.
pub fn reportsRemote(host: ?[]const u8) bool {
    const h = host orelse return false;
    if (h.len == 0 or std.mem.startsWith(u8, h, "sock:")) return false;
    if (sshroute.RouteSpec.isRoute(h)) {
        const r = sshroute.RouteSpec.parse(h) catch return false;
        return r.instance == null;
    }
    return true;
}

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

/// Icon and tooltip for each attach intent, shared by the tab-bar
/// popover and the Session Overview so the two never disagree.
pub const AttachVerb = struct { icon: [*:0]const u8, tip: [*:0]const u8, text: [*:0]const u8 };

pub fn attachVerb(lease: muxtabs.Lease) AttachVerb {
    return switch (lease) {
        .read_only => .{
            .icon = "view-reveal-symbolic",
            .tip = "View without sending keyboard or mouse input; also gives up control if you were controlling this session",
            .text = "Watch",
        },
        .control, .default => .{
            .icon = "input-keyboard-symbolic",
            .tip = "Use your keyboard and mouse in this session, for example to sign in",
            .text = "Take control",
        },
    };
}

/// A remote daemon whose `assistants` report this window reads.
const ReportHost = struct {
    spec: []u8,
    busy: bool = false,
    seen: bool = true,
    next_ms: i64 = 0,
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
    /// The chip's widget tree was disposed (the window closed): no
    /// label, popover or tooltip may be touched again. `Window.deinit`
    /// (and so `stop`) runs on a LATER idle than the widget destroy
    /// chain, which is why this is a flag and not an ordering rule.
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
        self.tick_id = c.g_timeout_add(TICK_MS, @ptrCast(&onTick), @ptrCast(self));
        self.rescan();
        return self;
    }

    /// Stop watching. Widgets are left to the window's own teardown;
    /// the struct is freed once no worker can still report into it.
    pub fn stop(self: *Watcher) void {
        self.dead = true;
        if (self.tick_id != 0) {
            _ = c.g_source_remove(self.tick_id);
            self.tick_id = 0;
        }
        if (self.rescan_id != 0) {
            _ = c.g_source_remove(self.rescan_id);
            self.rescan_id = 0;
        }
        self.disarm();
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
        if (changed) self.refreshChip();
    }

    fn applyRegistry(self: *Watcher, entries: []const mcp_registry.Entry) bool {
        var changed = false;
        for (self.roster.items) |*a| {
            if (a.reached == null) a.seen = false;
        }
        for (entries) |entry| {
            if (self.findByPid(entry.pid)) |a| {
                a.seen = true;
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
    /// idle ones that are due.
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
            if (h.seen or h.busy) {
                i += 1;
                continue;
            }
            _ = mergeReport(self.allocator, &self.roster, h.spec, &.{});
            self.allocator.free(h.spec);
            _ = self.hosts.swapRemove(i);
        }
        const now = clock.nowMs();
        for (self.hosts.items) |*h| {
            if (!h.busy and now >= h.next_ms) self.startReport(h);
        }
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

    fn startReport(self: *Watcher, h: *ReportHost) void {
        const allocator = std.heap.c_allocator;
        const op = allocator.create(ReportOp) catch return;
        op.* = .{ .watcher = self, .host = allocator.dupe(u8, h.spec) catch {
            allocator.destroy(op);
            return;
        } };
        op.conn = takeIdle(h.spec);
        const thread = std.Thread.spawn(.{}, reportThreadMain, .{op}) catch {
            op.destroy();
            return;
        };
        thread.detach();
        h.busy = true;
        self.pending_ops += 1;
    }

    fn applyReportOp(self: *Watcher, op: *ReportOp) void {
        const h = self.findHost(op.host) orelse return;
        h.busy = false;
        const now = clock.nowMs();
        if (!op.ok) {
            // Its assistants stay as last reported: the pane on that host
            // shows the broken link, and a stale row's attach names why.
            h.next_ms = now + HOST_RETRY_MS;
            return;
        }
        if (op.conn) |conn| {
            editorio.returnConn(op.host, conn);
            op.conn = null;
        }
        if (!op.capable) {
            // An older daemon says nothing about assistants: none known.
            h.next_ms = now + HOST_UNSUPPORTED_MS;
            if (mergeReport(self.allocator, &self.roster, op.host, &.{})) self.refreshChip();
            return;
        }
        const reports = if (op.parsed) |p| p.value.assistants else &.{};
        self.applyHostReport(op.host, reports);
    }

    // ── surfaces ────────────────────────────────────────────────

    /// Paint the chip from the roster. Hidden while nothing is live.
    fn refreshChip(self: *Watcher) void {
        if (self.dead or self.widgets_dead) return;
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
            w.print("{s}: {s}{s}\n", .{ a.label(), if (desc.len > 0) desc else "idle", if (a.failed) " (daemon unreachable)" else "" }) catch break;
        }
        const n = w.buffered().len;
        tip[n] = 0;
        c.gtk_widget_set_tooltip_text(self.chip, tip[0..n :0].ptr);
        c.gtk_widget_set_visible(self.chip, 1);
        if (c.gtk_widget_get_visible(self.popover) != 0) self.buildPopover();
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

    fn buildPopover(self: *Watcher) void {
        const pop: *c.GtkPopover = @ptrCast(self.popover);
        c.gtk_popover_set_child(pop, null);
        const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 8).?;
        c.gtk_widget_set_margin_start(root, 6);
        c.gtk_widget_set_margin_end(root, 6);
        c.gtk_widget_set_margin_top(root, 6);
        c.gtk_widget_set_margin_bottom(root, 6);
        // Preferred assistant first, then roster order.
        const first = self.findByHost(self.preferred());
        if (first) |a| self.appendAssistant(root, a);
        for (self.roster.items) |*a| {
            if (first == a) continue;
            self.appendAssistant(root, a);
        }
        if (self.roster.items.len == 0) {
            const none = c.gtk_label_new("No assistant is running.").?;
            c.gtk_widget_add_css_class(none, "dim-label");
            c.gtk_box_append(@ptrCast(root), none);
        }
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
    }

    fn appendAssistant(self: *Watcher, root: *c.GtkWidget, a: *Assistant) void {
        const section = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2).?;
        var head_buf: [256:0]u8 = undefined;
        const head = std.fmt.bufPrintZ(&head_buf, "{s}", .{a.label()}) catch "assistant";
        const head_label = c.gtk_label_new(head.ptr).?;
        c.gtk_label_set_xalign(@ptrCast(head_label), 0);
        c.gtk_widget_add_css_class(head_label, "heading");
        c.gtk_box_append(@ptrCast(section), head_label);
        var sub_buf: [512:0]u8 = undefined;
        const sub = std.fmt.bufPrintZ(&sub_buf, "{s}{s}{s}", .{
            a.mode.text(),
            if (a.detail.len > 0) " - " else "",
            a.detail,
        }) catch "";
        const sub_label = c.gtk_label_new(sub.ptr).?;
        c.gtk_label_set_xalign(@ptrCast(sub_label), 0);
        c.gtk_label_set_ellipsize(@ptrCast(sub_label), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_label_set_max_width_chars(@ptrCast(sub_label), 48);
        c.gtk_widget_add_css_class(sub_label, "dim-label");
        c.gtk_box_append(@ptrCast(section), sub_label);
        if (a.failed) {
            var fail_buf: [224:0]u8 = undefined;
            const text = if (a.why().len > 0)
                std.fmt.bufPrintZ(&fail_buf, "unreachable: {s}", .{a.why()}) catch "daemon unreachable"
            else
                "daemon unreachable";
            const failed = c.gtk_label_new(text.ptr).?;
            c.gtk_label_set_xalign(@ptrCast(failed), 0);
            c.gtk_label_set_wrap(@ptrCast(failed), 1);
            c.gtk_label_set_max_width_chars(@ptrCast(failed), 48);
            c.gtk_widget_add_css_class(failed, "dim-label");
            c.gtk_widget_add_css_class(failed, "error");
            c.gtk_box_append(@ptrCast(section), failed);
        } else if (a.sessions.items.len == 0) {
            const idle = c.gtk_label_new("no sessions yet").?;
            c.gtk_label_set_xalign(@ptrCast(idle), 0);
            c.gtk_widget_add_css_class(idle, "dim-label");
            c.gtk_box_append(@ptrCast(section), idle);
        }
        for (a.sessions.items) |*s| self.appendSessionRow(section, a, s);
        c.gtk_box_append(@ptrCast(root), section);
    }

    fn appendSessionRow(self: *Watcher, section: *c.GtkWidget, a: *Assistant, s: *Session) void {
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6).?;
        const icon = c.gtk_image_new_from_icon_name(s.kind.icon()).?;
        c.gtk_box_append(@ptrCast(row), icon);
        var title_buf: [320]u8 = undefined;
        var text_buf: [320:0]u8 = undefined;
        const text = std.fmt.bufPrintZ(&text_buf, "{s}", .{rowTitle(&title_buf, a, s)}) catch "session";
        const label = c.gtk_label_new(text.ptr).?;
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
        c.gtk_label_set_max_width_chars(@ptrCast(label), 36);
        c.gtk_widget_set_hexpand(label, 1);
        if (s.kind == .web) c.gtk_widget_add_css_class(label, "heading");
        var tip_buf: [400:0]u8 = undefined;
        const tip = if (s.kind == .web)
            std.fmt.bufPrintZ(&tip_buf, "{s}", .{s.browser.title()}) catch null
        else
            std.fmt.bufPrintZ(&tip_buf, "{s} ({s}) at {s}, {d} viewer(s)", .{ s.name, @tagName(s.kind), s.attachHost(a), s.viewers }) catch null;
        if (tip) |tz| c.gtk_widget_set_tooltip_text(label, tz.ptr);
        const identity = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2).?;
        c.gtk_widget_set_hexpand(identity, 1);
        c.gtk_box_append(@ptrCast(identity), label);
        if (s.kind == .web) {
            var domain_buf: [320:0]u8 = undefined;
            const domain = std.fmt.bufPrintZ(&domain_buf, "{s}", .{s.browser.subtitle()}) catch "Browser";
            const sub = c.gtk_label_new(domain.ptr).?;
            c.gtk_label_set_xalign(@ptrCast(sub), 0);
            c.gtk_label_set_ellipsize(@ptrCast(sub), c.PANGO_ELLIPSIZE_END);
            c.gtk_label_set_max_width_chars(@ptrCast(sub), 36);
            c.gtk_widget_add_css_class(sub, "dim-label");
            c.gtk_widget_add_css_class(sub, "caption");
            c.gtk_widget_set_tooltip_text(sub, domain.ptr);
            c.gtk_box_append(@ptrCast(identity), sub);
        }
        c.gtk_box_append(@ptrCast(row), identity);
        // Identity above actions: long names no longer compete for width
        // with the buttons, and each browser reads as one compact group.
        const card = if (s.kind == .web) c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6).? else row;
        const controls = if (s.kind == .web) c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6).? else row;
        if (s.kind == .web) {
            c.gtk_widget_set_margin_top(card, 8);
            c.gtk_widget_set_margin_bottom(card, 8);
            c.gtk_box_append(@ptrCast(card), row);
            c.gtk_box_append(@ptrCast(card), controls);
        }
        const placement = self.win.sessionPlacement(s.name, s.attachHost(a));
        const actions = [_]struct { lease: muxtabs.Lease, beside: bool = false }{
            .{ .lease = .read_only }, .{ .lease = .control }, .{ .lease = .read_only, .beside = true },
        };
        for (actions) |action| {
            // Beside relocates a LOCAL helper's observer; a remote watch
            // has no such placement yet.
            if (action.beside and (s.kind != .web or a.reached != null)) continue;
            const lease = action.lease;
            const verb: AttachVerb = if (action.beside) .{
                .icon = "view-dual-symbolic",
                .text = "Show beside pane",
                .tip = "Open or move this browser next to the selected pane. Starts read-only for a new viewer; keeps your current mode when moving.",
            } else attachVerb(lease);
            // Labelled, not icon-only: the popover is the one place a
            // person reads these verbs cold, and a rig drives them by text.
            const btn = c.gtk_button_new_with_label(verb.text).?;
            c.gtk_widget_add_css_class(btn, "flat");
            c.gtk_widget_set_tooltip_text(btn, verb.tip);
            // Browser actions focus, escalate, or relocate the existing
            // watch. Other session kinds retain their attachment policy.
            const sensitive = if (s.kind == .web) true else switch (placement) {
                .none => true,
                .tabless => lease == .control,
                .pane => false,
            };
            c.gtk_widget_set_sensitive(btn, @intFromBool(sensitive));
            const ctx = RowCtx.create(self.allocator, self, a.host, s.name, s.attachHost(a), lease, action.beside) orelse continue;
            _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onRowClicked), @ptrCast(ctx), @ptrCast(&freeRowCtx), c.G_CONNECT_DEFAULT);
            c.gtk_box_append(@ptrCast(controls), btn);
        }
        c.gtk_box_append(@ptrCast(section), card);
    }

    /// Attach `session` of the assistant keyed `key` (at `attach_host`)
    /// into this window with `lease`, off-thread; the popover closes
    /// when the attach lands, and a failure is a toast naming why.
    fn startAttach(self: *Watcher, key: []const u8, session: []const u8, attach_host: []const u8, lease: muxtabs.Lease, beside: bool) void {
        if (self.dead) return;
        const a = self.findByHost(key) orelse return;
        // The assistant's browser opens as a browser: a second client
        // of its own helper, its pages as web pages (webwatch.zig).
        // The mux app session behind it is never attached from here.
        if (kindOf(session, true) == .web) {
            const target = a.findSession(session) orelse return;
            const opened = if (a.reached) |reached|
                webwatch.openRemote(self.win, a.label(), reached, a.instance, session, lease)
            else if (beside)
                webwatch.openLocalBeside(self.win, target.browser.title(), a.host["sock:".len..], session)
            else
                webwatch.openLocal(self.win, target.browser.title(), a.host["sock:".len..], session, lease);
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
        const failed = !op.ok;
        var changed = a.failed != failed;
        a.failed = failed;
        if (failed) a.noteFailure(op.why_buf[0..op.why_len]);
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
    lease: muxtabs.Lease,
    beside: bool = false,

    fn create(allocator: std.mem.Allocator, watcher: *Watcher, key: []const u8, session: []const u8, attach_host: []const u8, lease: muxtabs.Lease, beside: bool) ?*RowCtx {
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
            .lease = lease,
            .beside = beside,
        };
        return ctx;
    }
};

fn freeRowCtx(user: ?*anyopaque, _: ?*c.GClosure) callconv(.c) void {
    const ctx = cast.userData(RowCtx, user);
    ctx.allocator.free(ctx.key);
    ctx.allocator.free(ctx.session);
    ctx.allocator.free(ctx.attach_host);
    ctx.allocator.destroy(ctx);
}

fn onRowClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RowCtx, user);
    // The popover is rebuilt while it is open, which frees this row's
    // button and with it this context: copy what the attach needs
    // before anything can rebuild.
    const watcher = ctx.watcher;
    const lease = ctx.lease;
    const beside = ctx.beside;
    var key_buf: [512]u8 = undefined;
    var name_buf: [256]u8 = undefined;
    var host_buf: [512]u8 = undefined;
    const key = copyInto(&key_buf, ctx.key) orelse return;
    const name = copyInto(&name_buf, ctx.session) orelse return;
    const host = copyInto(&host_buf, ctx.attach_host) orelse return;
    watcher.startAttach(key, name, host, lease, beside);
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
        if (self.local) return dialSocket(key["sock:".len..]);
        // Connect only: a route ends in `--proxy --instance`, which never
        // starts a daemon; its refusal names the hop and why.
        if (mux_cli.muxConnect(std.heap.c_allocator, key)) |conn| {
            var cc = conn;
            cc.setNonBlocking();
            return cc;
        }
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

/// Connect-only: a dead assistant daemon is never resurrected by a
/// viewer, and its absence is silent (the roster shows it unreachable).
fn dialSocket(path: []const u8) ?mux_client.Conn {
    var conn = mux_client.Conn.connectProbed(std.heap.c_allocator, path) catch return null;
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

/// One `assistants` report poll of one remote daemon (C heap, like FetchOp).
const ReportOp = struct {
    watcher: *Watcher,
    host: []u8,
    conn: ?mux_client.Conn = null,
    parsed: ?std.json.Parsed(ReportListing) = null,
    /// The daemon advertises `assistants`; without it the reply is not read.
    capable: bool = false,
    ok: bool = false,
    why_buf: [160]u8 = undefined,
    why_len: usize = 0,

    fn why(self: *const ReportOp) []const u8 {
        return self.why_buf[0..self.why_len];
    }

    fn destroy(self: *ReportOp) void {
        const allocator = std.heap.c_allocator;
        if (self.conn) |*conn| conn.deinit();
        if (self.parsed) |*parsed| parsed.deinit();
        allocator.free(self.host);
        allocator.destroy(self);
    }

    fn dial(self: *ReportOp) ?mux_client.Conn {
        if (mux_cli.muxConnect(std.heap.c_allocator, self.host)) |conn| {
            var cc = conn;
            cc.setNonBlocking();
            return cc;
        }
        const route_why = mux_client.routeFailure();
        const text = if (route_why.len > 0) route_why else "host unreachable";
        const n = @min(text.len, self.why_buf.len);
        @memcpy(self.why_buf[0..n], text[0..n]);
        self.why_len = n;
        return null;
    }

    fn run(self: *ReportOp) bool {
        const allocator = std.heap.c_allocator;
        const conn = &self.conn.?;
        self.capable = conn.caps.assistants;
        if (!self.capable) {
            self.ok = true;
            return true;
        }
        conn.sendFrame(.list, "") catch return false;
        const f = conn.recvExpectFor(&.{.welcome}, LIST_TIMEOUT_MS) catch return false;
        defer f.deinit(allocator);
        if (self.parsed) |*old| {
            old.deinit();
            self.parsed = null;
        }
        self.parsed = std.json.parseFromSlice(ReportListing, allocator, f.payload, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return false;
        self.ok = true;
        return true;
    }
};

fn reportThreadMain(op: *ReportOp) void {
    const reused = op.conn != null;
    if (op.conn == null) op.conn = op.dial();
    if (op.conn != null and !op.run() and reused) {
        op.conn.?.deinit();
        op.conn = op.dial();
        if (op.conn != null) _ = op.run();
    }
    _ = c.g_idle_add(@ptrCast(&onReportIdle), @ptrCast(op));
}

fn onReportIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const op = cast.userData(ReportOp, user);
    const self = op.watcher;
    if (!self.dead) self.applyReportOp(op);
    op.destroy();
    _ = self.opDone();
    return 0;
}

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

test "only a remote per-user daemon's report describes another machine" {
    try t.expect(!reportsRemote(null));
    try t.expect(!reportsRemote(""));
    try t.expect(!reportsRemote("sock:/run/user/1/sketerm/mcp-tmp-4/mux.sock"));
    try t.expect(reportsRemote("box"));
    try t.expect(reportsRemote("ssh:user@box"));
    try t.expect(reportsRemote("udp:box"));
    try t.expect(reportsRemote("route:a/b"));
    try t.expect(!reportsRemote("route:a#tmp-4"));
    try t.expect(!reportsRemote("route:a/b#hub"));
    try t.expect(!reportsRemote("route:"));
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
