//! Subscription bookkeeping for the content-blocking filter lists:
//! which file a subscribed url caches as, whether that cache is due for
//! a refetch, and whether a downloaded body is plausibly a filter list
//! at all.
//!
//! Deliberately PURE — no CEF, no GTK, no allocator, no IO (the one
//! import, `util/atomicwrite.zig`, is used only for its stage-name
//! vocabulary, never to touch the disk) — because
//! these are the decisions that can OVERWRITE a working filter file,
//! and they should be provable without a network or a browser. The
//! fetch itself lives in `cefhost.zig`: the helper is the only process
//! in this project with an HTTPS stack (the daemon is libc-only).
//!
//! Compiled into the helper AND both test roots.

const std = @import("std");
const atomicwrite = @import("../util/atomicwrite.zig");

/// Longest cache file name produced by `cacheName`.
pub const MAX_NAME = 96;

/// Our files are prefixed so a subscription can never overwrite a list
/// the user dropped into the directory by hand.
pub const PREFIX = "sub-";

/// Whether a subscription URL is representable on the wire and safe to
/// hand to the helper's network stack.
pub fn validUrl(url: []const u8) bool {
    if (url.len == 0 or url.len > std.math.maxInt(u16)) return false;
    for (url) |ch| {
        if (std.ascii.isControl(ch) or std.ascii.isWhitespace(ch)) return false;
    }
    const parsed = std.Uri.parse(url) catch return false;
    if (!(std.mem.eql(u8, parsed.scheme, "http") or std.mem.eql(u8, parsed.scheme, "https"))) return false;
    return if (parsed.host) |host| !host.isEmpty() else false;
}

fn slugInto(url: []const u8, out: []u8) usize {
    // The last path segment, minus any query/fragment and extension.
    var s = url;
    if (std.mem.indexOfAny(u8, s, "?#")) |i| s = s[0..i];
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| s = s[i + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, s, '.')) |i| {
        if (i != 0) s = s[0..i];
    }
    var n: usize = 0;
    for (s) |ch| {
        if (n == out.len) break;
        const lower = std.ascii.toLower(ch);
        if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9')) {
            out[n] = lower;
            n += 1;
        } else if (n != 0 and out[n - 1] != '-') {
            out[n] = '-';
            n += 1;
        }
    }
    while (n != 0 and out[n - 1] == '-') n -= 1;
    return n;
}

/// Cache file name for a subscription url.
///
/// The HASH is what makes this correct; the slug only makes the
/// directory legible to a human. Two urls that differ anywhere outside
/// the last segment — `…/easylist.txt` and `…/other/easylist.txt` —
/// must never collide, or one subscription silently serves the other's
/// rules and the user cannot see why.
///
/// Ends in `.txt` because that is what `interceptReload` scans for, so
/// a fetched list is picked up by the ordinary directory walk with no
/// second code path.
pub fn cacheName(url: []const u8, buf: []u8) error{NoSpace}![]const u8 {
    var slug_buf: [32]u8 = undefined;
    const slug_len = slugInto(url, &slug_buf);
    const slug: []const u8 = if (slug_len == 0) "list" else slug_buf[0..slug_len];
    const h = std.hash.Wyhash.hash(0x5e7e33a1, url);
    return std.fmt.bufPrint(buf, PREFIX ++ "{s}-{x:0>16}.txt", .{ slug, h }) catch
        return error.NoSpace;
}

