//! Enforced per-view network policy: the pure decision half.
//!
//! The helper's IO thread calls `decide` inline in
//! `on_before_resource_load` (cefhost.zig), so everything here is
//! allocation-free, clock-free (`now_ms` is passed in) and std-only —
//! no CEF, no GTK — which is what lets the whole enforcement table be
//! unit-tested with no helper process anywhere. The reason vocabulary
//! is `protocol.NetReason` (it is a wire byte); the resource-type mask
//! is `filter.RType` bits. Neither is restated here.

const std = @import("std");
const filter = @import("filter.zig");
const proto = @import("protocol.zig");
const urlhost = @import("urlhost.zig");

/// Hosts an allow-list can carry. The MCP layer refuses more, loudly;
/// the wire clamps at u16 as a last resort.
pub const MAX_HOSTS = 64;

/// URL schemes a policy can allow. A scheme outside this vocabulary is
/// always refused (fail closed on the unknown). `about:` is not here
/// because it is ALWAYS allowed: it is a view's own blank document, and
/// refusing it would break view creation itself.
pub const Scheme = enum(u4) {
    http,
    https,
    ws,
    wss,
    file,
    data,
    blob,

    pub fn bit(self: Scheme) u16 {
        return @as(u16, 1) << @intFromEnum(self);
    }
};

pub const default_schemes: u16 = Scheme.http.bit() | Scheme.https.bit();

/// Application-owned sign-in views need exact hosts and iframe-only paths,
/// while ordinary CDN resources remain available. This is not a wildcard host
/// policy: it is a separate, capability-negotiated navigation contract.
pub const NavigationRule = struct { host: []const u8, subdomains: bool = false, path: ?[]const u8 = null };
pub const NavigationGuard = struct {
    hosts: []const NavigationRule,
    frames: []const NavigationRule = &.{},

    pub fn validate(self: NavigationGuard) !void {
        if (self.hosts.len == 0 or self.hosts.len > MAX_HOSTS or self.frames.len > MAX_HOSTS) return error.BadNavigationGuard;
        for ([_][]const NavigationRule{ self.hosts, self.frames }) |rules| for (rules) |rule| {
            if (!validHostEntry(rule.host) or std.mem.indexOfAny(u8, rule.host, ":[]") != null or
                std.mem.endsWith(u8, rule.host, ".") or !std.ascii.isLower(rule.host[0])) return error.BadNavigationGuard;
            if (rule.path) |p| if (p.len == 0 or p[0] != '/' or std.mem.indexOfAny(u8, p, "?#") != null) return error.BadNavigationGuard;
        };
    }

    fn matches(rules: []const NavigationRule, host: []const u8, path: []const u8) bool {
        for (rules) |rule| {
            const host_ok = std.ascii.eqlIgnoreCase(host, rule.host) or (rule.subdomains and filter.hostWithin(host, rule.host));
            if (host_ok and (rule.path == null or std.mem.eql(u8, path, rule.path.?))) return true;
        }
        return false;
    }

    pub fn decide(self: NavigationGuard, url: []const u8, rtype: filter.RType) proto.NetReason {
        const navigation = rtype == .document or rtype == .subdocument;
        if (std.mem.eql(u8, url, "about:blank")) return .none;
        const host = urlhost.hostOf(url, urlhost.filtering);
        // This also blocks OAuth callbacks sent by images/fetches, not only
        // document navigations. The main-frame error event carries the full URL.
        if (isPrivateHostLiteral(host)) return .private_address;
        if (!navigation) return .none;
        if (!std.mem.startsWith(u8, url, "https://")) return .scheme;
        const rest = url[8..];
        const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        if (std.mem.indexOfScalar(u8, rest[0..end], '@') != null) return .malformed_url;
        if (urlhost.portOf(url) != 443) return .malformed_url;
        var pathname = rest[end..];
        if (std.mem.indexOfAny(u8, pathname, "?#")) |i| pathname = pathname[0..i];
        if (pathname.len == 0) pathname = "/";
        if (matches(self.hosts, host, pathname)) return .none;
        if (rtype == .subdocument and matches(self.frames, host, pathname)) return .none;
        return if (rtype == .document) .top_host else .sub_host;
    }
};

test "navigation guard separates exact hosts, iframe paths and resource requests" {
    const guard = NavigationGuard{
        .hosts = &.{ .{ .host = "auth.openai.com" }, .{ .host = "claude.ai", .subdomains = true } },
        .frames = &.{.{ .host = "sentinel.openai.com", .path = "/backend-api/sentinel/frame.html" }},
    };
    try guard.validate();
    const t = std.testing;
    for ([_][]const u8{ "https://auth.openai.com/login", "https://auth.openai.com:443/login", "https://sub.claude.ai/" }) |url|
        try t.expectEqual(proto.NetReason.none, guard.decide(url, .document));
    for ([_][]const u8{ "https://evil.auth.openai.com/", "https://auth.openai.com.evil.test/", "https://auth.openai.com./", "https://user@auth.openai.com/", "https://auth.openai.com:444/", "http://auth.openai.com/", "data:text/html,hello" }) |url|
        try t.expect(guard.decide(url, .document) != .none);
    const frame = "https://sentinel.openai.com/backend-api/sentinel/frame.html?version=fixture";
    try t.expectEqual(proto.NetReason.none, guard.decide(frame, .subdocument));
    try t.expect(guard.decide(frame, .document) != .none);
    try t.expect(guard.decide("https://sentinel.openai.com/backend-api/sentinel/frame.html/", .subdocument) != .none);
    try t.expect(guard.decide("https://sentinel.openai.com/other", .subdocument) != .none);
    try t.expectEqual(proto.NetReason.none, guard.decide("https://cdn.example.com/script.js", .script));
    for ([_][]const u8{ "http://localhost:1455/auth/callback?code=secret", "http://127.0.0.1:1455/auth/callback", "http://[::1]/", "https://sub.localhost/" }) |url| {
        try t.expectEqual(proto.NetReason.private_address, guard.decide(url, .document));
        try t.expectEqual(proto.NetReason.private_address, guard.decide(url, .xhr));
    }
}

