//! Userscript metadata: the `==UserScript==` block (Violentmonkey
//! spec subset) and the URL-matching semantics behind `@match` /
//! `@include` / `@exclude`.
//!
//! Pure code: std only, no CEF, no GTK, no sockets — parsed by the
//! helper at `us_script_set` time and by the GUI for display, so it
//! compiles in BOTH test roots.
//!
//! Supported keys: `@name`, `@match` (MV2 match patterns), `@include`
//! and `@exclude` (globs; `/regex/` includes are NOT supported and are
//! counted in `dropped_patterns` — the script then simply never
//! matches through that pattern), `@run-at` (`document-start` /
//! `document-end` / `document-idle`; anything else falls back to the
//! Violentmonkey default `document-end`), `@grant` (the GM_* functions
//! the injector hands the script — `granted`), `@connect` (the hosts
//! GM_xmlhttpRequest may reach — `connectAllowed`), `@namespace`,
//! `@version`, `@description` (GM_info, and the value-store key).
//! Unknown keys are ignored.
//!
//! A script with NO match/include patterns applies to every page
//! (Violentmonkey's rule); `@exclude` always wins over both.

const std = @import("std");

pub const RunAt = enum(u8) {
    document_start = 0,
    document_end = 1,
    document_idle = 2,
};

pub const Meta = struct {
    name: []const u8 = "",
    run_at: RunAt = .document_end,
    /// `@match` patterns, verbatim.
    matches: []const []const u8 = &.{},
    /// `@include` globs, verbatim (regex includes were dropped).
    includes: []const []const u8 = &.{},
    /// `@exclude` globs, verbatim.
    excludes: []const []const u8 = &.{},
    /// True when every `@grant` value is `none` (or none was given).
    grant_none: bool = true,
    /// `@grant` values other than `none`, verbatim (`GM_getValue`,
    /// `GM.xmlHttpRequest`, `unsafeWindow`, ...). Only these GM
    /// functions are handed to the script.
    grants: []const []const u8 = &.{},
    /// `@connect` values: the hosts `GM_xmlhttpRequest` may reach
    /// besides the page's own (`*` = any, `self` = the page's host).
    connects: []const []const u8 = &.{},
    namespace: []const u8 = "",
    version: []const u8 = "",
    description: []const u8 = "",
    /// `/regex/` include/exclude patterns this parser refuses.
    dropped_patterns: u32 = 0,
};

/// Parse the FIRST `==UserScript==` block. Null when the block is
/// absent or unterminated — a file without one is not a userscript.
/// Slices borrow from `source`; list slices are allocated from `gpa`
/// (free with `freeMeta`).
pub fn parseMeta(gpa: std.mem.Allocator, source: []const u8) !?Meta {
    const open = std.mem.indexOf(u8, source, "==UserScript==") orelse return null;
    const close_rel = std.mem.indexOf(u8, source[open..], "==/UserScript==") orelse return null;
    const block = source[open .. open + close_rel];

    var meta = Meta{};
    var matches: std.ArrayList([]const u8) = .empty;
    var includes: std.ArrayList([]const u8) = .empty;
    var excludes: std.ArrayList([]const u8) = .empty;
    errdefer matches.deinit(gpa);
    errdefer includes.deinit(gpa);
    errdefer excludes.deinit(gpa);
    var grants: std.ArrayList([]const u8) = .empty;
    errdefer grants.deinit(gpa);
    var connects: std.ArrayList([]const u8) = .empty;
    errdefer connects.deinit(gpa);

    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        // Metadata lines are comments: strip a leading `//`.
        const body = if (std.mem.startsWith(u8, line, "//"))
            std.mem.trimStart(u8, line[2..], " \t")
        else
            line;
        if (body.len == 0 or body[0] != '@') continue;
        const sp = std.mem.indexOfAny(u8, body, " \t") orelse continue;
        const key = body[0..sp];
        const val = std.mem.trim(u8, body[sp..], " \t");
        if (val.len == 0) continue;

        if (std.mem.eql(u8, key, "@name")) {
            if (meta.name.len == 0) meta.name = val;
        } else if (std.mem.eql(u8, key, "@match")) {
            try matches.append(gpa, val);
        } else if (std.mem.eql(u8, key, "@include")) {
            if (val.len >= 2 and val[0] == '/' and val[val.len - 1] == '/') {
                meta.dropped_patterns += 1;
            } else try includes.append(gpa, val);
        } else if (std.mem.eql(u8, key, "@exclude")) {
            if (val.len >= 2 and val[0] == '/' and val[val.len - 1] == '/') {
                meta.dropped_patterns += 1;
            } else try excludes.append(gpa, val);
        } else if (std.mem.eql(u8, key, "@run-at")) {
            if (std.mem.eql(u8, val, "document-start")) {
                meta.run_at = .document_start;
            } else if (std.mem.eql(u8, val, "document-end")) {
                meta.run_at = .document_end;
            } else if (std.mem.eql(u8, val, "document-idle")) {
                meta.run_at = .document_idle;
            }
        } else if (std.mem.eql(u8, key, "@grant")) {
            if (!std.mem.eql(u8, val, "none")) {
                meta.grant_none = false;
                try grants.append(gpa, val);
            }
        } else if (std.mem.eql(u8, key, "@connect")) {
            try connects.append(gpa, val);
        } else if (std.mem.eql(u8, key, "@namespace")) {
            if (meta.namespace.len == 0) meta.namespace = val;
        } else if (std.mem.eql(u8, key, "@version")) {
            if (meta.version.len == 0) meta.version = val;
        } else if (std.mem.eql(u8, key, "@description")) {
            if (meta.description.len == 0) meta.description = val;
        }
    }
    meta.matches = try matches.toOwnedSlice(gpa);
    errdefer gpa.free(meta.matches);
    meta.includes = try includes.toOwnedSlice(gpa);
    errdefer gpa.free(meta.includes);
    meta.excludes = try excludes.toOwnedSlice(gpa);
    errdefer gpa.free(meta.excludes);
    meta.grants = try grants.toOwnedSlice(gpa);
    errdefer gpa.free(meta.grants);
    meta.connects = try connects.toOwnedSlice(gpa);
    return meta;
}