/// Whether `name` is one of ours (so a reconcile can delete the cache
/// files of subscriptions the user removed, without touching theirs).
pub fn isCacheName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, PREFIX) or !std.mem.endsWith(u8, name, ".txt")) return false;
    const stem = name[PREFIX.len .. name.len - ".txt".len];
    const dash = std.mem.lastIndexOfScalar(u8, stem, '-') orelse return false;
    if (dash == 0 or stem.len - dash - 1 != 16) return false;
    const slug = stem[0..dash];
    if (slug.len > 32 or slug[0] == '-' or slug[slug.len - 1] == '-') return false;
    var prev_dash = false;
    for (slug) |ch| {
        if (ch == '-') {
            if (prev_dash) return false;
            prev_dash = true;
        } else {
            if (!((ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9'))) return false;
            prev_dash = false;
        }
    }
    for (stem[dash + 1 ..]) |ch| {
        if (!std.ascii.isHex(ch) or std.ascii.isUpper(ch)) return false;
    }
    return true;
}

/// Whether `name` is the staging sibling of one of our cache files.
///
/// The stage-name format belongs to `util/atomicwrite.zig` (the only thing
/// that writes one); recognising it by hand here is how orphaned stages
/// stopped being collected once the writer was shared.
pub fn isStageName(name: []const u8) bool {
    const base = atomicwrite.stageBaseName(name) orelse return false;
    return isCacheName(base);
}

/// The cache file a staging sibling belongs to, or null.
pub fn stageCacheName(name: []const u8) ?[]const u8 {
    const base = atomicwrite.stageBaseName(name) orelse return null;
    return if (isCacheName(base)) base else null;
}

/// Is a cache file due for a refetch?
///
/// `mtime_s <= 0` means "no file", which is always due. A file dated in
/// the FUTURE counts as fresh rather than stale: a clock that jumped
/// backwards must not turn every startup into a refetch storm against
/// somebody else's server.
pub fn isStale(now_s: i64, mtime_s: i64, interval_hours: u32) bool {
    if (interval_hours == 0) return false; // updates disabled
    if (mtime_s <= 0) return true; // never fetched
    if (mtime_s > now_s) return false; // clock skew
    const age = now_s - mtime_s;
    return age >= @as(i64, interval_hours) * 3600;
}

/// Does this body look like an EasyList-syntax filter list?
///
/// A captive portal, a proxy error page and an HTML 404 all arrive as a
/// perfectly successful fetch. Writing one of those over a working list
/// disables blocking with no error anywhere, so a body has to look like
/// what it claims before it is allowed to replace anything.
pub fn looksLikeFilterList(body: []const u8) bool {
    if (body.len < 16) return false;
    const head = body[0..@min(body.len, 1024)];
    // HTML, however it opens.
    var i: usize = 0;
    while (i < head.len and std.ascii.isWhitespace(head[i])) i += 1;
    if (i < head.len and head[i] == '<') return false;
    if (std.ascii.indexOfIgnoreCase(head, "<html") != null) return false;
    if (std.ascii.indexOfIgnoreCase(head, "<!doctype") != null) return false;

    // The conventional header is enough on its own.
    if (std.ascii.indexOfIgnoreCase(head, "[adblock") != null) return true;

    // Otherwise want several lines that are actually rules or comments.
    var rules: u32 = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '!' or line[0] == '[') {
            rules += 1;
        } else if (std.mem.startsWith(u8, line, "||") or
            std.mem.startsWith(u8, line, "@@") or
            std.mem.indexOf(u8, line, "##") != null or
            std.mem.startsWith(u8, line, "/") or
            std.mem.indexOfScalar(u8, line, '^') != null)
        {
            rules += 1;
        }
        if (rules >= 5) return true;
    }
    return false;
}

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

test "cacheName is stable, readable and collision-free on the tail" {
    var a: [MAX_NAME]u8 = undefined;
    var b: [MAX_NAME]u8 = undefined;
    const one = try cacheName("https://easylist.to/easylist/easylist.txt", &a);
    const two = try cacheName("https://example.com/other/easylist.txt", &b);
    try t.expect(std.mem.startsWith(u8, one, "sub-easylist-"));
    try t.expect(std.mem.endsWith(u8, one, ".txt"));
    // Same last segment, different url: MUST NOT collide.
    try t.expect(!std.mem.eql(u8, one, two));
    // Stable across calls.
    var c_buf: [MAX_NAME]u8 = undefined;
    const again = try cacheName("https://easylist.to/easylist/easylist.txt", &c_buf);
    try t.expectEqualStrings(one, again);
}