/// Immutable after `build`; the helper swaps whole policies under the
/// intercept spinlock exactly the way filter engines are swapped.
pub const Policy = struct {
    arena_state: std.heap.ArenaAllocator,
    serial: u32,
    /// Empty means no hosted top-level requests, never allow-all.
    allow_top: []const []const u8 = &.{},
    /// EXTRA hosts subresources may use; the effective subresource list
    /// is always the union with `allow_top`.
    allow_sub: []const []const u8 = &.{},
    /// `filter.RType`-indexed bits of resource classes to refuse.
    block_types: u16 = 0,
    allow_schemes: u16 = default_schemes,
    allow_private: bool = false,
    untrusted: bool = false,
    /// The helper's route is a caller-given proxy that resolves every
    /// host and decides which addresses are reachable
    /// (`webroute.Kind.proxyDecidesAddresses`): a private-looking host
    /// is the proxy's to refuse or serve, since nothing here connects to
    /// it. Set by the helper from its instance, never from the wire.
    proxy_decides_addresses: bool = false,
    max_requests: u32 = 0,
    max_bytes: u64 = 0,
    max_navigations: u32 = 0,
    deadline_ms: u32 = 0,
    navigation_guard: ?NavigationGuard = null,
    navigation_guard_json: []const u8 = "",

    /// Deep-copy a decoded wire frame into an owned policy. Caller
    /// destroys with `deinit` (outside any lock).
    pub fn build(gpa: std.mem.Allocator, req: proto.NetPolicySet) !*Policy {
        const p = try gpa.create(Policy);
        errdefer gpa.destroy(p);
        p.* = .{
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .serial = req.serial,
            .block_types = req.block_types,
            .allow_schemes = req.allow_schemes,
            .allow_private = req.flags & proto.NetPolicySet.flag_allow_private != 0,
            .untrusted = req.flags & proto.NetPolicySet.flag_untrusted != 0,
            .max_requests = req.max_requests,
            .max_bytes = req.max_bytes,
            .max_navigations = req.max_navigations,
            .deadline_ms = req.deadline_ms,
        };
        errdefer p.arena_state.deinit();
        const arena = p.arena_state.allocator();
        p.allow_top = try dupeHosts(arena, req.allow_top);
        p.allow_sub = try dupeHosts(arena, req.allow_sub);
        if (req.navigation_guard.len > 0) {
            if (p.untrusted) return error.BadNavigationGuard;
            p.navigation_guard_json = try arena.dupe(u8, req.navigation_guard);
            p.navigation_guard = try std.json.parseFromSliceLeaky(NavigationGuard, arena, p.navigation_guard_json, .{});
            try p.navigation_guard.?.validate();
        }
        return p;
    }

    pub fn deinit(self: *Policy, gpa: std.mem.Allocator) void {
        self.arena_state.deinit();
        gpa.destroy(self);
    }
};

fn dupeHosts(arena: std.mem.Allocator, hosts: []const []const u8) ![]const []const u8 {
    const n = @min(hosts.len, MAX_HOSTS);
    const out = try arena.alloc([]const u8, n);
    for (out, hosts[0..n]) |*d, s| d.* = try arena.dupe(u8, s);
    return out;
}

/// Live accounting for one view, mutated under the helper's intercept lock.
pub const Counters = struct {
    /// Policy install time; the deadline anchors here.
    started_ms: i64 = 0,
    requests: u32 = 0,
    bytes: u64 = 0,
    navigations: u32 = 0,
    denied: [proto.NREASONS]u32 = @splat(0),
    /// Latched at the first budget hit; every later `decide` answers
    /// the same reason so a caller is told once, loudly, not per URL.
    exhausted: proto.NetReason = .none,
};

/// One request as the gate sees it.
pub const Req = struct {
    url: []const u8 = "",
    host: []const u8,
    scheme: []const u8,
    port: u16 = 0,
    rtype: filter.RType,
    is_top: bool,
    /// The ring already holds a live entry with this request id: CEF
    /// re-issued a redirected request (the id survives the chain), so a
    /// host denial is a `redirect_host`.
    is_redirect_hop: bool = false,
};

/// Check budgets without counting or latching; navigation preflight and the resource gate share this rule.
pub fn budgetReason(p: *const Policy, c: *const Counters, is_top: bool, scheme: []const u8, now_ms: i64) proto.NetReason {
    if (c.exhausted != .none) return c.exhausted;
    if (p.deadline_ms != 0 and now_ms - c.started_ms >= p.deadline_ms) return .deadline;
    if (std.mem.eql(u8, scheme, "about")) return .none;
    if (is_top and p.max_navigations != 0 and c.navigations >= p.max_navigations) return .nav_cap;
    if (p.max_requests != 0 and c.requests >= p.max_requests) return .request_cap;
    if (p.max_bytes != 0 and c.bytes >= p.max_bytes) return .byte_cap;
    return .none;
}

/// First refusal wins; callers count allowed requests with `commit` and latch refusals with `deny`.
pub fn decide(p: *const Policy, c: *const Counters, r: Req, now_ms: i64) proto.NetReason {
    const budget = budgetReason(p, c, r.is_top, r.scheme, now_ms);
    if (c.exhausted != .none or budget == .deadline) return budget;

    // The view's own blank document; refusing it breaks view creation.
    if (std.mem.eql(u8, r.scheme, "about")) return .none;
    const scheme = std.meta.stringToEnum(Scheme, r.scheme) orelse return .scheme;
    if (p.untrusted and scheme != .http and scheme != .https) return .untrusted_transport;
    if (p.allow_schemes & scheme.bit() == 0) return .scheme;
    if (p.navigation_guard) |guard| {
        const reason = guard.decide(r.url, r.rtype);
        if (reason != .none) return reason;
        if (p.block_types & r.rtype.bit() != 0) return .resource_type;
        return budget;
    }

    // Hostless schemes (data:, about:, blob:) are judged by scheme
    // alone: there is no authority to test.
    if (r.host.len > 0) {
        if (!p.allow_private and !p.proxy_decides_addresses and isPrivateHostLiteral(r.host)) return .private_address;
        const listed = hostAllowed(p, r);
        if (!listed) return if (r.is_redirect_hop) .redirect_host else if (r.is_top) .top_host else .sub_host;
    }

    if (p.block_types & r.rtype.bit() != 0) return .resource_type;

    return budget;
}

fn hostAllowed(p: *const Policy, r: Req) bool {
    for (p.allow_top) |base| {
        if (entryAllows(base, r.host, r.port, r.scheme, p.untrusted)) return true;
    }
    if (!r.is_top) {
        for (p.allow_sub) |base| {
            if (entryAllows(base, r.host, r.port, r.scheme, p.untrusted)) return true;
        }
    }
    return false;
}

