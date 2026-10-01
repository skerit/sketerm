//! Shared SSH route planning for direct and forced Tor mux connections.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const shellquote = @import("../util/shellquote.zig");
const socks5_client = @import("socks5_client.zig");
const selfexec = @import("selfexec.zig");

pub const Mode = enum { auto, ssh, udp, tor };
pub const Route = enum { direct, tor };

/// A route spec reads as `.auto` with the whole text as `host`; callers that
/// dial check `RouteSpec.isRoute` first (`Conn.connectRemote` and the
/// `connectSsh*` family do), so a route can never reach a bare ssh argv.
pub const RemoteSpec = struct {
    host: []const u8,
    mode: Mode,

    pub fn parse(spec: []const u8) RemoteSpec {
        if (std.mem.startsWith(u8, spec, "udp:")) return .{ .host = spec[4..], .mode = .udp };
        if (std.mem.startsWith(u8, spec, "ssh:")) return .{ .host = spec[4..], .mode = .ssh };
        if (std.mem.startsWith(u8, spec, "tor:")) return .{ .host = spec[4..], .mode = .tor };
        return .{ .host = spec, .mode = .auto };
    }
};

/// Whether `destination` is an SSH destination that is safe on a command
/// line: an alias, a host or `user@host`, no option and no shell
/// metacharacter. The ONE rule for every destination this module puts on
/// an argv or into a remote command (ProxyCommand `%h`, route hops).
pub fn validDestination(destination: []const u8) bool {
    if (destination.len == 0 or destination.len > 255 or destination[0] == '-') return false;
    for (destination) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_', '@', ':', '[', ']' => {},
        else => return false,
    };
    return true;
}

/// One hop of a route: a valid destination that is not itself a
/// transport-prefixed or routed spec (`udp:b`, `tor:b`, `route:b`).
pub fn validHop(hop: []const u8) bool {
    if (!validDestination(hop)) return false;
    if (RemoteSpec.parse(hop).mode != .auto) return false;
    return !std.mem.startsWith(u8, hop, RouteSpec.PREFIX) and !std.mem.startsWith(u8, hop, "sock:");
}

const webpresence = @import("../web/webpresence.zig");

/// A host spec that reaches a daemon THROUGH other hosts:
/// `route:[tor:]<hop>[/<hop>...][#<instance>]`. The first hop is dialed
/// over ssh from here (through Tor with `tor:`); every further hop is
/// dialed by the `sketerm-mux --proxy --via` on the hop before it; the
/// optional instance is a live MCP server's private daemon on the LAST
/// hop, else that host's per-user daemon. `/` and `#` cannot occur in a
/// destination (`validDestination`), and `route:` is no transport
/// prefix, so no existing spec (bare host, user@host, udp:/ssh:/tor:,
/// sock:) parses as a route.
pub const RouteSpec = struct {
    pub const PREFIX = "route:";
    pub const MAX_HOPS = 8;

    tor: bool = false,
    hop_buf: [MAX_HOPS][]const u8 = undefined,
    n_hops: u8 = 0,
    instance: ?[]const u8 = null,

    pub const Error = error{ NotARoute, BadHop, TooManyHops, BadInstance, NotRouted };

    pub fn isRoute(spec: []const u8) bool {
        return std.mem.startsWith(u8, spec, PREFIX);
    }

    pub fn hops(self: *const RouteSpec) []const []const u8 {
        return self.hop_buf[0..self.n_hops];
    }

    /// Append one hop; refused unless `validHop`.
    pub fn addHop(self: *RouteSpec, hop: []const u8) Error!void {
        if (!validHop(hop)) return error.BadHop;
        if (self.n_hops >= MAX_HOPS) return error.TooManyHops;
        self.hop_buf[self.n_hops] = hop;
        self.n_hops += 1;
    }

    /// The slices point into `spec`.
    /// @throws NotRouted for a single hop without an instance: that is the plain host spec.
    pub fn parse(spec: []const u8) Error!RouteSpec {
        if (!isRoute(spec)) return error.NotARoute;
        var rest = spec[PREFIX.len..];
        var out: RouteSpec = .{};
        if (std.mem.startsWith(u8, rest, "tor:")) {
            out.tor = true;
            rest = rest["tor:".len..];
        }
        if (std.mem.indexOfScalar(u8, rest, '#')) |hash| {
            const inst = rest[hash + 1 ..];
            if (!webpresence.validInstance(inst)) return error.BadInstance;
            out.instance = inst;
            rest = rest[0..hash];
        }
        var it = std.mem.splitScalar(u8, rest, '/');
        while (it.next()) |hop| try out.addHop(hop);
        try out.check();
        return out;
    }

    /// Refuse what `parse` would refuse; builders call it before `format`.
    pub fn check(self: *const RouteSpec) Error!void {
        if (self.n_hops == 0) return error.BadHop;
        if (self.n_hops == 1 and self.instance == null) return error.NotRouted;
        for (self.hops()) |hop| if (!validHop(hop)) return error.BadHop;
        if (self.instance) |inst| if (!webpresence.validInstance(inst)) return error.BadInstance;
    }

    /// The canonical text `parse` reads back.
    pub fn format(self: *const RouteSpec, buf: []u8) (Error || error{NoSpaceLeft})![]const u8 {
        try self.check();
        var w: std.Io.Writer = .fixed(buf);
        w.writeAll(PREFIX) catch return error.NoSpaceLeft;
        if (self.tor) w.writeAll("tor:") catch return error.NoSpaceLeft;
        for (self.hops(), 0..) |hop, i| {
            if (i > 0) w.writeByte('/') catch return error.NoSpaceLeft;
            w.writeAll(hop) catch return error.NoSpaceLeft;
        }
        if (self.instance) |inst| w.print("#{s}", .{inst}) catch return error.NoSpaceLeft;
        return w.buffered();
    }
};

