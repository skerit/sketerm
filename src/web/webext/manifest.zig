//! Manifest V2 (Firefox-flavor WebExtensions) parse — the targeted
//! subset sketerm hosts: name, version, description, permissions,
//! content_scripts, background, browser_action, default_locale.
//!
//! Pure std + JSON, no CEF, no GTK: compiled into the helper AND both
//! test roots. MV3 is deliberately NOT supported — the proposal targets
//! the MV2/Firefox surface, where blocking webRequest still exists.
//!
//! Everything the parse produces is owned by a single ArenaAllocator the
//! caller resets to free the whole manifest at once (`Manifest.arena`);
//! nothing here borrows the source JSON.

const std = @import("std");

pub const RunAt = enum {
    document_start,
    document_end,
    document_idle,

    pub fn fromStr(s: []const u8) RunAt {
        if (std.mem.eql(u8, s, "document_start")) return .document_start;
        if (std.mem.eql(u8, s, "document_end")) return .document_end;
        return .document_idle;
    }
    pub fn toStr(self: RunAt) []const u8 {
        return @tagName(self);
    }
};

pub const ContentScript = struct {
    matches: [][]const u8 = &.{},
    exclude_matches: [][]const u8 = &.{},
    js: [][]const u8 = &.{},
    css: [][]const u8 = &.{},
    run_at: RunAt = .document_idle,
    all_frames: bool = false,
};

pub const Background = struct {
    /// `background.scripts` — loaded into a generated background page.
    scripts: [][]const u8 = &.{},
    /// `background.page` — an author-provided HTML page (takes
    /// precedence over `scripts` when both are present, per spec).
    page: ?[]const u8 = null,
    /// `background.persistent`; MV2 defaults to true. Non-persistent
    /// event pages are hosted the same way in this foundation.
    persistent: bool = true,
};

pub const BrowserAction = struct {
    default_title: ?[]const u8 = null,
    default_icon: ?[]const u8 = null,
    default_popup: ?[]const u8 = null,
};

pub const ActionKind = enum { browser, page };

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    manifest_version: u32 = 2,
    name: []const u8 = "",
    version: []const u8 = "",
    description: []const u8 = "",
    default_locale: ?[]const u8 = null,
    permissions: [][]const u8 = &.{},
    host_permissions: [][]const u8 = &.{},
    content_scripts: []ContentScript = &.{},
    background: ?Background = null,
    browser_action: ?BrowserAction = null,
    page_action: ?BrowserAction = null,
    /// `browser_specific_settings.gecko.id` (or the older
    /// `applications.gecko.id`) — the author's own stable identity,
    /// which is what an id should be derived from: it does not move
    /// when the version does. Null for packages that declare none.
    gecko_id: ?[]const u8 = null,
    /// `web_accessible_resources` patterns, relative paths that a PAGE
    /// (not just the extension) may load over `chrome-extension://`.
    web_accessible_resources: [][]const u8 = &.{},

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
    }

    /// Whether `permission` (or `<all_urls>`, or a matching host
    /// pattern) is declared. Callers gate privileged bridge verbs
    /// (tabs, storage) on this.
    pub fn hasPermission(self: *const Manifest, permission: []const u8) bool {
        for (self.permissions) |p| {
            if (std.mem.eql(u8, p, permission)) return true;
        }
        return false;
    }
};

pub const ParseError = error{
    OutOfMemory,
    BadJson,
    NotObject,
    MissingName,
    MissingVersion,
    UnsupportedManifestVersion,
    ConflictingActions,
};