/// An IP-literal entry names exactly that address (compared as bytes, so
/// spelling and case do not matter); a hostname entry also covers its
/// subdomains and never an address.
fn hostMatches(host: []const u8, base: []const u8) bool {
    if (ipLiteral(base)) |want| {
        const got = ipLiteral(host) orelse return false;
        return got.eql(want);
    }
    if (ipLiteral(host) != null) return false;
    return filter.hostWithin(host, base);
}

pub fn entryAllows(entry: []const u8, host: []const u8, port: u16, scheme: []const u8, untrusted: bool) bool {
    const base = urlhost.authorityOf(entry) orelse return false;
    const target = urlhost.authorityOf(host) orelse return false;
    if (!hostMatches(target.host, base.host)) return false;
    const effective = if (port != 0) port else urlhost.defaultPort(scheme);
    if (base.port != 0) return effective == base.port;
    return !untrusted or (effective != 0 and effective == urlhost.defaultPort(scheme));
}

pub fn entrySubset(narrow: []const u8, wide: []const u8, untrusted: bool, schemes: u16) bool {
    const n = urlhost.authorityOf(narrow) orelse return false;
    const w = urlhost.authorityOf(wide) orelse return false;
    if (!hostMatches(n.host, w.host)) return false;
    if (w.port != 0) return n.port == w.port;
    if (!untrusted or n.port == 0) return true;
    // An explicit port spans schemes; a bare untrusted entry does not.
    for ([_]Scheme{ .http, .https }) |scheme| {
        if (schemes & scheme.bit() != 0 and n.port != urlhost.defaultPort(@tagName(scheme))) return false;
    }
    return true;
}

/// Compare complete policies without allowing a replacement to expand any request scope.
pub fn subsetOf(next: *const Policy, old: *const Policy) bool {
    // Navigation guards are immutable for a view's lifetime. Replacements may
    // tighten budgets/types but cannot silently replace this authority.
    if (!std.mem.eql(u8, next.navigation_guard_json, old.navigation_guard_json)) return false;
    if (old.navigation_guard != null) {
        // Host-list patches must not claim to narrow an authority supplied by
        // the immutable navigation rules. Guarded views only tighten budgets,
        // schemes and resource types; a new authority requires a new view.
        for ([_][2][]const []const u8{ .{ next.allow_top, old.allow_top }, .{ next.allow_sub, old.allow_sub } }) |pair| {
            if (pair[0].len != pair[1].len) return false;
            for (pair[0], pair[1]) |a, b| if (!std.mem.eql(u8, a, b)) return false;
        }
    }
    if (next.untrusted != old.untrusted or
        (next.allow_private and !old.allow_private) or
        next.allow_schemes & ~old.allow_schemes != 0 or
        old.block_types & ~next.block_types != 0) return false;
    inline for (.{ "max_requests", "max_bytes", "max_navigations", "deadline_ms" }) |field| {
        const before = @field(old, field);
        const after = @field(next, field);
        if (before != 0 and (after == 0 or after > before)) return false;
    }
    for (next.allow_top) |entry| {
        var covered = false;
        for (old.allow_top) |base| if (entrySubset(entry, base, old.untrusted, next.allow_schemes)) {
            covered = true;
            break;
        };
        if (!covered) return false;
    }
    for (next.allow_sub) |entry| {
        var covered = false;
        for ([_][]const []const u8{ old.allow_top, old.allow_sub }) |list| {
            for (list) |base| if (entrySubset(entry, base, old.untrusted, next.allow_schemes)) {
                covered = true;
                break;
            };
        }
        if (!covered) return false;
    }
    return true;
}

/// Record one ALLOWED request. Kept beside `decide` so the counting
/// semantics ("requests counts every allowed request, document
/// included; every main-frame hop is a navigation") have one home.
pub fn commit(c: *Counters, is_top: bool) void {
    c.requests +%= 1;
    if (is_top) c.navigations +%= 1;
}

/// Record one refusal, latching budget reasons.
pub fn deny(c: *Counters, reason: proto.NetReason) void {
    const idx = @intFromEnum(reason);
    if (idx < c.denied.len) c.denied[idx] +%= 1;
    switch (reason) {
        .request_cap, .byte_cap, .nav_cap, .deadline => {
            if (c.exhausted == .none) c.exhausted = reason;
        },
        else => {},
    }
}

/// The scheme part of a folded url, "" when it has none.
pub fn schemeOf(url: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return "";
    return url[0..colon];
}

/// An address literal, family-tagged. IPv4 must be canonical dotted quad
/// (a leading zero is octal to a URL parser, so it is refused, not read
/// as decimal); IPv6 may be bracketed, in any case or compression.
pub const Ip = union(enum) {
    v4: [4]u8,
    v6: [16]u8,

    pub fn eql(a: Ip, b: Ip) bool {
        return switch (a) {
            .v4 => |x| b == .v4 and std.mem.eql(u8, &x, &b.v4),
            .v6 => |x| b == .v6 and std.mem.eql(u8, &x, &b.v6),
        };
    }
};

pub fn ipLiteral(host: []const u8) ?Ip {
    var h = host;
    if (h.len >= 2 and h[0] == '[' and h[h.len - 1] == ']') h = h[1 .. h.len - 1];
    if (std.mem.indexOfScalar(u8, h, ':') != null) return .{ .v6 = parseV6(h) orelse return null };
    const a = std.Io.net.Ip4Address.parse(h, 0) catch return null;
    return .{ .v4 = a.bytes };
}