/// Where an MCP sub-agent's sessions live, as the MCP registry records it:
/// `instance` (the MCP server's private daemon: local and `ssh -tt`
/// agents) or `host:<destination>` (that host's per-user daemon: the
/// remote sketerm-mux transport).
pub const Location = union(enum) {
    instance,
    host: []const u8,

    pub fn parse(text: []const u8) ?Location {
        if (std.mem.eql(u8, text, "instance")) return .instance;
        if (std.mem.startsWith(u8, text, "host:") and text.len > "host:".len) return .{ .host = text["host:".len..] };
        return null;
    }

    pub fn format(self: Location, buf: []u8) error{NoSpaceLeft}![]const u8 {
        return switch (self) {
            .instance => std.fmt.bufPrint(buf, "instance", .{}),
            .host => |h| std.fmt.bufPrint(buf, "host:{s}", .{h}),
        };
    }
};

/// The host spec a viewer dials to watch an agent at `location` of the MCP
/// instance `instance` whose registry a daemon reported. `reached` is the
/// spec that daemon was reached at (null or `sock:...` = this machine,
/// i.e. the local registry); `local_socket` is the instance's daemon
/// socket from the local registry and is only read for local `instance`
/// agents. Remote: `instance` -> the reached hops plus `#instance`;
/// `host:B` -> the reached hops plus `/B` (B's per-user daemon). Local:
/// `instance` -> `sock:<local_socket>`; `host:B` -> plain `B`. A UDP or
/// automatic first hop becomes plain ssh: routes always dial ssh.
pub fn watchSpec(
    buf: []u8,
    reached: ?[]const u8,
    instance: []const u8,
    local_socket: []const u8,
    location: Location,
) (RouteSpec.Error || error{NoSpaceLeft})![]const u8 {
    const local = if (reached) |r| std.mem.startsWith(u8, r, "sock:") else true;
    if (local) return switch (location) {
        .instance => blk: {
            if (local_socket.len == 0) return error.BadInstance;
            break :blk std.fmt.bufPrint(buf, "sock:{s}", .{local_socket});
        },
        .host => |h| blk: {
            if (!validHop(h)) return error.BadHop;
            break :blk std.fmt.bufPrint(buf, "{s}", .{h});
        },
    };
    var route: RouteSpec = .{};
    if (RouteSpec.isRoute(reached.?)) {
        const base = try RouteSpec.parse(reached.?);
        route.tor = base.tor;
        for (base.hops()) |hop| try route.addHop(hop);
    } else {
        const remote = RemoteSpec.parse(reached.?);
        route.tor = remote.mode == .tor;
        try route.addHop(remote.host);
    }
    switch (location) {
        .instance => {
            if (!webpresence.validInstance(instance)) return error.BadInstance;
            route.instance = instance;
        },
        .host => |h| try route.addHop(h),
    }
    return route.format(buf);
}

