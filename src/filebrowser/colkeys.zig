//! Extra listing columns: the ones a user adds by KEY instead of
//! picking from the fixed set.
//!
//! Two very different fetch paths feed them -- an extended attribute
//! rides the listing itself, media metadata arrives from a batched
//! `media_meta` job -- but they are ONE column mechanism, so this
//! module owns everything a key means: which source fetches it, what
//! its values are (text, a number, a timestamp), how they order, and
//! what a header calls it.
//!
//! Deliberately GTK-free and allocator-free. The comparator is the
//! part that must be a strict weak ordering, and that is only
//! provable in isolation: a comparator that is not one silently
//! corrupts std.mem.sort's output rather than failing.

const std = @import("std");
const fsserve = @import("../mux/fsserve.zig");

/// Which fetch path owns a column key.
pub const Source = enum {
    /// Value rides the listing (the daemon lgetxattr's it per entry).
    xattr,
    /// Value comes from a batched media_meta job, asynchronously.
    media,
};

/// How a column's raw values compare.
pub const ValueKind = enum {
    /// Case-insensitive byte order.
    text,
    /// Base-10 integer ("9" before "10").
    integer,
    /// Decimal number (2.8, -0.5).
    decimal,
    /// "1/250" or a plain decimal, ordered as the quotient.
    ratio,
    /// "YYYY-MM-DD HH:MM:SS", ordered chronologically.
    timestamp,
};

/// A key with a meaning beyond "some text": its ordering and the
/// title its header shows. Keys absent here are `.text` and titled
/// by their trailing segment.
pub const Known = struct {
    key: []const u8,
    kind: ValueKind,
    title: []const u8,
};

/// Public so the column picker can offer every known metadata column
/// as a checkbox instead of a type-the-key entry.
pub const KNOWN = [_]Known{
    .{ .key = "media.kind", .kind = .text, .title = "Media" },
    .{ .key = "media.format", .kind = .text, .title = "Format" },
    .{ .key = "media.codec", .kind = .text, .title = "Codec" },
    .{ .key = "media.width", .kind = .integer, .title = "Width" },
    .{ .key = "media.height", .kind = .integer, .title = "Height" },
    .{ .key = "media.duration_ms", .kind = .integer, .title = "Duration" },
    .{ .key = "media.duration_estimated", .kind = .text, .title = "Duration estimated" },
    .{ .key = "media.bitrate_kbps", .kind = .integer, .title = "Bitrate" },
    .{ .key = "media.sample_rate", .kind = .integer, .title = "Sample rate" },
    .{ .key = "media.channels", .kind = .integer, .title = "Channels" },
    .{ .key = "media.bit_depth", .kind = .integer, .title = "Bit depth" },
    .{ .key = "image.orientation", .kind = .integer, .title = "Orientation" },
    .{ .key = "tag.title", .kind = .text, .title = "Title" },
    .{ .key = "tag.artist", .kind = .text, .title = "Artist" },
    .{ .key = "tag.album", .kind = .text, .title = "Album" },
    .{ .key = "tag.album_artist", .kind = .text, .title = "Album artist" },
    .{ .key = "tag.composer", .kind = .text, .title = "Composer" },
    .{ .key = "tag.comment", .kind = .text, .title = "Comment" },
    .{ .key = "tag.genre", .kind = .text, .title = "Genre" },
    .{ .key = "tag.year", .kind = .integer, .title = "Year" },
    .{ .key = "tag.track", .kind = .integer, .title = "Track" },
    .{ .key = "tag.track_total", .kind = .integer, .title = "Tracks" },
    .{ .key = "tag.disc", .kind = .integer, .title = "Disc" },
    .{ .key = "exif.datetime_original", .kind = .timestamp, .title = "Taken" },
    .{ .key = "exif.datetime", .kind = .timestamp, .title = "EXIF date" },
    .{ .key = "exif.make", .kind = .text, .title = "Camera make" },
    .{ .key = "exif.model", .kind = .text, .title = "Camera" },
    .{ .key = "exif.lens", .kind = .text, .title = "Lens" },
    .{ .key = "exif.exposure_time", .kind = .ratio, .title = "Exposure" },
    .{ .key = "exif.f_number", .kind = .decimal, .title = "Aperture" },
    .{ .key = "exif.iso", .kind = .integer, .title = "ISO" },
    .{ .key = "exif.focal_length", .kind = .decimal, .title = "Focal length" },
    .{ .key = "exif.gps_lat", .kind = .decimal, .title = "Latitude" },
    .{ .key = "exif.gps_lon", .kind = .decimal, .title = "Longitude" },
    .{ .key = "doc.pages", .kind = .integer, .title = "Pages" },
    .{ .key = "doc.version", .kind = .text, .title = "Version" },
    .{ .key = "doc.title", .kind = .text, .title = "Title" },
    .{ .key = "doc.author", .kind = .text, .title = "Author" },
    .{ .key = "doc.producer", .kind = .text, .title = "Producer" },
    .{ .key = "doc.page_size", .kind = .text, .title = "Page size" },
};

