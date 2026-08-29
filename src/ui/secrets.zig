//! Read-only Secret Service (`org.freedesktop.secrets`) lookup, for the
//! browser face's "Fill Password…" row.
//!
//! Plain GDBus against the freedesktop Secret Service API rather than
//! libsecret: GIO is already linked into the GUI, libsecret would be a
//! new package dependency for one dialog's worth of calls.
//!
//! This module NEVER writes to the keyring, never creates or edits an
//! item, and never logs a secret. `fetchSecret` is the only call that
//! touches a secret value at all and its buffer is the caller's to
//! `zeroFree`. Two deliberate limitations, both visible to the user as
//! a toast rather than a hang:
//!
//! - A locked item is `Unlock`ed only when the service can do it
//!   without a prompt. A prompt would need the `Prompt.Completed`
//!   signal, and a synchronous call cannot wait for a signal on the
//!   main loop it is blocking.
//! - Matching enumerates items (`SearchItems` with no attributes, then
//!   one `GetAll` per item, capped at `MAX_ITEMS`). The Secret Service
//!   API only matches attributes for EQUALITY, so no server-side query
//!   can express "any item whose URL is on this host".

const std = @import("std");
const c = @import("../c.zig").c;
const urlhost = @import("../web/urlhost.zig");

const SERVICE = "org.freedesktop.secrets";
const SERVICE_PATH = "/org/freedesktop/secrets";
const IFACE_SERVICE = "org.freedesktop.Secret.Service";
const IFACE_ITEM = "org.freedesktop.Secret.Item";
const IFACE_PROPS = "org.freedesktop.DBus.Properties";

/// Every call is bounded: a wedged keyring agent must cost a toast,
/// not a frozen window (these run on the GLib main loop).
const CALL_TIMEOUT_MS: c_int = 2000;

/// Enumeration cap. A keyring with more items than this matches only
/// within the first `MAX_ITEMS`; the alternative is an unbounded
/// number of round trips on the main loop.
pub const MAX_ITEMS = 512;

pub const Error = error{
    /// No session bus at all.
    NoBus,
    /// Nothing answers org.freedesktop.secrets.
    NoService,
    /// The item is locked and unlocking needs a user prompt.
    Locked,
    /// The service answered, but with no usable secret.
    NoSecret,
    OutOfMemory,
};

/// Attribute names that hold a site address, across the conventions in
/// the wild (KeePassXC writes `URL`, GNOME's own schemas `server`).
const URL_KEYS = [_][]const u8{
    "URL", "url", "URI", "uri", "server", "host", "hostname", "address", "origin_url", "signon_realm",
};

/// Attribute names that hold the login name. `UserName` is KeePassXC's.
const USER_KEYS = [_][]const u8{
    "UserName", "username", "user", "user_name", "login", "account", "Account",
};

// ---------------------------------------------------------------- pure

/// Host part of `url`. A bare host is returned unchanged, so a keyring
/// attribute holding `example.com` works as well as a full address.
pub fn hostOf(url: []const u8) []const u8 {
    return urlhost.hostOf(url, urlhost.site);
}

/// `www.` is not a site of its own — every password manager already
/// treats the two spellings as one, and so must we.
fn deWww(host: []const u8) []const u8 {
    if (host.len > 4 and std.ascii.eqlIgnoreCase(host[0..4], "www.")) return host[4..];
    return host;
}

/// Same site? Case-insensitive, `www.`-insensitive, nothing cleverer:
/// a suffix rule would fill evil-example.com's form from example.com.
pub fn hostsMatch(a: []const u8, b: []const u8) bool {
    const x = deWww(a);
    const y = deWww(b);
    return x.len != 0 and std.ascii.eqlIgnoreCase(x, y);
}

