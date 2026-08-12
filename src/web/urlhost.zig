//! The one host extractor. Three call sites used to carry their own —
//! the request filter, the browser face's message text and the secrets
//! matcher — and they were deliberately, subtly different, which is the
//! worst shape for a function whose output feeds a security decision.
//! The differences are real and are expressed here as OPTIONS.
//!
//! Nothing here is normalization: the result is the raw host substring
//! of the input, never lower-cased, never punycode-decoded. Callers that
//! compare hosts must still do that themselves (`secrets.hostsMatch`).
//!
//! It lives HERE and not in `src/util/` because `sketerm-webengine`'s
//! root module is `src/web/main.zig`: a file compiled into the helper
//! cannot import anything above that directory. Same reason and same
//! shape as `protocol.zig` and `filter.zig`, which the GUI reaches as
//! `../web/*.zig`. std only — no CEF, no GTK.

const std = @import("std");

/// The three axes the old copies disagreed on.
pub const Options = struct {
    /// No `://` (and no leading `//`) means "this url has no authority"
    /// and the answer is the empty string. `data:`/`about:` urls must
    /// not be credited with a host when the result gates a match.
    require_scheme: bool = false,
    /// Keep a `:port` suffix. Off strips it, IPv6-literal-aware.
    keep_port: bool = false,
    /// An empty result yields the whole input instead. Only for prose:
    /// a message naming `about:blank` is better than one naming "".
    fallback_whole: bool = false,
};

/// Request filtering: an authority or nothing, port stripped. A url
/// with no authority must not match a host rule.
pub const filtering: Options = .{ .require_scheme = true };

/// Site identity: bare hosts allowed, port stripped. What the secrets
/// matcher compares — see `secrets.hostsMatch` for why the comparison
/// stays exact rather than suffix-based.
pub const site: Options = .{};

/// Prose: what to call the site a sentence is about. Keeps the port
/// (`example.com:8443` and `example.com` are different servers to a
/// reader) and never answers with nothing.
pub const prose: Options = .{ .keep_port = true, .fallback_whole = true };

/// Host part of `url` under `opts`.
pub fn hostOf(url: []const u8, opts: Options) []const u8 {
    var s = url;
    if (std.mem.indexOf(u8, s, "://")) |i| {
        s = s[i + 3 ..];
    } else if (std.mem.startsWith(u8, s, "//")) {
        s = s[2..];
    } else if (opts.require_scheme) {
        return "";
    }
    // The authority ends at the path, query or fragment.
    if (std.mem.indexOfAny(u8, s, "/?#")) |i| s = s[0..i];
    // Userinfo is everything up to the LAST '@' inside the authority (a
    // password may legally contain one).
    if (std.mem.lastIndexOfScalar(u8, s, '@')) |i| s = s[i + 1 ..];
    if (!opts.keep_port) {
        // A bracketed IPv6 literal keeps its colons; anything else
        // loses a trailing :port.
        if (s.len != 0 and s[0] == '[') {
            if (std.mem.indexOfScalar(u8, s, ']')) |i| s = s[0 .. i + 1];
        } else if (std.mem.lastIndexOfScalar(u8, s, ':')) |i| {
            s = s[0..i];
        }
    }
    if (s.len == 0 and opts.fallback_whole) return url;
    return s;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

test "filtering: authority or nothing, port stripped" {
    const t = std.testing;
    try t.expectEqualStrings("example.com", hostOf("http://example.com/x", filtering));
    try t.expectEqualStrings("example.com", hostOf("http://user:pw@example.com:8080/x", filtering));
    try t.expectEqualStrings("example.com", hostOf("https://example.com", filtering));
    try t.expectEqualStrings("example.com", hostOf("https://example.com?q=1", filtering));
    try t.expectEqualStrings("example.com", hostOf("//example.com/x", filtering));
    // No authority: a host rule must not match these.
    try t.expectEqualStrings("", hostOf("data:text/html,hi", filtering));
    try t.expectEqualStrings("", hostOf("about:blank", filtering));
    try t.expectEqualStrings("", hostOf("", filtering));
    // A password containing '@' does not hand the url a fake host.
    try t.expectEqualStrings("example.com", hostOf("http://u:p@ss@example.com/x", filtering));
}

test "site: bare hosts, no port, IPv6 literals intact" {
    const t = std.testing;
    try t.expectEqualStrings("example.com", hostOf("https://example.com/login?a=b#c", site));
    try t.expectEqualStrings("example.com", hostOf("example.com", site));
    try t.expectEqualStrings("example.com", hostOf("https://example.com:8443/", site));
    try t.expectEqualStrings("example.com", hostOf("https://u:p@ss@example.com/x", site));
    try t.expectEqualStrings("[::1]", hostOf("http://[::1]:8080/x", site));
    try t.expectEqualStrings("[::1]", hostOf("[::1]", site));
    try t.expectEqualStrings("", hostOf("", site));
}

test "prose: keeps the port and never answers with nothing" {
    const t = std.testing;
    try t.expectEqualStrings("example.com", hostOf("https://example.com/a/b?c=d", prose));
    try t.expectEqualStrings("example.com", hostOf("https://user@example.com/", prose));
    try t.expectEqualStrings("example.com:8443", hostOf("https://example.com:8443/x", prose));
    try t.expectEqualStrings("about:blank", hostOf("about:blank", prose));
    // Nothing but a path: naming the whole string beats naming nothing.
    try t.expectEqualStrings("https:///x", hostOf("https:///x", prose));
}

test "the secrets semantics never let a lookalike host match" {
    const t = std.testing;
    // The security property the site variant exists for: the extractor
    // must not hand back a suffix or a prefix of the real host, so an
    // exact comparison downstream cannot be fooled.
    try t.expectEqualStrings("evil-example.com", hostOf("https://evil-example.com/login", site));
    try t.expect(!std.mem.eql(u8, hostOf("https://evil-example.com/login", site), "example.com"));
    try t.expectEqualStrings("example.com.evil.net", hostOf("https://example.com.evil.net/", site));
    try t.expect(!std.mem.eql(u8, hostOf("https://example.com.evil.net/", site), "example.com"));
    // Userinfo is not a host: `example.com@evil.net` is evil.net.
    try t.expectEqualStrings("evil.net", hostOf("https://example.com@evil.net/", site));
    // Neither is a path or a fragment.
    try t.expectEqualStrings("evil.net", hostOf("https://evil.net/example.com", site));
    try t.expectEqualStrings("evil.net", hostOf("https://evil.net/#example.com", site));
    try t.expectEqualStrings("evil.net", hostOf("https://evil.net?next=example.com", site));
}
