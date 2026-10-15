//! `sketerm peer hub add|remove`, `join`, `leave` and `status`: peer
//! federation set up in one command (docs/mcp.md "Federation"). The
//! commands edit this user's config.conf in place through
//! `config_edit.zig`; the daemon reads these keys only when it starts.

const std = @import("std");
const c = @import("../c.zig").c;
const config = @import("../config.zig");
const Config = config.Config;
const Doc = @import("../config_edit.zig").Doc;
const fdio = @import("../util/fdio.zig");
const readfile = @import("../util/readfile.zig");
const atomicwrite = @import("../util/atomicwrite.zig");
const pathz = @import("../util/pathz.zig");
const vocab = @import("../agent/vocab.zig");
const peeraddr = @import("peeraddr.zig");
const muxclient = @import("../mux/client.zig");
const peer_cli = @import("peer_cli.zig");

/// The `sketerm peer` verbs this file answers.
pub const Verb = enum { hub, join, leave, status };
pub const HubVerb = enum { add, remove };

/// Printed after a written change.
pub const RESTART = "restart the sketerm daemon (no sessions attached) for it to take effect\n";

pub const Cli = struct {
    verb: Verb,
    hub_verb: ?HubVerb = null,
    /// `hub add|remove NAME`, `join HUB`.
    name: ?[]const u8 = null,
    host: ?[]const u8 = null,
    inbound: bool = false,
    dry_run: bool = false,
    help: bool = false,

    pub const ParseError = error{ UnknownFlag, MissingValue, ExtraArgument, UnknownVerb, NoName, NotForVerb };

    pub fn parse(args: []const []const u8) ParseError!Cli {
        var o: Cli = .{ .verb = undefined };
        var words: [4][]const u8 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            const eql = std.mem.eql;
            if (eql(u8, a, "--help") or eql(u8, a, "-h")) {
                o.help = true;
            } else if (eql(u8, a, "--inbound")) {
                o.inbound = true;
            } else if (eql(u8, a, "--dry-run")) {
                o.dry_run = true;
            } else if (eql(u8, a, "--host")) {
                if (i + 1 >= args.len) return error.MissingValue;
                i += 1;
                o.host = args[i];
            } else if (a.len > 1 and a[0] == '-') {
                return error.UnknownFlag;
            } else {
                if (n == words.len) return error.ExtraArgument;
                words[n] = a;
                n += 1;
            }
        }
        if (n == 0) return error.UnknownVerb;
        o.verb = std.meta.stringToEnum(Verb, words[0]) orelse return error.UnknownVerb;
        if (o.help) return o;
        var rest = words[1..n];
        if (o.verb == .hub) {
            if (rest.len == 0) return error.UnknownVerb;
            o.hub_verb = std.meta.stringToEnum(HubVerb, rest[0]) orelse return error.UnknownVerb;
            rest = rest[1..];
        }
        const takes_name = o.verb == .hub or o.verb == .join;
        if (takes_name) {
            if (rest.len == 0) return error.NoName;
            o.name = rest[0];
            rest = rest[1..];
        }
        if (rest.len > 0) return error.ExtraArgument;
        if (o.inbound and o.hub_verb != .add) return error.NotForVerb;
        if (o.host != null and o.hub_verb != .add and o.verb != .join) return error.NotForVerb;
        if (o.dry_run and o.verb == .status) return error.NotForVerb;
        return o;
    }
};

// ── the edits, on config.conf text ───────────────────────────────

pub const Refusal = error{
    /// `hub add` where `peer_hub_domain` is set.
    IsMember,
    /// `join` where `peer_hub = true` is set.
    IsHub,
    BadName,
    BadHost,
    /// `hub remove` of a domain the file has no section for.
    NoSuchDomain,
    /// The edit is made but the file still means otherwise (a
    /// `[platform.*]` section, say, sets the key again).
    Overridden,
};

pub const EditError = Refusal || error{ OutOfMemory, BadValue };

/// The edited text and what changed; no changes = already set up.
pub const Edit = struct { text: []const u8, changes: []const []const u8 };

