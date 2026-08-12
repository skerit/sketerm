//! MV2 match-pattern engine — the WebExtensions/Chrome content-script
//! match syntax, `<scheme>://<host>/<path>`.
//!
//! Pure std, no CEF, no GTK: compiled into the helper AND both test
//! roots, so a change to the matching rules is proven headless before it
//! reaches a browser. The reference is the Firefox/Chrome match-pattern
//! documentation; the corners that bite (a bare `*` scheme means
//! http+https+ws+wss only, a `*.` host prefix matches the domain AND any
//! subdomain, the special `<all_urls>` token) all have tests below.

const std = @import("std");

/// A parsed match pattern. Borrows nothing; the small fixed buffers hold
/// the scheme/host/path so a pattern outlives the source string.
pub const Pattern = struct {
    /// `*` here means "any of http/https/ws/wss" (NOT file/ftp), which
    /// is the documented meaning of a `*` scheme.
    scheme: Scheme,
    /// Empty host is only legal for schemes that have no host (file).
    host: [253]u8 = @splat(0),
    host_len: usize = 0,
    /// True when the host began with `*.`: match the bare domain and any
    /// subdomain of it. A lone `*` host sets `any_host` instead.
    subdomains: bool = false,
    any_host: bool = false,
    path: [1024]u8 = @splat(0),
    path_len: usize = 0,
    /// The `<all_urls>` sentinel matches every http/https/ws/wss/ftp/file
    /// url regardless of host or path.
    all_urls: bool = false,

    pub const Scheme = enum { any, http, https, ws, wss, ftp, file, data };

    pub fn hostSlice(self: *const Pattern) []const u8 {
        return self.host[0..self.host_len];
    }
    pub fn pathSlice(self: *const Pattern) []const u8 {
        return self.path[0..self.path_len];
    }

    /// Convenience: parse `url_text` and test it against this pattern.
    pub fn matchOk(self: *const Pattern, url_text: []const u8) bool {
        const url = Url.parse(url_text) orelse return false;
        return matches(self, &url);
    }
};

pub const ParseError = error{ BadPattern, TooLong };

/// Parse one match pattern. `<all_urls>` is accepted as a whole-string
/// token; everything else must be `scheme://host/path`.
pub fn parse(text: []const u8) ParseError!Pattern {
    if (std.mem.eql(u8, text, "<all_urls>")) {
        return .{ .scheme = .any, .all_urls = true };
    }
    const sep = std.mem.indexOf(u8, text, "://") orelse return error.BadPattern;
    const scheme_str = text[0..sep];
    const scheme: Pattern.Scheme = if (std.mem.eql(u8, scheme_str, "*"))
        .any
    else if (std.mem.eql(u8, scheme_str, "http"))
        .http
    else if (std.mem.eql(u8, scheme_str, "https"))
        .https
    else if (std.mem.eql(u8, scheme_str, "ws"))
        .ws
    else if (std.mem.eql(u8, scheme_str, "wss"))
        .wss
    else if (std.mem.eql(u8, scheme_str, "ftp"))
        .ftp
    else if (std.mem.eql(u8, scheme_str, "file"))
        .file
    else if (std.mem.eql(u8, scheme_str, "data"))
        .data
    else
        return error.BadPattern;

    const rest = text[sep + 3 ..];
    // The path begins at the FIRST slash after the host; a pattern with
    // no slash at all is malformed (except file:// with an empty host,
    // handled below).
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    var p: Pattern = .{ .scheme = scheme };

    const host_part = if (slash) |s| rest[0..s] else rest;
    const path_part = if (slash) |s| rest[s..] else "";

    if (scheme == .file) {
        // file:// has no host; the whole remainder is the path.
        if (host_part.len != 0) return error.BadPattern;
        if (path_part.len == 0) return error.BadPattern;
        return storePath(p, path_part);
    }
    if (scheme == .data) {
        // data: urls carry no host either; a `data://*` pattern matches
        // any data url. Store the path glob (usually just `*`).
        if (path_part.len == 0) {
            p.any_host = true;
            return storePath(p, "*");
        }
        p.any_host = true;
        return storePath(p, path_part);
    }
    if (slash == null) return error.BadPattern;

    if (std.mem.eql(u8, host_part, "*")) {
        p.any_host = true;
    } else if (std.mem.startsWith(u8, host_part, "*.")) {
        p.subdomains = true;
        const domain = host_part[2..];
        if (domain.len == 0 or std.mem.indexOfScalar(u8, domain, '*') != null) return error.BadPattern;
        if (domain.len > p.host.len) return error.TooLong;
        @memcpy(p.host[0..domain.len], domain);
        p.host_len = domain.len;
    } else {
        // A literal host must contain no wildcard.
        if (std.mem.indexOfScalar(u8, host_part, '*') != null) return error.BadPattern;
        if (host_part.len == 0) return error.BadPattern;
        if (host_part.len > p.host.len) return error.TooLong;
        @memcpy(p.host[0..host_part.len], host_part);
        p.host_len = host_part.len;
    }
    return storePath(p, path_part);
}

