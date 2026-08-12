//! `background.page` — the MV2 form where the background is an
//! author-provided HTML document rather than a list of scripts. Three of
//! the four tier-1 extensions (uBlock Origin, Dark Reader, Stylus) use
//! it, and only Violentmonkey uses `background.scripts`.
//!
//! Two jobs, both pure text and both unit-tested in either test root:
//!
//! - `bootstrapOffset` finds where to splice our own inline script into
//!   the served HTML. It must land BEFORE every author script, because
//!   that script is what defines `browser`/`chrome` and the author's
//!   first statement already uses them.
//! - `scan` lists the document's `<script>` elements in order. That is
//!   the FALLBACK path, used when no `chrome-extension://` origin could
//!   be registered: the scripts are then evaluated by us instead of by
//!   the engine. It cannot run ES modules (a static `import` is a
//!   SyntaxError outside a module), which is exactly why the origin is
//!   the real fix and this is only a fallback.
//!
//! The scanner is deliberately tolerant and deliberately NOT a parser:
//! it only has to be right about `<script>` elements in documents that
//! Chromium will also parse, and it never rewrites anything it did not
//! recognise.

const std = @import("std");

pub const Script = struct {
    /// `src` attribute value, a slice of the input. Empty for an inline
    /// script, in which case `body` holds the source.
    src: []const u8 = "",
    /// Inline source, a slice of the input. Empty when `src` is set.
    body: []const u8 = "",
    /// `type="module"`. Such a script can only be run by the engine, at
    /// a real origin — never through `new Function`.
    is_module: bool = false,
    /// `defer` or `async` were present. Recorded because it changes
    /// ordering, not because the fallback can honour it.
    deferred: bool = false,
};

/// Byte offset at which to insert content that must run before every
/// script in the document.
///
/// Right after `<head>` when there is one, else right after `<html…>`,
/// else 0. Never inside a comment or a doctype — a `<head>` that appears
/// only inside a comment is ignored, since Chromium would ignore it too.
pub fn bootstrapOffset(html: []const u8) usize {
    if (findTagEnd(html, "head")) |off| return off;
    if (findTagEnd(html, "html")) |off| return off;
    // No structural tags: after a doctype if present, else the very top.
    if (findTagEnd(html, "!doctype")) |off| return off;
    return 0;
}

/// Offset just past the `>` of the first `<name…>` open tag, skipping
/// comments.
fn findTagEnd(html: []const u8, name: []const u8) ?usize {
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] != '<') {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            const end = std.mem.indexOfPos(u8, html, i, "-->") orelse return null;
            i = end + 3;
            continue;
        }
        const rest = html[i + 1 ..];
        if (rest.len >= name.len and std.ascii.eqlIgnoreCase(rest[0..name.len], name)) {
            // The next byte must end the name, or this is `<header>`
            // matching `<head>`.
            const after = if (rest.len > name.len) rest[name.len] else '>';
            if (after == '>' or after == ' ' or after == '\t' or after == '\n' or after == '\r' or after == '/') {
                const close = std.mem.indexOfScalarPos(u8, html, i, '>') orelse return null;
                return close + 1;
            }
        }
        i += 1;
    }
    return null;
}

/// List the document's `<script>` elements in source order. Writes into
/// `out` and returns the used prefix; extra elements are dropped rather
/// than overflowing.
pub fn scan(html: []const u8, out: []Script) []Script {
    var n: usize = 0;
    var i: usize = 0;
    while (i < html.len and n < out.len) {
        if (html[i] != '<') {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            const end = std.mem.indexOfPos(u8, html, i, "-->") orelse break;
            i = end + 3;
            continue;
        }
        const rest = html[i + 1 ..];
        if (!(rest.len >= 6 and std.ascii.eqlIgnoreCase(rest[0..6], "script"))) {
            i += 1;
            continue;
        }
        const after = if (rest.len > 6) rest[6] else '>';
        if (!(after == '>' or after == ' ' or after == '\t' or after == '\n' or after == '\r' or after == '/')) {
            i += 1;
            continue;
        }
        const tag_end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse break;
        const attrs = html[i + 7 .. tag_end];
        var s = Script{};
        s.src = attrValue(attrs, "src");
        const ty = attrValue(attrs, "type");
        s.is_module = std.ascii.eqlIgnoreCase(std.mem.trim(u8, ty, " \t\r\n"), "module");
        s.deferred = hasAttr(attrs, "defer") or hasAttr(attrs, "async");
        // A `type` naming anything other than JS is data, not code.
        const is_js = ty.len == 0 or s.is_module or isJsType(ty);
        // `</script>` always closes it — a self-closing `<script/>` is
        // not a thing in HTML, so look for the close tag either way.
        const body_start = tag_end + 1;
        const close = indexOfClose(html, body_start);
        const body_end = close orelse html.len;
        if (s.src.len == 0) s.body = html[body_start..body_end];
        if (is_js and (s.src.len != 0 or std.mem.trim(u8, s.body, " \t\r\n").len != 0)) {
            out[n] = s;
            n += 1;
        }
        i = if (close) |cl| cl + "</script>".len else html.len;
    }
    return out[0..n];
}

