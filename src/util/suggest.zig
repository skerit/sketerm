//! Shared suggestion/ranking framework — the "one grown-up system"
//! behind the omnibox and the command palette (docs/proposal-browser.md
//! "Command palette synthesis"): URL / search / history / bookmarks /
//! open-tabs / commands are pluggable `Source`s merged into one ranked
//! list.
//!
//! GTK-free by design: consumers own the widgets, this module owns the
//! matching, the per-source score normalization, the interleaving, the
//! staleness arithmetic for IO-backed sources (`Model`) and the
//! dispatch (`Candidate.fire`). Candidate strings are BORROWED from the
//! producing source for the merge result's lifetime — a consumer that
//! keeps them past the next merge re-owns them.
//!
//! The framework deliberately stops at the model. Rendering stays with
//! each consumer, because the omnibox (a popover that rebuilds its rows
//! every keystroke) and the palette (a dialog whose expensive
//! AdwActionRows are built once and then re-sorted) use opposite and
//! individually correct row strategies; see `Model`'s docblock.

const std = @import("std");
const percent = @import("percent.zig");

/// What a candidate is, which decides what activating it does and
/// which icon a consumer renders next to it.
pub const Kind = enum {
    url,
    search,
    history,
    bookmark,
    /// An open WEB tab (the omnibox's "switch, don't navigate" row).
    open_tab,
    command,
    /// An open terminal tab / mux session (the palette's switcher row).
    session,
};

/// What activating a candidate does. Handed the producing `Source`'s
/// `ctx` and the candidate itself, so `payload` / `key` / `title` are
/// all in reach without the consumer switching on `kind` first.
pub const ActivateFn = *const fn (ctx: ?*anyopaque, cand: Candidate) void;

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
    /// Dispatch, copied off the producing `Source` by `merge`. This is
    /// what makes one merged list activatable without the consumer
    /// re-deriving which source a row came from — the half of
    /// unification that `payload` alone could not express.
    activate: ?ActivateFn = null,
    /// The producing source's `ctx`, likewise stamped by `merge`.
    activate_ctx: ?*anyopaque = null,

    /// Dispatch this row. @return false when its source declared no
    /// activation (an informational row), so a caller can fall back.
    pub fn fire(self: Candidate) bool {
        const f = self.activate orelse return false;
        f(self.activate_ctx, self);
        return true;
    }
};

pub const QueryFn = *const fn (
    ctx: ?*anyopaque,
    q: []const u8,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(Candidate),
) void;

/// Kick off whatever IO an async source needs for `q`. MUST NOT block:
/// the caller is the UI thread. `gen` is the `Model` generation this
/// request answers — hand it back through `Model.accepts` when the
/// reply lands so a superseded query's late reply is dropped.
pub const RefreshFn = *const fn (ctx: ?*anyopaque, q: []const u8, gen: u64) void;

