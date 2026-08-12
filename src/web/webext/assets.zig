//! Serving one extension's unpacked directory over
//! `sketerm-extension://<host>/…` (Chromium owns the
//! `chrome-extension` name and refuses to register it — see
//! src/web/CLAUDE.md): url -> on-disk path, the escape rejection that
//! makes that safe, MIME typing, and the `web_accessible_resources`
//! gate.
//!
//! Pure std, no CEF, no GTK, no allocator: compiled into the helper AND
//! both test roots. It is deliberately allocation-free because the
//! scheme handler's factory runs on CEF's IO THREAD, where the rest of
//! this subsystem also refuses to allocate.
//!
//! The escape rejection is the security property, and ANY web page can
//! name a path here, so treat it as hostile input. `resolve` splits on
//! the raw '/', decodes each segment, and refuses a segment that is
//! `..` OR that still contains a separator after decoding — rather
//! than normalising anything away, since a normalising resolver has to
//! be right about symlinks too and refusing is right about both.
//!
//! Both halves are load-bearing. Rejecting only whole-segment `..` let
//! `%2e%2e%2f%2e%2e%2fetc%2fpasswd` — one raw segment — decode straight
//! into the joined path, and the reply carries
//! `Access-Control-Allow-Origin: *`, so that was an arbitrary local
//! file read triggerable by any page on any site once one extension was
//! installed. Do not drop the separator check.

const std = @import("std");

/// Longest url path we will resolve; anything longer is refused rather
/// than truncated (a truncated path could name a DIFFERENT file).
pub const MAX_PATH = 1024;

/// Strip a url down to its path component: scheme and host off the
/// front, `?query` and `#fragment` off the back. Returns a slice of
/// `url`, always starting at the first byte after the host.
pub fn urlPath(url: []const u8) []const u8 {
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |i| {
        rest = rest[i + 3 ..];
        // Host runs to the next '/', '?' or '#'.
        const slash = std.mem.indexOfAny(u8, rest, "/?#") orelse return "";
        rest = rest[slash..];
    }
    if (std.mem.indexOfAny(u8, rest, "?#")) |i| rest = rest[0..i];
    return rest;
}

/// The host component of `url`, empty when there is none.
pub fn urlHost(url: []const u8) []const u8 {
    const i = std.mem.indexOf(u8, url, "://") orelse return "";
    const rest = url[i + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return rest[0..end];
}

pub const ResolveError = error{ TooLong, Escapes, Empty };

/// Join `dir` and a url path into an absolute on-disk path in `out`.
///
/// Percent-decodes, collapses `//`, drops `.` segments and REFUSES any
/// `..` segment or embedded NUL. Returns the slice used.
pub fn resolve(dir: []const u8, url_path: []const u8, out: []u8) ResolveError![]const u8 {
    if (url_path.len > MAX_PATH) return error.TooLong;
    if (dir.len + url_path.len + 2 > out.len) return error.TooLong;
    @memcpy(out[0..dir.len], dir);
    var n = dir.len;
    // Trailing slash on the dir would double up with the leading one.
    while (n > 1 and out[n - 1] == '/') n -= 1;

    var it = std.mem.splitScalar(u8, url_path, '/');
    var any = false;
    while (it.next()) |raw| {
        var seg_buf: [MAX_PATH]u8 = undefined;
        const seg = percentDecode(raw, &seg_buf) catch return error.TooLong;
        if (seg.len == 0) continue;
        // A SEPARATOR THAT SURVIVED DECODING IS AN ESCAPE ATTEMPT.
        //
        // The split above is on the RAW path, so a segment spelled
        // `%2e%2e%2f%2e%2e%2fetc%2fpasswd` arrives here as ONE segment
        // and decodes to `../../etc/passwd` — which equals neither "."
        // nor "..", so the two checks below would wave it through and
        // the whole string would be memcpy'd into the on-disk path.
        // Chromium keeps %2F escaped in a standard scheme's path, so
        // this reaches us verbatim from any page that can name the url.
        // Rejecting a decoded '/' outright is what makes the per-segment
        // `..` test mean what the header claims it means; decoding a
        // separator into a separator is also what no browser does.
        if (std.mem.indexOfScalar(u8, seg, '/') != null) return error.Escapes;
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) return error.Escapes;
        if (std.mem.indexOfScalar(u8, seg, 0) != null) return error.Escapes;
        if (n + 1 + seg.len > out.len) return error.TooLong;
        out[n] = '/';
        n += 1;
        @memcpy(out[n..][0..seg.len], seg);
        n += seg.len;
        any = true;
    }
    if (!any) return error.Empty;
    // Backstop, deliberately an explicit branch rather than an assert:
    // this tree builds ReleaseFast only, where `std.debug.assert`
    // compiles away. The per-segment checks above already make this
    // unreachable; it stays so that a future edit to them fails CLOSED
    // instead of quietly reopening a file read.
    const joined = out[0..n];
    if (!std.mem.startsWith(u8, joined, dir)) return error.Escapes;
    if (std.mem.indexOf(u8, joined[dir.len..], "/../") != null) return error.Escapes;
    if (std.mem.endsWith(u8, joined, "/..")) return error.Escapes;
    return joined;
}

