//! Shared suggestion/ranking framework — the "one grown-up system"
//! behind the omnibox and the command palette (docs/proposal-browser.md
//! "Command palette synthesis"): URL / search / history / bookmarks /
//! open-tabs / commands are pluggable `Source`s merged into one ranked
//! list.
//!
//! GTK-free by design: consumers own the widgets, this module owns the
//! matching, the per-source score normalization and the interleaving.
//! Candidate strings are BORROWED from the producing source for the
//! merge result's lifetime — a consumer that keeps them re-owns them.

const std = @import("std");
const percent = @import("percent.zig");

/// What a candidate is, which decides what activating it does and
/// which icon a consumer renders next to it.
pub const Kind = enum { url, search, history, bookmark, open_tab, command };

pub const Candidate = struct {
    title: []const u8,
    detail: []const u8 = "",
    kind: Kind,
    /// Source-local score. Match-quality sources emit 0..1 directly;
    /// sources on an unbounded scale (frecency) set
    /// `Source.normalize` and the merger divides by the batch max.
    score: f32,
    /// Source-defined (an index into the source's own storage, a view
    /// id, …). The merger never looks at it.
    payload: u64 = 0,
    /// Cross-source dedupe key (typically the URL); empty = never
    /// deduped. The highest-ranked holder of a key survives.
    key: []const u8 = "",
    /// Index of the producing source, filled in by `merge`.
    source: u8 = 0,
};

pub const QueryFn = *const fn (
    ctx: ?*anyopaque,
    q: []const u8,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(Candidate),
) void;

pub const Source = struct {
    ctx: ?*anyopaque = null,
    /// Divide this source's raw scores by its batch maximum before
    /// weighting — for scales like frecency where only the relative
    /// order means anything.
    normalize: bool = false,
    /// Cross-source multiplier applied AFTER normalization.
    weight: f32 = 1.0,
    query: QueryFn,
};

/// Query every source and interleave the results by effective score
/// (normalized, then weighted), stably: equal scores keep source
/// order, then each source's own emission order. Zero-or-less scores
/// are dropped, duplicates (same non-empty `key`) keep only the
/// highest-ranked holder, and the list is capped at `max`.
pub fn merge(
    gpa: std.mem.Allocator,
    sources: []const Source,
    q: []const u8,
    max: usize,
    out: *std.ArrayList(Candidate),
) error{OutOfMemory}!void {
    out.clearRetainingCapacity();
    for (sources, 0..) |src, si| {
        const start = out.items.len;
        src.query(src.ctx, q, gpa, out);
        // Drop non-matches before normalizing so a batch of zeros
        // cannot skew the max.
        var i: usize = start;
        while (i < out.items.len) {
            if (out.items[i].score <= 0) {
                _ = out.orderedRemove(i);
                continue;
            }
            i += 1;
        }
        var batch_max: f32 = 0;
        for (out.items[start..]) |cand| batch_max = @max(batch_max, cand.score);
        for (out.items[start..]) |*cand| {
            if (src.normalize and batch_max > 0) cand.score /= batch_max;
            cand.score *= src.weight;
            cand.source = @intCast(si);
        }
    }
    // Insertion sort is stable, and suggestion lists are tens of
    // entries at most.
    std.sort.insertion(Candidate, out.items, {}, scoreDesc);
    dedupeByKey(out);
    if (out.items.len > max) out.shrinkRetainingCapacity(max);
}

fn scoreDesc(_: void, a: Candidate, b: Candidate) bool {
    return a.score > b.score;
}

fn dedupeByKey(out: *std.ArrayList(Candidate)) void {
    var i: usize = 0;
    while (i < out.items.len) : (i += 1) {
        const key = out.items[i].key;
        if (key.len == 0) continue;
        var j: usize = i + 1;
        while (j < out.items.len) {
            const other = out.items[j].key;
            if (other.len != 0 and std.mem.eql(u8, other, key)) {
                _ = out.orderedRemove(j);
                continue;
            }
            j += 1;
        }
    }
}

// ── matching ─────────────────────────────────────────────────────