fn domainSection(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "domain.{s}", .{name});
}

fn checkHost(host: ?[]const u8) Refusal!void {
    if (host) |h| if (!muxclient.Conn.validSshHost(h)) return error.BadHost;
}

/// Whatever `text` sets, as the daemon would read it.
fn parsed(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!Config {
    return Config.loadFromBytes(arena, text) catch return error.OutOfMemory;
}

fn finish(arena: std.mem.Allocator, d: *Doc, holds: *const fn (*const Config, Cli) bool, o: Cli) EditError!Edit {
    const text = try d.render();
    var after = try parsed(arena, text);
    defer after.deinit();
    if (!holds(&after, o)) return error.Overridden;
    return .{ .text = text, .changes = d.changes.items };
}

/// `hub add`: `peer_hub = true` and `[domain.NAME] peers = true`, with
/// `peer_link = inbound` or an ssh `host` (kept unless `o.host` is given).
pub fn hubAdd(arena: std.mem.Allocator, text: []const u8, o: Cli) EditError!Edit {
    const name = o.name.?;
    peeraddr.validHost(name) catch return error.BadName;
    try checkHost(o.host);
    var before = try parsed(arena, text);
    defer before.deinit();
    if (before.peer_hub_domain.len > 0) return error.IsMember;
    var d = try Doc.parse(arena, text);
    const sec = try domainSection(arena, name);
    try d.set(null, "peer_hub", "true");
    try d.set(sec, "peers", "true");
    if (o.inbound) {
        try d.set(sec, "peer_link", "inbound");
    } else if (d.get(sec, "peer_link")) |v| {
        if (!std.mem.eql(u8, v, @tagName(vocab.PeerLinkDirection.outbound))) try d.remove(sec, "peer_link");
    }
    if (o.host) |h| {
        try d.set(sec, "host", h);
    } else if (!o.inbound and d.get(sec, "host") == null) {
        try d.set(sec, "host", name);
    }
    return finish(arena, &d, struct {
        fn holds(cfg: *const Config, q: Cli) bool {
            const dom = cfg.domainNamed(q.name.?) orelse return false;
            const want: vocab.PeerLinkDirection = if (q.inbound) .inbound else .outbound;
            return cfg.peer_hub and dom.peers and dom.peer_link == want and (q.inbound or dom.host.len > 0);
        }
    }.holds, o);
}

/// `hub remove`: drops `peers` and `peer_link` from `[domain.NAME]`.
pub fn hubRemove(arena: std.mem.Allocator, text: []const u8, o: Cli) EditError!Edit {
    const name = o.name.?;
    peeraddr.validHost(name) catch return error.BadName;
    var d = try Doc.parse(arena, text);
    const sec = try domainSection(arena, name);
    if (!d.hasSection(sec)) return error.NoSuchDomain;
    try d.remove(sec, "peers");
    try d.remove(sec, "peer_link");
    return finish(arena, &d, struct {
        fn holds(cfg: *const Config, q: Cli) bool {
            const dom = cfg.domainNamed(q.name.?) orelse return true;
            return !dom.peers;
        }
    }.holds, o);
}

/// `join`: `peer_hub_domain = HUB` and `[domain.HUB] host`.
pub fn join(arena: std.mem.Allocator, text: []const u8, o: Cli) EditError!Edit {
    const hub = o.name.?;
    peeraddr.validHost(hub) catch return error.BadName;
    try checkHost(o.host);
    var before = try parsed(arena, text);
    defer before.deinit();
    if (before.peer_hub) return error.IsHub;
    var d = try Doc.parse(arena, text);
    const sec = try domainSection(arena, hub);
    try d.set(null, "peer_hub_domain", hub);
    if (o.host) |h| {
        try d.set(sec, "host", h);
    } else if (d.get(sec, "host") == null) {
        try d.set(sec, "host", hub);
    }
    return finish(arena, &d, struct {
        fn holds(cfg: *const Config, q: Cli) bool {
            const dom = (cfg.peerHubDomain() catch return false) orelse return false;
            return std.mem.eql(u8, dom.name, q.name.?);
        }
    }.holds, o);
}

/// `leave`: drops `peer_hub_domain`.
pub fn leave(arena: std.mem.Allocator, text: []const u8, o: Cli) EditError!Edit {
    var d = try Doc.parse(arena, text);
    try d.remove(null, "peer_hub_domain");
    return finish(arena, &d, struct {
        fn holds(cfg: *const Config, _: Cli) bool {
            return cfg.peer_hub_domain.len == 0;
        }
    }.holds, o);
}

fn refusalText(e: EditError) []const u8 {
    return switch (e) {
        error.IsMember => "this config sets peer_hub_domain (a call-in member); a daemon is never hub and member at once: run `sketerm peer leave` first",
        error.IsHub => "this config sets peer_hub = true (the hub); a daemon is never hub and member at once: remove peer_hub first",
        error.BadName => "the name must be an address host: 1-253 of A-Za-z0-9._-, not starting with a dot",
        error.BadHost => "--host must be an ssh destination that does not start with '-'",
        error.NoSuchDomain => "this config has no [domain.<name>] section of that name",
        error.Overridden => "another line of this config (a [platform.*] section?) still overrides the change; nothing was written",
        error.BadValue => "a value holds a control character",
        error.OutOfMemory => "out of memory",
    };
}

// ── the command ──────────────────────────────────────────────────

fn say(fd: c_int, bytes: []const u8) void {
    _ = fdio.writeAll(fd, bytes);
}

fn fail(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) u8 {
    say(2, std.fmt.allocPrint(arena, "peer: " ++ fmt ++ "\n", args) catch "peer: failed\n");
    return 1;
}

/// Whether `args` is one of this file's verbs.
pub fn claims(args: []const []const u8) bool {
    for (args) |a| {
        if (a.len > 0 and a[0] == '-') continue;
        return std.meta.stringToEnum(Verb, a) != null;
    }
    return false;
}

/// `sketerm peer hub|join|leave|status ...`.
/// @return the process exit status.
pub fn cli(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const o = Cli.parse(args) catch |err| {
        say(2, switch (err) {
            error.UnknownFlag => "peer: unknown flag (see --help)\n",
            error.MissingValue => "peer: --host needs a value\n",
            error.ExtraArgument => "peer: too many arguments (see --help)\n",
            error.UnknownVerb => "peer: say hub add NAME, hub remove NAME, join HUB, leave or status (see --help)\n",
            error.NoName => "peer: hub add|remove and join need a domain name\n",
            error.NotForVerb => "peer: --inbound is for hub add, --host for hub add and join, --dry-run for the edits\n",
        });
        return 2;
    };
    if (o.help) {
        say(1, peer_cli.HELP);
        return 0;
    }
    const path = config.resolveConfigPath(arena) catch return fail(arena, "neither XDG_CONFIG_HOME nor HOME is set: no config.conf to edit", .{});
    const text = readConfig(arena, path) orelse return fail(arena, "cannot read {s}", .{path});
    if (o.verb == .status) return status(allocator, arena, path, text);

    const edit = switch (o.verb) {
        .hub => switch (o.hub_verb.?) {
            .add => hubAdd(arena, text, o),
            .remove => hubRemove(arena, text, o),
        },
        .join => join(arena, text, o),
        .leave => leave(arena, text, o),
        .status => unreachable,
    } catch |e| {
        _ = fail(arena, "{s}: {s}", .{ path, refusalText(e) });
        return switch (e) {
            error.BadName, error.BadHost, error.BadValue => 2,
            else => 1,
        };
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    report(&out.writer, path, edit, o) catch return 1;
    if (edit.changes.len > 0 and !o.dry_run) {
        pathz.makeParentDirs(path) catch return fail(arena, "cannot create the directory of {s}", .{path});
        atomicwrite.writeFile(path, edit.text, 0o600) catch |e| return fail(arena, "cannot write {s}: {s}", .{ path, @errorName(e) });
        out.writer.writeAll(RESTART) catch return 1;
    }
    if (o.verb == .join) {
        var host_buf: [256]u8 = undefined;
        const self_host = peeraddr.selfHost(&host_buf);
        if (peeraddr.validHost(self_host)) {
            out.writer.print("on the hub, run: sketerm peer hub add {s} --inbound\n", .{self_host}) catch return 1;
        } else |_| {
            out.writer.print("this host's name \"{s}\" is not usable in peer addresses; set {s} for the daemon\n", .{ self_host, peeraddr.HOST_ENV }) catch return 1;
        }
    }
    say(1, out.written());
    return 0;
}

/// What an edit prints: each change, or "already set up".
fn report(w: *std.Io.Writer, path: []const u8, edit: Edit, o: Cli) !void {
    if (edit.changes.len == 0) return w.print("already set up: {s} is unchanged\n", .{path});
    try w.print("{s} {s}:\n", .{ if (o.dry_run) "would change" else "changed", path });
    for (edit.changes) |ch| try w.print("  {s}\n", .{ch});
}

/// The file's text; empty when it does not exist yet.
fn readConfig(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return readfile.cappedAlloc(arena, path, config.MAX_FILE_BYTES) catch |e| switch (e) {
        error.OpenFailed => if (std.c._errno().* == c.ENOENT) "" else null,
        else => null,
    };
}

/// This host's role from config, null when it sets both (the daemon then
/// keeps federation off).
fn role(cfg: *const Config) ?vocab.PeerFederation {
    if (cfg.peer_hub and cfg.peer_hub_domain.len > 0) return null;
    if (cfg.peer_hub) return .hub;
    if (cfg.peer_hub_domain.len > 0) return .member;
    return .off;
}

/// The configured part of `status`.
fn writeConfigured(w: *std.Io.Writer, cfg: *const Config) !void {
    const r = role(cfg) orelse return w.writeAll("role: off (peer_hub and peer_hub_domain are both set)\n");
    switch (r) {
        .hub => {
            try w.writeAll("role: hub\n");
            var any = false;
            for (cfg.domains.items) |d| {
                if (!d.peers) continue;
                any = true;
                switch (d.peer_link) {
                    .outbound => try w.print("  domain {s}: dialed at {s} (outbound)\n", .{ d.name, if (d.host.len > 0) d.host else "(no host: skipped)" }),
                    .inbound => try w.print("  domain {s}: calls in (inbound)\n", .{d.name}),
                }
            }
            if (!any) try w.writeAll("  no [domain.<name>] sets peers = true\n");
        },
        .member => {
            const host = if (cfg.peerHubDomain()) |dom| (if (dom) |x| x.host else "") else |_| "";
            if (host.len > 0)
                try w.print("role: member, calls in to {s} at {s}\n", .{ cfg.peer_hub_domain, host })
            else
                try w.print("role: member of {s}, but no [domain.{s}] sets a host: nothing is dialed\n", .{ cfg.peer_hub_domain, cfg.peer_hub_domain });
        },
        .off => try w.writeAll("role: off\n"),
    }
}

fn status(allocator: std.mem.Allocator, arena: std.mem.Allocator, path: []const u8, text: []const u8) u8 {
    var cfg = parsed(arena, text) catch return 1;
    defer cfg.deinit();
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.print("config: {s}\n", .{path}) catch return 1;
    writeConfigured(w, &cfg) catch return 1;
    if (peer_cli.Link.open(allocator)) |link_value| {
        var link = link_value;
        defer link.close();
        if (link.peer.list(arena, peer_cli.REPLY_MS)) |reply| {
            w.print("daemon: federation {s}\n", .{@tagName(reply.value.federation)}) catch return 1;
            for (reply.value.hosts) |h| {
                w.writeAll("  ") catch return 1;
                peer_cli.writeHostText(w, h) catch return 1;
                w.writeAll("\n") catch return 1;
            }
        } else |_| w.writeAll("daemon: did not answer the peer list\n") catch return 1;
    } else |_| w.writeAll("daemon: not reachable\n") catch return 1;
    say(1, out.written());
    return 0;
}

const t = std.testing;

fn run(arena: std.mem.Allocator, args: []const []const u8, text: []const u8) EditError!Edit {
    const o = Cli.parse(args) catch unreachable;
    return switch (o.verb) {
        .hub => switch (o.hub_verb.?) {
            .add => hubAdd(arena, text, o),
            .remove => hubRemove(arena, text, o),
        },
        .join => join(arena, text, o),
        .leave => leave(arena, text, o),
        .status => unreachable,
    };
}

test "arguments: hub add|remove NAME, join HUB, leave, status; flags only where they mean something" {
    const a = try Cli.parse(&.{ "hub", "add", "aeor", "--inbound", "--dry-run" });
    try t.expectEqual(Verb.hub, a.verb);
    try t.expectEqual(HubVerb.add, a.hub_verb.?);
    try t.expectEqualStrings("aeor", a.name.?);
    try t.expect(a.inbound and a.dry_run);
    try t.expectEqualStrings("box", (try Cli.parse(&.{ "join", "archdev", "--host", "box" })).host.?);
    try t.expectEqual(Verb.status, (try Cli.parse(&.{"status"})).verb);
    try t.expectError(error.NoName, Cli.parse(&.{ "hub", "add" }));
    try t.expectError(error.UnknownVerb, Cli.parse(&.{ "hub", "drop", "x" }));
    try t.expectError(error.NotForVerb, Cli.parse(&.{ "join", "x", "--inbound" }));
    try t.expectError(error.NotForVerb, Cli.parse(&.{ "hub", "remove", "x", "--host", "h" }));
    try t.expectError(error.NotForVerb, Cli.parse(&.{ "status", "--dry-run" }));
    try t.expectError(error.ExtraArgument, Cli.parse(&.{ "leave", "x" }));
    try t.expect(claims(&.{ "hub", "add", "x" }) and claims(&.{"status"}) and !claims(&.{"list"}) and !claims(&.{}));
}

test "hub add on an empty file, then again: already set up" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // 1. An empty file gains the hub key and the domain, host defaulting to the name.
    const first = try run(a, &.{ "hub", "add", "dalaran" }, "");
    try t.expectEqualStrings("peer_hub = true\n\n[domain.dalaran]\npeers = true\nhost = dalaran\n", first.text);
    try t.expectEqual(@as(usize, 3), first.changes.len);
    try t.expectEqualStrings("[domain.dalaran] host = dalaran", first.changes[2]);
    // 2. The second run changes nothing.
    const again = try run(a, &.{ "hub", "add", "dalaran" }, first.text);
    try t.expectEqual(@as(usize, 0), again.changes.len);
    try t.expectEqualStrings(first.text, again.text);
    // 3. --inbound turns the same domain into a call-in, keeping its host.
    const in = try run(a, &.{ "hub", "add", "dalaran", "--inbound" }, first.text);
    try t.expectEqualStrings("peer_hub = true\n\n[domain.dalaran]\npeers = true\nhost = dalaran\npeer_link = inbound\n", in.text);
    // 4. Back to outbound with a new host: peer_link goes, host is replaced.
    const out = try run(a, &.{ "hub", "add", "dalaran", "--host", "me@dalaran.lan" }, in.text);
    try t.expectEqualStrings("peer_hub = true\n\n[domain.dalaran]\npeers = true\nhost = me@dalaran.lan\n", out.text);
}

test "hub add keeps comments and other sections byte for byte; --inbound needs no host" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\# sketerm, by hand
        \\font_size  =  13
        \\
        \\[profile.work]
        \\# dark at work
        \\font_size = 11
        \\
        \\[domain.lab]
        \\host = me@lab
        \\transport = ssh
        \\
    ;
    const e = try run(a, &.{ "hub", "add", "aeor", "--inbound" }, src);
    try t.expectEqualStrings(
        \\# sketerm, by hand
        \\font_size  =  13
        \\peer_hub = true
        \\
        \\[profile.work]
        \\# dark at work
        \\font_size = 11
        \\
        \\[domain.lab]
        \\host = me@lab
        \\transport = ssh
        \\
        \\[domain.aeor]
        \\peers = true
        \\peer_link = inbound
        \\
    , e.text);
    // An existing domain gains only its peer keys.
    const lab = try run(a, &.{ "hub", "add", "lab" }, src);
    try t.expectEqualStrings("[domain.lab]\nhost = me@lab\ntransport = ssh\npeers = true\n", lab.text[std.mem.indexOf(u8, lab.text, "[domain.lab]").?..]);
}

