//! The one glob matcher. Pure std (no libc, no GTK), so the daemon,
//! the file browser and the CEF helper's extension code all share it.
//!
//! `*` matches any run of bytes INCLUDING `/`: none of the consumers
//! is a shell, they all glob whole names, paths or mimetypes. `?` is a
//! single-byte wildcard only when the caller asks for it; otherwise it
//! is an ordinary literal byte. An empty pattern matches only an empty
//! text. Case folding is ASCII-only.
//!
//! The algorithm is iterative single-star backtracking, so an
//! adversarial pattern (`/a*a*a*a*b`) stays O(pattern * text) instead
//! of exponential, and it never recurses.

const std = @import("std");

pub const Options = struct {
    /// ASCII case-insensitive literal comparison.
    fold_case: bool = false,
    /// `?` matches exactly one byte instead of a literal `?`.
    question_wildcard: bool = false,
};

/// Shell-ish name glob: ASCII case-folded, `*` and `?`.
pub const name_opts: Options = .{ .fold_case = true, .question_wildcard = true };

/// URL/path glob: case-sensitive, `*` only, `?` literal.
pub const path_opts: Options = .{};

pub fn match(pattern: []const u8, text: []const u8, opts: Options) bool {
    var p: usize = 0;
    var ti: usize = 0;
    var star_p: ?usize = null;
    var star_t: usize = 0;
    while (ti < text.len) {
        if (p < pattern.len and pattern[p] == '*') {
            // Remember the star, then try to match zero bytes with it.
            star_p = p;
            star_t = ti;
            p += 1;
        } else if (p < pattern.len and literalEq(pattern[p], text[ti], opts)) {
            p += 1;
            ti += 1;
        } else if (star_p) |sp| {
            // Backtrack: let the last '*' swallow one more byte.
            star_t += 1;
            p = sp + 1;
            ti = star_t;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// Case-insensitive `*`/`?` glob over a filename, mimetype or filter.
pub fn matchName(pattern: []const u8, name: []const u8) bool {
    return match(pattern, name, name_opts);
}

/// Case-sensitive `*`-only glob over a URL or package path.
pub fn matchPath(pattern: []const u8, text: []const u8) bool {
    return match(pattern, text, path_opts);
}

fn literalEq(pat: u8, txt: u8, opts: Options) bool {
    if (opts.question_wildcard and pat == '?') return true;
    if (opts.fold_case) return std.ascii.toLower(pat) == std.ascii.toLower(txt);
    return pat == txt;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const t = std.testing;

const Case = struct {
    pat: []const u8,
    txt: []const u8,
    want: bool,
};

fn runCases(cases: []const Case, opts: Options) !void {
    for (cases) |c| {
        const got = match(c.pat, c.txt, opts);
        if (got != c.want) {
            std.debug.print("glob: pat='{s}' text='{s}' got={} want={}\n", .{ c.pat, c.txt, got, c.want });
            return error.TestUnexpectedResult;
        }
    }
}

test "glob: literals and the empty pattern" {
    const cases = [_]Case{
        .{ .pat = "", .txt = "", .want = true },
        .{ .pat = "", .txt = "x", .want = false },
        .{ .pat = "abc", .txt = "abc", .want = true },
        .{ .pat = "abc", .txt = "abcd", .want = false },
        .{ .pat = "abcd", .txt = "abc", .want = false },
        .{ .pat = "abc", .txt = "", .want = false },
    };
    try runCases(&cases, name_opts);
    try runCases(&cases, path_opts);
}

test "glob: case folding on and off" {
    const folded = [_]Case{
        .{ .pat = "readme", .txt = "README", .want = true },
        .{ .pat = "README", .txt = "readme", .want = true },
        .{ .pat = "*.png", .txt = "shot.PNG", .want = true },
    };
    try runCases(&folded, name_opts);
    const exact = [_]Case{
        .{ .pat = "readme", .txt = "README", .want = false },
        .{ .pat = "README", .txt = "readme", .want = false },
        .{ .pat = "*.png", .txt = "shot.PNG", .want = false },
        .{ .pat = "*.PNG", .txt = "shot.PNG", .want = true },
    };
    try runCases(&exact, path_opts);
}

test "glob: stars, leading, trailing and repeated" {
    const cases = [_]Case{
        .{ .pat = "*", .txt = "", .want = true },
        .{ .pat = "*", .txt = "anything", .want = true },
        .{ .pat = "**", .txt = "", .want = true },
        .{ .pat = "***", .txt = "abc", .want = true },
        .{ .pat = "a*", .txt = "a", .want = true },
        .{ .pat = "a*", .txt = "abc", .want = true },
        .{ .pat = "a*", .txt = "b", .want = false },
        .{ .pat = "*a", .txt = "a", .want = true },
        .{ .pat = "*a", .txt = "bba", .want = true },
        .{ .pat = "*a", .txt = "bbab", .want = false },
        .{ .pat = "a*c", .txt = "ac", .want = true },
        .{ .pat = "a*b*c", .txt = "abc", .want = true },
        .{ .pat = "a*b*c", .txt = "aXXbYYc", .want = true },
        .{ .pat = "a*b*c", .txt = "acb", .want = false },
        .{ .pat = "*b", .txt = "abab", .want = true },
        .{ .pat = "*.tar.gz", .txt = "a.tar.tar.gz", .want = true },
        .{ .pat = "*.tar.gz", .txt = "a.tar.gz.x", .want = false },
        .{ .pat = "**.tar.*", .txt = "x.tar.gz", .want = true },
    };
    try runCases(&cases, name_opts);
    try runCases(&cases, path_opts);
}

test "glob: a star crosses a slash" {
    const cases = [_]Case{
        .{ .pat = "*", .txt = "/a/b/c", .want = true },
        .{ .pat = "/foo*", .txt = "/foo/bar/baz", .want = true },
        .{ .pat = "*.js", .txt = "js/deep/start.js", .want = true },
        .{ .pat = "a*b", .txt = "a/x/b", .want = true },
    };
    try runCases(&cases, name_opts);
    try runCases(&cases, path_opts);
}

test "glob: question mark as wildcard and as literal" {
    const wild = [_]Case{
        .{ .pat = "a?c", .txt = "abc", .want = true },
        .{ .pat = "a?c", .txt = "aXc", .want = true },
        .{ .pat = "a?c", .txt = "a?c", .want = true },
        .{ .pat = "a?c", .txt = "ac", .want = false },
        .{ .pat = "a?c", .txt = "abbc", .want = false },
        .{ .pat = "?*", .txt = "x", .want = true },
        .{ .pat = "?*", .txt = "", .want = false },
        .{ .pat = "?", .txt = "/", .want = true },
    };
    try runCases(&wild, name_opts);
    const literal = [_]Case{
        .{ .pat = "a?c", .txt = "a?c", .want = true },
        .{ .pat = "a?c", .txt = "abc", .want = false },
        .{ .pat = "?*", .txt = "x", .want = false },
        .{ .pat = "?*", .txt = "?x", .want = true },
        .{ .pat = "/q?x=1", .txt = "/q?x=1", .want = true },
    };
    try runCases(&literal, path_opts);
}

test "glob: a literal star in the text is matchable" {
    // The pre-2026-08 filebrowser/fsjob matchers tested the literal
    // before the star and so lost these; the shared matcher does not.
    const cases = [_]Case{
        .{ .pat = "*", .txt = "*a", .want = true },
        .{ .pat = "*x", .txt = "*ax", .want = true },
        .{ .pat = "*a", .txt = "*a", .want = true },
        .{ .pat = "**", .txt = "**", .want = true },
    };
    try runCases(&cases, name_opts);
    try runCases(&cases, path_opts);
}

test "glob: adversarial star runs stay linear" {
    // The recursive matcher this replaced was exponential here and
    // would not have returned.
    try t.expect(!matchPath("/a*a*a*a*a*a*a*a*b", "/" ++ "a" ** 64));
    try t.expect(matchPath("/a*a*a*a*a*a*a*a*b", "/" ++ "a" ** 64 ++ "b"));
    try t.expect(!matchName("*a*a*a*a*a*a*a*a*b", "a" ** 64));
}

/// The exponential reference the shared matcher must agree with: the
/// textbook recursive definition, parameterised the same way.
fn refMatch(pattern: []const u8, text: []const u8, opts: Options) bool {
    if (pattern.len == 0) return text.len == 0;
    if (pattern[0] == '*') {
        var i: usize = 0;
        while (i <= text.len) : (i += 1)
            if (refMatch(pattern[1..], text[i..], opts)) return true;
        return false;
    }
    if (text.len == 0) return false;
    if (!literalEq(pattern[0], text[0], opts)) return false;
    return refMatch(pattern[1..], text[1..], opts);
}

/// The recursive `web_accessible_resources` matcher that used to live
/// in `web/webext/assets.zig`, verbatim, so the swap to the linear one
/// can be proven result-identical rather than asserted.
fn legacyAssetsMatch(pat: []const u8, s: []const u8) bool {
    if (pat.len == 0) return s.len == 0;
    const star = std.mem.indexOfScalar(u8, pat, '*') orelse return std.mem.eql(u8, pat, s);
    const head = pat[0..star];
    const tail = pat[star + 1 ..];
    if (!std.mem.startsWith(u8, s, head)) return false;
    const rest = s[head.len..];
    if (tail.len == 0) return true;
    var i: usize = 0;
    while (i <= rest.len) : (i += 1) {
        if (legacyAssetsMatch(tail, rest[i..])) return true;
    }
    return false;
}

fn nthString(buf: []u8, idx: usize, alphabet: []const u8, len: usize) []const u8 {
    var v = idx;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[i] = alphabet[v % alphabet.len];
        v /= alphabet.len;
    }
    return buf[0..len];
}

test "glob: exhaustive agreement with the recursive reference" {
    const pat_alphabet = "ab*?/";
    const txt_alphabet = "abA*?/";
    var pat_buf: [8]u8 = undefined;
    var txt_buf: [8]u8 = undefined;
    var pat_len: usize = 0;
    while (pat_len <= 4) : (pat_len += 1) {
        var pi: usize = 0;
        const pat_count = std.math.pow(usize, pat_alphabet.len, pat_len);
        while (pi < pat_count) : (pi += 1) {
            const pat = nthString(&pat_buf, pi, pat_alphabet, pat_len);
            var txt_len: usize = 0;
            while (txt_len <= 4) : (txt_len += 1) {
                var ti: usize = 0;
                const txt_count = std.math.pow(usize, txt_alphabet.len, txt_len);
                while (ti < txt_count) : (ti += 1) {
                    const txt = nthString(&txt_buf, ti, txt_alphabet, txt_len);
                    try t.expectEqual(refMatch(pat, txt, name_opts), match(pat, txt, name_opts));
                    try t.expectEqual(refMatch(pat, txt, path_opts), match(pat, txt, path_opts));
                    // The webext assets matcher is the path flavour.
                    try t.expectEqual(legacyAssetsMatch(pat, txt), match(pat, txt, path_opts));
                }
            }
        }
    }
}