pub const Source = struct {
    ctx: ?*anyopaque = null,
    /// Divide this source's raw scores by its batch maximum before
    /// weighting — for scales like frecency where only the relative
    /// order means anything.
    normalize: bool = false,
    /// Cross-source multiplier applied AFTER normalization.
    weight: f32 = 1.0,
    query: QueryFn,
    /// Stamped onto every candidate this source emits.
    activate: ?ActivateFn = null,
    /// Set only by sources whose data arrives asynchronously. `query`
    /// is still called synchronously on whatever data has landed so
    /// far, so an async source contributes nothing on the first
    /// keystroke and fills in on the reply. See `Model`.
    refresh: ?RefreshFn = null,
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
            // A source may pre-set a per-row activation (one source
            // emitting several row species); only fill the default in.
            if (cand.activate == null) {
                cand.activate = src.activate;
                cand.activate_ctx = src.ctx;
            }
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

// ── the shared model ─────────────────────────────────────────────

/// Longest query the model tracks. Anything past this is truncated
/// rather than rejected: a 512-byte suggestion query is already far
/// past the point where the ranking means anything.
pub const query_max = 512;

/// A query, a source set, and the ranked result — everything the
/// omnibox and the palette had each grown their own copy of.
///
/// **Why a shared model and NOT a shared list widget.** The obvious
/// next step from "both surfaces rank through `merge`" looks like a
/// shared suggestion-list view, and it is the wrong step. The two
/// surfaces disagree on row lifecycle for good reasons: the omnibox's
/// candidate SET changes per keystroke (history results differ per
/// query) so it rebuilds cheap GtkBox rows every time, while the
/// palette's rows are AdwActionRows carrying icon-theme lookups and
/// keybind labels, built once and thereafter only re-sorted and
/// shown/hidden. A single view would have to branch on that, on
/// popover-vs-dialog, on focus policy and on what Enter means — a pile
/// of conditionals for two call sites. Worse, it would be GTK code, so
/// everything moved into it would leave the `test-core` root. Keeping
/// the shared part GTK-free is what makes it testable at all, so the
/// split is: ONE model, two thin views.
///
/// Staleness and liveness are different problems and are solved
/// separately. `generation` answers "does this reply still answer the
/// question the user is asking?" — a pure model concern, handled here.
/// It does NOT answer "is my callback's user-data still allocated?";
/// that is the consumer's teardown mechanism (see CLAUDE.md's three
/// mechanisms), and dropping it because generations exist would be a
/// use-after-free.
pub const Model = struct {
    gpa: std.mem.Allocator,
    /// Borrowed for the model's lifetime.
    sources: []const Source,
    max: usize,
    /// The ranked result. Valid until the next merge; strings inside
    /// are borrowed from the sources.
    items: std.ArrayList(Candidate) = .empty,
    q_buf: [query_max]u8 = undefined,
    q_len: usize = 0,
    /// Bumped on every `setQuery`. Starts at 1 so a source can use 0
    /// as its "no request outstanding" sentinel.
    generation: u64 = 1,
    /// User-data for both hooks below.
    view_ctx: ?*anyopaque = null,
    /// Called immediately BEFORE the sources are queried. This is the
    /// hook for resetting the arena a consumer's sources build their
    /// candidate strings in: only the model knows when a merge starts,
    /// because an async reply triggers one without the view asking.
    /// Between this call and the merge returning, `items` holds
    /// pointers into the arena just reset — nothing reads them there.
    on_before_merge: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Called after every merge — synchronous ones and the ones an
    /// async reply triggers. This is the view's single "re-render"
    /// entry point.
    on_changed: ?*const fn (ctx: ?*anyopaque) void = null,

    pub fn init(gpa: std.mem.Allocator, sources: []const Source, max: usize) Model {
        return .{ .gpa = gpa, .sources = sources, .max = max };
    }

    pub fn deinit(self: *Model) void {
        self.items.deinit(self.gpa);
    }

    pub fn query(self: *const Model) []const u8 {
        return self.q_buf[0..self.q_len];
    }

    /// Point the model at a new query: bump the generation (so replies
    /// to the previous one stop counting), let every async source kick
    /// off its IO, then merge whatever is already available. Sources
    /// see the NEW generation, so a request issued here is live.
    pub fn setQuery(self: *Model, q: []const u8) void {
        const n = @min(q.len, self.q_buf.len);
        @memcpy(self.q_buf[0..n], q[0..n]);
        self.q_len = n;
        self.generation +%= 1;
        const gen = self.generation;
        for (self.sources) |src| {
            if (src.refresh) |kick| kick(src.ctx, self.query(), gen);
        }
        self.remerge();
    }

    /// Re-rank against the current query. Call this after an async
    /// source stores fresh data. An allocation failure shows fewer
    /// rows rather than failing the surface.
    pub fn remerge(self: *Model) void {
        if (self.on_before_merge) |hook| hook(self.view_ctx);
        merge(self.gpa, self.sources, self.query(), self.max, &self.items) catch {};
        if (self.on_changed) |hook| hook(self.view_ctx);
    }

    /// Whether a reply tagged `gen` still answers the CURRENT query.
    /// An async source checks this BEFORE storing the reply — storing
    /// a stale payload and only skipping the re-render would leave the
    /// next merge ranking answers to a question nobody asked.
    pub fn accepts(self: *const Model, gen: u64) bool {
        return gen == self.generation;
    }

    /// Dispatch row `idx`. @return false for an out-of-range index or
    /// a row whose source declared no activation.
    pub fn activate(self: *const Model, idx: usize) bool {
        if (idx >= self.items.items.len) return false;
        return self.items.items[idx].fire();
    }
};

// ── matching ─────────────────────────────────────────────────────

/// Substring match quality: 1.0 prefix, 0.8 word boundary, 0.6
/// anywhere, 0 no match. An empty query matches everything at 1.0 so
/// bare invocations keep each source's intrinsic order.
///
/// Case-insensitive (ASCII) on both sides. It used to require both
/// arguments PRE-lowercased, which every caller satisfied by
/// allocating a lowercase copy of each candidate's title and detail on
/// every keystroke; folding here deletes those allocations and makes
/// the function impossible to misuse. Passing already-lowercased text
/// still behaves identically.
///
/// ASCII-only is a real limit, not an oversight: correct Unicode
/// case-folding means `g_utf8_casefold`, and this module must stay
/// GLib-free to compile into `sketerm-mux`'s test root. A picker whose
/// data is genuinely non-ASCII (`app_switcher.zig`) is therefore
/// better off NOT adopting this — see its `matchesSearch`.
pub fn matchScore(q: []const u8, hay: []const u8) f32 {
    if (q.len == 0) return 1.0;
    const idx = std.ascii.findIgnoreCase(hay, q) orelse return 0.0;
    if (idx == 0) return 1.0;
    return if (std.ascii.isAlphanumeric(hay[idx - 1])) 0.6 else 0.8;
}

/// Combined match over a title and a secondary field (description,
/// URL): the secondary is worth 70% of a title hit.
pub fn fieldsScore(q: []const u8, title: []const u8, detail: []const u8) f32 {
    return @max(matchScore(q, title), 0.7 * matchScore(q, detail));
}

/// Case-insensitive (ASCII) substring test — the boolean half of
/// `matchScore`, for the GTK filter-func pickers that need a yes/no
/// and keep their own domain sort order.
///
/// Takes no scratch buffer and has no length ceiling on purpose: the
/// hand-rolled versions this replaces lowercased into fixed stack
/// buffers and FAILED OPEN (returned "matches") when either side
/// overflowed them.
pub fn containsFold(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.ascii.findIgnoreCase(hay, needle) != null;
}

/// Case-insensitive (ASCII) SUBSEQUENCE test: every byte of `needle`
/// occurs in `hay` in order, not necessarily adjacently — "fb" matches
/// "foo bar". Strictly more permissive than `containsFold`.
///
/// Fuzzy pickers (`editorlsp.zig`'s completion/symbol popup) need this
/// and substring matching cannot express it, so the framework carries
/// both rather than forcing one to lose capability.
pub fn subsequenceMatch(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var hi: usize = 0;
    for (needle) |nc| {
        const want = std.ascii.toLower(nc);
        while (hi < hay.len and std.ascii.toLower(hay[hi]) != want) hi += 1;
        if (hi == hay.len) return false;
        hi += 1;
    }
    return true;
}

/// Graded subsequence match on the same 0..1 scale as `matchScore`, so
/// a fuzzy source can be merged alongside substring ones.
///
/// The grade is `0.5 * tightness + 0.3 * starts_at_zero + 0.2 *
/// earliness`, which peaks at 1.0 exactly when the needle appears
/// contiguously at offset 0 — i.e. it agrees with `matchScore` on a
/// prefix hit and degrades smoothly as the match spreads out or starts
/// later. Greedy leftmost matching, so it measures ONE alignment
/// rather than searching for the best; that is what keeps it linear,
/// and for picker-length strings the difference is not visible.
pub fn subsequenceScore(q: []const u8, hay: []const u8) f32 {
    if (q.len == 0) return 1.0;
    if (hay.len == 0) return 0.0;
    var hi: usize = 0;
    var first: ?usize = null;
    var last: usize = 0;
    for (q) |nc| {
        const want = std.ascii.toLower(nc);
        while (hi < hay.len and std.ascii.toLower(hay[hi]) != want) hi += 1;
        if (hi == hay.len) return 0.0;
        if (first == null) first = hi;
        last = hi;
        hi += 1;
    }
    const start = first.?;
    const span: f32 = @floatFromInt(last - start + 1);
    const need: f32 = @floatFromInt(q.len);
    const tightness = need / span;
    const prefix: f32 = if (start == 0) 1.0 else 0.0;
    const earliness = 1.0 - (@as(f32, @floatFromInt(start)) / @as(f32, @floatFromInt(hay.len)));
    return 0.5 * tightness + 0.3 * prefix + 0.2 * earliness;
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

// ── matching: folding, substring, subsequence ────────────────────

test "matchScore folds case without pre-lowercasing" {
    // The old contract needed both sides lowercased by the caller.
    try t.expectEqual(@as(f32, 1.0), matchScore("NEW", "New Tab"));
    try t.expectEqual(@as(f32, 0.8), matchScore("Tab", "New Tab"));
    try t.expectEqual(@as(f32, 0.0), matchScore("zzz", "New Tab"));
    // Mixed case on both sides still grades identically.
    try t.expectEqual(matchScore("new", "new tab"), matchScore("NeW", "NEW TAB"));
}

test "containsFold has no length ceiling and no fail-open" {
    try t.expect(containsFold("New Tab", "tab"));
    try t.expect(containsFold("New Tab", ""));
    try t.expect(!containsFold("New Tab", "zzz"));
    try t.expect(!containsFold("short", "a much longer needle than the haystack"));
    // The hand-rolled versions this replaces lowercased into 256/512
    // byte stack buffers and returned "matches" on overflow. A long
    // non-matching needle must answer false, not true.
    const long_needle = "q" ** 600;
    const long_hay = "a" ** 900;
    try t.expect(!containsFold(long_hay, long_needle));
    try t.expect(containsFold(long_hay ++ long_needle, long_needle));
}

test "subsequenceMatch accepts non-adjacent runs that substring rejects" {
    try t.expect(subsequenceMatch("foo bar", "fb"));
    try t.expect(!containsFold("foo bar", "fb")); // the capability gap
    try t.expect(subsequenceMatch("Foo Bar", "FB"));
    try t.expect(!subsequenceMatch("foo bar", "bf")); // order matters
    try t.expect(subsequenceMatch("anything", ""));
    try t.expect(!subsequenceMatch("", "x"));
}

test "subsequenceScore peaks on a contiguous prefix and decays" {
    // Contiguous at offset 0 == a prefix hit on the substring scale.
    try t.expectApproxEqAbs(@as(f32, 1.0), subsequenceScore("new", "new tab"), 0.001);
    // Spread out and late scores strictly lower, but still non-zero.
    const spread = subsequenceScore("nt", "new tab");
    try t.expect(spread > 0.0);
    try t.expect(spread < 1.0);
    // A miss is a hard zero so `merge` drops it.
    try t.expectEqual(@as(f32, 0.0), subsequenceScore("zq", "new tab"));

    // The two grading axes, isolated. Same start, tighter run wins:
    try t.expect(subsequenceScore("ne", "new tab") > subsequenceScore("nw", "new tab"));
    // Same tightness (both contiguous), earlier start wins:
    try t.expect(subsequenceScore("new", "new tab") > subsequenceScore("tab", "new tab"));
    // Note the consequence, which is intended: a spread-out match
    // anchored at 0 can outrank a contiguous one starting late, because
    // the prefix bonus is worth more than perfect tightness.
    try t.expect(subsequenceScore("nwt", "new tab") > subsequenceScore("tab", "new tab"));
}

// ── activation ───────────────────────────────────────────────────

const Fired = struct {
    hits: usize = 0,
    last: u64 = 0,

    fn activate(ctx: ?*anyopaque, cand: Candidate) void {
        const self: *Fired = @ptrCast(@alignCast(ctx.?));
        self.hits += 1;
        self.last = cand.payload;
    }
    fn query(ctx: ?*anyopaque, q: []const u8, gpa: std.mem.Allocator, out: *std.ArrayList(Candidate)) void {
        _ = ctx;
        _ = q;
        out.append(gpa, .{ .title = "row", .kind = .command, .score = 1.0, .payload = 42 }) catch {};
    }
};

test "merge stamps activation and fire dispatches with the payload" {
    var sink = Fired{};
    const sources = [_]Source{.{ .ctx = &sink, .query = Fired.query, .activate = Fired.activate }};
    var out: std.ArrayList(Candidate) = .empty;
    defer out.deinit(t.allocator);
    try merge(t.allocator, &sources, "", 10, &out);
    try t.expectEqual(@as(usize, 1), out.items.len);
    try t.expect(out.items[0].fire());
    try t.expectEqual(@as(usize, 1), sink.hits);
    // The payload survives the merge, so a source can dispatch by index.
    try t.expectEqual(@as(u64, 42), sink.last);
}

test "a candidate whose source declares no activation does not fire" {
    var sink = Fired{};
    const sources = [_]Source{.{ .ctx = &sink, .query = Fired.query }};
    var out: std.ArrayList(Candidate) = .empty;
    defer out.deinit(t.allocator);
    try merge(t.allocator, &sources, "", 10, &out);
    try t.expect(!out.items[0].fire());
    try t.expectEqual(@as(usize, 0), sink.hits);
}

// ── the model: async staleness + hooks ───────────────────────────

/// Stands in for a daemon-backed source. `refresh` records the
/// generation instead of doing IO; `land` is the reply path.
const AsyncSrc = struct {
    model: *Model = undefined,
    kicks: usize = 0,
    last_gen: u64 = 0,
    store: [4][]const u8 = @splat(""),
    n: usize = 0,

    fn refresh(ctx: ?*anyopaque, q: []const u8, gen: u64) void {
        const self: *AsyncSrc = @ptrCast(@alignCast(ctx.?));
        _ = q;
        self.kicks += 1;
        self.last_gen = gen;
        // A new query invalidates what the previous one answered.
        self.n = 0;
    }
    fn query(ctx: ?*anyopaque, q: []const u8, gpa: std.mem.Allocator, out: *std.ArrayList(Candidate)) void {
        _ = q;
        const self: *AsyncSrc = @ptrCast(@alignCast(ctx.?));
        for (self.store[0..self.n]) |h|
            out.append(gpa, .{ .title = h, .kind = .history, .score = 1.0 }) catch {};
    }
    /// Gate on staleness BEFORE storing, then re-rank — the two-step
    /// every async source is meant to follow.
    fn land(self: *AsyncSrc, gen: u64, title: []const u8) bool {
        if (!self.model.accepts(gen)) return false;
        self.store[self.n] = title;
        self.n += 1;
        self.model.remerge();
        return true;
    }
};

test "Model kicks async sources and refuses a superseded reply" {
    var src = AsyncSrc{};
    const sources = [_]Source{.{ .ctx = &src, .query = AsyncSrc.query, .refresh = AsyncSrc.refresh }};
    var model = Model.init(t.allocator, &sources, 10);
    defer model.deinit();
    src.model = &model;

    // Generations start at 1, so 0 is free as a source's "nothing
    // outstanding" sentinel.
    try t.expectEqual(@as(u64, 1), model.generation);

    model.setQuery("ab");
    try t.expectEqual(@as(usize, 1), src.kicks);
    const gen_ab = src.last_gen;
    try t.expect(gen_ab != 0);
    // The reply has not landed, so the synchronous pass shows nothing.
    try t.expectEqual(@as(usize, 0), model.items.items.len);

    // The user keeps typing before the first reply arrives.
    model.setQuery("abc");
    try t.expectEqual(@as(usize, 2), src.kicks);
    const gen_abc = src.last_gen;
    try t.expect(gen_abc != gen_ab);

    // The superseded reply is refused outright — not merely un-rendered.
    try t.expect(!src.land(gen_ab, "stale"));
    try t.expectEqual(@as(usize, 0), model.items.items.len);

    // The live one lands and re-ranks.
    try t.expect(src.land(gen_abc, "fresh"));
    try t.expectEqual(@as(usize, 1), model.items.items.len);
    try t.expectEqualStrings("fresh", model.items.items[0].title);
    try t.expectEqualStrings("abc", model.query());
}

const Hooks = struct {
    before: usize = 0,
    changed: usize = 0,
    /// Merges observed while `on_before_merge` had already run — the
    /// ordering guarantee a consumer's arena reset depends on.
    ordered: bool = true,

    fn onBefore(ctx: ?*anyopaque) void {
        const self: *Hooks = @ptrCast(@alignCast(ctx.?));
        self.before += 1;
    }
    fn onChanged(ctx: ?*anyopaque) void {
        const self: *Hooks = @ptrCast(@alignCast(ctx.?));
        if (self.before != self.changed + 1) self.ordered = false;
        self.changed += 1;
    }
};

test "Model runs the arena-reset hook before every merge and the render hook after" {
    var src = AsyncSrc{};
    var hooks = Hooks{};
    const sources = [_]Source{.{ .ctx = &src, .query = AsyncSrc.query, .refresh = AsyncSrc.refresh }};
    var model = Model.init(t.allocator, &sources, 10);
    defer model.deinit();
    src.model = &model;
    model.view_ctx = &hooks;
    model.on_before_merge = Hooks.onBefore;
    model.on_changed = Hooks.onChanged;

    model.setQuery("a");
    try t.expectEqual(@as(usize, 1), hooks.changed);
    // An async reply merges again WITHOUT the view asking, which is
    // exactly why the arena reset cannot live in the view's own code.
    try t.expect(src.land(src.last_gen, "hit"));
    try t.expectEqual(@as(usize, 2), hooks.before);
    try t.expectEqual(@as(usize, 2), hooks.changed);
    try t.expect(hooks.ordered);
}

test "Model.activate dispatches the ranked row and rejects a bad index" {
    var sink = Fired{};
    const sources = [_]Source{.{ .ctx = &sink, .query = Fired.query, .activate = Fired.activate }};
    var model = Model.init(t.allocator, &sources, 10);
    defer model.deinit();
    model.setQuery("");
    try t.expectEqual(@as(usize, 1), model.items.items.len);
    try t.expect(model.activate(0));
    try t.expectEqual(@as(usize, 1), sink.hits);
    try t.expect(!model.activate(7));
    try t.expectEqual(@as(usize, 1), sink.hits);
}

test "a query longer than query_max is truncated, not rejected" {
    var src = AsyncSrc{};
    const sources = [_]Source{.{ .ctx = &src, .query = AsyncSrc.query, .refresh = AsyncSrc.refresh }};
    var model = Model.init(t.allocator, &sources, 10);
    defer model.deinit();
    src.model = &model;
    const huge = "x" ** (query_max + 64);
    model.setQuery(huge);
    try t.expectEqual(@as(usize, query_max), model.query().len);
}
