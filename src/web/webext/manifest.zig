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
};

/// Parse `json` (a manifest.json body) into an owned `Manifest`. The
/// backing arena is created on `gpa`; the caller frees it with
/// `Manifest.deinit`.
pub fn parse(gpa: std.mem.Allocator, json: []const u8) ParseError!Manifest {
    var m = Manifest{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer m.arena.deinit();
    const a = m.arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return error.BadJson;
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

    m.name = dupStr(a, root.get("name")) orelse return error.MissingName;
    m.version = dupStr(a, root.get("version")) orelse return error.MissingVersion;
    m.description = dupStr(a, root.get("description")) orelse "";
    m.default_locale = dupStr(a, root.get("default_locale"));

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
                if (dupStr(a, o.get("run_at"))) |ra| script.run_at = RunAt.fromStr(ra);
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
            b.page = dupStr(a, o.get("page"));
            if (o.get("persistent")) |p| b.persistent = !(p == .bool and !p.bool);
            m.background = b;
        }
    }

    if (root.get("browser_action") orelse root.get("page_action")) |ba| {
        if (ba == .object) {
            const o = ba.object;
            var act = BrowserAction{};
            act.default_title = dupStr(a, o.get("default_title"));
            act.default_popup = dupStr(a, o.get("default_popup"));
            // default_icon may be a string or an object of sizes; take a
            // string form when present, else leave null.
            if (o.get("default_icon")) |di| {
                if (di == .string) act.default_icon = a.dupe(u8, di.string) catch return error.OutOfMemory;
            }
            m.browser_action = act;
        }
    }

    return m;
}

fn dupStr(a: std.mem.Allocator, val: ?std.json.Value) ?[]const u8 {
    const v = val orelse return null;
    return switch (v) {
        .string => |s| a.dupe(u8, s) catch null,
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

/// A short, filesystem-safe id derived from the manifest when the
/// package carries none (unpacked dirs frequently do not). Deterministic
/// so re-loading the same extension keeps its storage. `out` must hold
/// at least 16 bytes; returns the slice used.
pub fn deriveId(name: []const u8, version: []const u8, out: []u8) []const u8 {
    std.debug.assert(out.len >= 16);
    var h = std.hash.Wyhash.init(0xE87E11D);
    h.update(name);
    h.update("@");
    h.update(version);
    const digest = h.final();
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        out[i] = hex[(digest >> @intCast((15 - i) * 4)) & 0xf];
    }
    return out[0..16];
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

test "deriveId is stable and hex" {
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    const id1 = deriveId("My Ext", "1.0", &a);
    const id2 = deriveId("My Ext", "1.0", &b);
    try t.expectEqualStrings(id1, id2);
    const c = deriveId("My Ext", "1.1", &b);
    try t.expect(!std.mem.eql(u8, id1, c));
    for (id1) |ch| try t.expect(std.ascii.isHex(ch));
}