/// RFC 4291 text (one `::`, an optional dotted IPv4 tail, no zone). Not
/// `std.Io.net.Ip6Address.parse`: it refuses `::ffff:7f00:1`, the very
/// form Chromium canonicalizes IPv4-mapped hosts to.
fn parseV6(text: []const u8) ?[16]u8 {
    var groups: [8]u16 = @splat(0);
    var n: usize = 0;
    var gap: ?usize = null;
    var rest = text;
    if (std.mem.startsWith(u8, rest, "::")) {
        gap = 0;
        rest = rest[2..];
    } else if (rest.len != 0 and rest[0] == ':') return null;
    while (rest.len != 0) {
        const end = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
        const part = rest[0..end];
        if (std.mem.indexOfScalar(u8, part, '.') != null) {
            // A dotted IPv4 tail fills the last two groups and ends the text.
            if (end != rest.len or n > 6) return null;
            const v4 = std.Io.net.Ip4Address.parse(part, 0) catch return null;
            groups[n] = @as(u16, v4.bytes[0]) << 8 | v4.bytes[1];
            groups[n + 1] = @as(u16, v4.bytes[2]) << 8 | v4.bytes[3];
            n += 2;
            rest = "";
            break;
        }
        if (part.len == 0 or part.len > 4 or n == 8) return null;
        groups[n] = std.fmt.parseInt(u16, part, 16) catch return null;
        n += 1;
        rest = rest[end..];
        if (rest.len == 0) break;
        if (std.mem.startsWith(u8, rest, "::")) {
            if (gap != null) return null;
            gap = n;
            rest = rest[2..];
        } else {
            rest = rest[1..];
            if (rest.len == 0) return null;
        }
    }
    if (gap) |at| {
        if (n == 8) return null;
        const tail = n - at;
        var i: usize = 0;
        while (i < tail) : (i += 1) {
            groups[7 - i] = groups[n - 1 - i];
            groups[n - 1 - i] = 0;
        }
    } else if (n != 8) return null;
    var out: [16]u8 = undefined;
    for (groups, 0..) |g, i| std.mem.writeInt(u16, out[i * 2 ..][0..2], g, .big);
    return out;
}

/// A host the gate must treat as non-public WITHOUT resolving it: a
/// reserved name, or an address literal outside ordinary public unicast.
/// The address rule mirrors the untrusted broker's connect-time check
/// (`sk_public_address` in `vendor/web_untrusted.c`) range for range, so a
/// literal is refused here exactly when the broker would refuse its
/// socket. A hostname that merely RESOLVES to a private address is
/// invisible here (no resolver on this path); the positive host
/// allow-list and, untrusted, the broker are the defence there.
pub fn isPrivateHostLiteral(host: []const u8) bool {
    if (host.len == 0) return false;
    // Reserved names.
    if (std.mem.eql(u8, host, "localhost")) return true;
    if (std.mem.endsWith(u8, host, ".localhost")) return true;
    if (std.mem.endsWith(u8, host, ".local")) return true;
    if (std.mem.endsWith(u8, host, ".internal")) return true;
    if (ipLiteral(host)) |ip| return switch (ip) {
        .v4 => |b| !publicV4(b),
        .v6 => |b| !publicV6(b),
    };
    // Address-shaped but not a canonical literal (an unparseable IPv6, a
    // numeric last label a URL parser reads as IPv4): refuse, never guess.
    var h = host;
    if (h[0] == '[') return true;
    if (std.mem.indexOfScalar(u8, h, ':') != null) return true;
    if (std.mem.lastIndexOfScalar(u8, h, '.')) |dot| h = h[dot + 1 ..];
    return numericLabel(h);
}

/// The broker's `sk_public_v4`: everything IANA reserves as special-purpose,
/// multicast or reserved is not public.
pub fn publicV4(b: [4]u8) bool {
    if (b[0] == 0 or b[0] == 10 or b[0] == 127 or b[0] >= 224) return false;
    if (b[0] == 100 and (b[1] & 0xc0) == 64) return false;
    if (b[0] == 169 and b[1] == 254) return false;
    if (b[0] == 172 and (b[1] & 0xf0) == 16) return false;
    if (b[0] == 192 and (b[1] == 168 or (b[1] == 0 and (b[2] == 0 or b[2] == 2)) or (b[1] == 88 and b[2] == 99))) return false;
    if (b[0] == 198 and (b[1] == 18 or b[1] == 19 or (b[1] == 51 and b[2] == 100))) return false;
    if (b[0] == 203 and b[1] == 0 and b[2] == 113) return false;
    return true;
}

/// The broker's IPv6 half: an IPv4-mapped address is judged as its IPv4;
/// otherwise only 2000::/3 global unicast, minus 2001::/23 (Teredo and the
/// other protocol assignments), 2001:db8::/32, 2002::/16 (6to4) and 3fff::/20.
pub fn publicV6(b: [16]u8) bool {
    const mapped = [12]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
    if (std.mem.eql(u8, b[0..12], &mapped)) return publicV4(b[12..16].*);
    if ((b[0] & 0xe0) != 0x20) return false;
    if (b[0] == 0x20 and b[1] == 0x01 and b[2] < 2) return false;
    if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0x0d and b[3] == 0xb8) return false;
    if (b[0] == 0x20 and b[1] == 0x02) return false;
    if (b[0] == 0x3f and b[1] == 0xff and (b[2] & 0xf0) == 0) return false;
    return true;
}

