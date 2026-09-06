//! Document search: a literal scan, plus a regular-expression mode
//! backed by `editor/regex.zig`.
//!
//! The literal scan never materializes the document: chunks stream out
//! of `Rope.iterateRange` into a small window buffer that retains only
//! `needle.len - 1` bytes across chunk boundaries, so a match spanning
//! two leaves is still found and can never be reported twice (a match
//! needs `needle.len` bytes and every retained byte is within the last
//! `needle.len - 1`). The regex engine reads the same rope through its
//! own `Source` window, for the same reason.
//!
//! Deliberate simplifications (documented, not accidental):
//! - Case-insensitive matching folds ASCII only, in BOTH modes. A
//!   needle containing non-ASCII therefore matches case-sensitively for
//!   those bytes.
//! - A literal needle is bytes, nothing more (one containing "\n"
//!   simply matches a newline). Regex mode's supported and unsupported
//!   syntax is listed in `editor/regex.zig`'s header — read it before
//!   promising a user anything.
//! - Whole-word tests the codepoint immediately before/after the match
//!   through `unicode.wordClassOf`, the same classifier double-click
//!   word selection uses. It applies to regex matches too.
//! - Replacement templates use `$0`..`$9` for capture groups and `$$`
//!   for a literal `$`. `\1` is NOT a reference (it is not even valid
//!   in a pattern here), so there is one syntax, not two.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Document = @import("document.zig").Document;
const unicode = @import("unicode.zig");
const regex = @import("regex.zig");

pub const Match = struct {
    start: usize,
    end: usize,
};

pub const Options = struct {
    case_sensitive: bool = false,
    whole_word: bool = false,
    /// Treat the needle as a regular expression (`regex.zig` syntax).
    regex: bool = false,
};

/// Compiling a bad pattern is a normal, user-visible outcome — the find
/// bar reports it instead of silently finding nothing.
pub const Error = regex.Error || Allocator.Error;

fn foldByte(b: u8, case_sensitive: bool) u8 {
    if (case_sensitive) return b;
    return if (b >= 'A' and b <= 'Z') b + 32 else b;
}

/// Copy up to `buf.len` bytes of the document starting at `off`.
fn readAt(doc: *const Document, off: usize, buf: []u8) []const u8 {
    const n = doc.rope.len();
    if (off >= n) return buf[0..0];
    const end = @min(n, off + buf.len);
    var it = doc.rope.iterateRange(off, end);
    var pos: usize = 0;
    while (it.next()) |chunk| {
        @memcpy(buf[pos .. pos + chunk.len], chunk);
        pos += chunk.len;
    }
    return buf[0..pos];
}

/// Codepoint starting at `off`, or null at/after the end.
fn cpAt(doc: *const Document, off: usize) ?u21 {
    var buf: [4]u8 = undefined;
    const s = readAt(doc, off, &buf);
    if (s.len == 0) return null;
    return unicode.decodeAt(s, 0).cp;
}

/// Codepoint ending at `off`, or null at the document start.
fn cpBefore(doc: *const Document, off: usize) ?u21 {
    if (off == 0) return null;
    var buf: [4]u8 = undefined;
    const start = off -| 4;
    // Only [start, off): `readAt` fills the whole buffer, so within the
    // document's first four bytes a full-width read would reach FORWARD
    // past `off` and the walk-back would find a codepoint that comes
    // AFTER the offset we were asked about.
    const s = readAt(doc, start, buf[0 .. off - start]);
    if (s.len == 0) return null;
    // Walk back to the last lead byte.
    var i: usize = s.len;
    while (i > 0) {
        i -= 1;
        if ((s[i] & 0xC0) != 0x80) return unicode.decodeAt(s, i).cp;
    }
    return null;
}

fn isWordCp(cp: u21) bool {
    return unicode.wordClassOf(cp) == .word;
}

fn wholeWordOk(doc: *const Document, m: Match) bool {
    if (cpBefore(doc, m.start)) |cp| {
        if (isWordCp(cp)) return false;
    }
    if (cpAt(doc, m.end)) |cp| {
        if (isWordCp(cp)) return false;
    }
    return true;
}

// ---- regex mode -------------------------------------------------------

fn docRead(ctx: *const anyopaque, off: usize, buf: []u8) []const u8 {
    const doc: *const Document = @ptrCast(@alignCast(ctx));
    return readAt(doc, off, buf);
}

fn docSource(doc: *const Document) regex.Source {
    return .{ .ctx = @ptrCast(doc), .len = doc.rope.len(), .read = docRead };
}

