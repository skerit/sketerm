//! What reading a page produces, shared by `web_read` (one tab) and
//! `web_fetch` (several urls through background tabs): the mode
//! vocabulary, where a body came from, the size caps, and regex matches
//! with context. std-only and engine-free, so both test roots import it.

const std = @import("std");
const regex = @import("../editor/regex.zig");

/// How a page's content comes back. ONE vocabulary: both tools' `mode`
/// schema enums are generated from it, `fetchable` says which of them
/// `web_fetch` takes.
pub const Mode = enum {
    /// Readable text: reader mode for a page, the body itself for plain
    /// text, XML or JSON.
    text,
    /// The response body as the server sent it (the page source).
    raw,
    /// Matches of `pattern` over the text or the raw body.
    regex,
    /// Every link with its absolute url and the page area it sits in.
    links,
    /// Every script (inline or external) and iframe.
    resources,

    /// `web_fetch` reads bodies; the element lists are a tab's.
    pub fn fetchable(self: Mode) bool {
        return switch (self) {
            .text, .raw, .regex => true,
            .links, .resources => false,
        };
    }
};

/// What a `regex` runs over (`regex_in`).
pub const RegexIn = enum { text, raw };

/// Where a body came from (`body_source`).
pub const BodySource = enum {
    /// Reader mode over the rendered page (web_read's extraction).
    reader,
    /// The response body as received, from the tab's capture.
    response,
    /// The rendered DOM (outerHTML / innerText): no captured response.
    dom,
};

pub const DEFAULT_MAX_CHARS: usize = 50_000;
pub const MAX_MAX_CHARS: usize = 1_000_000;
pub const DEFAULT_MAX_ITEMS: usize = 200;
pub const MAX_MAX_ITEMS: usize = 5_000;
pub const DEFAULT_CONTEXT: usize = 60;
pub const MAX_CONTEXT: usize = 1000;
pub const DEFAULT_MAX_MATCHES: usize = 50;
pub const MAX_MAX_MATCHES: usize = 1000;
/// Matches counted past the cap before counting stops (`match_count`
/// then reads as "at least").
pub const COUNT_CEILING: usize = 100_000;

/// `s` cut to at most `max` bytes on a UTF-8 boundary.
pub fn truncate(s: []const u8, max: usize) struct { text: []const u8, truncated: bool } {
    if (s.len <= max) return .{ .text = s, .truncated = false };
    return .{ .text = s[0..utf8Floor(s, max)], .truncated = true };
}

/// One page of `s`: at most `max` bytes from `offset`, both ends on UTF-8
/// boundaries, so walking `next` from 0 covers `s` with no gap and no
/// overlap.
pub const Page = struct {
    text: []const u8,
    /// Where this page starts (the asked offset, floored to a boundary).
    offset: usize,
    /// Where the next page starts; null when this page reaches the end.
    next: ?usize,
};

pub fn page(s: []const u8, offset: usize, max: usize) Page {
    const start = utf8Floor(s, @min(offset, s.len));
    var end = utf8Floor(s, @min(s.len, start +| max));
    // A page must make progress even when `max` is smaller than the
    // codepoint at `start`.
    if (end == start and start < s.len) end = utf8Ceil(s, start + 1);
    return .{ .text = s[start..end], .offset = start, .next = if (end < s.len) end else null };
}

