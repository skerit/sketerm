//! GTK-free display formatting for file-browser labels.

const std = @import("std");
const c = @import("../c.zig").c;
const strz = @import("../util/strz.zig");
const clock = @import("../util/clock.zig");

/// A readable, deterministic color for a tag set.
pub fn tagColorHex(tags: []const u8) []const u8 {
    const palette = [_][]const u8{
        "#e05050", "#d08030", "#a0a020", "#40a040",
        "#30a0a0", "#5080e0", "#9060d0", "#d060a0",
    };
    var h = std.hash.Wyhash.init(7);
    h.update(tags);
    return palette[@intCast(h.final() % palette.len)];
}

/// Truncating copy into a sentinel buffer of any size (`*[N:0]u8`).
pub const copyZN = strz.copyZ;

/// Truncating copy into a 256-byte sentinel buffer for GTK label text.
/// Callers with a differently sized buffer use copyZN; this signature
/// stays concrete so `@ptrCast(&buf)` arguments keep a result type.
pub fn copyZ(buf: *[256:0]u8, text: []const u8) [*:0]const u8 {
    return copyZN(buf, text);
}

pub fn fmtSize(buf: *[48:0]u8, size: u64) [:0]const u8 {
    const s = if (size >= (1 << 30))
        std.fmt.bufPrintZ(buf, "{d:.1} GB", .{@as(f64, @floatFromInt(size)) / (1 << 30)}) catch "?"
    else if (size >= (1 << 20))
        std.fmt.bufPrintZ(buf, "{d:.1} MB", .{@as(f64, @floatFromInt(size)) / (1 << 20)}) catch "?"
    else if (size >= 1024)
        std.fmt.bufPrintZ(buf, "{d:.1} KB", .{@as(f64, @floatFromInt(size)) / 1024}) catch "?"
    else
        std.fmt.bufPrintZ(buf, "{d} B", .{size}) catch "?";
    return @ptrCast(s);
}

pub fn fmtModeZ(buf: *[16:0]u8, mode: u32, is_dir: bool) [*:0]const u8 {
    const bits = [_]u8{ 'r', 'w', 'x' };
    buf[0] = if (is_dir) 'd' else '-';
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        const on = (mode >> @intCast(8 - i)) & 1 == 1;
        buf[1 + i] = if (on) bits[i % 3] else '-';
    }
    buf[10] = 0;
    return @ptrCast(buf);
}

/// The daemon's fs_reply `error` field made readable.
///
/// The daemon answers with the errno TAG (`fsserve.errnoName` =
/// `@tagName` of `std.posix.E`), which is the real reason but reads
/// like a compiler message. Anything that is not a tag we know passes
/// through byte for byte: an unrecognised reason must never be
/// replaced by a guess.
pub fn errorPhrase(daemon_error: []const u8) []const u8 {
    const map = [_]struct { tag: []const u8, phrase: []const u8 }{
        .{ .tag = "NOENT", .phrase = "no such file or directory" },
        .{ .tag = "ACCES", .phrase = "permission denied" },
        .{ .tag = "PERM", .phrase = "operation not permitted" },
        .{ .tag = "NOTDIR", .phrase = "not a directory" },
        .{ .tag = "ISDIR", .phrase = "is a directory" },
        .{ .tag = "LOOP", .phrase = "too many symbolic links" },
        .{ .tag = "NAMETOOLONG", .phrase = "path too long" },
        .{ .tag = "NOTEMPTY", .phrase = "directory not empty" },
        .{ .tag = "EXIST", .phrase = "already exists" },
        .{ .tag = "NOSPC", .phrase = "no space left on device" },
        .{ .tag = "ROFS", .phrase = "read-only filesystem" },
        .{ .tag = "XDEV", .phrase = "different filesystem" },
        .{ .tag = "IO", .phrase = "I/O error" },
        .{ .tag = "NFILE", .phrase = "too many open files" },
        .{ .tag = "MFILE", .phrase = "too many open files" },
        .{ .tag = "STALE", .phrase = "stale file handle" },
        .{ .tag = "NOMEM", .phrase = "out of memory" },
    };
    for (map) |m| {
        if (std.mem.eql(u8, daemon_error, m.tag)) return m.phrase;
    }
    if (daemon_error.len == 0) return "the daemon gave no reason";
    return daemon_error;
}

/// What an empty-looking listing area actually MEANS. A failed
/// listing, a directory that cannot be read, a query with no hits and
/// a genuinely empty folder are four different states, and the whole
/// point of naming them is that they must never share wording.
pub const ListingState = enum {
    /// The request is out; no reply yet.
    listing,
    /// The listing was refused, and `Dir.load_error` says why.
    failed,
    /// A real, readable, empty directory.
    empty,
    /// A search / panelize / register tab whose rows are its results.
    no_matches,
    /// Rows are present; the listing area speaks for itself.
    populated,
};