/// A compiled pattern plus its matcher, for callers that need capture
/// groups as well as spans (replace). Compiling once and reusing it is
/// what keeps Replace All from recompiling per match.
pub const Regex = struct {
    alloc: Allocator,
    prog: regex.Program,
    matcher: regex.Matcher,
    whole_word: bool,

    pub fn init(alloc: Allocator, pattern: []const u8, opts: Options) Error!Regex {
        var out = Regex{
            .alloc = alloc,
            .prog = try regex.compile(alloc, pattern, .{ .case_insensitive = !opts.case_sensitive }),
            .matcher = undefined,
            .whole_word = opts.whole_word,
        };
        errdefer out.prog.deinit();
        out.matcher = try regex.Matcher.init(alloc, &out.prog);
        return out;
    }

    pub fn deinit(self: *Regex) void {
        self.matcher.deinit();
        self.prog.deinit();
    }

    /// The matcher holds a pointer to `prog`, which moved when `init`
    /// returned by value — re-point it before the first use. Called by
    /// every entry point, so callers never have to know.
    fn rebind(self: *Regex) void {
        self.matcher.prog = &self.prog;
    }

    /// Every non-overlapping match, ascending. An empty match advances
    /// by one CODEPOINT, so `x*` terminates and never reports the same
    /// position twice.
    pub fn findAll(self: *Regex, doc: *const Document) Error![]Match {
        self.rebind();
        const src = docSource(doc);
        var out: std.ArrayList(Match) = .empty;
        errdefer out.deinit(self.alloc);
        var pos: usize = 0;
        while (pos <= src.len) {
            const caps = (try self.matcher.search(src, pos)) orelse break;
            const m = Match{ .start = caps.start(), .end = caps.end() };
            if (!self.whole_word or wholeWordOk(doc, m)) try out.append(self.alloc, m);
            if (m.end > m.start) {
                pos = m.end;
            } else {
                if (m.end >= src.len) break;
                pos = m.end + cpLenAt(doc, m.end);
            }
        }
        return out.toOwnedSlice(self.alloc);
    }

    /// Captures of the match that starts exactly at `start`, or null
    /// when the pattern no longer matches there.
    pub fn capturesAt(self: *Regex, doc: *const Document, start: usize) Error!?regex.Captures {
        self.rebind();
        const caps = (try self.matcher.search(docSource(doc), start)) orelse return null;
        if (caps.start() != start) return null;
        return caps;
    }

    /// Expand a replacement template against one match, appending to
    /// `out`. `$0`..`$9` are groups (`$0` = whole match), `$$` a literal
    /// dollar; a `$` followed by anything else is itself.
    pub fn expand(
        self: *Regex,
        doc: *const Document,
        caps: regex.Captures,
        template: []const u8,
        out: *std.ArrayList(u8),
    ) Error!void {
        var i: usize = 0;
        while (i < template.len) {
            const ch = template[i];
            if (ch != '$') {
                try out.append(self.alloc, ch);
                i += 1;
                continue;
            }
            if (i + 1 >= template.len) {
                try out.append(self.alloc, '$');
                break;
            }
            const nxt = template[i + 1];
            if (nxt == '$') {
                try out.append(self.alloc, '$');
                i += 2;
                continue;
            }
            if (nxt < '0' or nxt > '9') {
                try out.append(self.alloc, '$');
                i += 1;
                continue;
            }
            i += 2;
            const g = caps.group(nxt - '0') orelse continue;
            try appendRange(self.alloc, out, doc, g.start, g.end);
        }
    }
};

/// Byte length of the codepoint at `off` (at least 1, so a scan always
/// advances even over invalid UTF-8).
fn cpLenAt(doc: *const Document, off: usize) usize {
    var buf: [4]u8 = undefined;
    const s = readAt(doc, off, &buf);
    if (s.len == 0) return 1;
    return @max(1, unicode.decodeAt(s, 0).len);
}

fn appendRange(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    doc: *const Document,
    start: usize,
    end: usize,
) Allocator.Error!void {
    var off = start;
    var buf: [512]u8 = undefined;
    while (off < end) {
        const want = @min(buf.len, end - off);
        const got = readAt(doc, off, buf[0..want]);
        if (got.len == 0) break;
        try out.appendSlice(alloc, got);
        off += got.len;
    }
}