test "a daemon is hub or member, never both; bad names and hosts are refused" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const member = "peer_hub_domain = archdev\n[domain.archdev]\nhost = archdev\n";
    try t.expectError(error.IsMember, run(a, &.{ "hub", "add", "x" }, member));
    try t.expectError(error.IsHub, run(a, &.{ "join", "archdev" }, "peer_hub = true\n"));
    try t.expectError(error.BadName, run(a, &.{ "hub", "add", "a/b" }, ""));
    try t.expectError(error.BadName, run(a, &.{ "join", ".x" }, ""));
    try t.expectError(error.BadHost, run(a, &.{ "hub", "add", "x", "--host", "-oProxyCommand=y" }, ""));
    try t.expectError(error.BadValue, run(a, &.{ "hub", "add", "x", "--host", "a\nb" }, ""));
    // A platform section that sets the key again defeats the edit.
    const plat = @tagName(config.Platform.current orelse return error.SkipZigTest);
    const overridden = try std.fmt.allocPrint(a, "peer_hub_domain = a\n[domain.a]\nhost = a\n[platform.{s}]\npeer_hub_domain = a\n", .{plat});
    try t.expectError(error.Overridden, run(a, &.{"leave"}, overridden));
}

test "hub remove drops the peer keys and keeps the section" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "peer_hub = true\n\n[domain.aeor]\n# the laptop\nhost = aeor\npeers = true\npeer_link = inbound\n";
    const e = try run(a, &.{ "hub", "remove", "aeor" }, src);
    try t.expectEqualStrings("peer_hub = true\n\n[domain.aeor]\n# the laptop\nhost = aeor\n", e.text);
    try t.expectEqual(@as(usize, 0), (try run(a, &.{ "hub", "remove", "aeor" }, e.text)).changes.len);
    try t.expectError(error.NoSuchDomain, run(a, &.{ "hub", "remove", "nowhere" }, src));
}

