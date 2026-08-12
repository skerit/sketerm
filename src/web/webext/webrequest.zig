//! MV2 blocking `browser.webRequest` — the ENGINE-FREE half: the
//! per-extension listener registry, the `RequestFilter` test, the
//! permission gate, and the decision parse.
//!
//! Pure std, no CEF, no GTK: compiled into the helper AND both test
//! roots, so the rules that decide whether a request reaches JS at all
//! are proven headless. `cefhost.zig` owns the other half (holding the
//! CEF request, the round trip to the background page, the timeout).
//!
//! Two properties this module exists to guarantee, both of them
//! correctness AND performance requirements:
//!
//! - An extension with NO blocking listener can never hold a request.
//!   `Registry.summary` is an O(1) bitmask consulted before any pattern
//!   is walked, so the common "no extension cares" request pays one
//!   load and one branch.
//! - A request no `RequestFilter` matches never reaches JS. `needFor`
//!   returns the empty need in that case and the caller continues the
//!   request inline.
//!
//! MV2 semantics deliberately, not MV3: `["blocking"]` is the whole
//! point of targeting the Firefox surface.

const std = @import("std");
const match = @import("match.zig");
const manifest = @import("manifest.zig");

/// The three blocking-capable events. MV2 has more (onCompleted,
/// onErrorOccurred, …) but only these three can change a request, and
/// only these three are worth a cross-process round trip.
pub const Event = enum(u8) {
    before_request = 0,
    before_send_headers = 1,
    headers_received = 2,

    pub fn fromStr(s: []const u8) ?Event {
        if (std.mem.eql(u8, s, "onBeforeRequest")) return .before_request;
        if (std.mem.eql(u8, s, "onBeforeSendHeaders")) return .before_send_headers;
        if (std.mem.eql(u8, s, "onHeadersReceived")) return .headers_received;
        return null;
    }

    pub fn toStr(self: Event) []const u8 {
        return switch (self) {
            .before_request => "onBeforeRequest",
            .before_send_headers => "onBeforeSendHeaders",
            .headers_received => "onHeadersReceived",
        };
    }
};