/// Every occurrence of `needle`, ascending by start offset. Caller
/// frees. An empty needle yields no matches, in either mode.
pub fn findAll(
    alloc: Allocator,
    doc: *const Document,
    needle: []const u8,
    opts: Options,
) Error![]Match {
    if (needle.len == 0) return alloc.alloc(Match, 0);
    if (opts.regex) {
        var re = try Regex.init(alloc, needle, opts);
        defer re.deinit();
        return re.findAll(doc);
    }
    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(alloc);
    const doc_len = doc.rope.len();
    if (needle.len > doc_len) return out.toOwnedSlice(alloc);

    // Folded needle, so the inner loop compares byte-for-byte.
    const pat = try alloc.alloc(u8, needle.len);
    defer alloc.free(pat);
    for (needle, 0..) |b, i| pat[i] = foldByte(b, opts.case_sensitive);

    var win: std.ArrayList(u8) = .empty;
    defer win.deinit(alloc);
    // Document offset of win.items[0].
    var base: usize = 0;
    var it = doc.rope.iterateRange(0, doc_len);
    while (it.next()) |chunk| {
        const before = win.items.len;
        try win.resize(alloc, before + chunk.len);
        for (chunk, 0..) |b, i| win.items[before + i] = foldByte(b, opts.case_sensitive);
        try scanWindow(alloc, &out, win.items, base, pat);
        const keep = @min(win.items.len, needle.len - 1);
        const drop = win.items.len - keep;
        if (drop > 0) {
            std.mem.copyForwards(u8, win.items[0..keep], win.items[drop..]);
            win.shrinkRetainingCapacity(keep);
            base += drop;
        }
    }

    // Overlapping hits are not distinct results. `scanWindow` steps one
    // byte at a time (it has to: the window retains only needle.len-1
    // bytes across a leaf seam), so "aa" in "aaaa" comes out three
    // times. Regex mode already advances to `m.end`, and every consumer
    // downstream skips the overlaps — which is how the find bar came to
    // say "3 matches" and Replace All then "replaced 2".
    {
        var w: usize = 0;
        var prev_end: usize = 0;
        for (out.items) |m| {
            if (w > 0 and m.start < prev_end) continue;
            out.items[w] = m;
            prev_end = m.end;
            w += 1;
        }
        out.shrinkRetainingCapacity(w);
    }

    if (opts.whole_word) {
        var w: usize = 0;
        for (out.items) |m| {
            if (wholeWordOk(doc, m)) {
                out.items[w] = m;
                w += 1;
            }
        }
        out.shrinkRetainingCapacity(w);
    }
    return out.toOwnedSlice(alloc);
}

fn scanWindow(
    alloc: Allocator,
    out: *std.ArrayList(Match),
    hay: []const u8,
    base: usize,
    pat: []const u8,
) !void {
    if (hay.len < pat.len) return;
    var i: usize = 0;
    const last = hay.len - pat.len;
    while (i <= last) : (i += 1) {
        if (std.mem.eql(u8, hay[i .. i + pat.len], pat)) {
            try out.append(alloc, .{ .start = base + i, .end = base + i + pat.len });
        }
    }
}

/// Index of the match to select when searching from `from` (a caret
/// offset). Forward picks the first match starting at or after `from`;
/// backward picks the last match ending at or before `from`. Both wrap
/// around. Null only when there are no matches.
pub fn pick(matches: []const Match, from: usize, forward: bool) ?usize {
    if (matches.len == 0) return null;
    if (forward) {
        for (matches, 0..) |m, i| {
            if (m.start >= from) return i;
        }
        return 0;
    }
    var i: usize = matches.len;
    while (i > 0) {
        i -= 1;
        if (matches[i].end <= from) return i;
    }
    return matches.len - 1;
}