/// Parse `json` (a manifest.json body) into an owned `Manifest`. The
/// backing arena is created on `gpa`; the caller frees it with
/// `Manifest.deinit`.
pub fn parse(gpa: std.mem.Allocator, json: []const u8) ParseError!Manifest {
    var m = Manifest{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer m.arena.deinit();
    const a = m.arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadJson,
    };
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotObject,
    };

    if (root.get("manifest_version")) |mv| {
        m.manifest_version = switch (mv) {
            .integer => |i| @intCast(@max(i, 0)),
            else => 2,
        };
    }
    // Reject MV3 loudly: its content-script/background/permission model
    // differs enough that silently parsing it would mislead a user.
    if (m.manifest_version >= 3) return error.UnsupportedManifestVersion;

    m.name = try dupStr(a, root.get("name")) orelse return error.MissingName;
    m.version = try dupStr(a, root.get("version")) orelse return error.MissingVersion;
    m.description = try dupStr(a, root.get("description")) orelse "";
    m.default_locale = try dupStr(a, root.get("default_locale"));

    m.permissions = try dupStrArray(a, root.get("permissions"));
    m.host_permissions = try dupStrArray(a, root.get("host_permissions"));

    if (root.get("content_scripts")) |cs| {
        if (cs == .array) {
            var list = std.ArrayList(ContentScript).empty;
            for (cs.array.items) |item| {
                if (item != .object) continue;
                const o = item.object;
                var script = ContentScript{};
                script.matches = try dupStrArray(a, o.get("matches"));
                script.exclude_matches = try dupStrArray(a, o.get("exclude_matches"));
                script.js = try dupStrArray(a, o.get("js"));
                script.css = try dupStrArray(a, o.get("css"));
                if (try dupStr(a, o.get("run_at"))) |ra| script.run_at = RunAt.fromStr(ra);
                if (o.get("all_frames")) |af| script.all_frames = (af == .bool and af.bool);
                try list.append(a, script);
            }
            m.content_scripts = try list.toOwnedSlice(a);
        }
    }

    if (root.get("background")) |bg| {
        if (bg == .object) {
            const o = bg.object;
            var b = Background{};
            b.scripts = try dupStrArray(a, o.get("scripts"));
            b.page = try dupStr(a, o.get("page"));
            if (o.get("persistent")) |p| b.persistent = !(p == .bool and !p.bool);
            m.background = b;
        }
    }

    // `browser_specific_settings` is the current spelling, `applications`
    // the deprecated one; both carry the same `gecko.id`.
    if (root.get("browser_specific_settings") orelse root.get("applications")) |bss| {
        if (bss == .object) {
            if (bss.object.get("gecko")) |g| {
                if (g == .object) m.gecko_id = try dupStr(a, g.object.get("id"));
            }
        }
    }

    // MV2 spells this as a bare array of path patterns.
    m.web_accessible_resources = try dupStrArray(a, root.get("web_accessible_resources"));

    const browser_action = root.get("browser_action");
    const page_action = root.get("page_action");
    if (browser_action != null and page_action != null) return error.ConflictingActions;
    if (browser_action) |ba| m.browser_action = try parseAction(a, ba);
    if (page_action) |pa| m.page_action = try parseAction(a, pa);

    return m;
}

fn parseAction(a: std.mem.Allocator, value: std.json.Value) ParseError!?BrowserAction {
    if (value != .object) return null;
    const o = value.object;
    var act = BrowserAction{};
    act.default_title = try dupStr(a, o.get("default_title"));
    act.default_popup = try dupStr(a, o.get("default_popup"));
    if (o.get("default_icon")) |di| {
        if (iconFromValue(di)) |path| act.default_icon = a.dupe(u8, path) catch return error.OutOfMemory;
    }
    return act;
}

/// Resolve an MV2 icon value — a plain path string, or an object keyed
/// by pixel size, preferring the largest toolbar-sized (<=64) entry and
/// falling back to any entry. Shared with `browserAction.setIcon`.
///
/// @return a slice borrowing `v`; the caller copies it.
pub fn iconFromValue(v: std.json.Value) ?[]const u8 {
    if (v == .string) return v.string;
    if (v != .object) return null;
    var best: ?[]const u8 = null;
    var best_size: u32 = 0;
    var best_fits = false;
    var it = v.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        const size = std.fmt.parseInt(u32, entry.key_ptr.*, 10) catch 0;
        const fits = size <= 64;
        if (best == null or (fits and (!best_fits or size > best_size))) {
            best = entry.value_ptr.string;
            best_size = size;
            best_fits = fits;
        }
    }
    return best;
}

fn dupStr(a: std.mem.Allocator, val: ?std.json.Value) ParseError!?[]const u8 {
    const v = val orelse return null;
    return switch (v) {
        .string => |s| a.dupe(u8, s) catch return error.OutOfMemory,
        else => null,
    };
}