/// The MV2 `ResourceType` strings a `RequestFilter.types` may carry.
/// The engine's own resource type is mapped onto this by the caller, so
/// this enum — not CEF's — is what a filter tests against.
pub const RType = enum(u8) {
    other = 0,
    main_frame = 1,
    sub_frame = 2,
    stylesheet = 3,
    script = 4,
    image = 5,
    font = 6,
    xmlhttprequest = 7,
    media = 8,
    websocket = 9,
    ping = 10,
    csp_report = 11,
    object = 12,
    imageset = 13,

    pub fn fromStr(s: []const u8) ?RType {
        inline for (@typeInfo(RType).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        // MV2 spells these with a different casing/name than a Zig tag.
        if (std.mem.eql(u8, s, "xhr")) return .xmlhttprequest;
        return null;
    }

    pub fn toStr(self: RType) []const u8 {
        return @tagName(self);
    }

    pub fn bit(self: RType) u32 {
        return @as(u32, 1) << @intCast(@intFromEnum(self));
    }
};

/// `types` absent in a RequestFilter means every type, which is NOT the
/// same as "no bits set" — an empty explicit array matches nothing.
pub const ALL_TYPES: u32 = 0xffff_ffff;

/// What a listener asked for beyond being called.
pub const Extra = packed struct {
    blocking: bool = false,
    request_headers: bool = false,
    response_headers: bool = false,
};

/// One `addListener` call. Owns its pattern set; `urls` is the
/// RequestFilter's own list and `hosts` is the EXTENSION's host
/// permissions — a request must satisfy both, which is what stops an
/// extension filtering urls it was never granted.
pub const Listener = struct {
    /// Renderer-side listener id, echoed back so `removeListener` and
    /// the decision dispatch can name exactly one function.
    lid: u32,
    event: Event,
    extra: Extra = .{},
    types: u32 = ALL_TYPES,
    urls: match.PatternSet = .{},

    pub fn deinit(self: *Listener, gpa: std.mem.Allocator) void {
        self.urls.deinit(gpa);
    }
};

/// O(1) precomputed answer to "could ANY listener of this extension
/// care about this event, and would it block?". Recomputed on every
/// registry mutation; read on the request path before anything else.
pub const Summary = packed struct {
    /// Bit per Event: a listener exists at all (blocking or not).
    any: u8 = 0,
    /// Bit per Event: a BLOCKING listener exists.
    blocking: u8 = 0,

    pub fn hasAny(self: Summary, ev: Event) bool {
        return self.any & evBit(ev) != 0;
    }
    pub fn hasBlocking(self: Summary, ev: Event) bool {
        return self.blocking & evBit(ev) != 0;
    }
    pub fn empty(self: Summary) bool {
        return self.any == 0;
    }
};

fn evBit(ev: Event) u8 {
    return @as(u8, 1) << @as(u3, @intCast(@intFromEnum(ev)));
}

pub const RegisterError = error{
    /// The manifest declares no `webRequest` permission.
    NoWebRequestPermission,
    /// `["blocking"]` was asked for without `webRequestBlocking`.
    NoBlockingPermission,
    /// The listener is not in an extension's background page.
    NotBackground,
    BadEvent,
    BadFilter,
    OutOfMemory,
};

/// One extension's listener set. The extension's host permissions are
/// compiled once here rather than per request.
pub const Registry = struct {
    listeners: std.ArrayList(Listener) = .empty,
    /// Compiled `permissions` + `host_permissions` match patterns. An
    /// extension with none can register but will never match a url.
    hosts: match.PatternSet = .{},
    hosts_built: bool = false,
    summary: Summary = .{},

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        for (self.listeners.items) |*l| l.deinit(gpa);
        self.listeners.deinit(gpa);
        self.hosts.deinit(gpa);
    }

    /// Compile the extension's host permissions once. MV2 puts host
    /// patterns in `permissions` alongside API names; `host_permissions`
    /// is accepted too so a hybrid manifest works.
    pub fn buildHosts(self: *Registry, gpa: std.mem.Allocator, man: *const manifest.Manifest) void {
        if (self.hosts_built) return;
        self.hosts_built = true;
        for (man.permissions) |p| self.hosts.addInclude(gpa, p) catch continue;
        for (man.host_permissions) |p| self.hosts.addInclude(gpa, p) catch continue;
    }

    fn recompute(self: *Registry) void {
        var s = Summary{};
        for (self.listeners.items) |l| {
            const b = evBit(l.event);
            s.any |= b;
            if (l.extra.blocking) s.blocking |= b;
        }
        self.summary = s;
    }

    /// Register one listener. `man` gates it: `webRequest` is required
    /// to listen at all and `webRequestBlocking` to ask for "blocking",
    /// exactly as Firefox enforces it.
    pub fn add(
        self: *Registry,
        gpa: std.mem.Allocator,
        man: *const manifest.Manifest,
        lid: u32,
        event: Event,
        extra: Extra,
        types: u32,
        urls: []const []const u8,
    ) RegisterError!void {
        if (!man.hasPermission("webRequest")) return error.NoWebRequestPermission;
        if (extra.blocking and !man.hasPermission("webRequestBlocking")) return error.NoBlockingPermission;

        var l = Listener{ .lid = lid, .event = event, .extra = extra, .types = types };
        errdefer l.deinit(gpa);
        for (urls) |u| l.urls.addInclude(gpa, u) catch return error.BadFilter;
        // A RequestFilter with no `urls` matches every url; MV2 requires
        // the key but tolerating its absence costs nothing and keeps a
        // sloppy extension working.
        if (l.urls.include.items.len == 0) l.urls.addInclude(gpa, "<all_urls>") catch return error.OutOfMemory;

        self.remove(gpa, lid);
        self.listeners.append(gpa, l) catch return error.OutOfMemory;
        self.recompute();
    }

    pub fn remove(self: *Registry, gpa: std.mem.Allocator, lid: u32) void {
        for (self.listeners.items, 0..) |*l, i| {
            if (l.lid != lid) continue;
            l.deinit(gpa);
            _ = self.listeners.orderedRemove(i);
            self.recompute();
            return;
        }
    }

    pub fn clear(self: *Registry, gpa: std.mem.Allocator) void {
        for (self.listeners.items) |*l| l.deinit(gpa);
        self.listeners.clearRetainingCapacity();
        self.summary = .{};
    }

    /// Whether `url` is inside this extension's host permissions.
    pub fn hostAllowed(self: *const Registry, url: []const u8) bool {
        return self.hosts.matchesUrl(url);
    }
};