pub const Plan = struct {
    destination: []const u8,
    route: Route = .direct,
    tor_endpoint: []const u8 = socks5_client.DEFAULT_ENDPOINT,

    /// OpenSSH percent-expands `%h` INTO the ProxyCommand string and then
    /// runs the result through `/bin/sh -c`. Our command starts with `exec`,
    /// which makes an injected `';cmd;'` unreachable today, but that is a
    /// subtle property to depend on: one edit to the command prefix would
    /// turn a destination into arbitrary local execution, hence the
    /// module-level `validDestination`.
    pub fn init(destination: []const u8, route: Route, tor_endpoint: []const u8) !Plan {
        if (!validDestination(destination)) return error.BadDestination;
        if (route == .tor) _ = try socks5_client.Endpoint.parse(tor_endpoint);
        return .{ .destination = destination, .route = route, .tor_endpoint = tor_endpoint };
    }

    /// Stable memo identity: a direct verification never suppresses a Tor-routed check.
    pub fn memoKey(self: Plan, buf: []u8) ?[]const u8 {
        return switch (self.route) {
            .direct => std.fmt.bufPrint(buf, "ssh:{s}", .{self.destination}) catch null,
            .tor => std.fmt.bufPrint(buf, "tor:{s}:{s}", .{ self.tor_endpoint, self.destination }) catch null,
        };
    }

    /// Build route options once, then append them to every SSH leg.
    pub fn args(self: Plan, allow_multiplex: bool) !Args {
        var out = Args{ .route = self.route, .multiplex = allow_multiplex and self.route == .direct };
        if (self.route == .tor) try out.buildProxy(self.tor_endpoint);
        return out;
    }
};

pub const Args = struct {
    route: Route,
    multiplex: bool,
    proxy: [12 * 1024:0]u8 = undefined,
    proxy_len: usize = 0,

    fn buildProxy(self: *Args, endpoint: []const u8) !void {
        var exe_buf: [4096]u8 = undefined;
        const exe = platform.exePath(&exe_buf) orelse return error.ExecutablePathUnavailable;
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(std.heap.c_allocator);
        try command.appendSlice(std.heap.c_allocator, "ProxyCommand=exec ");
        try shellquote.appendQuoted(&command, std.heap.c_allocator, exe);
        try command.append(std.heap.c_allocator, ' ');
        try command.appendSlice(std.heap.c_allocator, selfexec.Mode.socks5_connect.flag().?);
        try command.append(std.heap.c_allocator, ' ');
        try shellquote.appendQuoted(&command, std.heap.c_allocator, endpoint);
        // OpenSSH expands these after applying the original destination's
        // Host/Match config. Quoting keeps the expansions as single argv.
        try command.appendSlice(std.heap.c_allocator, " '%h' '%p'");
        if (command.items.len >= self.proxy.len) return error.ProxyCommandTooLong;
        @memcpy(self.proxy[0..command.items.len], command.items);
        self.proxy[command.items.len] = 0;
        self.proxy_len = command.items.len;
    }

    /// Most route options any route emits, plus room to grow.
    pub const MAX_OPTIONS = 26;

    /// The ONE definition of a route's SSH options.
    ///
    /// Two consumers need different string shapes — `execvp` argv wants
    /// `[*:0]`, the MCP tools build `[]const u8` lists for termdrive — and
    /// a hand-copied second list is exactly how a route option goes missing
    /// from one of them. Everything here is either a literal or `self.proxy`,
    /// both null-terminated, so one sentinel-slice list serves both.
    /// `ssh_flags` adds `-T`/`-x`, which are ssh-only: `scp -T` means
    /// "disable strict filename checking" and would be a real behaviour
    /// change, so transfer callers ask for the `-o` options alone.
    pub fn options(self: *const Args, out: *[MAX_OPTIONS][:0]const u8, ssh_flags: bool) usize {
        var n: usize = 0;
        const put = struct {
            fn f(buf: *[MAX_OPTIONS][:0]const u8, i: *usize, v: [:0]const u8) void {
                buf[i.*] = v;
                i.* += 1;
            }
        }.f;
        if (ssh_flags) {
            put(out, &n, "-T");
            // The proxy channel carries the mux binary protocol — never X11.
            // `-x` disables X11 forwarding so a user's `ForwardX11 yes` config
            // can't print "X11 forwarding request failed" onto the terminal
            // (and can't perturb the protocol pipe).
            put(out, &n, "-x");
        }
        put(out, &n, "-o");
        put(out, &n, "BatchMode=yes");
        // A dedicated mux/deployment connection must not recreate unrelated
        // LocalForward/RemoteForward/DynamicForward entries from ssh_config.
        put(out, &n, "-o");
        put(out, &n, "ClearAllForwardings=yes");
        switch (self.route) {
            .direct => if (self.multiplex) {
                // `%C` is a fixed-length hash, so the socket path stays
                // well under the sun_path limit.
                put(out, &n, "-o");
                put(out, &n, "ControlMaster=auto");
                put(out, &n, "-o");
                put(out, &n, "ControlPath=~/.ssh/sketerm-%C");
                put(out, &n, "-o");
                put(out, &n, "ControlPersist=120");
            },
            .tor => {
                // Command-line -o values precede and therefore override the
                // user's ProxyJump/ProxyCommand and multiplexing settings.
                put(out, &n, "-o");
                put(out, &n, self.proxy[0..self.proxy_len :0]);
                put(out, &n, "-o");
                put(out, &n, "ProxyJump=none");
                put(out, &n, "-o");
                put(out, &n, "ProxyUseFdpass=no");
                // A direct ControlMaster must never satisfy a Tor request.
                put(out, &n, "-o");
                put(out, &n, "ControlMaster=no");
                put(out, &n, "-o");
                put(out, &n, "ControlPath=none");
                put(out, &n, "-o");
                put(out, &n, "ControlPersist=no");
                // No canonicalization or host-IP lookup may resolve the
                // destination outside Tor. Host-key lookup still uses the
                // original SSH alias and all of its remaining config.
                put(out, &n, "-o");
                put(out, &n, "CanonicalizeHostname=no");
                put(out, &n, "-o");
                put(out, &n, "CheckHostIP=no");
                put(out, &n, "-o");
                put(out, &n, "VerifyHostKeyDNS=no");
                put(out, &n, "-o");
                put(out, &n, "GSSAPIAuthentication=no");
            },
        }
        return n;
    }

    /// Append options common to deployment and the final mux proxy SSH.
    pub fn append(self: *Args, argv: []?[*:0]const u8, count: *usize) !void {
        var buf: [MAX_OPTIONS][:0]const u8 = undefined;
        const n = self.options(&buf, true);
        if (count.* + n > argv.len) return error.ArgumentOverflow;
        for (buf[0..n]) |opt| {
            argv[count.*] = opt.ptr;
            count.* += 1;
        }
    }

    /// Same options for callers that spawn ssh/scp through a `[]const u8`
    /// argv list (the MCP transfer and port-forward tools).
    pub fn appendSlices(self: *Args, allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), ssh_flags: bool) !void {
        var buf: [MAX_OPTIONS][:0]const u8 = undefined;
        const n = self.options(&buf, ssh_flags);
        // Duped: the Tor ProxyCommand lives inside `self`, which is a stack
        // temporary at every caller here.
        for (buf[0..n]) |opt| try out.append(allocator, try allocator.dupe(u8, opt));
    }
};