/// Namespaces the media_meta job answers for (src/mux/mediameta.zig).
const MEDIA_NAMESPACES = [_][]const u8{ "media.", "tag.", "exif.", "image.", "doc." };

/// @return null when `key` is not a usable column key at all, which
/// is what the column picker rejects.
pub fn sourceOf(key: []const u8) ?Source {
    if (std.mem.startsWith(u8, key, "user.")) return .xattr;
    for (MEDIA_NAMESPACES) |ns| {
        if (std.mem.startsWith(u8, key, ns)) return .media;
    }
    return null;
}

fn known(key: []const u8) ?Known {
    for (KNOWN) |k| {
        if (std.mem.eql(u8, k.key, key)) return k;
    }
    return null;
}

pub fn kindOf(key: []const u8) ValueKind {
    return if (known(key)) |k| k.kind else .text;
}

/// Header/row title for a key: the agreed name where there is one,
/// otherwise the key minus its namespace.
pub fn label(key: []const u8) []const u8 {
    if (known(key)) |k| return k.title;
    if (std.mem.eql(u8, key, fsserve.TAGS_XATTR)) return "Tags";
    if (std.mem.eql(u8, key, "user.xdg.comment")) return "Comment";
    if (std.mem.eql(u8, key, "user.xdg.origin.url")) return "Where from";
    if (std.mem.eql(u8, key, "user.xdg.referrer.url")) return "Referrer";
    if (std.mem.startsWith(u8, key, "user.sketerm.")) return key["user.sketerm.".len..];
    if (std.mem.startsWith(u8, key, "user.")) return key["user.".len..];
    if (std.mem.indexOfScalar(u8, key, '.')) |dot| return key[dot + 1 ..];
    return key;
}

// --- ordering --------------------------------------------------

/// A value reduced to the one thing it can be compared as. Values
/// that do not parse as their column's type rank `.missing`: mixing
/// numeric and lexical comparison inside one column destroys
/// transitivity (9 < 10 numerically but "10" < "1x" < "9" textually),
/// and a comparator that is not a strict weak ordering corrupts the
/// sort rather than merely misordering a row.
const Ranked = union(enum) {
    missing,
    num: f64,
    text: []const u8,
};

fn rank(kind: ValueKind, v: []const u8) Ranked {
    if (v.len == 0) return .missing;
    return switch (kind) {
        .text => .{ .text = v },
        .integer, .decimal => if (parseNumber(v)) |n| .{ .num = n } else .missing,
        .ratio => if (parseRatio(v)) |n| .{ .num = n } else .missing,
        .timestamp => if (parseStamp(v)) |n| .{ .num = n } else .missing,
    };
}

/// @return null for anything non-finite too: a NaN in a comparator
/// is never ordered, not even against itself.
fn parseNumber(v: []const u8) ?f64 {
    const n = std.fmt.parseFloat(f64, v) catch return null;
    if (std.math.isNan(n) or std.math.isInf(n)) return null;
    return n;
}

fn parseRatio(v: []const u8) ?f64 {
    const slash = std.mem.indexOfScalar(u8, v, '/') orelse return parseNumber(v);
    const num = parseNumber(v[0..slash]) orelse return null;
    const den = parseNumber(v[slash + 1 ..]) orelse return null;
    if (den == 0) return null;
    return num / den;
}

/// Digits in order as YYYYMMDDHHMMSS, zero-filling a value that stops
/// early, so a date-only stamp orders before the same date with a
/// time. Fewer than a full date's worth of digits is not a timestamp.
fn parseStamp(v: []const u8) ?f64 {
    var digits: [14]u8 = @splat('0');
    var n: usize = 0;
    for (v) |ch| {
        if (!std.ascii.isDigit(ch)) continue;
        if (n >= digits.len) break;
        digits[n] = ch;
        n += 1;
    }
    if (n < 8) return null;
    const packed_stamp = std.fmt.parseInt(u64, &digits, 10) catch return null;
    return @floatFromInt(packed_stamp);
}