/// Index of the match exactly covering [start,end), if any (used to
/// keep "3 of 17" stable when the caret already sits on a match).
pub fn indexOfRange(matches: []const Match, start: usize, end: usize) ?usize {
    for (matches, 0..) |m, i| {
        if (m.start == start and m.end == end) return i;
    }
    return null;
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

fn docOf(text: []const u8) !Document {
    return try Document.initFromBytes(testing.allocator, text);
}

test "search: literal matches, case folding, empty needle" {
    const a = testing.allocator;
    var doc = try docOf("Foo foo FOO bar");
    defer doc.deinit();

    {
        const m = try findAll(a, &doc, "foo", .{});
        defer a.free(m);
        try testing.expectEqual(@as(usize, 3), m.len);
        try testing.expectEqual(@as(usize, 0), m[0].start);
        try testing.expectEqual(@as(usize, 4), m[1].start);
        try testing.expectEqual(@as(usize, 8), m[2].start);
        try testing.expectEqual(@as(usize, 3), m[0].end);
    }
    {
        const m = try findAll(a, &doc, "foo", .{ .case_sensitive = true });
        defer a.free(m);
        try testing.expectEqual(@as(usize, 1), m.len);
        try testing.expectEqual(@as(usize, 4), m[0].start);
    }
    {
        const m = try findAll(a, &doc, "", .{});
        defer a.free(m);
        try testing.expectEqual(@as(usize, 0), m.len);
    }
}

test "search: whole word filters substrings" {
    const a = testing.allocator;
    var doc = try docOf("cat category cat.dog scatter");
    defer doc.deinit();
    const all = try findAll(a, &doc, "cat", .{});
    defer a.free(all);
    try testing.expectEqual(@as(usize, 4), all.len);
    const ww = try findAll(a, &doc, "cat", .{ .whole_word = true });
    defer a.free(ww);
    try testing.expectEqual(@as(usize, 2), ww.len);
    try testing.expectEqual(@as(usize, 0), ww[0].start);
    try testing.expectEqual(@as(usize, 13), ww[1].start);
}

test "search: a literal needle does not report overlapping matches" {
    // Regex mode advances to the match end, and every consumer skips
    // overlaps, so a literal that overlapped itself made the find bar's
    // count disagree with what Replace All actually rewrote.
    const a = testing.allocator;
    var doc = try docOf("aaaa");
    defer doc.deinit();
    const m = try findAll(a, &doc, "aa", .{});
    defer a.free(m);
    try testing.expectEqual(@as(usize, 2), m.len);
    try testing.expectEqual(@as(usize, 0), m[0].start);
    try testing.expectEqual(@as(usize, 2), m[1].start);

    var rx = try Regex.init(a, "aa", .{ .regex = true });
    defer rx.deinit();
    const rm = try rx.findAll(&doc);
    defer a.free(rm);
    try testing.expectEqual(m.len, rm.len);
}

test "search: whole word looks at the codepoint BEFORE a near-start match" {
    // The preceding-codepoint window is read backwards from the match,
    // so within the first four bytes of the document it must not be
    // allowed to reach FORWARD past the match start: "a-bc d" would
    // then test 'c' (a word byte) instead of '-' and reject the match.
    const a = testing.allocator;
    var doc = try docOf("a-bc d");
    defer doc.deinit();
    const ww = try findAll(a, &doc, "bc", .{ .whole_word = true });
    defer a.free(ww);
    try testing.expectEqual(@as(usize, 1), ww.len);
    try testing.expectEqual(@as(usize, 2), ww[0].start);

    // …and the genuine rejection still happens.
    var doc2 = try docOf("abc d");
    defer doc2.deinit();
    const none = try findAll(a, &doc2, "bc", .{ .whole_word = true });
    defer a.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "search: matches spanning rope leaf boundaries are found once" {
    const a = testing.allocator;
    // Build a document large enough to hold many leaves, with the
    // needle placed at many offsets so some straddle a boundary.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        try text.appendSlice(a, "abcdefg");
        if (i % 7 == 0) try text.appendSlice(a, "NEEDLE");
    }
    var doc = try Document.initFromBytes(a, text.items);
    defer doc.deinit();
    const m = try findAll(a, &doc, "NEEDLE", .{});
    defer a.free(m);
    const expected = (4000 + 6) / 7;
    try testing.expectEqual(expected, m.len);
    // Strictly ascending, non-overlapping.
    var prev: usize = 0;
    for (m, 0..) |x, k| {
        if (k > 0) try testing.expect(x.start >= prev);
        prev = x.end;
        try testing.expectEqual(@as(usize, 6), x.end - x.start);
    }
    // And each really is the needle.
    const first = try doc.rope.sliceAlloc(a, m[0].start, m[0].end);
    defer a.free(first);
    try testing.expectEqualStrings("NEEDLE", first);
}

test "search: pick wraps in both directions" {
    const m = [_]Match{
        .{ .start = 5, .end = 8 },
        .{ .start = 20, .end = 23 },
    };
    try testing.expectEqual(@as(usize, 0), pick(&m, 0, true).?);
    try testing.expectEqual(@as(usize, 1), pick(&m, 9, true).?);
    try testing.expectEqual(@as(usize, 0), pick(&m, 99, true).?); // wrapped
    try testing.expectEqual(@as(usize, 1), pick(&m, 99, false).?);
    try testing.expectEqual(@as(usize, 0), pick(&m, 20, false).?);
    try testing.expectEqual(@as(usize, 1), pick(&m, 0, false).?); // wrapped
    try testing.expectEqual(@as(?usize, null), pick(&.{}, 0, true));
}

test "search: regex mode over the rope, with whole-word and case folding" {
    const a = testing.allocator;
    var doc = try docOf("cat category CAT scatter\ncat\n");
    defer doc.deinit();
    {
        const m = try findAll(a, &doc, "c.t", .{ .regex = true });
        defer a.free(m);
        // cat, category, CAT, scatter, cat
        try testing.expectEqual(@as(usize, 5), m.len);
    }
    {
        const m = try findAll(a, &doc, "c.t", .{ .regex = true, .case_sensitive = true });
        defer a.free(m);
        try testing.expectEqual(@as(usize, 4), m.len);
    }
    {
        const m = try findAll(a, &doc, "c.t", .{ .regex = true, .whole_word = true });
        defer a.free(m);
        try testing.expectEqual(@as(usize, 3), m.len);
        try testing.expectEqual(@as(usize, 0), m[0].start);
        try testing.expectEqual(@as(usize, 13), m[1].start);
        try testing.expectEqual(@as(usize, 25), m[2].start);
    }
    {
        // Anchors are per LINE.
        const m = try findAll(a, &doc, "^cat$", .{ .regex = true });
        defer a.free(m);
        try testing.expectEqual(@as(usize, 1), m.len);
        try testing.expectEqual(@as(usize, 25), m[0].start);
    }
    {
        const m = try findAll(a, &doc, "", .{ .regex = true });
        defer a.free(m);
        try testing.expectEqual(@as(usize, 0), m.len);
    }
}

test "search: a regex match spanning rope leaves is found once" {
    const a = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        try text.appendSlice(a, "abcdefg");
        if (i % 7 == 0) try text.print(a, "N{d}Z", .{i});
    }
    var doc = try Document.initFromBytes(a, text.items);
    defer doc.deinit();
    const m = try findAll(a, &doc, "N\\d+Z", .{ .regex = true });
    defer a.free(m);
    try testing.expectEqual((4000 + 6) / 7, m.len);
    const first = try doc.rope.sliceAlloc(a, m[0].start, m[0].end);
    defer a.free(first);
    try testing.expectEqualStrings("N0Z", first);
}