test "remote specs recognize forced Tor without changing the SSH destination" {
    const t = std.testing;
    const spec = RemoteSpec.parse("tor:work-alias");
    try t.expectEqual(Mode.tor, spec.mode);
    try t.expectEqualStrings("work-alias", spec.host);
}

test "Tor route forces the internal proxy and disables direct multiplexing" {
    const t = std.testing;
    const plan = try Plan.init("work-alias", .tor, socks5_client.DEFAULT_ENDPOINT);
    var args = try plan.args(true);
    var argv: [32:null]?[*:0]const u8 = .{null} ** 32;
    var count: usize = 0;
    try args.append(&argv, &count);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(t.allocator);
    for (argv[0..count]) |arg| {
        if (joined.items.len != 0) try joined.append(t.allocator, ' ');
        try joined.appendSlice(t.allocator, std.mem.span(arg.?));
    }
    try t.expect(std.mem.indexOf(u8, joined.items, "--internal-socks5-connect") != null);
    try t.expect(std.mem.indexOf(u8, joined.items, "127.0.0.1:9050") != null);
    try t.expect(std.mem.indexOf(u8, joined.items, "'%h' '%p'") != null);
    try t.expect(std.mem.indexOf(u8, joined.items, "ControlMaster=no") != null);
    try t.expect(std.mem.indexOf(u8, joined.items, "ControlMaster=auto") == null);
    try t.expect(std.mem.indexOf(u8, joined.items, "CanonicalizeHostname=no") != null);
    try t.expect(std.mem.indexOf(u8, joined.items, "VerifyHostKeyDNS=no") != null);
    try t.expect(std.mem.indexOf(u8, joined.items, "ProxyUseFdpass=no") != null);
    try t.expect(std.mem.indexOf(u8, joined.items, "ClearAllForwardings=yes") != null);
}