pub fn freeMeta(gpa: std.mem.Allocator, meta: *const Meta) void {
    gpa.free(meta.matches);
    gpa.free(meta.includes);
    gpa.free(meta.excludes);
    gpa.free(meta.grants);
    gpa.free(meta.connects);
}

/// Whether the script declared `@grant name`. `GM_foo` and its
/// promise-API spelling `GM.foo` grant each other, as in
/// Violentmonkey/Tampermonkey.
pub fn granted(meta: *const Meta, name: []const u8) bool {
    for (meta.grants) |g| {
        if (std.mem.eql(u8, g, name)) return true;
        if (std.mem.startsWith(u8, g, "GM.") and std.mem.startsWith(u8, name, "GM_") and
            std.ascii.eqlIgnoreCase(g[3..], name[3..])) return true;
        if (std.mem.startsWith(u8, g, "GM_") and std.mem.startsWith(u8, name, "GM.") and
            std.ascii.eqlIgnoreCase(g[3..], name[3..])) return true;
    }
    return false;
}

/// `@connect` enforcement for `GM_xmlhttpRequest`: the page's own host
/// is always reachable; beyond it a request needs a `@connect` naming
/// the target host or a parent domain of it, `*` (anything), `self`
/// (the page host again) or `localhost` (loopback names). With no
/// `@connect` at all only the page's host is reachable — the strict
/// reading, because an undeclared cross-origin request with the user's
/// cookies is exactly what the key exists to prevent.
pub fn connectAllowed(meta: *const Meta, page_host: []const u8, target_host: []const u8) bool {
    if (target_host.len == 0) return false;
    if (page_host.len != 0 and std.ascii.eqlIgnoreCase(page_host, target_host)) return true;
    for (meta.connects) |cn| {
        if (std.mem.eql(u8, cn, "*")) return true;
        if (std.mem.eql(u8, cn, "self")) {
            if (std.ascii.eqlIgnoreCase(page_host, target_host)) return true;
            continue;
        }
        if (std.mem.eql(u8, cn, "localhost")) {
            if (std.mem.eql(u8, target_host, "localhost") or std.mem.eql(u8, target_host, "127.0.0.1") or
                std.mem.eql(u8, target_host, "[::1]")) return true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(cn, target_host)) return true;
        // A parent domain covers its subdomains.
        if (target_host.len > cn.len + 1 and target_host[target_host.len - cn.len - 1] == '.' and
            std.ascii.eqlIgnoreCase(target_host[target_host.len - cn.len ..], cn)) return true;
    }
    return false;
}