fn percentDecode(s: []const u8, out: []u8) error{TooLong}![]const u8 {
    if (s.len > out.len) return error.TooLong;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                out[n] = s[i];
                n += 1;
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                out[n] = s[i];
                n += 1;
                i += 1;
                continue;
            };
            out[n] = @as(u8, hi) << 4 | lo;
            n += 1;
            i += 3;
            continue;
        }
        out[n] = s[i];
        n += 1;
        i += 1;
    }
    return out[0..n];
}

/// Resolve a document-relative `src` against the package-relative path
/// of the document that named it, as the HTML parser would. A leading
/// `/` means the package root. Returns a slice of `out`, or of `src`
/// when it is already root-relative.
pub fn resolveRelative(doc_path: []const u8, src: []const u8, out: []u8) ?[]const u8 {
    if (src.len == 0) return null;
    if (src[0] == '/') return src;
    const clean_doc = std.mem.trimStart(u8, doc_path, "/");
    const slash = std.mem.lastIndexOfScalar(u8, clean_doc, '/');
    const dir = if (slash) |i| clean_doc[0 .. i + 1] else "";
    if (dir.len + src.len > out.len) return null;
    @memcpy(out[0..dir.len], dir);
    @memcpy(out[dir.len..][0..src.len], src);
    return out[0 .. dir.len + src.len];
}

/// MIME type for an extension asset. Getting `text/javascript` right is
/// load-bearing rather than cosmetic: Chromium REFUSES to evaluate a
/// `<script type="module">` served with any other type, so a wrong
/// answer here silently kills every ES-module background page.
pub fn mimeFor(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
    const ext = path[dot + 1 ..];
    const map = .{
        .{ "html", "text/html" },
        .{ "htm", "text/html" },
        .{ "js", "text/javascript" },
        .{ "mjs", "text/javascript" },
        .{ "json", "application/json" },
        .{ "css", "text/css" },
        .{ "svg", "image/svg+xml" },
        .{ "png", "image/png" },
        .{ "jpg", "image/jpeg" },
        .{ "jpeg", "image/jpeg" },
        .{ "gif", "image/gif" },
        .{ "webp", "image/webp" },
        .{ "ico", "image/x-icon" },
        .{ "woff", "font/woff" },
        .{ "woff2", "font/woff2" },
        .{ "ttf", "font/ttf" },
        .{ "otf", "font/otf" },
        .{ "wasm", "application/wasm" },
        .{ "txt", "text/plain" },
        .{ "xml", "text/xml" },
        .{ "webmanifest", "application/manifest+json" },
    };
    inline for (map) |pair| {
        if (std.ascii.eqlIgnoreCase(ext, pair[0])) return pair[1];
    }
    return "application/octet-stream";
}