fn indexOfClose(html: []const u8, from: usize) ?usize {
    var i = from;
    while (i + 8 < html.len) {
        if (html[i] == '<' and std.ascii.eqlIgnoreCase(html[i .. i + 9], "</script>")) return i;
        i += 1;
    }
    return null;
}

fn isJsType(ty: []const u8) bool {
    const trimmed = std.mem.trim(u8, ty, " \t\r\n");
    const ok = [_][]const u8{
        "text/javascript",     "application/javascript", "text/ecmascript",
        "application/ecmascript", "module",
    };
    for (ok) |o| {
        if (std.ascii.eqlIgnoreCase(trimmed, o)) return true;
    }
    return false;
}

fn hasAttr(attrs: []const u8, name: []const u8) bool {
    var i: usize = 0;
    while (i < attrs.len) {
        while (i < attrs.len and isSpace(attrs[i])) i += 1;
        const start = i;
        while (i < attrs.len and !isSpace(attrs[i]) and attrs[i] != '=') i += 1;
        if (i > start and std.ascii.eqlIgnoreCase(attrs[start..i], name)) return true;
        // Skip a value if present.
        while (i < attrs.len and isSpace(attrs[i])) i += 1;
        if (i < attrs.len and attrs[i] == '=') {
            i += 1;
            i = skipValue(attrs, i);
        }
    }
    return false;
}

/// Value of `name=` in an open tag's attribute run, a slice of `attrs`.
fn attrValue(attrs: []const u8, name: []const u8) []const u8 {
    var i: usize = 0;
    while (i < attrs.len) {
        while (i < attrs.len and isSpace(attrs[i])) i += 1;
        const start = i;
        while (i < attrs.len and !isSpace(attrs[i]) and attrs[i] != '=') i += 1;
        const key = attrs[start..i];
        while (i < attrs.len and isSpace(attrs[i])) i += 1;
        if (i >= attrs.len or attrs[i] != '=') {
            if (key.len == 0) i += 1;
            continue;
        }
        i += 1;
        while (i < attrs.len and isSpace(attrs[i])) i += 1;
        const vstart = i;
        var vend = i;
        if (i < attrs.len and (attrs[i] == '"' or attrs[i] == '\'')) {
            const q = attrs[i];
            i += 1;
            const s = i;
            while (i < attrs.len and attrs[i] != q) i += 1;
            vend = i;
            if (i < attrs.len) i += 1;
            if (std.ascii.eqlIgnoreCase(key, name)) return attrs[s..vend];
            continue;
        }
        while (i < attrs.len and !isSpace(attrs[i])) i += 1;
        vend = i;
        if (std.ascii.eqlIgnoreCase(key, name)) return attrs[vstart..vend];
    }
    return "";
}

fn skipValue(attrs: []const u8, from: usize) usize {
    var i = from;
    while (i < attrs.len and isSpace(attrs[i])) i += 1;
    if (i < attrs.len and (attrs[i] == '"' or attrs[i] == '\'')) {
        const q = attrs[i];
        i += 1;
        while (i < attrs.len and attrs[i] != q) i += 1;
        if (i < attrs.len) i += 1;
        return i;
    }
    while (i < attrs.len and !isSpace(attrs[i])) i += 1;
    return i;
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '/';
}

// ─── tests ──────────────────────────────────────────────────────────

const t = std.testing;

test "bootstrapOffset lands right after <head>" {
    const html = "<!DOCTYPE html><html><head><script src=\"a.js\"></script></head></html>";
    const off = bootstrapOffset(html);
    try t.expectEqualStrings("<script src=\"a.js\">", html[off .. off + 19]);
}

test "bootstrapOffset falls back to <html>, then a doctype, then the top" {
    const no_head = "<html><body><script src=\"a.js\"></script></body></html>";
    try t.expectEqualStrings("<body>", no_head[bootstrapOffset(no_head)..][0..6]);
    const only_doctype = "<!doctype html><script src=\"a.js\"></script>";
    try t.expectEqualStrings("<script", only_doctype[bootstrapOffset(only_doctype)..][0..7]);
    const bare = "<script src=\"a.js\"></script>";
    try t.expectEqual(@as(usize, 0), bootstrapOffset(bare));
}

test "bootstrapOffset ignores a <head> that only appears in a comment" {
    const html = "<!-- <head> --><html><head><script></script></head></html>";
    const off = bootstrapOffset(html);
    try t.expectEqualStrings("<script>", html[off..][0..8]);
}

test "bootstrapOffset does not mistake <header> for <head>" {
    const html = "<html><header>hi</header><head><b></b></head></html>";
    const off = bootstrapOffset(html);
    try t.expectEqualStrings("<b>", html[off..][0..3]);
}