test "connectAllowed: page host, declared hosts and parents, star, and nothing else" {
    const gpa = std.testing.allocator;
    const src =
        \\// ==UserScript==
        \\// @name c
        \\// @grant GM_xmlhttpRequest
        \\// @grant GM.getValue
        \\// @connect example.com
        \\// @connect localhost
        \\// ==/UserScript==
    ;
    const meta = (try parseMeta(gpa, src)).?;
    defer freeMeta(gpa, &meta);
    try std.testing.expect(connectAllowed(&meta, "page.test", "page.test"));
    try std.testing.expect(connectAllowed(&meta, "page.test", "example.com"));
    try std.testing.expect(connectAllowed(&meta, "page.test", "api.example.com"));
    try std.testing.expect(!connectAllowed(&meta, "page.test", "badexample.com"));
    try std.testing.expect(connectAllowed(&meta, "page.test", "127.0.0.1"));
    try std.testing.expect(!connectAllowed(&meta, "page.test", "evil.test"));
    try std.testing.expect(granted(&meta, "GM_xmlhttpRequest"));
    try std.testing.expect(granted(&meta, "GM_getValue"));
    try std.testing.expect(!granted(&meta, "GM_setValue"));
    try std.testing.expect(!meta.grant_none);
}

/// Does the script run on `url`? Patterns win in Violentmonkey order:
/// no match/include pattern = everywhere; any hit among matches OR
/// includes qualifies; any exclude hit disqualifies.
pub fn applies(meta: *const Meta, url: []const u8) bool {
    for (meta.excludes) |g| {
        if (globMatch(g, url)) return false;
    }
    if (meta.matches.len == 0 and meta.includes.len == 0) return true;
    for (meta.matches) |p| {
        if (matchPattern(p, url)) return true;
    }
    for (meta.includes) |g| {
        if (globMatch(g, url)) return true;
    }
    return false;
}

/// MV2 match pattern: `<all_urls>` or `<scheme>://<host><path>` where
/// scheme is `*` (= http|https), `http`, `https` or `file`; host is
/// `*`, `*.domain` or exact (URL ports are ignored, per the spec);
/// path is a `*` glob matched against path+query. Malformed patterns
/// match nothing.
pub fn matchPattern(pattern: []const u8, url: []const u8) bool {
    if (std.mem.eql(u8, pattern, "<all_urls>")) {
        return std.mem.indexOf(u8, url, "://") != null;
    }
    const psep = std.mem.indexOf(u8, pattern, "://") orelse return false;
    const pscheme = pattern[0..psep];
    const usep = std.mem.indexOf(u8, url, "://") orelse return false;
    const uscheme = url[0..usep];
    if (std.mem.eql(u8, pscheme, "*")) {
        if (!std.mem.eql(u8, uscheme, "http") and !std.mem.eql(u8, uscheme, "https"))
            return false;
    } else if (!std.mem.eql(u8, pscheme, uscheme)) {
        return false;
    }

    const prest = pattern[psep + 3 ..];
    const pslash = std.mem.indexOfScalar(u8, prest, '/') orelse return false;
    const phost = prest[0..pslash];
    const ppath = prest[pslash..];

    const urest = url[usep + 3 ..];
    const uslash = std.mem.indexOfScalar(u8, urest, '/') orelse urest.len;
    var uhost = urest[0..uslash];
    // Ports never appear in patterns and are ignored in the URL.
    if (std.mem.indexOfScalar(u8, uhost, ':')) |colon| uhost = uhost[0..colon];
    var upath = if (uslash < urest.len) urest[uslash..] else "/";
    if (std.mem.indexOfScalar(u8, upath, '#')) |frag| upath = upath[0..frag];

    if (std.mem.eql(u8, phost, "*")) {
        // any host
    } else if (std.mem.startsWith(u8, phost, "*.")) {
        const base = phost[2..];
        if (!std.ascii.eqlIgnoreCase(uhost, base) and
            !(uhost.len > base.len + 1 and
                uhost[uhost.len - base.len - 1] == '.' and
                std.ascii.endsWithIgnoreCase(uhost, base)))
            return false;
    } else if (!std.ascii.eqlIgnoreCase(uhost, phost)) {
        return false;
    }

    return globMatch(ppath, upath);
}

/// `*`-glob over the whole string (the `@include` and match-path
/// semantics; `@include` additionally case-folds nothing — URLs are
/// matched as given, like Violentmonkey).
pub const globMatch = @import("../util/glob.zig").matchPath;

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const t = std.testing;