fn isMissing(r: Ranked) bool {
    return switch (r) {
        .missing => true,
        else => false,
    };
}

fn orderCaseless(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |ca, cb| {
        const la = std.ascii.toLower(ca);
        const lb = std.ascii.toLower(cb);
        if (la != lb) return if (la < lb) .lt else .gt;
    }
    return std.math.order(a.len, b.len);
}

/// Order two raw column values.
///
/// A row WITHOUT a value sorts last in BOTH directions, so the
/// presence test happens before the descending swap: absence is not
/// "smallest". Descending inverts by swapping the operands rather
/// than negating the result.
pub fn order(kind: ValueKind, a: []const u8, b: []const u8, desc: bool) std.math.Order {
    const ra = rank(kind, a);
    const rb = rank(kind, b);
    if (isMissing(ra) or isMissing(rb)) {
        if (isMissing(ra) and isMissing(rb)) return .eq;
        return if (isMissing(ra)) .gt else .lt;
    }
    const x = if (desc) rb else ra;
    const y = if (desc) ra else rb;
    return switch (x) {
        // Handled above; a column has one kind, so a numeric and a
        // textual rank never meet in practice either.
        .missing => .eq,
        .num => |xn| switch (y) {
            .num => |yn| std.math.order(xn, yn),
            else => .lt,
        },
        .text => |xt| switch (y) {
            .text => |yt| orderCaseless(xt, yt),
            else => .gt,
        },
    };
}

/// Order by key rather than a pre-resolved kind. The sort path
/// resolves the kind once per sort instead (kindOf scans a table).
pub fn orderKey(key: []const u8, a: []const u8, b: []const u8, desc: bool) std.math.Order {
    return order(kindOf(key), a, b, desc);
}

// --- column bookkeeping ----------------------------------------

/// Position of column `i` inside the dense value array its own
/// source fills. The two sources number their columns independently:
/// xattr values arrive in the listing's requested-attribute order,
/// media values in media-column order.
pub fn subIndex(names: []const []const u8, i: usize) usize {
    const src = sourceOf(names[i]) orelse return 0;
    var n: usize = 0;
    for (names[0..i]) |name| {
        if (sourceOf(name) == src) n += 1;
    }
    return n;
}

pub fn countOf(names: []const []const u8, src: Source) usize {
    var n: usize = 0;
    for (names) |name| {
        if (sourceOf(name) == src) n += 1;
    }
    return n;
}

// --- bounded fetch window --------------------------------------

/// Rows fetched on each side of the visible range. Fixed on purpose:
/// the inventory's number one remote pain point is per-row storms, so
/// the window never grows with the directory.
pub const FETCH_OVERSCAN: usize = 24;

/// Names one request may carry. Matches the client cap in
/// src/ipc/fsdrive.zig (the daemon refuses a larger batch outright).
pub const FETCH_BATCH_MAX: usize = 128;

pub const Window = struct {
    first: usize = 0,
    count: usize = 0,

    pub fn end(self: Window) usize {
        return self.first + self.count;
    }
};

/// The row range worth asking about, given what the user can see.
/// The result never exceeds FETCH_BATCH_MAX no matter how tall the
/// window or how large the directory; a viewport taller than that
/// fills the rest on the next scroll settle.
pub fn fetchWindow(visible_first: usize, visible_count: usize, total: usize) Window {
    if (total == 0) return .{};
    const first = visible_first -| FETCH_OVERSCAN;
    const wanted = @min(total, visible_first +| visible_count +| FETCH_OVERSCAN);
    if (wanted <= first) return .{ .first = first, .count = 0 };
    return .{ .first = first, .count = @min(wanted - first, FETCH_BATCH_MAX) };
}

// --- display ---------------------------------------------------