/// Substring match quality of an already-lowercased query against an
/// already-lowercased haystack: 1.0 prefix, 0.8 word boundary, 0.6
/// anywhere, 0 no match. An empty query matches everything at 1.0 so
/// bare invocations keep each source's intrinsic order.
pub fn matchScore(q_lower: []const u8, hay_lower: []const u8) f32 {
    if (q_lower.len == 0) return 1.0;
    const idx = std.mem.indexOf(u8, hay_lower, q_lower) orelse return 0.0;
    if (idx == 0) return 1.0;
    return if (std.ascii.isAlphanumeric(hay_lower[idx - 1])) 0.6 else 0.8;
}

/// Combined match over a title and a secondary field (description,
/// URL): the secondary is worth 70% of a title hit.
pub fn fieldsScore(q_lower: []const u8, title_lower: []const u8, detail_lower: []const u8) f32 {
    return @max(matchScore(q_lower, title_lower), 0.7 * matchScore(q_lower, detail_lower));
}

/// ASCII-lowercase `s` into `out`, truncating to `out.len`.
pub fn toLower(out: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, out.len);
    for (s[0..n], 0..) |ch, i| out[i] = std.ascii.toLower(ch);
    return out[0..n];
}

// ── the address-bar heuristic ────────────────────────────────────

/// What a typed address-bar string means.
pub const SpecClass = enum { url, host, search };

pub const default_search_template = "https://duckduckgo.com/?q={q}";

/// An explicit scheme wins, a token with a dot and no space is a
/// host, anything else is a web search.
pub fn classify(spec: []const u8) SpecClass {
    if (std.mem.indexOf(u8, spec, "://") != null) return .url;
    if (std.mem.startsWith(u8, spec, "about:") or
        std.mem.startsWith(u8, spec, "data:") or
        std.mem.startsWith(u8, spec, "file:") or
        std.mem.startsWith(u8, spec, "chrome:")) return .url;
    const looks_like_host = std.mem.indexOfScalar(u8, spec, ' ') == null and
        std.mem.indexOfScalar(u8, spec, '.') != null;
    return if (looks_like_host) .host else .search;
}

/// Instantiate a `{q}` search-engine template with the percent-encoded
/// query. @return null when the template lacks `{q}` or `buf` is too
/// small.
pub fn searchUrl(buf: []u8, template: []const u8, q: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, template, "{q}") orelse return null;
    const prefix = template[0..at];
    const suffix = template[at + 3 ..];
    if (prefix.len > buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    const encoded = percent.encodeQueryInto(buf[prefix.len..], q) orelse return null;
    const w = prefix.len + encoded.len;
    if (w + suffix.len > buf.len) return null;
    @memcpy(buf[w .. w + suffix.len], suffix);
    return buf[0 .. w + suffix.len];
}

/// Turn address-bar input into a URL the engine can take: explicit
/// schemes pass through, hosts get `https://`, everything else becomes
/// a search on `template` (falling back to the default engine when the
/// template is unusable).
pub fn normalizeUrl(buf: []u8, spec: []const u8, template: []const u8) ?[]const u8 {
    switch (classify(spec)) {
        .url => return spec,
        .host => return std.fmt.bufPrint(buf, "https://{s}", .{spec}) catch null,
        .search => return searchUrl(buf, template, spec) orelse
            searchUrl(buf, default_search_template, spec),
    }
}

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

test "matchScore grades prefix, boundary, substring" {
    try t.expectEqual(@as(f32, 1.0), matchScore("", "anything"));
    try t.expectEqual(@as(f32, 1.0), matchScore("new", "new tab"));
    try t.expectEqual(@as(f32, 0.8), matchScore("tab", "new tab"));
    try t.expectEqual(@as(f32, 0.6), matchScore("ab", "new tab"));
    try t.expectEqual(@as(f32, 0.0), matchScore("zzz", "new tab"));
}

test "fieldsScore discounts the secondary field" {
    // Title miss + detail prefix hit = 0.7.
    try t.expectApproxEqAbs(@as(f32, 0.7), fieldsScore("close", "quit", "close the tab"), 0.001);
    // Title hit wins over any detail hit.
    try t.expectEqual(@as(f32, 1.0), fieldsScore("quit", "quit", "quit it all"));
}

const TestEmit = struct {
    cands: []const Candidate,
    fn query(ctx: ?*anyopaque, q: []const u8, gpa: std.mem.Allocator, out: *std.ArrayList(Candidate)) void {
        _ = q;
        const self: *const TestEmit = @ptrCast(@alignCast(ctx.?));
        for (self.cands) |cand| out.append(gpa, cand) catch {};
    }
};