// -- the published table (main thread writes, IO thread reads) ---------
//
// THE ONE PIECE OF SHARED STATE in the WebExtensions host. The engine
// delivers `on_before_resource_load` on its IO thread (see the
// interception section of `cefhost.zig` for why that is deliberate),
// so the request path cannot walk `Host.exts` — that ArrayList
// reallocates under the main thread's feet. Instead the main thread
// PUBLISHES a stable `*Registry` per extension into these fixed slots,
// and the IO thread reads them under the spinlock below.
//
// The spinlock is the repo's pattern (`src/ui/panel/events.zig`
// documents why a spinlock and not a condvar). Registrations are rare
// and a `needFor` walk is a handful of pattern compares, so neither
// side holds it long.
//
// NOTHING here allocates on the IO thread. The main thread creates and
// destroys `Registry` objects; a slot is cleared under the lock BEFORE
// its registry is freed, so a reader can never observe a dangling one.

pub const MAX_PUBLISHED = 16;
pub const MAX_ID = 64;

pub const Slot = struct {
    used: bool = false,
    id: [MAX_ID]u8 = @splat(0),
    id_len: usize = 0,
    /// The hidden background-page view that owns the listeners. 0 when
    /// the background is not up yet — a request must then fail open,
    /// because there is nobody to ask.
    bg_view: u32 = 0,
    reg: ?*Registry = null,

    pub fn idSlice(self: *const Slot) []const u8 {
        return self.id[0..self.id_len];
    }
};

pub var lock: std.atomic.Value(u8) = .init(0);
pub var slots: [MAX_PUBLISHED]Slot = @splat(.{});

/// Set whenever ANY published extension has at least one listener, so
/// the request path can bail before even taking the lock. Written under
/// the lock, read without it — a stale read only costs one wasted lock
/// acquisition, never a wrong verdict, because the summary is rechecked
/// inside.
pub var any_listeners: std.atomic.Value(bool) = .init(false);