/// Human form of a raw value, written into `buf`.
///
/// `estimated` marks a duration the daemon DERIVED from a bitrate
/// rather than read from a header (media.duration_estimated): it is
/// shown as approximate in both forms, never as a measurement.
/// `verbose` is the Properties-row form; the compact form is what a
/// listing column shows.
pub fn display(key: []const u8, value: []const u8, estimated: bool, verbose: bool, buf: []u8) []const u8 {
    if (value.len == 0) return "";
    if (std.mem.eql(u8, key, "media.duration_ms")) {
        const ms = std.fmt.parseInt(u64, value, 10) catch return value;
        var hms: [24]u8 = undefined;
        const clock = formatClock(&hms, ms);
        if (!estimated) return std.fmt.bufPrint(buf, "{s}", .{clock}) catch value;
        return (if (verbose)
            std.fmt.bufPrint(buf, "{s} (estimated from bitrate)", .{clock})
        else
            std.fmt.bufPrint(buf, "~{s}", .{clock})) catch value;
    }
    if (std.mem.eql(u8, key, "media.duration_estimated"))
        return if (std.mem.eql(u8, value, "1")) "yes" else "no";
    if (std.mem.eql(u8, key, "media.bitrate_kbps"))
        return std.fmt.bufPrint(buf, "{s} kbps", .{value}) catch value;
    if (std.mem.eql(u8, key, "media.sample_rate"))
        return std.fmt.bufPrint(buf, "{s} Hz", .{value}) catch value;
    if (std.mem.eql(u8, key, "exif.iso"))
        return std.fmt.bufPrint(buf, "ISO {s}", .{value}) catch value;
    if (std.mem.eql(u8, key, "exif.f_number"))
        return std.fmt.bufPrint(buf, "f/{s}", .{value}) catch value;
    if (std.mem.eql(u8, key, "exif.focal_length"))
        return std.fmt.bufPrint(buf, "{s} mm", .{value}) catch value;
    if (std.mem.eql(u8, key, "exif.exposure_time"))
        return std.fmt.bufPrint(buf, "{s} s", .{value}) catch value;
    return value;
}

fn formatClock(buf: []u8, ms: u64) []const u8 {
    const total_s = ms / 1000;
    const h = total_s / 3600;
    const m = (total_s % 3600) / 60;
    const s = total_s % 60;
    if (h > 0) return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch "";
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ m, s }) catch "";
}

// --- tests -----------------------------------------------------

test "sourceOf splits the namespaces and rejects the rest" {
    const t = std.testing;
    try t.expectEqual(Source.xattr, sourceOf("user.xdg.comment").?);
    try t.expectEqual(Source.media, sourceOf("media.width").?);
    try t.expectEqual(Source.media, sourceOf("tag.artist").?);
    try t.expectEqual(Source.media, sourceOf("exif.iso").?);
    try t.expectEqual(Source.media, sourceOf("image.orientation").?);
    try t.expectEqual(Source.media, sourceOf("doc.pages").?);
    try t.expect(sourceOf("security.selinux") == null);
    try t.expect(sourceOf("") == null);
}

test "numeric column keys order by value, not lexically" {
    const t = std.testing;
    try t.expectEqual(ValueKind.integer, kindOf("media.duration_ms"));
    try t.expectEqual(ValueKind.integer, kindOf("media.width"));
    // The whole point: "9" must come before "10".
    try t.expectEqual(std.math.Order.lt, order(.integer, "9", "10", false));
    try t.expectEqual(std.math.Order.gt, order(.integer, "10", "9", false));
    try t.expectEqual(std.math.Order.gt, order(.integer, "9", "10", true));
    try t.expectEqual(std.math.Order.eq, order(.integer, "42", "42", false));
    try t.expectEqual(std.math.Order.lt, order(.integer, "1920", "3840", false));
}

test "text column keys order case-insensitively" {
    const t = std.testing;
    try t.expectEqual(ValueKind.text, kindOf("tag.artist"));
    try t.expectEqual(std.math.Order.lt, order(.text, "abba", "Beatles", false));
    try t.expectEqual(std.math.Order.lt, order(.text, "ABBA", "beatles", false));
    try t.expectEqual(std.math.Order.gt, order(.text, "abba", "Beatles", true));
    try t.expectEqual(std.math.Order.eq, order(.text, "Zappa", "zappa", false));
    // Lexically "10" precedes "9"; a text column must keep that.
    try t.expectEqual(std.math.Order.lt, order(.text, "10", "9", false));
}