test "scan: uBlock Origin's background.html shape" {
    // The real 1.73.0 document, reduced to its script elements.
    const html =
        \\<!DOCTYPE html>
        \\<html><head><meta charset="utf-8">
        \\<title>uBlock Origin</title>
        \\<script src="lib/lz4/lz4-block-codec-any.js"></script>
        \\<script src="js/vapi.js"></script>
        \\<script type="module" src="js/start.js"></script>
        \\</head><body></body></html>
    ;
    var buf: [8]Script = undefined;
    const got = scan(html, &buf);
    try t.expectEqual(@as(usize, 3), got.len);
    try t.expectEqualStrings("lib/lz4/lz4-block-codec-any.js", got[0].src);
    try t.expect(!got[0].is_module);
    try t.expectEqualStrings("js/vapi.js", got[1].src);
    try t.expectEqualStrings("js/start.js", got[2].src);
    try t.expect(got[2].is_module);
}

test "scan: the three real tier-1 background documents, verbatim" {
    var buf: [8]Script = undefined;

    // uBlock Origin 1.73.0 background.html, byte for byte. Note the
    // scripts live in <body> while the bootstrap goes in <head>, and
    // `type="module"` follows `src` rather than preceding it.
    const ubo =
        "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n" ++
        "<title>uBlock Origin Background Page</title>\n</head>\n<body>\n" ++
        "<script src=\"lib/lz4/lz4-block-codec-any.js\"></script>\n" ++
        "<script src=\"js/vapi.js\"></script>\n" ++
        "<script src=\"js/start.js\" type=\"module\"></script>\n</body>\n</html>";
    const u = scan(ubo, &buf);
    try t.expectEqual(@as(usize, 3), u.len);
    try t.expectEqualStrings("lib/lz4/lz4-block-codec-any.js", u[0].src);
    try t.expectEqualStrings("js/vapi.js", u[1].src);
    try t.expectEqualStrings("js/start.js", u[2].src);
    try t.expect(u[2].is_module);
    try t.expect(bootstrapOffset(ubo) < std.mem.indexOf(u8, ubo, "<body>").?);

    // Dark Reader 4.9.129 background/index.html — one deferred script.
    const dr =
        "<!doctype html>\n<html>\n    <head>\n        <meta charset=\"utf-8\" />\n" ++
        "        <title>Dark Reader background</title>\n" ++
        "        <script src=\"index.js\" defer></script>\n    </head>\n\n    <body></body>\n</html>\n";
    const d = scan(dr, &buf);
    try t.expectEqual(@as(usize, 1), d.len);
    try t.expectEqualStrings("index.js", d[0].src);
    try t.expect(d[0].deferred);
    try t.expect(!d[0].is_module);

    // Stylus 2.4.10 background.html — no <head>, no <html>, a <link>
    // first. The bootstrap must land at offset 0, before everything.
    const st =
        "<link href=\"/css/common.css\" rel=\"stylesheet\"><script src=\"/js/common.js\"></script>" ++
        "<script src=\"/js/vendors-node_modules_pnpm_db-to-cloud_0_8_1.js\"></script>" ++
        "<script src=\"/js/background.js\"></script>";
    const s = scan(st, &buf);
    try t.expectEqual(@as(usize, 3), s.len);
    try t.expectEqualStrings("/js/common.js", s[0].src);
    try t.expectEqualStrings("/js/background.js", s[2].src);
    try t.expectEqual(@as(usize, 0), bootstrapOffset(st));
}

test "scan: inline scripts, single quotes, unquoted, defer" {
    const html =
        \\<head>
        \\<script>var a = 1;</script>
        \\<script src='b.js' defer></script>
        \\<script src=c.js async></script>
        \\<script type="application/json">{"not":"code"}</script>
        \\</head>
    ;
    var buf: [8]Script = undefined;
    const got = scan(html, &buf);
    try t.expectEqual(@as(usize, 3), got.len);
    try t.expectEqualStrings("var a = 1;", got[0].body);
    try t.expectEqualStrings("", got[0].src);
    try t.expectEqualStrings("b.js", got[1].src);
    try t.expect(got[1].deferred);
    try t.expectEqualStrings("c.js", got[2].src);
    try t.expect(got[2].deferred);
}

test "scan: comments and empty scripts are skipped, order is source order" {
    const html =
        \\<head>
        \\<!-- <script src="never.js"></script> -->
        \\<script src="one.js"></script>
        \\<script>   </script>
        \\<script src="two.js"></script>
        \\</head>
    ;
    var buf: [8]Script = undefined;
    const got = scan(html, &buf);
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("one.js", got[0].src);
    try t.expectEqualStrings("two.js", got[1].src);
}

test "scan: an unterminated script takes the rest of the document" {
    const html = "<head><script>var a=1;";
    var buf: [4]Script = undefined;
    const got = scan(html, &buf);
    try t.expectEqual(@as(usize, 1), got.len);
    try t.expectEqualStrings("var a=1;", got[0].body);
}

test "scan: overflow drops rather than overruns" {
    const html =
        \\<script src="a.js"></script><script src="b.js"></script><script src="c.js"></script>
    ;
    var buf: [2]Script = undefined;
    const got = scan(html, &buf);
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("b.js", got[1].src);
}