/// A label a URL parser reads as a number (decimal, or 0x-prefixed hex).
fn numericLabel(label: []const u8) bool {
    if (label.len == 0) return false;
    if (label.len >= 2 and label[0] == '0' and (label[1] == 'x' or label[1] == 'X')) {
        for (label[2..]) |ch| if (!std.ascii.isHex(ch)) return false;
        return true;
    }
    for (label) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// Resource-class names -> `filter.RType` mask. Derived from the enum
/// (one home); an unknown name is a loud null, never a silent skip.
pub fn typeBit(name: []const u8) ?u16 {
    const t = std.meta.stringToEnum(filter.RType, name) orelse return null;
    return t.bit();
}

/// Scheme names -> mask bit, same contract as `typeBit`.
pub fn schemeBit(name: []const u8) ?u16 {
    const s = std.meta.stringToEnum(Scheme, name) orelse return null;
    return s.bit();
}

/// Host entries may include a nonzero port; IPv6 with a port must be bracketed.
///
/// An entry is EITHER a complete address literal (matched exactly) or a
/// lower-case hostname whose last label is not numeric: "0.1" or "2.3.4"
/// would otherwise act as a suffix of every address ending in it.
pub fn validHostEntry(host: []const u8) bool {
    if (host.len == 0 or host.len > 253) return false;
    const authority = urlhost.authorityOf(host) orelse return false;
    if (ipLiteral(authority.host) != null) return true;
    if (std.mem.indexOfScalar(u8, authority.host, ':') != null) return false;
    var it = std.mem.splitScalar(u8, authority.host, '.');
    var last: []const u8 = "";
    while (it.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |ch| {
            const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-';
            if (!ok) return false;
        }
        last = label;
    }
    return !numericLabel(last);
}

/// Errors `canonicalEntry` names so a caller can say WHY a url host cannot be an entry.
pub const EntryError = error{ NonAscii, InvalidHost, NoSpaceLeft };

/// The policy entry for a url's host (and port, when nonzero): lower-cased
/// hostname, or an address literal in the form Chromium canonicalizes
/// request hosts to (RFC 5952 hex groups, IPv6 bracketed). A non-ASCII
/// (IDN) host is refused: there is no punycode encoder here, and a
/// lowercased Unicode name would never match the engine's xn-- host.
pub fn canonicalEntry(buf: []u8, host: []const u8, port: u16) EntryError![]const u8 {
    for (host) |ch| if (ch >= 0x80) return error.NonAscii;
    var w = std.Io.Writer.fixed(buf);
    if (ipLiteral(host)) |ip| switch (ip) {
        .v4 => |b| w.print("{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }) catch return error.NoSpaceLeft,
        .v6 => |b| {
            w.writeByte('[') catch return error.NoSpaceLeft;
            writeV6(&w, b) catch return error.NoSpaceLeft;
            w.writeByte(']') catch return error.NoSpaceLeft;
        },
    } else {
        if (host.len > buf.len) return error.NoSpaceLeft;
        for (host) |ch| w.writeByte(std.ascii.toLower(ch)) catch return error.NoSpaceLeft;
    }
    if (port != 0) w.print(":{d}", .{port}) catch return error.NoSpaceLeft;
    const out = buf[0..w.end];
    if (!validHostEntry(out)) return error.InvalidHost;
    return out;
}

/// RFC 5952 text, hex groups throughout (Chromium writes a mapped address as `::ffff:7f00:1`).
fn writeV6(w: *std.Io.Writer, b: [16]u8) !void {
    var parts: [8]u16 = undefined;
    for (&parts, 0..) |*p, i| p.* = std.mem.readInt(u16, b[i * 2 ..][0..2], .big);
    var best: usize = 8;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < 8) {
        if (parts[i] != 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < 8 and parts[j] == 0) j += 1;
        if (j - i > best_len) {
            best = i;
            best_len = j - i;
        }
        i = j;
    }
    if (best_len < 2) best = 8;
    i = 0;
    while (i < 8) {
        if (i == best) {
            // The group before already wrote its separator.
            try w.writeAll(if (i == 0) "::" else ":");
            i += best_len;
            continue;
        }
        try w.print("{x}", .{parts[i]});
        i += 1;
        if (i < 8) try w.writeByte(':');
    }
}

// ---------------------------------------------------------------------
// Tests: the decision table, no CEF, no sockets.
// ---------------------------------------------------------------------

const testing = std.testing;

fn testPolicy(arena_gpa: std.mem.Allocator, req: proto.NetPolicySet) !*Policy {
    return Policy.build(arena_gpa, req);
}

fn baseSet() proto.NetPolicySet {
    return .{
        .view = 1,
        .serial = 1,
        .flags = 0,
        .block_types = 0,
        .allow_schemes = default_schemes,
        .max_requests = 0,
        .max_bytes = 0,
        .max_navigations = 0,
        .deadline_ms = 0,
        .allow_top = &.{"site.example"},
        .allow_sub = &.{},
    };
}

test "host allow-list: subdomains yes, sibling suffixes and lookalikes no" {
    const p = try testPolicy(testing.allocator, baseSet());
    defer p.deinit(testing.allocator);
    const c = Counters{};
    const yes = [_][]const u8{ "site.example", "a.site.example", "deep.a.site.example" };
    for (yes) |h| try testing.expectEqual(proto.NetReason.none, decide(p, &c, .{ .host = h, .scheme = "https", .rtype = .document, .is_top = true }, 0));
    const no = [_][]const u8{ "notsite.example", "site.example.attacker.net", "example", "other.example" };
    for (no) |h| try testing.expectEqual(proto.NetReason.top_host, decide(p, &c, .{ .host = h, .scheme = "https", .rtype = .document, .is_top = true }, 0));
}

test "subresource list is a union with the top list; empty means top only" {
    var set = baseSet();
    set.allow_sub = &.{"cdn.example"};
    const p = try testPolicy(testing.allocator, set);
    defer p.deinit(testing.allocator);
    const c = Counters{};
    try testing.expectEqual(proto.NetReason.none, decide(p, &c, .{ .host = "cdn.example", .scheme = "https", .rtype = .image, .is_top = false }, 0));
    try testing.expectEqual(proto.NetReason.none, decide(p, &c, .{ .host = "site.example", .scheme = "https", .rtype = .image, .is_top = false }, 0));
    // The sub list never widens the TOP-LEVEL document.
    try testing.expectEqual(proto.NetReason.top_host, decide(p, &c, .{ .host = "cdn.example", .scheme = "https", .rtype = .document, .is_top = true }, 0));
    // A denied redirect hop names the redirect, not the list.
    try testing.expectEqual(proto.NetReason.redirect_host, decide(p, &c, .{ .host = "evil.example", .scheme = "https", .rtype = .document, .is_top = true, .is_redirect_hop = true }, 0));
}

test "type mask refuses the named classes and never a document by accident" {
    var set = baseSet();
    set.block_types = typeBit("image").? | typeBit("media").? | typeBit("font").?;
    const p = try testPolicy(testing.allocator, set);
    defer p.deinit(testing.allocator);
    const c = Counters{};
    try testing.expectEqual(proto.NetReason.resource_type, decide(p, &c, .{ .host = "site.example", .scheme = "https", .rtype = .image, .is_top = false }, 0));
    try testing.expectEqual(proto.NetReason.resource_type, decide(p, &c, .{ .host = "site.example", .scheme = "https", .rtype = .media, .is_top = false }, 0));
    try testing.expectEqual(proto.NetReason.none, decide(p, &c, .{ .host = "site.example", .scheme = "https", .rtype = .document, .is_top = true }, 0));
    try testing.expect(typeBit("no-such-type") == null);
}

test "private-literal table" {
    const private = [_][]const u8{
        "127.0.0.1",     "127.9.9.9",     "0.0.0.0",     "10.0.0.1", "172.16.0.1",
        "172.31.255.1",  "192.168.1.1",   "169.254.0.9", "::1",      "[::1]",
        "fe80::1",       "[febf::2]",     "fc00::1",     "fd12::3",  "localhost",
        "sub.localhost", "printer.local", "db.internal",
    };
    for (private) |h| try testing.expect(isPrivateHostLiteral(h));
    const public = [_][]const u8{
        "172.15.0.1",     "172.32.0.1",            "11.0.0.1",         "192.169.1.1",  "10.example.com",
        "notlocalhost",   "localhost.example.com", "2606:4700::1111",  "site.example", "1.2.3.4",
        "[2a00:1450::1]", "[::ffff:1.2.3.4]",      "[::ffff:102:304]",
    };
    for (public) |h| try testing.expect(!isPrivateHostLiteral(h));
}

test "literal classifier matches the broker's connect-time ranges" {
    // Each row: a literal and whether `sk_public_address` would connect to it.
    const rows = [_]struct { []const u8, bool }{
        .{ "0.0.0.0", false },            .{ "0.255.1.1", false },             .{ "10.1.2.3", false },
        .{ "100.63.255.255", true },      .{ "100.64.0.1", false },            .{ "100.127.255.255", false },
        .{ "100.128.0.1", true },         .{ "127.0.0.1", false },             .{ "169.254.1.1", false },
        .{ "172.16.0.1", false },         .{ "172.31.255.255", false },        .{ "192.0.0.8", false },
        .{ "192.0.2.1", false },          .{ "192.88.99.1", false },           .{ "192.168.0.1", false },
        .{ "198.18.0.1", false },         .{ "198.19.255.1", false },          .{ "198.51.100.1", false },
        .{ "203.0.113.9", false },        .{ "224.0.0.1", false },             .{ "239.255.255.250", false },
        .{ "240.0.0.1", false },          .{ "255.255.255.255", false },       .{ "8.8.8.8", true },
        .{ "223.255.255.255", true },     .{ "198.20.0.1", true },             .{ "192.0.1.1", true },
        .{ "[::]", false },               .{ "[::1]", false },                 .{ "[::ffff:127.0.0.1]", false },
        .{ "[::ffff:7f00:1]", false },    .{ "[::ffff:a00:1]", false },        .{ "[::ffff:808:808]", true },
        .{ "[fc00::1]", false },          .{ "[fe80::1]", false },             .{ "[fec0::1]", false },
        .{ "[ff02::1]", false },          .{ "[ff0e::1]", false },             .{ "[64:ff9b::7f00:1]", false },
        .{ "[64:ff9b::808:808]", false }, .{ "[2002:7f00:1::]", false },       .{ "[2002:808:808::1]", false },
        .{ "[2001::1]", false },          .{ "[2001:0:4136:e378::1]", false }, .{ "[2001:1ff::1]", false },
        .{ "[2001:200::1]", true },       .{ "[2001:db8::1]", false },         .{ "[2001:DB8::1]", false },
        .{ "[3fff::1]", false },          .{ "[3fff:1000::1]", true },         .{ "[2606:4700::1]", true },
        .{ "[4000::1]", false },          .{ "[1fff::1]", false },
    };
    for (rows) |row| {
        if (isPrivateHostLiteral(row[0]) == row[1]) {
            std.debug.print("misclassified {s}\n", .{row[0]});
            return error.Misclassified;
        }
    }
    // Address-shaped hosts that are not canonical literals are refused, not guessed.
    for ([_][]const u8{ "2130706433", "0x7f000001", "127.1", "a.0x7f", "[bad::ipv6::]", "010.0.0.1" }) |h|
        try testing.expect(isPrivateHostLiteral(h));
}

test "IP literal entries match exactly; hostname entries never match addresses" {
    try testing.expect(entryAllows("1.2.3.4", "1.2.3.4", 0, "https", false));
    try testing.expect(!entryAllows("1.2.3.4", "5.1.2.3.4", 0, "https", false));
    try testing.expect(entryAllows("[2001:0DB8::1]", "2001:db8::1", 0, "https", false));
    try testing.expect(entryAllows("[2001:db8:0:0::1]:8443", "[2001:db8::1]", 8443, "https", false));
    try testing.expect(!entryAllows("[2001:db8::1]", "2001:db8::2", 0, "https", false));
    try testing.expect(!entryAllows("1.2.3.4", "[::ffff:1.2.3.4]", 0, "https", false));
    try testing.expect(!entryAllows("example", "1.2.3.4", 0, "https", false));
    try testing.expect(entrySubset("[2001:db8::1]", "[2001:DB8:0::1]", false, default_schemes));
    try testing.expect(!entrySubset("1.2.3.4", "2.3.4", false, default_schemes));
    for ([_][]const u8{ "0.1", "2.3.4", "4", "1.2.3", "a.0x1f", "a..b", "-a.example", "a-.example", "example.", "1.2.3.04", "[::1", "::1:8080x" }) |entry|
        try testing.expect(!validHostEntry(entry));
    for ([_][]const u8{ "1.2.3.4", "1.2.3.4:80", "2001:db8::1", "[2001:DB8::1]:443", "a1.example", "x-y.example", "localhost" }) |entry|
        try testing.expect(validHostEntry(entry));
}

test "canonical entries lower-case names, compress IPv6 and refuse IDN text" {
    var buf: [300]u8 = undefined;
    try testing.expectEqualStrings("site.example:8443", try canonicalEntry(&buf, "SiTe.Example", 8443));
    try testing.expectEqualStrings("[2001:db8::1]", try canonicalEntry(&buf, "[2001:0DB8:0:0::1]", 0));
    try testing.expectEqualStrings("[::ffff:7f00:1]:443", try canonicalEntry(&buf, "[::ffff:127.0.0.1]", 443));
    try testing.expectEqualStrings("[::1]", try canonicalEntry(&buf, "[::1]", 0));
    try testing.expectEqualStrings("[1::]", try canonicalEntry(&buf, "[1:0:0:0:0:0:0:0]", 0));
    try testing.expectEqualStrings("[1:0:2::3]", try canonicalEntry(&buf, "[1:0:2:0:0:0:0:3]", 0));
    try testing.expectEqualStrings("[1:2:3:4:5:6:7:8]", try canonicalEntry(&buf, "[1:2:3:4:5:6:7:8]", 0));
    try testing.expectEqualStrings("10.0.0.1:80", try canonicalEntry(&buf, "10.0.0.1", 80));
    try testing.expectError(error.NonAscii, canonicalEntry(&buf, "b\xc3\xbccher.example", 0));
    try testing.expectError(error.InvalidHost, canonicalEntry(&buf, "1.2.3", 0));
    try testing.expectError(error.InvalidHost, canonicalEntry(&buf, "under_score.example", 0));
}

test "scheme mask, hostless schemes, and the private toggle" {
    var set = baseSet();
    set.allow_schemes = default_schemes | schemeBit("data").?;
    const p = try testPolicy(testing.allocator, set);
    defer p.deinit(testing.allocator);
    const c = Counters{};
    // data: carries no host: scheme alone decides. about: is always
    // allowed (a view's own blank document).
    try testing.expectEqual(proto.NetReason.none, decide(p, &c, .{ .host = "", .scheme = "data", .rtype = .image, .is_top = false }, 0));
    try testing.expectEqual(proto.NetReason.none, decide(p, &c, .{ .host = "", .scheme = "about", .rtype = .document, .is_top = true }, 0));
    try testing.expectEqual(proto.NetReason.scheme, decide(p, &c, .{ .host = "site.example", .scheme = "ftp", .rtype = .document, .is_top = true }, 0));
    try testing.expectEqual(proto.NetReason.private_address, decide(p, &c, .{ .host = "127.0.0.1", .scheme = "http", .rtype = .document, .is_top = true }, 0));

    var set2 = baseSet();
    set2.flags = proto.NetPolicySet.flag_allow_private;
    set2.allow_top = &.{"127.0.0.1"};
    const p2 = try testPolicy(testing.allocator, set2);
    defer p2.deinit(testing.allocator);
    try testing.expectEqual(proto.NetReason.none, decide(p2, &c, .{ .host = "127.0.0.1", .scheme = "http", .rtype = .document, .is_top = true }, 0));
}

test "a proxy that decides addresses takes the private literal refusal, never the allow-list" {
    var set = baseSet();
    set.allow_top = &.{ "127.0.0.1", "render.localhost" };
    const p = try testPolicy(testing.allocator, set);
    defer p.deinit(testing.allocator);
    const c = Counters{};
    const loopback = Req{ .host = "127.0.0.1", .scheme = "http", .rtype = .document, .is_top = true };
    const named = Req{ .host = "render.localhost", .scheme = "http", .rtype = .document, .is_top = true };
    // Without the proxy the literal test refuses both, allow-listed or not.
    try testing.expectEqual(proto.NetReason.private_address, decide(p, &c, loopback, 0));
    try testing.expectEqual(proto.NetReason.private_address, decide(p, &c, named, 0));
    // On a proxy route the proxy is asked instead...
    p.proxy_decides_addresses = true;
    try testing.expectEqual(proto.NetReason.none, decide(p, &c, loopback, 0));
    try testing.expectEqual(proto.NetReason.none, decide(p, &c, named, 0));
    // ...and every other gate still holds on top of it.
    try testing.expectEqual(proto.NetReason.top_host, decide(p, &c, .{ .host = "10.0.0.1", .scheme = "http", .rtype = .document, .is_top = true }, 0));
    try testing.expectEqual(proto.NetReason.scheme, decide(p, &c, .{ .host = "127.0.0.1", .scheme = "ftp", .rtype = .document, .is_top = true }, 0));
}

test "budgets latch and every later decide answers the same reason" {
    var set = baseSet();
    set.max_requests = 2;
    const p = try testPolicy(testing.allocator, set);
    defer p.deinit(testing.allocator);
    var c = Counters{};
    const r = Req{ .host = "site.example", .scheme = "https", .rtype = .image, .is_top = false };
    try testing.expectEqual(proto.NetReason.none, decide(p, &c, r, 0));
    commit(&c, false);
    try testing.expectEqual(proto.NetReason.none, decide(p, &c, r, 0));
    commit(&c, false);
    const third = decide(p, &c, r, 0);
    try testing.expectEqual(proto.NetReason.request_cap, third);
    deny(&c, third);
    // Latched: even a request that would otherwise pass answers the cap.
    try testing.expectEqual(proto.NetReason.request_cap, decide(p, &c, .{ .host = "site.example", .scheme = "https", .rtype = .document, .is_top = true }, 0));
    try testing.expectEqual(@as(u32, 1), c.denied[@intFromEnum(proto.NetReason.request_cap)]);
}

test "navigation cap counts main-frame hops only; byte cap stops the next request" {
    var set = baseSet();
    set.max_navigations = 1;
    set.max_bytes = 1000;
    const p = try testPolicy(testing.allocator, set);
    defer p.deinit(testing.allocator);
    var c = Counters{};
    try testing.expectEqual(proto.NetReason.none, decide(p, &c, .{ .host = "site.example", .scheme = "https", .rtype = .document, .is_top = true }, 0));
    commit(&c, true);
    // Subresources are not navigations.
    try testing.expectEqual(proto.NetReason.none, decide(p, &c, .{ .host = "site.example", .scheme = "https", .rtype = .script, .is_top = false }, 0));
    const second_nav = decide(p, &c, .{ .host = "site.example", .scheme = "https", .rtype = .document, .is_top = true }, 0);
    try testing.expectEqual(proto.NetReason.nav_cap, second_nav);
    deny(&c, second_nav);
    try testing.expectEqual(proto.NetReason.nav_cap, c.exhausted);

    // Bytes latch AFTER crossing (the response that crossed completed).
    var c2 = Counters{ .bytes = 1500 };
    const over = decide(p, &c2, .{ .host = "site.example", .scheme = "https", .rtype = .script, .is_top = false }, 0);
    // nav_cap latching does not apply here; byte cap answers directly.
    try testing.expectEqual(proto.NetReason.byte_cap, over);
}

test "budget preflight never counts or latches the last allowed navigation" {
    var set = baseSet();
    set.max_navigations = 1;
    const p = try testPolicy(testing.allocator, set);
    defer p.deinit(testing.allocator);
    var c = Counters{};
    try testing.expectEqual(proto.NetReason.none, budgetReason(p, &c, true, "https", 0));
    try testing.expectEqual(@as(u32, 0), c.requests);
    commit(&c, true);
    for (0..3) |_| {
        try testing.expectEqual(proto.NetReason.nav_cap, budgetReason(p, &c, true, "https", 0));
        try testing.expectEqual(proto.NetReason.none, c.exhausted);
        try testing.expectEqual(proto.NetReason.none, budgetReason(p, &c, false, "https", 0));
    }
    try testing.expectEqual(proto.NetReason.none, decide(p, &c, .{ .host = "site.example", .scheme = "https", .rtype = .script, .is_top = false }, 0));
    commit(&c, false);
    try testing.expectEqual(@as(u32, 2), c.requests);
    try testing.expectEqual(@as(u32, 1), c.navigations);
    deny(&c, budgetReason(p, &c, true, "https", 0));
    try testing.expectEqual(proto.NetReason.nav_cap, c.exhausted);
    try testing.expectEqual(@as(u32, 1), c.denied[@intFromEnum(proto.NetReason.nav_cap)]);
}

test "deadline is monotone against a clock that jumps backwards" {
    var set = baseSet();
    set.deadline_ms = 1000;
    const p = try testPolicy(testing.allocator, set);
    defer p.deinit(testing.allocator);
    var c = Counters{ .started_ms = 10_000 };
    const r = Req{ .host = "site.example", .scheme = "https", .rtype = .document, .is_top = true };
    try testing.expectEqual(proto.NetReason.none, decide(p, &c, r, 10_500));
    const late = decide(p, &c, r, 11_000);
    try testing.expectEqual(proto.NetReason.deadline, late);
    deny(&c, late);
    // A clock that jumps BACK cannot un-expire a latched deadline.
    try testing.expectEqual(proto.NetReason.deadline, decide(p, &c, r, 9_000));
}

test "host entry validation supports ports but refuses wildcards, schemes and upper case" {
    try testing.expect(validHostEntry("site.example"));
    try testing.expect(validHostEntry("127.0.0.1"));
    try testing.expect(validHostEntry("[::1]"));
    try testing.expect(!validHostEntry("*"));
    try testing.expect(!validHostEntry("Site.Example"));
    try testing.expect(validHostEntry("[2001:DB8::1]"));
    try testing.expect(validHostEntry("site.example:8080"));
    try testing.expect(validHostEntry("[2001:db8::1]:8443"));
    try testing.expect(!validHostEntry("[bad::ipv6]:8443"));
    try testing.expect(!validHostEntry("site.example:0"));
    try testing.expect(!validHostEntry("https://site.example"));
    try testing.expect(!validHostEntry("site.example/path"));
    try testing.expect(!validHostEntry(""));
}

test "wire round trip: build copies and clamps" {
    var many: [70][]const u8 = undefined;
    for (&many) |*h| h.* = "h.example";
    var set = baseSet();
    set.allow_top = &many;
    const p = try testPolicy(testing.allocator, set);
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, MAX_HOSTS), p.allow_top.len);
    try testing.expectEqualStrings("h.example", p.allow_top[0]);
}