test "a destination that could break out of the ProxyCommand is refused" {
    const t = std.testing;
    // Reaches Plan.init from [domain.*] config, saved layouts and MCP args.
    try t.expectError(error.BadDestination, Plan.init("box';touch /tmp/x;'", .tor, DEFAULT_ENDPOINT_FOR_TEST));
    try t.expectError(error.BadDestination, Plan.init("box\ntouch /tmp/x", .tor, DEFAULT_ENDPOINT_FOR_TEST));
    try t.expectError(error.BadDestination, Plan.init("box$(id)", .tor, DEFAULT_ENDPOINT_FOR_TEST));
    try t.expectError(error.BadDestination, Plan.init("box`id`", .tor, DEFAULT_ENDPOINT_FOR_TEST));
    try t.expectError(error.BadDestination, Plan.init("-oProxyCommand=bad", .tor, DEFAULT_ENDPOINT_FOR_TEST));
    // Legitimate shapes still pass, on both routes.
    _ = try Plan.init("me@build.example.com", .tor, DEFAULT_ENDPOINT_FOR_TEST);
    _ = try Plan.init("abcdefghij234567.onion", .tor, DEFAULT_ENDPOINT_FOR_TEST);
    _ = try Plan.init("work-alias_2", .direct, DEFAULT_ENDPOINT_FOR_TEST);
}

const DEFAULT_ENDPOINT_FOR_TEST = socks5_client.DEFAULT_ENDPOINT;

test "the slice form carries the same route options minus the ssh-only flags" {
    const t = std.testing;
    const plan = try Plan.init("work-alias", .tor, socks5_client.DEFAULT_ENDPOINT);
    var args = try plan.args(false);

    var argv: [40:null]?[*:0]const u8 = .{null} ** 40;
    var count: usize = 0;
    try args.append(&argv, &count);

    var slices: std.ArrayList([]const u8) = .empty;
    defer slices.deinit(t.allocator);
    try args.appendSlices(t.allocator, &slices, true);
    defer for (slices.items) |item| t.allocator.free(item);

    // One definition, two shapes: they must not drift.
    try t.expectEqual(count, slices.items.len);
    for (argv[0..count], slices.items) |a, b| try t.expectEqualStrings(std.mem.span(a.?), b);

    // scp form: `-T` there means "no strict filename checking", so the
    // ssh-only flags are dropped and every `-o` option is kept.
    var scp: std.ArrayList([]const u8) = .empty;
    defer scp.deinit(t.allocator);
    try args.appendSlices(t.allocator, &scp, false);
    defer for (scp.items) |item| t.allocator.free(item);
    try t.expectEqual(slices.items.len - 2, scp.items.len);
    for (scp.items) |item| try t.expect(!std.mem.eql(u8, item, "-T") and !std.mem.eql(u8, item, "-x"));
    var proxies: usize = 0;
    for (scp.items) |item| if (std.mem.startsWith(u8, item, "ProxyCommand=")) {
        proxies += 1;
    };
    try t.expectEqual(@as(usize, 1), proxies);
}

test "route specs round-trip through their one canonical text" {
    const t = std.testing;
    const cases = [_][]const u8{
        "route:hosta#tmp-4242",
        "route:me@hosta/hostb",
        "route:a/b/c#work_1",
        "route:tor:abcdefghij234567.onion/inner#default",
        "route:[::1]/b",
    };
    for (cases) |text| {
        const r = try RouteSpec.parse(text);
        var buf: [256]u8 = undefined;
        try t.expectEqualStrings(text, try r.format(&buf));
    }
    const r = try RouteSpec.parse("route:tor:a/b#x");
    try t.expect(r.tor);
    try t.expectEqual(@as(usize, 2), r.hops().len);
    try t.expectEqualStrings("b", r.hops()[1]);
    try t.expectEqualStrings("x", r.instance.?);
}