test "join sets the hub domain and its host; leave clears it" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const j = try run(a, &.{ "join", "archdev" }, "# laptop\n");
    try t.expectEqualStrings("# laptop\npeer_hub_domain = archdev\n\n[domain.archdev]\nhost = archdev\n", j.text);
    try t.expectEqual(@as(usize, 0), (try run(a, &.{ "join", "archdev" }, j.text)).changes.len);
    const h = try run(a, &.{ "join", "archdev", "--host", "me@archdev.lan" }, j.text);
    try t.expectEqualStrings("# laptop\npeer_hub_domain = archdev\n\n[domain.archdev]\nhost = me@archdev.lan\n", h.text);
    const l = try run(a, &.{"leave"}, h.text);
    try t.expectEqualStrings("# laptop\n\n[domain.archdev]\nhost = me@archdev.lan\n", l.text);
    try t.expectEqual(@as(usize, 0), (try run(a, &.{"leave"}, l.text)).changes.len);
}

test "status names the configured role and links" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var hub = try parsed(a, "peer_hub = true\n[domain.dalaran]\nhost = dalaran\npeers = true\n[domain.aeor]\npeers = true\npeer_link = inbound\n[domain.web]\nhost = web\n");
    defer hub.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    try writeConfigured(&out.writer, &hub);
    try t.expectEqualStrings("role: hub\n  domain dalaran: dialed at dalaran (outbound)\n  domain aeor: calls in (inbound)\n", out.written());
    var member = try parsed(a, "peer_hub_domain = archdev\n[domain.archdev]\nhost = archdev\n");
    defer member.deinit();
    var mo: std.Io.Writer.Allocating = .init(a);
    try writeConfigured(&mo.writer, &member);
    try t.expectEqualStrings("role: member, calls in to archdev at archdev\n", mo.written());
}