test "timestamp column keys order chronologically and tolerate date-only" {
    const t = std.testing;
    try t.expectEqual(ValueKind.timestamp, kindOf("exif.datetime_original"));
    try t.expectEqual(std.math.Order.lt, order(
        .timestamp,
        "2019-12-31 23:59:59",
        "2020-01-01 00:00:00",
        false,
    ));
    try t.expectEqual(std.math.Order.gt, order(
        .timestamp,
        "2020-01-01 00:00:00",
        "2019-12-31 23:59:59",
        false,
    ));
    // A date with no time sorts before the same date with one.
    try t.expectEqual(std.math.Order.lt, order(.timestamp, "2020-01-01", "2020-01-01 00:00:01", false));
    // Not a timestamp at all: ranks missing, so it sorts last.
    try t.expectEqual(std.math.Order.lt, order(.timestamp, "2020-01-01", "yesterday", false));
}

test "ratio column keys order as the quotient" {
    const t = std.testing;
    try t.expectEqual(ValueKind.ratio, kindOf("exif.exposure_time"));
    try t.expectEqual(std.math.Order.lt, order(.ratio, "1/250", "1/60", false));
    try t.expectEqual(std.math.Order.lt, order(.ratio, "1/60", "2.5", false));
    // A zero denominator is malformed, not infinite.
    try t.expectEqual(std.math.Order.lt, order(.ratio, "1/250", "1/0", false));
}

test "missing values sort last in BOTH directions" {
    const t = std.testing;
    const cases = [_]struct { kind: ValueKind, present: []const u8 }{
        .{ .kind = .integer, .present = "1200" },
        .{ .kind = .decimal, .present = "2.8" },
        .{ .kind = .text, .present = "Beatles" },
        .{ .kind = .timestamp, .present = "2020-01-01 10:00:00" },
        .{ .kind = .ratio, .present = "1/250" },
    };
    for (cases) |case| {
        try t.expectEqual(std.math.Order.gt, order(case.kind, "", case.present, false));
        try t.expectEqual(std.math.Order.gt, order(case.kind, "", case.present, true));
        try t.expectEqual(std.math.Order.lt, order(case.kind, case.present, "", false));
        try t.expectEqual(std.math.Order.lt, order(case.kind, case.present, "", true));
        try t.expectEqual(std.math.Order.eq, order(case.kind, "", "", false));
        try t.expectEqual(std.math.Order.eq, order(case.kind, "", "", true));
    }
}

test "malformed numeric values rank as missing rather than breaking transitivity" {
    const t = std.testing;
    // Junk in a numeric column sorts last, exactly like an absent
    // value, so the comparator stays a strict weak ordering.
    try t.expectEqual(std.math.Order.lt, order(.integer, "10", "1x", false));
    try t.expectEqual(std.math.Order.lt, order(.integer, "9", "1x", false));
    try t.expectEqual(std.math.Order.eq, order(.integer, "1x", "junk", false));
    try t.expectEqual(std.math.Order.eq, order(.integer, "nan", "inf", false));
    try t.expectEqual(std.math.Order.gt, order(.integer, "nan", "0", false));
}

test "comparator is a strict weak ordering over adversarial values" {
    const t = std.testing;
    const values = [_][]const u8{ "", "9", "10", "1x", "0", "-3", "nan", "1e3", "junk", "007" };
    for ([_]bool{ false, true }) |desc| {
        for (values) |a| {
            // Irreflexive on equality.
            try t.expectEqual(std.math.Order.eq, order(.integer, a, a, desc));
            for (values) |b| {
                // Antisymmetric.
                const ab = order(.integer, a, b, desc);
                const ba = order(.integer, b, a, desc);
                try t.expectEqual(ab, switch (ba) {
                    .lt => std.math.Order.gt,
                    .gt => std.math.Order.lt,
                    .eq => std.math.Order.eq,
                });
                for (values) |cv| {
                    // Transitive: a<b and b<c implies a<c.
                    if (ab != .lt) continue;
                    if (order(.integer, b, cv, desc) != .lt) continue;
                    try t.expectEqual(std.math.Order.lt, order(.integer, a, cv, desc));
                }
            }
        }
    }
}