fn dupStrArray(a: std.mem.Allocator, val: ?std.json.Value) ParseError![][]const u8 {
    const v = val orelse return &.{};
    if (v != .array) return &.{};
    var list = std.ArrayList([]const u8).empty;
    for (v.array.items) |item| {
        if (item != .string) continue;
        try list.append(a, a.dupe(u8, item.string) catch return error.OutOfMemory);
    }
    return list.toOwnedSlice(a) catch return error.OutOfMemory;
}

/// Longest id we will mint or accept. Pinned to `webrequest.MAX_ID`,
/// the fixed slot width the engine's IO thread reads ids out of.
pub const MAX_ID_LEN = 64;

/// The stable identity of an extension. **Never version-dependent**: a
/// v1 and a v2 of the same package must land on the SAME id, or an
/// upgrade mints a second registry entry, leaves the old copy enabled
/// and injecting, and orphans `storage.local`.
///
/// Prefers the author's own `browser_specific_settings.gecko.id`; falls
/// back to a hash of the NAME alone. `out` must hold `MAX_ID_LEN` bytes.
pub fn extensionId(m: *const Manifest, out: []u8) []const u8 {
    std.debug.assert(out.len >= MAX_ID_LEN);
    if (m.gecko_id) |g| {
        if (idValid(g)) {
            @memcpy(out[0..g.len], g);
            return out[0..g.len];
        }
    }
    return deriveId(m.name, out);
}

/// Whether a manifest-declared id can be used verbatim. It becomes a
/// path component under the data dir and a key in a fixed-width slot
/// table, so a separator or a control byte disqualifies it; everything
/// else Gecko allows (`user@host`, `{uuid}`) is fine on both counts.
pub fn idValid(g: []const u8) bool {
    if (g.len == 0 or g.len > MAX_ID_LEN) return false;
    for (g) |ch| {
        if (ch == '/' or ch == '\\' or ch < 0x21 or ch == 0x7f) return false;
    }
    // A leading dot would hide the directory and `..` would escape it.
    if (g[0] == '.') return false;
    return true;
}

/// A short, filesystem-safe id for a package that declares none.
/// Deterministic AND version-independent, so re-loading or upgrading the
/// same extension keeps its storage. `out` must hold >= 16 bytes.
pub fn deriveId(name: []const u8, out: []u8) []const u8 {
    std.debug.assert(out.len >= 16);
    return hex16(0xE87E11D, name, out);
}

/// The HOST half of this extension's `chrome-extension://<host>/` origin.
///
/// It is NOT the id: a Gecko id is `uBlock0@raymondhill.net` or
/// `{7a7a4a92-…}`, and neither `@` nor `{}` may appear in a URL host —
/// the first would parse as userinfo and the second is simply invalid.
/// Firefox has exactly this split (a per-install UUID in the url, the
/// author's id in `runtime.id`), so extensions already expect the two to
/// differ. 16 lowercase hex digits, stable for a given id.
pub fn originHost(id: []const u8, out: []u8) []const u8 {
    std.debug.assert(out.len >= 16);
    return hex16(0x0B18E17, id, out);
}

/// The 16-hex-digit rendering of a Wyhash digest, the same one
/// `filtersub.cacheName` prints — zero-padded, so a small digest still
/// occupies the full width a caller slices out.
fn hex16(seed: u64, bytes: []const u8, out: []u8) []const u8 {
    var h = std.hash.Wyhash.init(seed);
    h.update(bytes);
    return std.fmt.bufPrint(out, "{x:0>16}", .{h.final()}) catch unreachable;
}

// ─── tests ──────────────────────────────────────────────────────────

const t = std.testing;

test "parse: minimal manifest" {
    const gpa = t.allocator;
    var m = try parse(gpa,
        \\{"manifest_version":2,"name":"Test","version":"1.2.3"}
    );
    defer m.deinit();
    try t.expectEqualStrings("Test", m.name);
    try t.expectEqualStrings("1.2.3", m.version);
    try t.expectEqual(@as(usize, 0), m.content_scripts.len);
    try t.expectEqual(@as(?Background, null), m.background);
}

