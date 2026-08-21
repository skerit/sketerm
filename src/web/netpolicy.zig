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

/// Immutable after `build`; the helper swaps whole policies under the
/// intercept spinlock exactly the way filter engines are swapped.
pub const Policy = struct {
    arena_state: std.heap.ArenaAllocator,
    serial: u32,
    /// Hosts (and, `hostWithin`-style, their subdomains) the TOP-LEVEL
    /// document may load from. Never empty: an empty allow-list is
    /// refused at parse time, not silently allow-all.
    allow_top: []const []const u8 = &.{},
    /// EXTRA hosts subresources may use; the effective subresource list
    /// is always the union with `allow_top`.
    allow_sub: []const []const u8 = &.{},
    /// `filter.RType`-indexed bits of resource classes to refuse.
    block_types: u16 = 0,
    allow_schemes: u16 = default_schemes,
    allow_private: bool = false,
    max_requests: u32 = 0,
    max_bytes: u64 = 0,
    max_navigations: u32 = 0,
    deadline_ms: u32 = 0,

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
            .max_requests = req.max_requests,
            .max_bytes = req.max_bytes,
            .max_navigations = req.max_navigations,
            .deadline_ms = req.deadline_ms,
        };
        errdefer p.arena_state.deinit();
        const arena = p.arena_state.allocator();
        p.allow_top = try dupeHosts(arena, req.allow_top);
        p.allow_sub = try dupeHosts(arena, req.allow_sub);
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

/// Live accounting for one view. Mutated ONLY on the IO thread under
/// the intercept lock (cefhost owns the locking).
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
    host: []const u8,
    scheme: []const u8,
    rtype: filter.RType,
    is_top: bool,
    /// The ring already holds a live entry with this request id: CEF
    /// re-issued a redirected request (the id survives the chain), so a
    /// host denial is a `redirect_host`.
    is_redirect_hop: bool = false,
};

/// The verdict, first refusal wins, cheapest checks first. Pure: no
/// allocation, no clock. Budget hits LATCH `c.exhausted`; the caller
/// commits counter updates for allowed requests via `commit`.
pub fn decide(p: *const Policy, c: *const Counters, r: Req, now_ms: i64) proto.NetReason {
    if (c.exhausted != .none) return c.exhausted;
    if (p.deadline_ms != 0 and now_ms - c.started_ms >= p.deadline_ms) return .deadline;

    // The view's own blank document; refusing it breaks view creation.
    if (std.mem.eql(u8, r.scheme, "about")) return .none;
    const scheme = std.meta.stringToEnum(Scheme, r.scheme) orelse return .scheme;
    if (p.allow_schemes & scheme.bit() == 0) return .scheme;

    // Hostless schemes (data:, about:, blob:) are judged by scheme
    // alone: there is no authority to test.
    if (r.host.len > 0) {
        if (!p.allow_private and isPrivateHostLiteral(r.host)) return .private_address;
        const listed = hostAllowed(p, r.host, r.is_top);
        if (!listed) return if (r.is_redirect_hop) .redirect_host else if (r.is_top) .top_host else .sub_host;
    }

    if (p.block_types & r.rtype.bit() != 0) return .resource_type;

    if (r.is_top and p.max_navigations != 0 and c.navigations >= p.max_navigations) return .nav_cap;
    if (p.max_requests != 0 and c.requests >= p.max_requests) return .request_cap;
    if (p.max_bytes != 0 and c.bytes >= p.max_bytes) return .byte_cap;
    return .none;
}