/// The largest index <= `at` that does not split a UTF-8 sequence.
fn utf8Floor(s: []const u8, at: usize) usize {
    var i = @min(at, s.len);
    while (i > 0 and i < s.len and (s[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

/// The smallest index >= `at` that does not split a UTF-8 sequence.
fn utf8Ceil(s: []const u8, at: usize) usize {
    var i = @min(at, s.len);
    while (i < s.len and (s[i] & 0xC0) == 0x80) i += 1;
    return i;
}

pub const Match = struct {
    /// Byte offset of the match in the searched text.
    offset: usize,
    match: []const u8,
    before: []const u8,
    after: []const u8,
};

pub const Matches = struct {
    items: []const Match,
    /// Every match found, up to `COUNT_CEILING`.
    total: usize,
    /// More matches exist than `items` holds.
    capped: bool,
};

pub const MatchOpts = struct {
    ignore_case: bool = false,
    context: usize = DEFAULT_CONTEXT,
    max: usize = DEFAULT_MAX_MATCHES,
};

/// Every match of `pattern` in `text` (the find bar's engine, so the
/// syntax is `editor/regex.zig`'s), the first `opts.max` with up to
/// `opts.context` bytes on either side. Slices borrow `text`.
pub fn findMatches(arena: std.mem.Allocator, text: []const u8, pattern: []const u8, opts: MatchOpts) regex.Error!Matches {
    var prog = try regex.compile(arena, pattern, .{ .case_insensitive = opts.ignore_case });
    defer prog.deinit();
    var m = try regex.Matcher.init(arena, &prog);
    defer m.deinit();
    const src_bytes = text;
    const src = regex.sliceSource(&src_bytes);
    var out: std.ArrayList(Match) = .empty;
    var total: usize = 0;
    var from: usize = 0;
    while (from <= text.len and total < COUNT_CEILING) {
        const caps = (try m.search(src, from)) orelse break;
        const s = caps.start();
        const e = caps.end();
        total += 1;
        if (out.items.len < opts.max) {
            const b = utf8Floor(text, s -| opts.context);
            const a = utf8Ceil(text, @min(e + opts.context, text.len));
            try out.append(arena, .{ .offset = s, .match = text[s..e], .before = text[b..s], .after = text[e..a] });
        }
        // An empty match must still move on, by one whole codepoint.
        from = if (e > s) e else utf8Ceil(text, e + 1);
        if (e == text.len and e == s) break;
    }
    return .{ .items = out.items, .total = total, .capped = total > out.items.len };
}

/// A validated regex request: what `mode:"regex"` searches and how.
pub const RegexOpts = struct {
    pattern: []const u8,
    in: RegexIn = .text,
    ignore_case: bool = false,
    context: usize = DEFAULT_CONTEXT,
    max_matches: usize = DEFAULT_MAX_MATCHES,
};

/// The refusal a pattern the matcher cannot compile gets, naming the
/// syntax so the caller can fix it.
pub const BAD_PATTERN = "'pattern' is not a supported regex ({s}); the syntax is the editor find bar's: classes, groups, alternation, quantifiers, \\b, line anchors; no backreferences or lookaround";

/// Lowercase hex SHA-256 of `s`: lets a caller paging a long body tell
/// whether it changed between two pages.
pub fn sha256Hex(s: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(s, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

const t = std.testing;

test "truncation stays on a codepoint" {
    const cut = truncate("caf\xc3\xa9!", 4);
    try t.expect(cut.truncated);
    try t.expectEqualStrings("caf", cut.text);
    try t.expect(!truncate("abc", 3).truncated);
}

test "pages cover the text with no gap and no overlap, multibyte included" {
    const s = "ab\xc3\xa9cd\xe2\x82\xacefgh\xf0\x9f\x98\x80ij";
    for ([_]usize{ 1, 2, 3, 4, 5, 7 }) |max| {
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(t.allocator);
        var off: ?usize = 0;
        var pages: usize = 0;
        while (off) |o| : (pages += 1) {
            const p = page(s, o, max);
            try t.expectEqual(o, p.offset);
            try t.expect(std.unicode.utf8ValidateSlice(p.text));
            try t.expect(p.text.len > 0);
            try joined.appendSlice(t.allocator, p.text);
            off = p.next;
        }
        try t.expectEqualStrings(s, joined.items);
        try t.expect(pages >= 2);
    }
    // An offset inside a codepoint starts at its first byte; past the
    // end is an empty last page.
    try t.expectEqual(@as(usize, 2), page(s, 3, 10).offset);
    const end = page(s, 999, 10);
    try t.expectEqual(@as(usize, 0), end.text.len);
    try t.expect(end.next == null);
    try t.expect(page("abc", 0, 3).next == null);
}

test "regex matches carry context, stop at the cap and keep counting" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const text = "id=1 x id=22 y id=333 z";
    const m = try findMatches(a.allocator(), text, "id=\\d+", .{ .context = 2, .max = 2 });
    try t.expectEqual(@as(usize, 3), m.total);
    try t.expect(m.capped);
    try t.expectEqual(@as(usize, 2), m.items.len);
    try t.expectEqualStrings("id=1", m.items[0].match);
    try t.expectEqualStrings("", m.items[0].before);
    try t.expectEqualStrings(" x", m.items[0].after);
    try t.expectEqualStrings("x ", m.items[1].before);
    try t.expectEqual(@as(usize, 7), m.items[1].offset);
    const ci = try findMatches(a.allocator(), "Sitemap SITEMAP", "sitemap", .{ .ignore_case = true });
    try t.expectEqual(@as(usize, 2), ci.total);
    // An empty-matching pattern advances instead of looping.
    const empty = try findMatches(a.allocator(), "ab", "x*", .{});
    try t.expectEqual(@as(usize, 3), empty.total);
    try t.expectError(error.InvalidPattern, findMatches(a.allocator(), "x", "(", .{}));
}

test "web_fetch takes the body modes only" {
    try t.expect(Mode.text.fetchable() and Mode.raw.fetchable() and Mode.regex.fetchable());
    try t.expect(!Mode.links.fetchable() and !Mode.resources.fetchable());
    const h = sha256Hex("abc");
    try t.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &h);
}