test "parse: full content script + background" {
    const gpa = t.allocator;
    var m = try parse(gpa,
        \\{
        \\  "manifest_version": 2,
        \\  "name": "Full",
        \\  "version": "0.1",
        \\  "description": "does things",
        \\  "default_locale": "en",
        \\  "permissions": ["storage", "tabs", "<all_urls>"],
        \\  "content_scripts": [{
        \\    "matches": ["*://*.example.com/*"],
        \\    "exclude_matches": ["*://admin.example.com/*"],
        \\    "js": ["cs.js"],
        \\    "css": ["cs.css"],
        \\    "run_at": "document_end",
        \\    "all_frames": true
        \\  }],
        \\  "background": { "scripts": ["bg.js"], "persistent": false },
        \\  "browser_action": { "default_title": "Go", "default_popup": "popup.html" }
        \\}
    );
    defer m.deinit();
    try t.expectEqualStrings("does things", m.description);
    try t.expectEqualStrings("en", m.default_locale.?);
    try t.expect(m.hasPermission("storage"));
    try t.expect(m.hasPermission("tabs"));
    try t.expect(!m.hasPermission("cookies"));
    try t.expectEqual(@as(usize, 1), m.content_scripts.len);
    const cs = m.content_scripts[0];
    try t.expectEqualStrings("*://*.example.com/*", cs.matches[0]);
    try t.expectEqualStrings("*://admin.example.com/*", cs.exclude_matches[0]);
    try t.expectEqualStrings("cs.js", cs.js[0]);
    try t.expectEqualStrings("cs.css", cs.css[0]);
    try t.expectEqual(RunAt.document_end, cs.run_at);
    try t.expect(cs.all_frames);
    try t.expectEqualStrings("bg.js", m.background.?.scripts[0]);
    try t.expect(!m.background.?.persistent);
    try t.expectEqualStrings("Go", m.browser_action.?.default_title.?);
    try t.expectEqualStrings("popup.html", m.browser_action.?.default_popup.?);
}

test "parse: rejects MV3 and missing fields" {
    const gpa = t.allocator;
    try t.expectError(error.UnsupportedManifestVersion, parse(gpa,
        \\{"manifest_version":3,"name":"x","version":"1"}
    ));
    try t.expectError(error.MissingName, parse(gpa,
        \\{"manifest_version":2,"version":"1"}
    ));
    try t.expectError(error.MissingVersion, parse(gpa,
        \\{"manifest_version":2,"name":"x"}
    ));
    try t.expectError(error.BadJson, parse(gpa, "not json"));
}

test "parse: browser action chooses a toolbar-sized icon" {
    const gpa = t.allocator;
    var m = try parse(gpa,
        \\{"manifest_version":2,"name":"Icons","version":"1",
        \\ "browser_action":{"default_icon":{"128":"i128.png","16":"i16.png","32":"i32.png"}}}
    );
    defer m.deinit();
    try t.expectEqualStrings("i32.png", m.browser_action.?.default_icon.?);
}

test "parse: page action remains distinct from browser action" {
    const gpa = t.allocator;
    var m = try parse(gpa,
        \\{"manifest_version":2,"name":"Page","version":"1",
        \\ "page_action":{"default_title":"Only here","default_popup":"page.html"}}
    );
    defer m.deinit();
    try t.expect(m.browser_action == null);
    try t.expectEqualStrings("Only here", m.page_action.?.default_title.?);
}

test "parse: browser and page actions are mutually exclusive" {
    const gpa = t.allocator;
    try t.expectError(error.ConflictingActions, parse(gpa,
        \\{"manifest_version":2,"name":"Both","version":"1",
        \\ "browser_action":{},"page_action":{}}
    ));
}

test "idValid rejects malformed and overlong ids" {
    try t.expect(idValid("uBlock0@raymondhill.net"));
    try t.expect(idValid("{7a7a4a92-a2a0-41d1-9fd7-1e92480d612d}"));
    try t.expect(!idValid(""));
    try t.expect(!idValid(".hidden"));
    try t.expect(!idValid("../escape"));
    try t.expect(!idValid("bad\\path"));
    try t.expect(!idValid("bad\x00id"));
    try t.expect(!idValid("x" ** (MAX_ID_LEN + 1)));
}