fn hostAllowed(p: *const Policy, host: []const u8, is_top: bool) bool {
    for (p.allow_top) |base| {
        if (filter.hostWithin(host, base)) return true;
    }
    if (!is_top) {
        for (p.allow_sub) |base| {
            if (filter.hostWithin(host, base)) return true;
        }
    }
    return false;
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

/// A host that IS a literal loopback/private/link-local address, or a
/// name reserved for one. A hostname that merely RESOLVES to a private
/// address is invisible here (no resolver on this path) — the positive
/// host allow-list is the real defence, and the docs say so.
pub fn isPrivateHostLiteral(host: []const u8) bool {
    if (host.len == 0) return false;
    // Reserved names.
    if (std.mem.eql(u8, host, "localhost")) return true;
    if (std.mem.endsWith(u8, host, ".localhost")) return true;
    if (std.mem.endsWith(u8, host, ".local")) return true;
    if (std.mem.endsWith(u8, host, ".internal")) return true;
    // IPv6 literal (urlhost keeps the brackets off or on; accept both).
    var h = host;
    if (h[0] == '[' and h[h.len - 1] == ']') h = h[1 .. h.len - 1];
    if (std.mem.indexOfScalar(u8, h, ':') != null) return isPrivateV6(h);
    return isPrivateV4(h);
}

fn isPrivateV6(h: []const u8) bool {
    if (std.mem.eql(u8, h, "::1") or std.mem.eql(u8, h, "::")) return true;
    // fc00::/7 (fc, fd) and fe80::/10 (fe80-febf).
    if (h.len >= 2) {
        const a = std.ascii.toLower(h[0]);
        const b = std.ascii.toLower(h[1]);
        if (a == 'f' and (b == 'c' or b == 'd')) return true;
        if (h.len >= 4 and a == 'f' and b == 'e') {
            const c3 = std.ascii.toLower(h[2]);
            if (c3 == '8' or c3 == '9' or c3 == 'a' or c3 == 'b') return true;
        }
    }
    return false;
}

fn isPrivateV4(h: []const u8) bool {
    var parts: [4]u32 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, h, '.');
    while (it.next()) |part| {
        if (n >= 4 or part.len == 0 or part.len > 3) return false;
        for (part) |ch| {
            if (ch < '0' or ch > '9') return false;
        }
        parts[n] = std.fmt.parseInt(u32, part, 10) catch return false;
        if (parts[n] > 255) return false;
        n += 1;
    }
    if (n != 4) return false;
    const a = parts[0];
    const b = parts[1];
    if (a == 127 or a == 10 or a == 0) return true;
    if (a == 172 and b >= 16 and b <= 31) return true;
    if (a == 192 and b == 168) return true;
    if (a == 169 and b == 254) return true;
    return false;
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

/// A host allow-list entry a caller may store: lower-case labels,
/// digits, '-' and '.', no scheme, no port, no path, no wildcard. A
/// bare IP literal is fine (it is a host).
pub fn validHostEntry(host: []const u8) bool {
    if (host.len == 0 or host.len > 253) return false;
    if (std.mem.eql(u8, host, "*")) return false;
    // IPv6 literals keep their colons (always at least two of them);
    // ONE colon is a :port, which an entry must not carry.
    const v6 = host[0] == '[' or std.mem.count(u8, host, ":") >= 2;
    for (host) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or
            ch == '-' or ch == '.' or (v6 and (ch == ':' or ch == '[' or ch == ']'));
        if (!ok) return false;
    }
    return true;
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
        "172.15.0.1",   "172.32.0.1",            "11.0.0.1", "192.169.1.1",  "10.example.com",
        "notlocalhost", "localhost.example.com", "fe00::1",  "site.example", "1.2.3.4",
    };
    for (public) |h| try testing.expect(!isPrivateHostLiteral(h));
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

test "host entry validation refuses wildcards, ports, schemes and upper case" {
    try testing.expect(validHostEntry("site.example"));
    try testing.expect(validHostEntry("127.0.0.1"));
    try testing.expect(validHostEntry("[::1]"));
    try testing.expect(!validHostEntry("*"));
    try testing.expect(!validHostEntry("Site.Example"));
    try testing.expect(!validHostEntry("site.example:8080"));
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