fn storePath(p_in: Pattern, path: []const u8) ParseError!Pattern {
    var p = p_in;
    if (path.len > p.path.len) return error.TooLong;
    @memcpy(p.path[0..path.len], path);
    p.path_len = path.len;
    return p;
}

/// A parsed url, split into the three parts a pattern tests against.
pub const Url = struct {
    scheme: Pattern.Scheme,
    host: []const u8,
    /// Path INCLUDING the leading slash, WITHOUT the query/fragment (a
    /// match pattern's path glob never sees the `?`/`#` — same as
    /// Chrome).
    path: []const u8,

    pub fn parse(text: []const u8) ?Url {
        const sep = std.mem.indexOf(u8, text, "://") orelse {
            // Schemeless: only data: has this shape (`data:...`).
            if (std.mem.startsWith(u8, text, "data:")) {
                return .{ .scheme = .data, .host = "", .path = text[5..] };
            }
            return null;
        };
        const scheme_str = text[0..sep];
        const scheme: Pattern.Scheme = if (std.mem.eql(u8, scheme_str, "http"))
            .http
        else if (std.mem.eql(u8, scheme_str, "https"))
            .https
        else if (std.mem.eql(u8, scheme_str, "ws"))
            .ws
        else if (std.mem.eql(u8, scheme_str, "wss"))
            .wss
        else if (std.mem.eql(u8, scheme_str, "ftp"))
            .ftp
        else if (std.mem.eql(u8, scheme_str, "file"))
            .file
        else
            return null;

        const after = text[sep + 3 ..];
        if (scheme == .file) {
            return .{ .scheme = .file, .host = "", .path = trimQuery(after) };
        }
        const slash = std.mem.indexOfScalar(u8, after, '/');
        const host_raw = if (slash) |s| after[0..s] else after;
        const path = if (slash) |s| trimQuery(after[s..]) else "/";
        // Strip userinfo and port from the authority — the pattern host
        // never contains either.
        var host = host_raw;
        if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
        if (std.mem.indexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
        return .{ .scheme = scheme, .host = host, .path = path };
    }
};

fn trimQuery(path: []const u8) []const u8 {
    const q = std.mem.indexOfAny(u8, path, "?#") orelse return path;
    return path[0..q];
}

/// Whether `url` matches `pat`. Host comparison is case-insensitive
/// (DNS is), path glob is case-SENSITIVE (paths are).
pub fn matches(pat: *const Pattern, url: *const Url) bool {
    if (pat.all_urls) {
        return switch (url.scheme) {
            .http, .https, .ws, .wss, .ftp, .file => true,
            else => false,
        };
    }
    if (!schemeMatches(pat.scheme, url.scheme)) return false;
    if (!pat.any_host) {
        if (pat.subdomains) {
            if (!hostInDomain(url.host, pat.hostSlice())) return false;
        } else if (pat.scheme != .file and pat.scheme != .data) {
            if (!eqIgnoreCase(url.host, pat.hostSlice())) return false;
        }
    }
    return globMatch(pat.pathSlice(), url.path);
}

fn schemeMatches(pat: Pattern.Scheme, url: Pattern.Scheme) bool {
    if (pat == url) return true;
    if (pat == .any) {
        return switch (url) {
            .http, .https, .ws, .wss => true,
            else => false,
        };
    }
    return false;
}

/// True when `host` is `domain` or a subdomain of it. `a.example.com`
/// is in `example.com`; `notexample.com` is NOT (the boundary must be a
/// dot).
fn hostInDomain(host: []const u8, domain: []const u8) bool {
    if (eqIgnoreCase(host, domain)) return true;
    if (host.len <= domain.len + 1) return false;
    const start = host.len - domain.len;
    if (host[start - 1] != '.') return false;
    return eqIgnoreCase(host[start..], domain);
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Glob match with `*` as the only metacharacter (matches any run,
/// including empty). This is the match-pattern path glob, not a full
/// regex. Iterative backtracking so it never recurses on adversarial
/// input.
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var ti: usize = 0;
    var star: ?usize = null;
    var star_t: usize = 0;
    while (ti < text.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            star_t = ti;
            p += 1;
        } else if (p < pattern.len and pattern[p] == text[ti]) {
            p += 1;
            ti += 1;
        } else if (star) |s| {
            p = s + 1;
            star_t += 1;
            ti = star_t;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// A set of include/exclude patterns, the shape a content_scripts entry
/// carries (`matches` / `exclude_matches`). Owns its patterns.
pub const PatternSet = struct {
    include: std.ArrayList(Pattern) = .empty,
    exclude: std.ArrayList(Pattern) = .empty,

    pub fn deinit(self: *PatternSet, gpa: std.mem.Allocator) void {
        self.include.deinit(gpa);
        self.exclude.deinit(gpa);
    }

    pub fn addInclude(self: *PatternSet, gpa: std.mem.Allocator, text: []const u8) !void {
        try self.include.append(gpa, try parse(text));
    }
    pub fn addExclude(self: *PatternSet, gpa: std.mem.Allocator, text: []const u8) !void {
        try self.exclude.append(gpa, try parse(text));
    }

    /// True when at least one include matches and no exclude does.
    pub fn matchesUrl(self: *const PatternSet, url_text: []const u8) bool {
        const url = Url.parse(url_text) orelse return false;
        var included = false;
        for (self.include.items) |*pat| {
            if (matches(pat, &url)) {
                included = true;
                break;
            }
        }
        if (!included) return false;
        for (self.exclude.items) |*pat| {
            if (matches(pat, &url)) return false;
        }
        return true;
    }
};

// ─── tests ──────────────────────────────────────────────────────────

const t = std.testing;

test "glob matcher: stars, anchors, empties" {
    try t.expect(globMatch("*", ""));
    try t.expect(globMatch("*", "/anything/here"));
    try t.expect(globMatch("/foo*", "/foobar"));
    try t.expect(globMatch("/foo*", "/foo"));
    try t.expect(!globMatch("/foo*", "/fo"));
    try t.expect(globMatch("/a*b*c", "/axxbyyc"));
    try t.expect(!globMatch("/a*b*c", "/axxbyy"));
    try t.expect(globMatch("/exact", "/exact"));
    try t.expect(!globMatch("/exact", "/exactly"));
}

test "parse: scheme forms" {
    try t.expectEqual(Pattern.Scheme.any, (try parse("*://*/*")).scheme);
    try t.expectEqual(Pattern.Scheme.https, (try parse("https://example.com/*")).scheme);
    try t.expectError(error.BadPattern, parse("gopher://x/*"));
    try t.expectError(error.BadPattern, parse("noscheme"));
    // A wildcard host needs the trailing slash for the path.
    try t.expectError(error.BadPattern, parse("http://example.com"));
}

test "host matching: literal, subdomain, any" {
    {
        const p = try parse("https://example.com/*");
        try t.expect(p.matchOk("https://example.com/anything"));
        try t.expect(!p.matchOk("https://sub.example.com/x"));
        try t.expect(!p.matchOk("http://example.com/x")); // scheme differs
    }
    {
        const p = try parse("*://*.example.com/*");
        try t.expect(p.matchOk("https://example.com/x"));
        try t.expect(p.matchOk("http://a.example.com/x"));
        try t.expect(p.matchOk("https://a.b.example.com/x"));
        try t.expect(!p.matchOk("https://notexample.com/x"));
        try t.expect(!p.matchOk("https://example.com.evil.com/x"));
    }
    {
        const p = try parse("*://*/*");
        try t.expect(p.matchOk("http://any.host/x"));
        try t.expect(p.matchOk("wss://sockets.example/y"));
        try t.expect(!p.matchOk("file:///etc/passwd")); // * scheme excludes file
    }
}

test "path glob and query stripping" {
    const p = try parse("https://example.com/foo/*");
    try t.expect(p.matchOk("https://example.com/foo/bar"));
    try t.expect(p.matchOk("https://example.com/foo/bar?x=1#frag"));
    try t.expect(!p.matchOk("https://example.com/other"));
    // Port and userinfo in the authority are ignored.
    try t.expect(p.matchOk("https://user@example.com:8443/foo/bar"));
}

test "all_urls and file" {
    const a = try parse("<all_urls>");
    try t.expect(a.all_urls);
    try t.expect(a.matchOk("https://any.example/x"));
    try t.expect(a.matchOk("file:///home/x/file.txt"));
    try t.expect(!a.matchOk("data:text/html,hi"));

    const f = try parse("file:///home/*");
    try t.expect(f.matchOk("file:///home/user/x"));
    try t.expect(!f.matchOk("file:///etc/passwd"));
}

test "pattern set include/exclude" {
    const gpa = t.allocator;
    var set = PatternSet{};
    defer set.deinit(gpa);
    try set.addInclude(gpa, "*://*.example.com/*");
    try set.addExclude(gpa, "*://admin.example.com/*");
    try t.expect(set.matchesUrl("https://www.example.com/page"));
    try t.expect(!set.matchesUrl("https://admin.example.com/panel"));
    try t.expect(!set.matchesUrl("https://other.org/x"));
}