test "search: an invalid pattern is an error, not an empty result" {
    const a = testing.allocator;
    var doc = try docOf("whatever");
    defer doc.deinit();
    try testing.expectError(error.InvalidPattern, findAll(a, &doc, "(unclosed", .{ .regex = true }));
    try testing.expectError(error.UnsupportedPattern, findAll(a, &doc, "(a)\\1", .{ .regex = true }));
    // The same text is a perfectly good LITERAL needle.
    const m = try findAll(a, &doc, "(unclosed", .{});
    defer a.free(m);
    try testing.expectEqual(@as(usize, 0), m.len);
}

test "search: capture-group replacement templates" {
    const a = testing.allocator;
    var doc = try docOf("jelle@example.com and root@localhost.org");
    defer doc.deinit();
    var re = try Regex.init(a, "(\\w+)@(\\w+)\\.(\\w+)", .{});
    defer re.deinit();
    const m = try re.findAll(&doc);
    defer a.free(m);
    try testing.expectEqual(@as(usize, 2), m.len);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const caps = (try re.capturesAt(&doc, m[0].start)).?;
    try re.expand(&doc, caps, "$2.$3/$1 [$0] $$ $9", &out);
    try testing.expectEqualStrings(
        "example.com/jelle [jelle@example.com] $ ",
        out.items,
    );

    // A position the pattern does not start at answers null (offset 5
    // is the '@': the leftmost match from there begins much later).
    try testing.expect((try re.capturesAt(&doc, m[0].start + 5)) == null);
}

test "search: an empty-matching regex terminates and steps by codepoint" {
    const a = testing.allocator;
    var doc = try docOf("a\u{00e9}b");
    defer doc.deinit();
    const m = try findAll(a, &doc, "x*", .{ .regex = true });
    defer a.free(m);
    // One empty match per codepoint boundary plus the end.
    try testing.expectEqual(@as(usize, 4), m.len);
    try testing.expectEqual(@as(usize, 0), m[0].start);
    try testing.expectEqual(@as(usize, 1), m[1].start);
    try testing.expectEqual(@as(usize, 3), m[2].start);
    try testing.expectEqual(@as(usize, 4), m[3].start);
}

test "search: multi-line needle" {
    const a = testing.allocator;
    var doc = try docOf("one\ntwo\nthree\ntwo\n");
    defer doc.deinit();
    const m = try findAll(a, &doc, "two\n", .{});
    defer a.free(m);
    try testing.expectEqual(@as(usize, 2), m.len);
    try testing.expectEqual(@as(usize, 4), m[0].start);
    try testing.expectEqual(@as(usize, 14), m[1].start);
}