test "merge normalizes, weights, interleaves and caps" {
    // Frecency-style source: raw scores 200/50 normalize to 1.0/0.25,
    // weighted 0.8 => 0.8/0.2.
    var hist = TestEmit{ .cands = &.{
        .{ .title = "h1", .kind = .history, .score = 200 },
        .{ .title = "h2", .kind = .history, .score = 50 },
    } };
    // Unit-scale source at weight 1.0: 0.9 and 0.5.
    var cmd = TestEmit{ .cands = &.{
        .{ .title = "c1", .kind = .command, .score = 0.9 },
        .{ .title = "c2", .kind = .command, .score = 0.5 },
        .{ .title = "c3", .kind = .command, .score = 0.0 }, // dropped
    } };
    const sources = [_]Source{
        .{ .ctx = &hist, .normalize = true, .weight = 0.8, .query = TestEmit.query },
        .{ .ctx = &cmd, .query = TestEmit.query },
    };
    var out: std.ArrayList(Candidate) = .empty;
    defer out.deinit(t.allocator);
    try merge(t.allocator, &sources, "x", 3, &out);
    // Effective: c1 0.9, h1 0.8, c2 0.5, h2 0.2 — capped at 3.
    try t.expectEqual(@as(usize, 3), out.items.len);
    try t.expectEqualStrings("c1", out.items[0].title);
    try t.expectEqualStrings("h1", out.items[1].title);
    try t.expectEqualStrings("c2", out.items[2].title);
    try t.expectEqual(@as(u8, 0), out.items[1].source);
}

test "merge is stable on ties and dedupes by key" {
    var a = TestEmit{ .cands = &.{
        .{ .title = "first", .kind = .bookmark, .score = 1.0, .key = "https://x/" },
        .{ .title = "second", .kind = .bookmark, .score = 1.0 },
    } };
    var b = TestEmit{ .cands = &.{
        .{ .title = "shadowed", .kind = .history, .score = 0.9, .key = "https://x/" },
        .{ .title = "third", .kind = .history, .score = 1.0 },
    } };
    const sources = [_]Source{
        .{ .ctx = &a, .query = TestEmit.query },
        .{ .ctx = &b, .query = TestEmit.query },
    };
    var out: std.ArrayList(Candidate) = .empty;
    defer out.deinit(t.allocator);
    try merge(t.allocator, &sources, "", 10, &out);
    // Ties keep source order then emission order; the key duplicate
    // ("shadowed", ranked below "first") is gone.
    try t.expectEqual(@as(usize, 3), out.items.len);
    try t.expectEqualStrings("first", out.items[0].title);
    try t.expectEqualStrings("second", out.items[1].title);
    try t.expectEqualStrings("third", out.items[2].title);
}

test "classify separates urls, hosts and searches" {
    try t.expectEqual(SpecClass.url, classify("https://example.com/"));
    try t.expectEqual(SpecClass.url, classify("about:blank"));
    try t.expectEqual(SpecClass.host, classify("example.com"));
    try t.expectEqual(SpecClass.search, classify("two words"));
    try t.expectEqual(SpecClass.search, classify("zig 0.16 std.posix"));
}

test "searchUrl percent-encodes the query into the template" {
    var buf: [512]u8 = undefined;
    try t.expectEqualStrings(
        "https://duckduckgo.com/?q=two%20words",
        searchUrl(&buf, default_search_template, "two words").?,
    );
    try t.expectEqualStrings(
        "https://www.google.com/search?q=a%26b&hl=en",
        searchUrl(&buf, "https://www.google.com/search?q={q}&hl=en", "a&b").?,
    );
    try t.expect(searchUrl(&buf, "https://no-placeholder.example/", "x") == null);
}

test "normalizeUrl falls back to the default engine on a bad template" {
    var buf: [512]u8 = undefined;
    try t.expectEqualStrings("https://example.com", normalizeUrl(&buf, "example.com", "broken").?);
    try t.expectEqualStrings(
        "https://duckduckgo.com/?q=two%20words",
        normalizeUrl(&buf, "two words", "broken").?,
    );
}