test "cacheName copes with a url that has no usable segment" {
    var buf: [MAX_NAME]u8 = undefined;
    const n = try cacheName("https://example.com/", &buf);
    try t.expect(std.mem.startsWith(u8, n, "sub-list-"));
    const q = try cacheName("https://example.com/l.txt?v=2#x", &buf);
    try t.expect(std.mem.startsWith(u8, q, "sub-l-"));
    try t.expect(isCacheName(q));
    try t.expect(!isCacheName("my-own-rules.txt"));
    try t.expect(!isCacheName("sub-my-own-rules.txt"));
    try t.expect(!isCacheName("sub--0000000000000000.txt"));
    try t.expect(!isCacheName("sub-list--0000000000000000.txt"));
    try t.expect(!isCacheName("sub-abcdefghijklmnopqrstuvwxyz1234567-0000000000000000.txt"));
    try t.expect(!isCacheName("sub-list-000000000000000g.txt"));
    try t.expect(!isCacheName("sub-list-000000000000000A.txt"));
    // Derive the stage name from the writer that produces it: a
    // hand-built one passed while the sweeper matched nothing real.
    var stage_buf: atomicwrite.StageBuf = undefined;
    const stage = try atomicwrite.stagePath(&stage_buf, q);
    try t.expect(isStageName(stage));
    try t.expectEqualStrings(q, stageCacheName(stage).?);
    var mine_buf: atomicwrite.StageBuf = undefined;
    const mine = try atomicwrite.stagePath(&mine_buf, "sub-my-own-rules.txt");
    try t.expect(!isStageName(mine));
    try t.expect(stageCacheName(mine) == null);
    try t.expect(!isStageName(q));
}

test "validUrl accepts only bounded HTTP subscription URLs with a host" {
    try t.expect(validUrl("https://easylist.to/easylist/easylist.txt"));
    try t.expect(validUrl("http://127.0.0.1:8080/list.txt?revision=2"));
    try t.expect(!validUrl("file:///tmp/list.txt"));
    try t.expect(!validUrl("HTTPS://example.com/list.txt"));
    try t.expect(!validUrl("https:///list.txt"));
    try t.expect(!validUrl("https://example.com:bad/list.txt"));
    try t.expect(!validUrl("https://example.com:99999/list.txt"));
    try t.expect(!validUrl("https://[::1/list.txt"));
    try t.expect(!validUrl("https://example.com/list\nnext"));
    const oversized = [_]u8{'a'} ** (std.math.maxInt(u16) + 1);
    try t.expect(!validUrl(&oversized));
}

test "isStale: disabled, missing, aged and a backwards clock" {
    const now: i64 = 1_000_000;
    try t.expect(!isStale(now, 0, 0)); // interval 0 = never update
    try t.expect(isStale(now, 0, 24)); // no file yet
    try t.expect(!isStale(now, now - 3600, 24)); // an hour old, want 24
    try t.expect(isStale(now, now - 24 * 3600, 24)); // exactly due
    try t.expect(isStale(now, now - 48 * 3600, 24)); // overdue
    // A file from the future must not cause a refetch storm.
    try t.expect(!isStale(now, now + 5000, 1));
}

test "looksLikeFilterList refuses the pages a fetch really returns" {
    try t.expect(!looksLikeFilterList("<!DOCTYPE html><html><body>Sign in</body></html>"));
    try t.expect(!looksLikeFilterList("  <html><head><title>404</title></head></html>"));
    try t.expect(!looksLikeFilterList(""));
    try t.expect(!looksLikeFilterList("nope"));
    // A portal that answers 200 with prose is not a list.
    try t.expect(!looksLikeFilterList("You must accept the terms before browsing the internet."));

    try t.expect(looksLikeFilterList("[Adblock Plus 2.0]\n! Title: Test\n||ads.example.com^\n"));
    try t.expect(looksLikeFilterList(
        \\! Title: handwritten
        \\||ads.example.com^
        \\||tracker.example.net^
        \\@@||good.example.com^
        \\example.com##.banner
        \\
    ));
}