/// Whether a path is listed in `web_accessible_resources`. Only consulted
/// for a load whose INITIATOR is not the extension itself; the extension's
/// own pages may read anything in their own package.
pub fn webAccessible(patterns: []const []const u8, path: []const u8) bool {
    const clean = std.mem.trimStart(u8, path, "/");
    for (patterns) |pat| {
        if (globMatch(std.mem.trimStart(u8, pat, "/"), clean)) return true;
    }
    return false;
}

/// `*` matches any run of characters INCLUDING `/` — MV2's
/// `web_accessible_resources` globs are path globs, not shell globs.
fn globMatch(pat: []const u8, s: []const u8) bool {
    if (pat.len == 0) return s.len == 0;
    const star = std.mem.indexOfScalar(u8, pat, '*') orelse return std.mem.eql(u8, pat, s);
    const head = pat[0..star];
    const tail = pat[star + 1 ..];
    if (!std.mem.startsWith(u8, s, head)) return false;
    const rest = s[head.len..];
    if (tail.len == 0) return true;
    var i: usize = 0;
    while (i <= rest.len) : (i += 1) {
        if (globMatch(tail, rest[i..])) return true;
    }
    return false;
}

// ─── tests ──────────────────────────────────────────────────────────

const t = std.testing;

test "urlPath / urlHost split a chrome-extension url" {
    try t.expectEqualStrings("/js/start.js", urlPath("chrome-extension://abc123/js/start.js"));
    try t.expectEqualStrings("abc123", urlHost("chrome-extension://abc123/js/start.js"));
    try t.expectEqualStrings("/a", urlPath("chrome-extension://h/a?x=1#y"));
    try t.expectEqualStrings("", urlPath("chrome-extension://h"));
    try t.expectEqualStrings("h", urlHost("chrome-extension://h"));
    try t.expectEqualStrings("/plain/path", urlPath("/plain/path"));
}

test "resolve joins, decodes and collapses" {
    var buf: [512]u8 = undefined;
    try t.expectEqualStrings("/ext/js/start.js", try resolve("/ext", "/js/start.js", &buf));
    try t.expectEqualStrings("/ext/js/start.js", try resolve("/ext/", "//js//start.js", &buf));
    try t.expectEqualStrings("/ext/a b.js", try resolve("/ext", "/a%20b.js", &buf));
    try t.expectEqualStrings("/ext/js/start.js", try resolve("/ext", "/./js/./start.js", &buf));
}

test "resolve REFUSES every escape, however spelled" {
    var buf: [512]u8 = undefined;
    try t.expectError(error.Escapes, resolve("/ext", "/../etc/passwd", &buf));
    try t.expectError(error.Escapes, resolve("/ext", "/js/../../etc/passwd", &buf));
    // Percent-encoded `..` is decoded FIRST, so it is caught too — this
    // is the bypass a normalise-then-check resolver would miss.
    try t.expectError(error.Escapes, resolve("/ext", "/%2e%2e/etc/passwd", &buf));
    try t.expectError(error.Escapes, resolve("/ext", "/a/%2E%2E/%2E%2E/etc", &buf));
    try t.expectError(error.Escapes, resolve("/ext", "/a%00b/../x", &buf));
    try t.expectError(error.Empty, resolve("/ext", "/", &buf));
    try t.expectError(error.Empty, resolve("/ext", "", &buf));

    // ENCODED SEPARATORS. The split runs on the RAW path, so each of
    // these is ONE segment that only becomes an escape after decoding.
    // Every spelling below reached open() before 2026-08-12, with the
    // reply carrying `Access-Control-Allow-Origin: *`; the test above
    // passed the whole time because it spells every escape with a
    // literal '/'. Chromium does not unescape %2F in a standard
    // scheme's path, so these arrive here exactly as written.
    try t.expectError(error.Escapes, resolve("/ext", "/%2e%2e%2f%2e%2e%2fetc%2fpasswd", &buf));
    try t.expectError(error.Escapes, resolve("/ext", "/%2E%2E%2F%2E%2E%2Fetc", &buf));
    try t.expectError(error.Escapes, resolve("/ext", "/war/..%2f..%2f..%2fetc%2fpasswd", &buf));
    // A leading `.` makes every intermediate component exist, so this
    // spelling resolves even when the attacker knows no subdirectory.
    try t.expectError(error.Escapes, resolve("/ext", "/%2e%2f%2e%2e%2f%2e%2e%2fhome", &buf));
    // A bare encoded separator with no dots is still not ours to join.
    try t.expectError(error.Escapes, resolve("/ext", "/a%2fb", &buf));
}