pub fn acquire() void {
    while (lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

pub fn release() void {
    lock.store(0, .release);
}

/// Recompute `any_listeners`. Call under the lock after any mutation.
pub fn refreshAnyLocked() void {
    for (&slots) |*s| {
        const r = s.reg orelse continue;
        if (!s.used) continue;
        if (!r.summary.empty()) {
            any_listeners.store(true, .release);
            return;
        }
    }
    any_listeners.store(false, .release);
}

fn findSlotLocked(id: []const u8) ?*Slot {
    for (&slots) |*s| {
        if (s.used and std.mem.eql(u8, s.idSlice(), id)) return s;
    }
    return null;
}

/// Publish (or re-point) one extension's registry. MAIN THREAD.
/// Returns false when the table is full — the extension then simply
/// never sees a request, which is a degradation, never a hang.
pub fn publish(id: []const u8, reg: *Registry) bool {
    if (id.len > MAX_ID) return false;
    acquire();
    defer release();
    if (findSlotLocked(id)) |s| {
        s.reg = reg;
        refreshAnyLocked();
        return true;
    }
    for (&slots) |*s| {
        if (s.used) continue;
        s.* = .{ .used = true, .reg = reg };
        @memcpy(s.id[0..id.len], id);
        s.id_len = id.len;
        refreshAnyLocked();
        return true;
    }
    return false;
}

/// Drop an extension from the table. MAIN THREAD, and it must run
/// BEFORE the registry it points at is freed — that ordering is the
/// whole safety property.
pub fn unpublish(id: []const u8) void {
    acquire();
    defer release();
    if (findSlotLocked(id)) |s| s.* = .{};
    refreshAnyLocked();
}

/// Record where an extension's background page lives. MAIN THREAD.
pub fn setBgView(id: []const u8, view: u32) void {
    acquire();
    defer release();
    if (findSlotLocked(id)) |s| s.bg_view = view;
}

/// What one request needs from one extension. `none()` is the answer for
/// the overwhelming majority of requests and costs no allocation.
/// Matching listener ids carried per request. An extension with more
/// than this many listeners matching ONE request is not a shape any real
/// extension has (uBO's busiest event has two), and the overflow
/// degrades by running fewer listeners, never by running wrong ones.
pub const MAX_MATCHED = 16;

pub const Need = struct {
    /// A listener matched at all (blocking or observational).
    matched: bool = false,
    /// At least one matching listener asked to block: the caller must
    /// HOLD the request until the decision comes back.
    blocking: bool = false,
    /// The union of the matching listeners' extraInfoSpec, so the caller
    /// only pays for header collection when somebody asked for it.
    want_request_headers: bool = false,
    want_response_headers: bool = false,
    /// WHICH listeners matched.
    ///
    /// Not a detail: a `RequestFilter` belongs to ONE listener, and an
    /// extension registers several with DIFFERENT filters. uBlock Origin
    /// registers a guard on `onBeforeRequest` filtered to its own
    /// `web_accessible_resources/*` that cancels anything reaching it
    /// without a secret — so "this request matched SOME listener, run
    /// them all" cancels every page on the web. Measured exactly that
    /// way before these ids existed.
    ids: [MAX_MATCHED]u32 = @splat(0),
    n_ids: u8 = 0,

    pub fn none() Need {
        return .{};
    }
    pub fn isNone(self: Need) bool {
        return !self.matched;
    }
    pub fn idSlice(self: *const Need) []const u32 {
        return self.ids[0..self.n_ids];
    }
};

/// THE fast path. Returns `Need.none()` without touching a pattern when
/// the summary says no listener of this event exists — which is the
/// zero-cost property an extension with no blocking listener must have.
pub fn needFor(
    reg: *const Registry,
    event: Event,
    url_text: []const u8,
    rtype: RType,
) Need {
    if (!reg.summary.hasAny(event)) return Need.none();
    // Host permissions gate before the per-listener filters: an
    // extension may only see urls it was granted.
    if (!reg.hostAllowed(url_text)) return Need.none();

    const url = match.Url.parse(url_text) orelse return Need.none();
    const tbit = rtype.bit();
    var need = Need{};
    for (reg.listeners.items) |*l| {
        if (l.event != event) continue;
        if (l.types & tbit == 0) continue;
        var hit = false;
        for (l.urls.include.items) |*pat| {
            if (match.matches(pat, &url)) {
                hit = true;
                break;
            }
        }
        if (!hit) continue;
        need.matched = true;
        if (l.extra.blocking) need.blocking = true;
        if (l.extra.request_headers) need.want_request_headers = true;
        if (l.extra.response_headers) need.want_response_headers = true;
        if (need.n_ids < MAX_MATCHED) {
            need.ids[need.n_ids] = l.lid;
            need.n_ids += 1;
        }
    }
    return need;
}

/// Parse a `types` array from a RequestFilter into a mask. `null` (key
/// absent) is every type; an explicit empty array is NO type, which is
/// a filter that matches nothing — that asymmetry is MV2's, not ours.
pub fn typesMask(v: ?std.json.Value) u32 {
    const val = v orelse return ALL_TYPES;
    if (val != .array) return ALL_TYPES;
    var mask: u32 = 0;
    for (val.array.items) |it| {
        if (it != .string) continue;
        if (RType.fromStr(it.string)) |rt| mask |= rt.bit();
    }
    return mask;
}

/// Parse an `extraInfoSpec` array. Unknown entries are ignored, which
/// is what a browser does with a spec it does not implement.
pub fn extraFrom(v: ?std.json.Value) Extra {
    var e = Extra{};
    const val = v orelse return e;
    if (val != .array) return e;
    for (val.array.items) |it| {
        if (it != .string) continue;
        if (std.mem.eql(u8, it.string, "blocking")) e.blocking = true;
        if (std.mem.eql(u8, it.string, "requestHeaders")) e.request_headers = true;
        if (std.mem.eql(u8, it.string, "responseHeaders")) e.response_headers = true;
    }
    return e;
}

// -- the decision ------------------------------------------------------

pub const HeaderEdit = struct {
    name: []const u8,
    /// An empty value REMOVES the header — that is how MV2 expresses a
    /// deletion (the header is simply absent from the returned array).
    value: []const u8,
    remove: bool = false,
};

/// A listener's `BlockingResponse`, already validated. Borrows from the
/// JSON parse the caller keeps alive.
pub const Decision = struct {
    cancel: bool = false,
    redirect: ?[]const u8 = null,
    /// Present only when the listener returned a `requestHeaders` /
    /// `responseHeaders` array. Null means "unchanged", which is NOT the
    /// same as an empty array (that would strip every header).
    headers: ?[]HeaderEdit = null,

    pub fn isNoop(self: Decision) bool {
        return !self.cancel and self.redirect == null and self.headers == null;
    }
};

pub const DecisionParse = struct {
    parsed: std.json.Parsed(std.json.Value),
    edits: std.ArrayList(HeaderEdit),
    decision: Decision,

    pub fn deinit(self: *DecisionParse, gpa: std.mem.Allocator) void {
        self.edits.deinit(gpa);
        self.parsed.deinit();
    }
};

/// Parse a `BlockingResponse` object. A malformed or absent body is a
/// no-op decision, never a cancel: a broken extension must not be able
/// to break the page.
pub fn parseDecision(gpa: std.mem.Allocator, json: []const u8, want_headers_key: []const u8) !DecisionParse {
    var out = DecisionParse{
        .parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{}),
        .edits = .empty,
        .decision = .{},
    };
    errdefer out.deinit(gpa);
    if (out.parsed.value != .object) return out;
    const o = out.parsed.value.object;
    if (o.get("cancel")) |cv| {
        if (cv == .bool and cv.bool) out.decision.cancel = true;
    }
    if (o.get("redirectUrl")) |rv| {
        if (rv == .string and rv.string.len != 0) out.decision.redirect = rv.string;
    }
    if (want_headers_key.len != 0) {
        if (o.get(want_headers_key)) |hv| {
            if (hv == .array) {
                for (hv.array.items) |it| {
                    if (it != .object) continue;
                    const nm = it.object.get("name") orelse continue;
                    if (nm != .string) continue;
                    const val = it.object.get("value");
                    const sval: []const u8 = if (val) |vv| (if (vv == .string) vv.string else "") else "";
                    try out.edits.append(gpa, .{ .name = nm.string, .value = sval });
                }
                out.decision.headers = out.edits.items;
            }
        }
    }
    return out;
}

// ─── tests ──────────────────────────────────────────────────────────

const t = std.testing;

fn testManifest(gpa: std.mem.Allocator, perms: []const u8) !manifest.Manifest {
    var buf: [512]u8 = undefined;
    const src = try std.fmt.bufPrint(&buf,
        \\{{"manifest_version":2,"name":"t","version":"1","permissions":{s}}}
    , .{perms});
    return manifest.parse(gpa, src);
}

test "permission gate: webRequest and webRequestBlocking are both enforced" {
    const gpa = t.allocator;
    {
        var man = try testManifest(gpa, "[]");
        defer man.deinit();
        var reg = Registry{};
        defer reg.deinit(gpa);
        try t.expectError(error.NoWebRequestPermission, reg.add(gpa, &man, 1, .before_request, .{}, ALL_TYPES, &.{"<all_urls>"}));
    }
    {
        var man = try testManifest(gpa, "[\"webRequest\"]");
        defer man.deinit();
        var reg = Registry{};
        defer reg.deinit(gpa);
        // Non-blocking is fine…
        try reg.add(gpa, &man, 1, .before_request, .{}, ALL_TYPES, &.{"<all_urls>"});
        // …blocking is not, without webRequestBlocking.
        try t.expectError(error.NoBlockingPermission, reg.add(gpa, &man, 2, .before_request, .{ .blocking = true }, ALL_TYPES, &.{"<all_urls>"}));
    }
    {
        var man = try testManifest(gpa, "[\"webRequest\",\"webRequestBlocking\"]");
        defer man.deinit();
        var reg = Registry{};
        defer reg.deinit(gpa);
        try reg.add(gpa, &man, 1, .before_request, .{ .blocking = true }, ALL_TYPES, &.{"<all_urls>"});
        try t.expect(reg.summary.hasBlocking(.before_request));
    }
}

test "summary short-circuits: no listener for an event costs no matching" {
    const gpa = t.allocator;
    var man = try testManifest(gpa, "[\"webRequest\",\"webRequestBlocking\",\"<all_urls>\"]");
    defer man.deinit();
    var reg = Registry{};
    defer reg.deinit(gpa);
    reg.buildHosts(gpa, &man);
    try reg.add(gpa, &man, 1, .before_request, .{ .blocking = true }, ALL_TYPES, &.{"<all_urls>"});

    try t.expect(needFor(&reg, .before_request, "https://x.example/a.js", .script).blocking);
    // No onHeadersReceived listener at all -> the empty need, without
    // ever parsing the url.
    try t.expect(needFor(&reg, .headers_received, "https://x.example/a.js", .script).isNone());
    try t.expect(!reg.summary.hasAny(.headers_received));
}

test "host permissions gate the filter: an unlisted origin never reaches JS" {
    const gpa = t.allocator;
    var man = try testManifest(gpa, "[\"webRequest\",\"webRequestBlocking\",\"*://*.allowed.test/*\"]");
    defer man.deinit();
    var reg = Registry{};
    defer reg.deinit(gpa);
    reg.buildHosts(gpa, &man);
    // The RequestFilter asks for everything; the manifest grants one host.
    try reg.add(gpa, &man, 1, .before_request, .{ .blocking = true }, ALL_TYPES, &.{"<all_urls>"});

    try t.expect(needFor(&reg, .before_request, "https://a.allowed.test/x.js", .script).blocking);
    try t.expect(needFor(&reg, .before_request, "https://denied.test/x.js", .script).isNone());
}

test "RequestFilter urls and types both narrow" {
    const gpa = t.allocator;
    var man = try testManifest(gpa, "[\"webRequest\",\"webRequestBlocking\",\"<all_urls>\"]");
    defer man.deinit();
    var reg = Registry{};
    defer reg.deinit(gpa);
    reg.buildHosts(gpa, &man);
    try reg.add(gpa, &man, 7, .before_request, .{ .blocking = true }, RType.image.bit() | RType.script.bit(), &.{"*://ads.test/*"});

    try t.expect(needFor(&reg, .before_request, "https://ads.test/a.png", .image).blocking);
    try t.expect(needFor(&reg, .before_request, "https://ads.test/a.css", .stylesheet).isNone());
    try t.expect(needFor(&reg, .before_request, "https://news.test/a.png", .image).isNone());
}

test "extraInfoSpec union, and non-blocking never sets blocking" {
    const gpa = t.allocator;
    var man = try testManifest(gpa, "[\"webRequest\",\"webRequestBlocking\",\"<all_urls>\"]");
    defer man.deinit();
    var reg = Registry{};
    defer reg.deinit(gpa);
    reg.buildHosts(gpa, &man);
    try reg.add(gpa, &man, 1, .before_send_headers, .{ .request_headers = true }, ALL_TYPES, &.{"<all_urls>"});
    const observational = needFor(&reg, .before_send_headers, "https://x.test/a", .xmlhttprequest);
    try t.expect(observational.matched);
    try t.expect(!observational.blocking);
    try t.expect(observational.want_request_headers);

    try reg.add(gpa, &man, 2, .before_send_headers, .{ .blocking = true }, ALL_TYPES, &.{"<all_urls>"});
    try t.expect(needFor(&reg, .before_send_headers, "https://x.test/a", .xmlhttprequest).blocking);

    // Removing the blocking one puts the registry back to observational.
    reg.remove(gpa, 2);
    try t.expect(!needFor(&reg, .before_send_headers, "https://x.test/a", .xmlhttprequest).blocking);
}

test "types mask: absent is all, explicit empty is none" {
    const gpa = t.allocator;
    {
        var p = try std.json.parseFromSlice(std.json.Value, gpa, "[\"image\",\"script\"]", .{});
        defer p.deinit();
        try t.expectEqual(RType.image.bit() | RType.script.bit(), typesMask(p.value));
    }
    {
        var p = try std.json.parseFromSlice(std.json.Value, gpa, "[]", .{});
        defer p.deinit();
        try t.expectEqual(@as(u32, 0), typesMask(p.value));
    }
    try t.expectEqual(ALL_TYPES, typesMask(null));
    try t.expectEqual(RType.xmlhttprequest, RType.fromStr("xmlhttprequest").?);
    try t.expectEqual(RType.main_frame, RType.fromStr("main_frame").?);
}

test "decision parse: cancel, redirect, header edits, and garbage is a no-op" {
    const gpa = t.allocator;
    {
        var d = try parseDecision(gpa, "{\"cancel\":true}", "");
        defer d.deinit(gpa);
        try t.expect(d.decision.cancel);
    }
    {
        var d = try parseDecision(gpa, "{\"redirectUrl\":\"https://ok.test/1.png\"}", "");
        defer d.deinit(gpa);
        try t.expectEqualStrings("https://ok.test/1.png", d.decision.redirect.?);
    }
    {
        var d = try parseDecision(gpa,
            \\{"requestHeaders":[{"name":"X-A","value":"1"},{"name":"Referer"}]}
        , "requestHeaders");
        defer d.deinit(gpa);
        const h = d.decision.headers.?;
        try t.expectEqual(@as(usize, 2), h.len);
        try t.expectEqualStrings("X-A", h[0].name);
        try t.expectEqualStrings("1", h[0].value);
        // A name with no value is an empty value, which the applier
        // treats as a removal.
        try t.expectEqualStrings("", h[1].value);
    }
    {
        // A listener that returned nothing, or something silly, must not
        // cancel anything.
        var d = try parseDecision(gpa, "null", "requestHeaders");
        defer d.deinit(gpa);
        try t.expect(d.decision.isNoop());
    }
    {
        var d = try parseDecision(gpa, "{\"cancel\":\"yes-please\"}", "");
        defer d.deinit(gpa);
        try t.expect(!d.decision.cancel);
    }
}

test "clear drops every listener and the summary with it" {
    const gpa = t.allocator;
    var man = try testManifest(gpa, "[\"webRequest\",\"webRequestBlocking\",\"<all_urls>\"]");
    defer man.deinit();
    var reg = Registry{};
    defer reg.deinit(gpa);
    reg.buildHosts(gpa, &man);
    try reg.add(gpa, &man, 1, .before_request, .{ .blocking = true }, ALL_TYPES, &.{"<all_urls>"});
    try t.expect(!reg.summary.empty());
    reg.clear(gpa);
    try t.expect(reg.summary.empty());
    try t.expect(needFor(&reg, .before_request, "https://x.test/a", .script).isNone());
}