test "policy ports constrain ordinary and untrusted requests without widening defaults" {
    var set = baseSet();
    set.allow_top = &.{ "site.example:8443", "[2606:4700::1]:443" };
    const p = try testPolicy(testing.allocator, set);
    defer p.deinit(testing.allocator);
    const counters = Counters{};
    var r = Req{ .host = "site.example", .scheme = "https", .rtype = .document, .is_top = true };
    try testing.expectEqual(proto.NetReason.top_host, decide(p, &counters, r, 0));
    r.port = 8443;
    try testing.expectEqual(proto.NetReason.none, decide(p, &counters, r, 0));
    r.host = "2606:4700::1";
    r.port = 443;
    try testing.expectEqual(proto.NetReason.none, decide(p, &counters, r, 0));
    try testing.expect(entryAllows("site.example", "site.example", 8443, "https", false));
    try testing.expect(!entryAllows("site.example", "site.example", 8443, "https", true));
    try testing.expect(entryAllows("site.example", "site.example", 0, "https", true));
    try testing.expect(!entrySubset("sub.site.example:443", "site.example", true, default_schemes));
    try testing.expect(entrySubset("sub.site.example:443", "site.example", true, Scheme.https.bit()));
    try testing.expect(!entrySubset("site.example:8443", "site.example", true, default_schemes));
    try testing.expect(!entrySubset("site.example", "site.example:443", false, default_schemes));
    p.untrusted = true;
    p.allow_private = true;
    p.allow_top = &.{"127.0.0.1:443"};
    r.host = "127.0.0.1";
    try testing.expectEqual(proto.NetReason.none, decide(p, &counters, r, 0));
    p.allow_private = false;
    try testing.expectEqual(proto.NetReason.private_address, decide(p, &counters, r, 0));
    r.scheme = "wss";
    try testing.expectEqual(proto.NetReason.untrusted_transport, decide(p, &counters, r, 0));
}