test "a real sort by a numeric media column lands in numeric order" {
    const t = std.testing;
    var rows = [_][]const u8{ "", "600000", "9000", "60000", "bogus", "1000" };
    const Ctx = struct {
        desc: bool,
        fn lt(ctx: @This(), a: []const u8, b: []const u8) bool {
            return order(.integer, a, b, ctx.desc) == .lt;
        }
    };
    std.mem.sort([]const u8, &rows, Ctx{ .desc = false }, Ctx.lt);
    try t.expectEqualStrings("1000", rows[0]);
    try t.expectEqualStrings("9000", rows[1]);
    try t.expectEqualStrings("60000", rows[2]);
    try t.expectEqualStrings("600000", rows[3]);
    // Both value-less rows are at the end, either order.
    try t.expect(rows[4].len == 0 or std.mem.eql(u8, rows[4], "bogus"));
    std.mem.sort([]const u8, &rows, Ctx{ .desc = true }, Ctx.lt);
    try t.expectEqualStrings("600000", rows[0]);
    try t.expectEqualStrings("1000", rows[3]);
    try t.expect(rows[4].len == 0 or std.mem.eql(u8, rows[4], "bogus"));
}

test "fetchWindow is fixed size regardless of directory size" {
    const t = std.testing;
    // Same viewport, two directories three orders of magnitude apart.
    const small = fetchWindow(0, 30, 500);
    const huge = fetchWindow(0, 30, 500_000);
    try t.expectEqual(small.first, huge.first);
    try t.expectEqual(small.count, huge.count);
    try t.expectEqual(@as(usize, 0), huge.first);
    try t.expectEqual(@as(usize, 30 + FETCH_OVERSCAN), huge.count);

    // Scrolled into the middle: overscan on both sides, still fixed.
    const mid = fetchWindow(20_000, 30, 50_000);
    try t.expectEqual(@as(usize, 20_000 - FETCH_OVERSCAN), mid.first);
    try t.expectEqual(@as(usize, 30 + 2 * FETCH_OVERSCAN), mid.count);

    // Never larger than one request, however tall the viewport.
    const tall = fetchWindow(0, 4000, 50_000);
    try t.expectEqual(FETCH_BATCH_MAX, tall.count);

    // A short directory is clamped to what exists, and an empty one
    // asks for nothing.
    try t.expectEqual(@as(usize, 5), fetchWindow(0, 30, 5).count);
    try t.expectEqual(@as(usize, 0), fetchWindow(0, 30, 0).count);
}

test "subIndex numbers each source independently" {
    const t = std.testing;
    const names = [_][]const u8{ "user.a", "media.width", "user.b", "tag.artist", "media.height" };
    try t.expectEqual(@as(usize, 0), subIndex(&names, 0));
    try t.expectEqual(@as(usize, 0), subIndex(&names, 1));
    try t.expectEqual(@as(usize, 1), subIndex(&names, 2));
    try t.expectEqual(@as(usize, 1), subIndex(&names, 3));
    try t.expectEqual(@as(usize, 2), subIndex(&names, 4));
    try t.expectEqual(@as(usize, 2), countOf(&names, .xattr));
    try t.expectEqual(@as(usize, 3), countOf(&names, .media));
}

test "labels name the known keys and strip namespaces from the rest" {
    const t = std.testing;
    try t.expectEqualStrings("Duration", label("media.duration_ms"));
    try t.expectEqualStrings("Artist", label("tag.artist"));
    try t.expectEqualStrings("Taken", label("exif.datetime_original"));
    try t.expectEqualStrings("Comment", label("user.xdg.comment"));
    try t.expectEqualStrings("Tags", label(fsserve.TAGS_XATTR));
    try t.expectEqualStrings("mine", label("user.mine"));
    try t.expectEqualStrings("whatever", label("exif.whatever"));
}

test "an estimated duration is never displayed as a measurement" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("3:45", display("media.duration_ms", "225000", false, false, &buf));
    try t.expectEqualStrings("~3:45", display("media.duration_ms", "225000", true, false, &buf));
    try t.expectEqualStrings(
        "3:45 (estimated from bitrate)",
        display("media.duration_ms", "225000", true, true, &buf),
    );
    try t.expectEqualStrings("1:01:05", display("media.duration_ms", "3665000", false, false, &buf));
    try t.expectEqualStrings("44100 Hz", display("media.sample_rate", "44100", false, false, &buf));
    try t.expectEqualStrings("f/2.8", display("exif.f_number", "2.8", false, false, &buf));
    try t.expectEqualStrings("1920", display("media.width", "1920", false, false, &buf));
    try t.expectEqualStrings("", display("media.width", "", false, false, &buf));
    // Unparseable duration is passed through rather than invented.
    try t.expectEqualStrings("soon", display("media.duration_ms", "soon", false, false, &buf));
}