/// Fallback for items that carry no URL attribute at all: does the
/// label name this host? Substring, case-insensitive.
pub fn labelMentions(label: []const u8, host: []const u8) bool {
    const needle = deWww(host);
    if (needle.len < 4 or label.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= label.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(label[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// One candidate login. Nothing here is a secret: the secret is fetched
/// separately, only for the entry the user picks.
pub const Match = struct {
    /// D-Bus object path of the item, the handle `fetchSecret` takes.
    path: [:0]u8,
    label: []u8,
    /// Empty when the item declares no login name.
    username: []u8,
    locked: bool,
    /// 0 = a URL attribute's host matched, 1 = only the label mentions
    /// the host. Sort key, so the exact matches come first.
    score: u8,

    fn free(self: Match, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.label);
        allocator.free(self.username);
    }
};

pub const Matches = struct {
    allocator: std.mem.Allocator,
    items: []Match,

    pub fn deinit(self: *Matches) void {
        for (self.items) |m| m.free(self.allocator);
        self.allocator.free(self.items);
        self.items = &.{};
    }
};

fn lessMatch(_: void, a: Match, b: Match) bool {
    if (a.score != b.score) return a.score < b.score;
    return std.mem.lessThan(u8, a.username, b.username);
}

// ---------------------------------------------------------------- dbus

/// The session bus, as a REF the caller owns: the connection is a
/// process-wide singleton, but `g_bus_get_sync` is transfer-full, so every
/// call must be balanced with `g_object_unref`.
fn bus() Error!*c.GDBusConnection {
    var err: [*c]c.GError = null;
    const conn = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, &err) orelse {
        if (err != null) c.g_error_free(err);
        return Error.NoBus;
    };
    return conn;
}

/// One bounded method call. A null reply is any failure at all —
/// the caller turns that into a described state, never a log line
/// (a GError message can quote an item label).
fn call(
    conn: *c.GDBusConnection,
    path: [*:0]const u8,
    iface: [*:0]const u8,
    method: [*:0]const u8,
    params: ?*c.GVariant,
    reply_type: ?*const c.GVariantType,
) ?*c.GVariant {
    var err: [*c]c.GError = null;
    const reply = c.g_dbus_connection_call_sync(
        conn,
        SERVICE,
        path,
        iface,
        method,
        params,
        reply_type,
        c.G_DBUS_CALL_FLAGS_NONE,
        CALL_TIMEOUT_MS,
        null,
        &err,
    );
    if (reply == null and err != null) c.g_error_free(err);
    return reply;
}

fn strOf(v: ?*c.GVariant) []const u8 {
    var len: c.gsize = 0;
    const p = c.g_variant_get_string(v, &len);
    if (p == null) return &.{};
    return p[0..len];
}

/// Value of the first attribute in `keys`, or empty.
fn attrLookup(attrs: ?*c.GVariant, keys: []const []const u8) []const u8 {
    const n = c.g_variant_n_children(attrs);
    var i: c.gsize = 0;
    while (i < n) : (i += 1) {
        const pair = c.g_variant_get_child_value(attrs, i) orelse continue;
        defer c.g_variant_unref(pair);
        const kv = c.g_variant_get_child_value(pair, 0) orelse continue;
        defer c.g_variant_unref(kv);
        const key = strOf(kv);
        for (keys) |want| {
            if (!std.mem.eql(u8, key, want)) continue;
            const vv = c.g_variant_get_child_value(pair, 1) orelse continue;
            defer c.g_variant_unref(vv);
            const val = strOf(vv);
            if (val.len != 0) return val;
        }
    }
    return &.{};
}

/// Every item the service knows, unlocked ones first. `SearchItems`
/// with an EMPTY attribute set is the documented "match everything".
fn allItems(conn: *c.GDBusConnection) Error!*c.GVariant {
    var b: c.GVariantBuilder = undefined;
    c.g_variant_builder_init(&b, c.G_VARIANT_TYPE("a{ss}"));
    const params = c.g_variant_new("(a{ss})", &b);
    return call(
        conn,
        SERVICE_PATH,
        IFACE_SERVICE,
        "SearchItems",
        params,
        c.G_VARIANT_TYPE("(aoao)"),
    ) orelse Error.NoService;
}

/// Candidate logins for `host`, best match first. Read-only.
pub fn findForHost(allocator: std.mem.Allocator, host: []const u8) Error!Matches {
    if (host.len == 0) return .{ .allocator = allocator, .items = &.{} };
    const conn = try bus();
    defer c.g_object_unref(conn);
    const reply = try allItems(conn);
    defer c.g_variant_unref(reply);

    var out: std.ArrayList(Match) = .empty;
    errdefer {
        for (out.items) |m| m.free(allocator);
        out.deinit(allocator);
    }

    var scanned: usize = 0;
    var group: c.gsize = 0;
    while (group < 2) : (group += 1) {
        const locked = group == 1;
        const paths = c.g_variant_get_child_value(reply, group) orelse continue;
        defer c.g_variant_unref(paths);
        const n = c.g_variant_n_children(paths);
        var i: c.gsize = 0;
        while (i < n and scanned < MAX_ITEMS) : (i += 1) {
            scanned += 1;
            const pv = c.g_variant_get_child_value(paths, i) orelse continue;
            defer c.g_variant_unref(pv);
            const path = strOf(pv);
            if (path.len == 0) continue;
            const path_z = allocator.dupeZ(u8, path) catch return Error.OutOfMemory;
            var keep = false;
            defer if (!keep) allocator.free(path_z);

            const props = call(
                conn,
                path_z.ptr,
                IFACE_PROPS,
                "GetAll",
                c.g_variant_new("(s)", IFACE_ITEM),
                c.G_VARIANT_TYPE("(a{sv})"),
            ) orelse continue;
            defer c.g_variant_unref(props);
            const dict = c.g_variant_get_child_value(props, 0) orelse continue;
            defer c.g_variant_unref(dict);

            const label_v = c.g_variant_lookup_value(dict, "Label", c.G_VARIANT_TYPE("s"));
            defer if (label_v != null) c.g_variant_unref(label_v);
            const label = if (label_v != null) strOf(label_v) else "";

            const attrs = c.g_variant_lookup_value(dict, "Attributes", c.G_VARIANT_TYPE("a{ss}"));
            defer if (attrs != null) c.g_variant_unref(attrs);

            var score: u8 = 255;
            if (attrs != null) {
                const site = attrLookup(attrs, &URL_KEYS);
                if (site.len != 0 and hostsMatch(hostOf(site), host)) score = 0;
            }
            if (score == 255 and labelMentions(label, host)) score = 1;
            if (score == 255) continue;

            const user = if (attrs != null) attrLookup(attrs, &USER_KEYS) else "";
            const label_owned = allocator.dupe(u8, label) catch return Error.OutOfMemory;
            errdefer allocator.free(label_owned);
            const user_owned = allocator.dupe(u8, user) catch return Error.OutOfMemory;
            errdefer allocator.free(user_owned);
            out.append(allocator, .{
                .path = path_z,
                .label = label_owned,
                .username = user_owned,
                .locked = locked,
                .score = score,
            }) catch return Error.OutOfMemory;
            keep = true;
        }
    }

    const items = out.toOwnedSlice(allocator) catch return Error.OutOfMemory;
    std.mem.sort(Match, items, {}, lessMatch);
    return .{ .allocator = allocator, .items = items };
}

/// Best-effort promptless unlock. True when the item is usable after.
fn tryUnlock(conn: *c.GDBusConnection, path: [*:0]const u8) bool {
    const one = [_][*c]const u8{ path, null };
    const arr = c.g_variant_new_objv(&one, 1);
    const reply = call(
        conn,
        SERVICE_PATH,
        IFACE_SERVICE,
        "Unlock",
        c.g_variant_new("(@ao)", arr),
        c.G_VARIANT_TYPE("(aoo)"),
    ) orelse return false;
    defer c.g_variant_unref(reply);
    const unlocked = c.g_variant_get_child_value(reply, 0) orelse return false;
    defer c.g_variant_unref(unlocked);
    return c.g_variant_n_children(unlocked) != 0;
}

/// The item's secret value. The returned buffer is the caller's, and
/// the caller MUST release it with `zeroFree` — it is a password.
///
/// A "plain" session is deliberate: the transport is a local AF_UNIX
/// bus, and DH-encrypting to the same machine buys nothing while
/// adding a crypto path to get wrong.
pub fn fetchSecret(allocator: std.mem.Allocator, item_path: [:0]const u8, locked: bool) Error![]u8 {
    const conn = try bus();
    // Registered first, so it runs after the session Close below.
    defer c.g_object_unref(conn);
    if (locked and !tryUnlock(conn, item_path.ptr)) return Error.Locked;

    const opened = call(
        conn,
        SERVICE_PATH,
        IFACE_SERVICE,
        "OpenSession",
        c.g_variant_new("(sv)", "plain", c.g_variant_new_string("")),
        c.G_VARIANT_TYPE("(vo)"),
    ) orelse return Error.NoService;
    defer c.g_variant_unref(opened);
    const session_v = c.g_variant_get_child_value(opened, 1) orelse return Error.NoSecret;
    defer c.g_variant_unref(session_v);
    const session = strOf(session_v);
    const session_z = allocator.dupeZ(u8, session) catch return Error.OutOfMemory;
    defer allocator.free(session_z);
    defer _ = call(conn, session_z.ptr, "org.freedesktop.Secret.Session", "Close", null, null);

    const got = call(
        conn,
        item_path.ptr,
        IFACE_ITEM,
        "GetSecret",
        c.g_variant_new("(o)", session_z.ptr),
        c.G_VARIANT_TYPE("((oayays))"),
    ) orelse return if (locked) Error.Locked else Error.NoSecret;
    defer c.g_variant_unref(got);

    const secret = c.g_variant_get_child_value(got, 0) orelse return Error.NoSecret;
    defer c.g_variant_unref(secret);
    const value = c.g_variant_get_child_value(secret, 2) orelse return Error.NoSecret;
    defer c.g_variant_unref(value);

    var n: c.gsize = 0;
    const raw = c.g_variant_get_fixed_array(value, &n, 1);
    if (raw == null or n == 0) return Error.NoSecret;
    const bytes: [*]const u8 = @ptrCast(raw);
    return allocator.dupe(u8, bytes[0..n]) catch Error.OutOfMemory;
}

/// Wipe then free. `secureZero` and not `@memset`: this builds
/// ReleaseFast only, where a memset before a free is dead code.
pub fn zeroFree(allocator: std.mem.Allocator, buf: []u8) void {
    std.crypto.secureZero(u8, buf);
    allocator.free(buf);
}

// --------------------------------------------------------------- tests

test "hostOf: scheme, port, path, userinfo, bare host" {
    const t = std.testing;
    try t.expectEqualStrings("example.com", hostOf("https://example.com/login?a=b#c"));
    try t.expectEqualStrings("example.com", hostOf("example.com"));
    try t.expectEqualStrings("example.com", hostOf("https://example.com:8443/"));
    try t.expectEqualStrings("example.com", hostOf("https://u:p@ss@example.com/x"));
    try t.expectEqualStrings("[::1]", hostOf("http://[::1]:8080/x"));
    try t.expectEqualStrings("", hostOf(""));
    // The security property, end to end through the shared extractor:
    // no attacker-shaped url may resolve to a host that matches the
    // real site.
    try t.expect(!hostsMatch(hostOf("https://evil-example.com/login"), "example.com"));
    try t.expect(!hostsMatch(hostOf("https://example.com.evil.net/"), "example.com"));
    try t.expect(!hostsMatch(hostOf("https://example.com@evil.net/"), "example.com"));
    try t.expect(!hostsMatch(hostOf("https://evil.net/example.com"), "example.com"));
    try t.expect(!hostsMatch(hostOf("https://evil.net?next=example.com"), "example.com"));
}

test "hostsMatch: www-insensitive, never a suffix rule" {
    const t = std.testing;
    try t.expect(hostsMatch("www.example.com", "example.com"));
    try t.expect(hostsMatch("EXAMPLE.com", "example.COM"));
    try t.expect(!hostsMatch("evil-example.com", "example.com"));
    try t.expect(!hostsMatch("mail.example.com", "example.com"));
    try t.expect(!hostsMatch("", "example.com"));
}

test "labelMentions: substring, and never on a stub host" {
    const t = std.testing;
    try t.expect(labelMentions("GitHub (github.com) work", "github.com"));
    try t.expect(labelMentions("Example.COM login", "www.example.com"));
    try t.expect(!labelMentions("some other entry", "example.com"));
    // Too short a needle would match everything.
    try t.expect(!labelMentions("anything", "ab"));
}

test "match ordering: URL hits before label hits" {
    const t = std.testing;
    var items = [_]Match{
        .{ .path = @constCast(""), .label = @constCast(""), .username = @constCast("zoe"), .locked = false, .score = 1 },
        .{ .path = @constCast(""), .label = @constCast(""), .username = @constCast("amy"), .locked = false, .score = 1 },
        .{ .path = @constCast(""), .label = @constCast(""), .username = @constCast("bob"), .locked = false, .score = 0 },
    };
    std.mem.sort(Match, &items, {}, lessMatch);
    try t.expectEqualStrings("bob", items[0].username);
    try t.expectEqualStrings("amy", items[1].username);
    try t.expectEqualStrings("zoe", items[2].username);
}