test "host subset never admits a new scheme and port combination" {
    const entries = [_][]const u8{ "site.example", "site.example:80", "site.example:443", "sub.site.example", "sub.site.example:443", "site.example:8443" };
    for ([_]bool{ false, true }) |untrusted| {
        for ([_]u16{ Scheme.http.bit(), Scheme.https.bit(), default_schemes }) |schemes| {
            for (entries) |wide| for (entries) |narrow| {
                if (!entrySubset(narrow, wide, untrusted, schemes)) continue;
                for ([_][]const u8{ "site.example", "sub.site.example", "deep.sub.site.example" }) |host| {
                    for ([_]Scheme{ .http, .https }) |scheme| {
                        if (schemes & scheme.bit() == 0) continue;
                        for ([_]u16{ 0, 80, 443, 8443 }) |port| {
                            if (entryAllows(narrow, host, port, @tagName(scheme), untrusted))
                                try testing.expect(entryAllows(wide, host, port, @tagName(scheme), untrusted));
                        }
                    }
                }
            };
        }
    }
}

test "whole policy replacement must preserve every restriction" {
    var set = baseSet();
    set.flags = proto.NetPolicySet.flag_untrusted | proto.NetPolicySet.flag_allow_private;
    set.max_requests = 20;
    const old = try testPolicy(testing.allocator, set);
    defer old.deinit(testing.allocator);
    set.allow_top = &.{"site.example:443"};
    const next = try testPolicy(testing.allocator, set);
    defer next.deinit(testing.allocator);
    try testing.expect(!subsetOf(next, old));
    next.allow_schemes = Scheme.https.bit();
    try testing.expect(subsetOf(next, old));
    next.max_requests = 0;
    try testing.expect(!subsetOf(next, old));
    next.max_requests = 10;
    next.allow_private = false;
    try testing.expect(subsetOf(next, old));
    next.untrusted = false;
    try testing.expect(!subsetOf(next, old));
}