/// Classify a listing from the four facts that decide it.
/// `flat` marks result rows (search, panelize, registers) rather than
/// a directory's children, which is what separates "no matches" from
/// "empty folder".
pub fn listingState(loaded: bool, failed: bool, flat: bool, count: usize) ListingState {
    if (failed) return .failed;
    if (count > 0) return .populated;
    if (!loaded) return .listing;
    return if (flat) .no_matches else .empty;
}

/// The headline for an empty listing area. `.failed` has none: the
/// reason from the daemon is the headline, and inventing a second one
/// would compete with it.
pub fn listingHeadline(state: ListingState) []const u8 {
    return switch (state) {
        .listing => "Listing...",
        .failed => "",
        .empty => "Empty folder",
        .no_matches => "No matches",
        .populated => "",
    };
}

/// The status-bar phrase for a listing with no rows, in the SAME
/// words as the placeholder so the two can never disagree.
pub fn listingStatus(state: ListingState) []const u8 {
    return switch (state) {
        .listing => "listing...",
        .failed => "",
        .empty => "Empty folder - 0 items",
        .no_matches => "No matches - 0 items",
        .populated => "",
    };
}

/// A file's mtime as `YYYY-MM-DD HH:MM` in local time; an empty
/// string when it has no local representation (the cell just stays
/// blank rather than showing a placeholder).
pub fn fmtTimeZ(buf: *[40:0]u8, ms: i64) [*:0]const u8 {
    const s = clock.localStamp(buf[0 .. buf.len - 1], ms) orelse return "";
    buf[s.len] = 0;
    return @ptrCast(buf);
}

test "fmtSize picks the unit by threshold" {
    const t = std.testing;
    var buf: [48:0]u8 = undefined;
    try t.expectEqualStrings("0 B", fmtSize(&buf, 0));
    try t.expectEqualStrings("1023 B", fmtSize(&buf, 1023));
    try t.expectEqualStrings("1.0 KB", fmtSize(&buf, 1024));
    try t.expectEqualStrings("1.5 KB", fmtSize(&buf, 1536));
    try t.expectEqualStrings("1.0 MB", fmtSize(&buf, 1 << 20));
    try t.expectEqualStrings("2.0 GB", fmtSize(&buf, 2 << 30));
}

test "fmtModeZ renders an ls-style permission string" {
    const t = std.testing;
    var buf: [16:0]u8 = undefined;
    try t.expectEqualStrings("-rwxr-xr-x", std.mem.span(fmtModeZ(&buf, 0o755, false)));
    try t.expectEqualStrings("drwx------", std.mem.span(fmtModeZ(&buf, 0o700, true)));
    try t.expectEqualStrings("----------", std.mem.span(fmtModeZ(&buf, 0, false)));
    // Only the low 9 bits are shown; setuid and the S_IFREG type bits
    // do not leak into the triples.
    try t.expectEqualStrings("-rwxr-xr-x", std.mem.span(fmtModeZ(&buf, 0o104755, false)));
}

test "fmtTimeZ produces a fixed-width local timestamp" {
    const t = std.testing;
    var buf: [40:0]u8 = undefined;
    const s = std.mem.span(fmtTimeZ(&buf, 1_000_000_000_000));
    // "YYYY-MM-DD HH:MM" -- the exact value is timezone dependent, the
    // shape is not.
    try t.expectEqual(@as(usize, 16), s.len);
    try t.expectEqual(@as(u8, '-'), s[4]);
    try t.expectEqual(@as(u8, '-'), s[7]);
    try t.expectEqual(@as(u8, ' '), s[10]);
    try t.expectEqual(@as(u8, ':'), s[13]);
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15 }) |i|
        try t.expect(std.ascii.isDigit(s[i]));
}

test "tagColorHex is deterministic and stays in the palette" {
    const t = std.testing;
    const a = tagColorHex("work");
    try t.expectEqualStrings(a, tagColorHex("work"));
    try t.expect(!std.mem.eql(u8, a, tagColorHex("work,urgent")));
    try t.expectEqual(@as(usize, 7), a.len);
    try t.expectEqual(@as(u8, '#'), a[0]);
    for (a[1..]) |ch| try t.expect(std.ascii.isHex(ch));
}

test "errorPhrase reads out errno tags and passes anything else through" {
    const t = std.testing;
    try t.expectEqualStrings("no such file or directory", errorPhrase("NOENT"));
    try t.expectEqualStrings("permission denied", errorPhrase("ACCES"));
    try t.expectEqualStrings("not a directory", errorPhrase("NOTDIR"));
    // The daemon also sends prose for its own refusals; it must
    // survive verbatim rather than be replaced by a guess.
    try t.expectEqualStrings("path must be absolute", errorPhrase("path must be absolute"));
    try t.expectEqualStrings("view id in use", errorPhrase("view id in use"));
    // A reply with an empty error field still has to say something.
    try t.expect(errorPhrase("").len > 0);
}

