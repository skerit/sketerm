//! Shared SSH route planning for direct and forced Tor mux connections.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const shellquote = @import("../util/shellquote.zig");
const socks5_client = @import("socks5_client.zig");

pub const Mode = enum { auto, ssh, udp, tor };
pub const Route = enum { direct, tor };

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

pub const Plan = struct {
    destination: []const u8,
    route: Route = .direct,
    tor_endpoint: []const u8 = socks5_client.DEFAULT_ENDPOINT,

    /// OpenSSH percent-expands `%h` INTO the ProxyCommand string and then
    /// runs the result through `/bin/sh -c`. Our command starts with `exec`,
    /// which makes an injected `';cmd;'` unreachable today, but that is a
    /// subtle property to depend on: one edit to the command prefix would
    /// turn a destination into arbitrary local execution. Constrain the
    /// destination to what an SSH alias or user@host can legitimately hold.
    fn validDestination(destination: []const u8) bool {
        if (destination.len == 0 or destination[0] == '-') return false;
        for (destination) |byte| switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_', '@', ':', '[', ']' => {},
            else => return false,
        };
        return true;
    }

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
        try command.appendSlice(std.heap.c_allocator, " --internal-socks5-connect ");
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

test "route memo identity separates direct and Tor verification" {
    const direct = try Plan.init("alias", .direct, socks5_client.DEFAULT_ENDPOINT);
    const tor = try Plan.init("alias", .tor, socks5_client.DEFAULT_ENDPOINT);
    var direct_buf: [128]u8 = undefined;
    var tor_buf: [128]u8 = undefined;
    try std.testing.expect(!std.mem.eql(u8, direct.memoKey(&direct_buf).?, tor.memoKey(&tor_buf).?));
}