test "resolve never returns a path outside the package directory" {
    // Property check over the shapes an attacker controls, rather than
    // a list of spellings someone remembered: whatever comes back must
    // live under `dir`.
    var buf: [512]u8 = undefined;
    const dir = "/ext";
    const paths = [_][]const u8{
        "/js/start.js",      "/a%20b.js",                    "/./x",
        "/%2e%2e%2fetc",     "/..%2f..%2fetc",               "/%2e%2e/etc",
        "/a/%2E%2E/%2E%2E/x", "/war/%2e%2f%2e%2e%2f%2e%2e%2fetc", "/a%2fb",
        "//x//y",            "/%00",                         "/....//x",
    };
    for (paths) |p| {
        const got = resolve(dir, p, &buf) catch continue;
        try t.expect(std.mem.startsWith(u8, got, dir ++ "/"));
        try t.expect(std.mem.indexOf(u8, got, "/../") == null);
    }
}

test "resolve refuses an embedded NUL" {
    var buf: [512]u8 = undefined;
    try t.expectError(error.Escapes, resolve("/ext", "/a%00.js", &buf));
}

test "mimeFor: modules need text/javascript or Chromium refuses them" {
    try t.expectEqualStrings("text/javascript", mimeFor("/js/start.js"));
    try t.expectEqualStrings("text/javascript", mimeFor("/js/start.mjs"));
    try t.expectEqualStrings("text/html", mimeFor("/background.html"));
    try t.expectEqualStrings("application/json", mimeFor("/manifest.json"));
    try t.expectEqualStrings("text/css", mimeFor("/a.CSS"));
    try t.expectEqualStrings("application/octet-stream", mimeFor("/noext"));
    try t.expectEqualStrings("application/octet-stream", mimeFor("/a.unknownthing"));
}

test "resolveRelative follows the document's own directory" {
    var buf: [256]u8 = undefined;
    // Dark Reader: background/index.html names `index.js` next to it.
    try t.expectEqualStrings("background/index.js", resolveRelative("background/index.html", "index.js", &buf).?);
    // uBO: background.html sits at the root.
    try t.expectEqualStrings("js/vapi.js", resolveRelative("background.html", "js/vapi.js", &buf).?);
    // Stylus spells its scripts root-relative already.
    try t.expectEqualStrings("/js/common.js", resolveRelative("background.html", "/js/common.js", &buf).?);
    try t.expectEqualStrings("a/b/c.js", resolveRelative("/a/b/page.html", "c.js", &buf).?);
    try t.expect(resolveRelative("x.html", "", &buf) == null);
}

test "webAccessible globs cross directory separators" {
    const pats = [_][]const u8{"/web_accessible_resources/*"};
    try t.expect(webAccessible(&pats, "/web_accessible_resources/noop.js"));
    try t.expect(webAccessible(&pats, "/web_accessible_resources/deep/noop.js"));
    try t.expect(!webAccessible(&pats, "/js/start.js"));
    const none = [_][]const u8{};
    try t.expect(!webAccessible(&none, "/anything"));
}