test "listingState separates a failure from an empty folder" {
    const t = std.testing;
    // The exact case Jelle hit: a refused listing must NOT classify as
    // an empty directory, whatever `loaded` ended up as.
    try t.expectEqual(ListingState.failed, listingState(false, true, false, 0));
    try t.expectEqual(ListingState.failed, listingState(true, true, false, 0));
    try t.expectEqual(ListingState.listing, listingState(false, false, false, 0));
    try t.expectEqual(ListingState.empty, listingState(true, false, false, 0));
    try t.expectEqual(ListingState.no_matches, listingState(true, false, true, 0));
    try t.expectEqual(ListingState.populated, listingState(true, false, false, 3));
    // Rows present but a failure recorded: the failure wins, since it
    // is the newer fact about the listing.
    try t.expectEqual(ListingState.failed, listingState(true, true, false, 3));

    // No two states may share their wording, in either surface.
    const states = [_]ListingState{ .listing, .failed, .empty, .no_matches, .populated };
    for (states, 0..) |a, i| {
        for (states[i + 1 ..]) |b| {
            const ha = listingHeadline(a);
            const hb = listingHeadline(b);
            if (ha.len > 0 and hb.len > 0) try t.expect(!std.mem.eql(u8, ha, hb));
            const sa = listingStatus(a);
            const sb = listingStatus(b);
            if (sa.len > 0 and sb.len > 0) try t.expect(!std.mem.eql(u8, sa, sb));
        }
    }
    // "0 items" alone was the old, dishonest message; both empty-ish
    // states must say more than the count.
    try t.expect(!std.mem.eql(u8, "0 items", listingStatus(.empty)));
    try t.expect(!std.mem.eql(u8, "0 items", listingStatus(.no_matches)));
}

test "copyZ truncates instead of overflowing" {
    const t = std.testing;
    var buf: [256:0]u8 = undefined;
    try t.expectEqualStrings("hi", std.mem.span(copyZ(&buf, "hi")));
    const long = "x" ** 300;
    try t.expectEqual(@as(usize, 255), std.mem.span(copyZ(&buf, long)).len);
    // copyZN takes any sentinel buffer size, not just 256.
    var wide: [512:0]u8 = undefined;
    try t.expectEqual(@as(usize, 300), std.mem.span(copyZN(&wide, long)).len);
}

/// Natural (version-aware) case-insensitive name order: digit runs
/// compare as numbers, so "file2" < "file10". Equal-value runs with
/// different zero-padding, and case-insensitively equal names, break
/// the tie bytewise for a strict deterministic order.
pub fn naturalLess(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const da = std.ascii.isDigit(a[i]);
        const db = std.ascii.isDigit(b[j]);
        if (da and db) {
            var zi = i;
            while (zi < a.len and a[zi] == '0') zi += 1;
            var zj = j;
            while (zj < b.len and b[zj] == '0') zj += 1;
            var ei = zi;
            while (ei < a.len and std.ascii.isDigit(a[ei])) ei += 1;
            var ej = zj;
            while (ej < b.len and std.ascii.isDigit(b[ej])) ej += 1;
            if (ei - zi != ej - zj) return ei - zi < ej - zj;
            const ord = std.mem.order(u8, a[zi..ei], b[zj..ej]);
            if (ord != .eq) return ord == .lt;
            if (ei - i != ej - j) return ei - i < ej - j;
            i = ei;
            j = ej;
            continue;
        }
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[j]);
        if (ca != cb) return ca < cb;
        i += 1;
        j += 1;
    }
    if (a.len - i != b.len - j) return a.len - i < b.len - j;
    return std.mem.lessThan(u8, a, b);
}

test "naturalLess orders digit runs numerically" {
    const t = std.testing;
    try t.expect(naturalLess("file2.txt", "file10.txt"));
    try t.expect(!naturalLess("file10.txt", "file2.txt"));
    try t.expect(naturalLess("file9", "file10"));
    try t.expect(naturalLess("2", "10"));
    try t.expect(naturalLess("img001", "img2") == naturalLess("img1", "img2"));
    // Case-insensitive on the text parts.
    try t.expect(naturalLess("Alpha", "beta"));
    try t.expect(naturalLess("alpha", "Beta"));
    // Equal numeric value, different padding: deterministic, not equal-both-ways.
    try t.expect(naturalLess("a01", "a1") != naturalLess("a1", "a01"));
    // Prefix orders before its extension.
    try t.expect(naturalLess("file", "file2"));
    // Plain text still ordinary.
    try t.expect(naturalLess("apple", "banana"));
    try t.expect(!naturalLess("banana", "apple"));
}