test "deriveId is stable, hex and version-independent" {
    var a: [MAX_ID_LEN]u8 = undefined;
    var b: [MAX_ID_LEN]u8 = undefined;
    const id1 = deriveId("My Ext", &a);
    const id2 = deriveId("My Ext", &b);
    try t.expectEqualStrings(id1, id2);
    try t.expect(!std.mem.eql(u8, id1, deriveId("Other Ext", &b)));
    for (id1) |ch| try t.expect(std.ascii.isHex(ch));
}

test "extensionId prefers gecko.id and never moves with the version" {
    const gpa = t.allocator;
    var v1 = try parse(gpa,
        \\{"manifest_version":2,"name":"uBlock Origin","version":"1.73.0",
        \\ "browser_specific_settings":{"gecko":{"id":"uBlock0@raymondhill.net"}}}
    );
    defer v1.deinit();
    var v2 = try parse(gpa,
        \\{"manifest_version":2,"name":"uBlock Origin","version":"1.74.0",
        \\ "browser_specific_settings":{"gecko":{"id":"uBlock0@raymondhill.net"}}}
    );
    defer v2.deinit();
    var a: [MAX_ID_LEN]u8 = undefined;
    var b: [MAX_ID_LEN]u8 = undefined;
    try t.expectEqualStrings("uBlock0@raymondhill.net", extensionId(&v1, &a));
    // THE upgrade defect: two versions must land on one id.
    try t.expectEqualStrings(extensionId(&v1, &a), extensionId(&v2, &b));

    // The deprecated `applications` spelling is honoured too.
    var old = try parse(gpa,
        \\{"manifest_version":2,"name":"X","version":"1",
        \\ "applications":{"gecko":{"id":"{7a7a4a92-a2a0-41d1-9fd7-1e92480d612d}"}}}
    );
    defer old.deinit();
    try t.expectEqualStrings("{7a7a4a92-a2a0-41d1-9fd7-1e92480d612d}", extensionId(&old, &a));

    // No gecko id: a version-independent hash of the name.
    var bare1 = try parse(gpa,
        \\{"manifest_version":2,"name":"Bare","version":"1.0"}
    );
    defer bare1.deinit();
    var bare2 = try parse(gpa,
        \\{"manifest_version":2,"name":"Bare","version":"9.9"}
    );
    defer bare2.deinit();
    try t.expectEqualStrings(extensionId(&bare1, &a), extensionId(&bare2, &b));
}

test "extensionId refuses an id that would escape its directory" {
    const gpa = t.allocator;
    var m = try parse(gpa,
        \\{"manifest_version":2,"name":"Evil","version":"1",
        \\ "browser_specific_settings":{"gecko":{"id":"../../etc/passwd"}}}
    );
    defer m.deinit();
    var a: [MAX_ID_LEN]u8 = undefined;
    const id = extensionId(&m, &a);
    try t.expect(std.mem.indexOf(u8, id, "/") == null);
    try t.expectEqualStrings(deriveId("Evil", &a), id);
}

test "originHost is a valid url host and differs from the id" {
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    const h = originHost("uBlock0@raymondhill.net", &a);
    try t.expectEqual(@as(usize, 16), h.len);
    for (h) |ch| try t.expect(std.ascii.isHex(ch));
    try t.expect(!std.mem.eql(u8, h, originHost("addon@darkreader.org", &b)));
    try t.expectEqualStrings(h, originHost("uBlock0@raymondhill.net", &b));
}

test "parse: web_accessible_resources" {
    const gpa = t.allocator;
    var m = try parse(gpa,
        \\{"manifest_version":2,"name":"x","version":"1",
        \\ "web_accessible_resources":["/web_accessible_resources/*"]}
    );
    defer m.deinit();
    try t.expectEqual(@as(usize, 1), m.web_accessible_resources.len);
    try t.expectEqualStrings("/web_accessible_resources/*", m.web_accessible_resources[0]);
}