test "userscript: metadata block parses keys and defaults" {
    const src =
        \\// ==UserScript==
        \\// @name      Example Script
        \\// @match     https://example.com/*
        \\// @include   http://old.example/*
        \\// @exclude   https://example.com/admin/*
        \\// @run-at    document-start
        \\// @grant     none
        \\// ==/UserScript==
        \\console.log("hi");
    ;
    const meta = (try parseMeta(t.allocator, src)).?;
    defer freeMeta(t.allocator, &meta);
    try t.expectEqualStrings("Example Script", meta.name);
    try t.expectEqual(RunAt.document_start, meta.run_at);
    try t.expectEqual(@as(usize, 1), meta.matches.len);
    try t.expectEqual(@as(usize, 1), meta.includes.len);
    try t.expectEqual(@as(usize, 1), meta.excludes.len);
    try t.expect(meta.grant_none);
    try t.expectEqual(@as(u32, 0), meta.dropped_patterns);
}

test "userscript: missing block, defaults, regex includes refused" {
    try t.expectEqual(@as(?Meta, null), try parseMeta(t.allocator, "console.log(1)"));
    // Unterminated block is not a userscript.
    try t.expectEqual(@as(?Meta, null), try parseMeta(t.allocator, "// ==UserScript==\n// @name x\n"));

    const src =
        \\// ==UserScript==
        \\// @name r
        \\// @include /https?:.*/
        \\// @grant GM_setValue
        \\// ==/UserScript==
    ;
    const meta = (try parseMeta(t.allocator, src)).?;
    defer freeMeta(t.allocator, &meta);
    // Violentmonkey default run-at; the regex include is counted, and
    // a non-none grant is recorded (the injector still provides no
    // GM_* API — the canary here is the FLAG, not behavior).
    try t.expectEqual(RunAt.document_end, meta.run_at);
    try t.expectEqual(@as(u32, 1), meta.dropped_patterns);
    try t.expect(!meta.grant_none);
    // No match/include left: applies everywhere.
    try t.expect(applies(&meta, "https://anything.example/"));
}

test "userscript: MV2 match pattern semantics" {
    // Scheme.
    try t.expect(matchPattern("*://example.com/*", "http://example.com/"));
    try t.expect(matchPattern("*://example.com/*", "https://example.com/x"));
    try t.expect(!matchPattern("*://example.com/*", "file:///example.com/"));
    try t.expect(matchPattern("https://example.com/*", "https://example.com/"));
    try t.expect(!matchPattern("https://example.com/*", "http://example.com/"));
    // Host: exact, *.domain (base itself AND subdomains), bare *.
    try t.expect(matchPattern("*://*.example.com/*", "https://example.com/"));
    try t.expect(matchPattern("*://*.example.com/*", "https://a.b.example.com/"));
    try t.expect(!matchPattern("*://*.example.com/*", "https://notexample.com/"));
    try t.expect(matchPattern("*://*/path", "https://any.host/path"));
    // Ports are ignored; fragments are ignored.
    try t.expect(matchPattern("*://example.com/x", "https://example.com:8080/x"));
    try t.expect(matchPattern("*://example.com/x", "https://example.com/x#frag"));
    // Path glob includes the query.
    try t.expect(matchPattern("*://example.com/a/*", "https://example.com/a/b?q=1"));
    try t.expect(!matchPattern("*://example.com/a/*", "https://example.com/b/a"));
    try t.expect(matchPattern("*://example.com/*.png", "https://example.com/img/x.png"));
    // A URL with no path component matches "/".
    try t.expect(matchPattern("*://example.com/", "https://example.com"));
    // <all_urls>.
    try t.expect(matchPattern("<all_urls>", "https://x.test/"));
    try t.expect(matchPattern("<all_urls>", "file:///tmp/x.html"));
    // Malformed patterns match nothing.
    try t.expect(!matchPattern("example.com/*", "https://example.com/"));
    try t.expect(!matchPattern("*://example.com", "https://example.com/"));
}

test "userscript: include/exclude globs and applies()" {
    const src =
        \\// ==UserScript==
        \\// @name g
        \\// @include https://*.wiki.test/*
        \\// @exclude https://*.wiki.test/talk/*
        \\// ==/UserScript==
    ;
    const meta = (try parseMeta(t.allocator, src)).?;
    defer freeMeta(t.allocator, &meta);
    try t.expect(applies(&meta, "https://en.wiki.test/page"));
    try t.expect(!applies(&meta, "https://en.wiki.test/talk/page"));
    try t.expect(!applies(&meta, "https://other.test/"));

    try t.expect(globMatch("*", "anything"));
    try t.expect(globMatch("a*c", "abc"));
    try t.expect(globMatch("a*c", "ac"));
    try t.expect(!globMatch("a*c", "ab"));
    try t.expect(globMatch("*end", "the end"));
    try t.expect(!globMatch("start*", "not it"));
}