test "route specs refuse what could not be dialed safely" {
    const t = std.testing;
    try t.expectError(error.NotARoute, RouteSpec.parse("hosta"));
    try t.expectError(error.NotRouted, RouteSpec.parse("route:hosta"));
    try t.expectError(error.BadHop, RouteSpec.parse("route:"));
    try t.expectError(error.BadHop, RouteSpec.parse("route:a//b"));
    try t.expectError(error.BadHop, RouteSpec.parse("route:a/b;rm -rf ~"));
    try t.expectError(error.BadHop, RouteSpec.parse("route:a/$(id)"));
    try t.expectError(error.BadHop, RouteSpec.parse("route:a/-oProxyCommand=x"));
    try t.expectError(error.BadHop, RouteSpec.parse("route:a/udp:b"));
    try t.expectError(error.BadHop, RouteSpec.parse("route:udp:a/b"));
    try t.expectError(error.BadHop, RouteSpec.parse("route:a/route:b"));
    try t.expectError(error.BadHop, RouteSpec.parse("route:a/sock:b"));
    try t.expectError(error.BadInstance, RouteSpec.parse("route:a#"));
    try t.expectError(error.BadInstance, RouteSpec.parse("route:a#../x"));
    try t.expectError(error.BadInstance, RouteSpec.parse("route:a#x/y"));
    try t.expectError(error.TooManyHops, RouteSpec.parse("route:a/b/c/d/e/f/g/h/i"));
}

test "route specs never collide with the existing host specs" {
    const t = std.testing;
    for ([_][]const u8{ "box", "user@box", "udp:box", "ssh:box", "tor:box", "sock:/run/x/mux.sock", "[::1]" }) |spec| {
        try t.expect(!RouteSpec.isRoute(spec));
        try t.expectError(error.NotARoute, RouteSpec.parse(spec));
    }
    // ...and a route is never mistaken for a transport prefix or a destination.
    try t.expectEqual(Mode.auto, RemoteSpec.parse("route:a#x").mode);
    try t.expect(!validDestination("route:a#x"));
    try t.expect(!validDestination("route:a/b"));
}

test "agent locations round-trip" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("instance", try (Location{ .instance = {} }).format(&buf));
    try t.expectEqualStrings("host:me@b", try (Location{ .host = "me@b" }).format(&buf));
    try t.expectEqual(Location.instance, Location.parse("instance").?);
    try t.expectEqualStrings("b", Location.parse("host:b").?.host);
    try t.expect(Location.parse("host:") == null);
    try t.expect(Location.parse("elsewhere") == null);
}

test "watchSpec derives the route an agent is watched at" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    // Reached at host A (any transport): instance -> A#I, host:B -> A/B.
    try t.expectEqualStrings("route:a#tmp-9", try watchSpec(&buf, "a", "tmp-9", "", .instance));
    try t.expectEqualStrings("route:a/b", try watchSpec(&buf, "udp:a", "tmp-9", "", .{ .host = "b" }));
    try t.expectEqualStrings("route:a#tmp-9", try watchSpec(&buf, "ssh:a", "tmp-9", "", .instance));
    try t.expectEqualStrings("route:tor:a/b", try watchSpec(&buf, "tor:a", "x", "", .{ .host = "b" }));
    // Reached through a route: its hops are kept, its own instance is not.
    try t.expectEqualStrings("route:a/b#w", try watchSpec(&buf, "route:a/b", "w", "", .instance));
    try t.expectEqualStrings("route:a/c", try watchSpec(&buf, "route:a#x", "w", "", .{ .host = "c" }));
    // The local registry: the private socket, or the host's own daemon.
    try t.expectEqualStrings("sock:/run/u/sketerm/mcp-w/mux.sock", try watchSpec(&buf, null, "w", "/run/u/sketerm/mcp-w/mux.sock", .instance));
    try t.expectEqualStrings("b", try watchSpec(&buf, null, "w", "", .{ .host = "b" }));
    try t.expectEqualStrings("b", try watchSpec(&buf, "sock:/x/mux.sock", "w", "", .{ .host = "b" }));
    // A host an MCP accepted but a route cannot carry is refused.
    try t.expectError(error.BadHop, watchSpec(&buf, "a", "w", "", .{ .host = "b;x" }));
    try t.expectError(error.BadHop, watchSpec(&buf, null, "w", "", .{ .host = "b c" }));
    try t.expectError(error.BadInstance, watchSpec(&buf, "a", "../w", "", .instance));
}

test "route memo identity separates direct and Tor verification" {
    const direct = try Plan.init("alias", .direct, socks5_client.DEFAULT_ENDPOINT);
    const tor = try Plan.init("alias", .tor, socks5_client.DEFAULT_ENDPOINT);
    var direct_buf: [128]u8 = undefined;
    var tor_buf: [128]u8 = undefined;
    try std.testing.expect(!std.mem.eql(u8, direct.memoKey(&direct_buf).?, tor.memoKey(&tor_buf).?));
}
