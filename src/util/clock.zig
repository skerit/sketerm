//! The monotonic millisecond clock every deadline in the tree is
//! measured against, plus the wall clock every human-readable
//! timestamp comes from.
//!
//! Zig 0.16 removed `std.time.milliTimestamp` and
//! `std.posix.clock_gettime`, so each module that needed a deadline
//! grew its own copy of the same `clock_gettime(CLOCK_MONOTONIC)`
//! arithmetic. This is that copy, once.
//!
//! Importable from BOTH dependency sets (the GUI `cbindings` module
//! and the lean mux core set) — libc only, no GTK/GLib, so the
//! daemon's ELF dependency invariant is unaffected.

const std = @import("std");
const c = @import("../c.zig").c;

/// Milliseconds since an unspecified monotonic epoch.
///
/// `tv_sec`/`tv_nsec` widths differ across libc and target, hence the
/// `@intCast`es rather than a plain `@as`.
pub fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    const sec: i64 = @intCast(ts.tv_sec);
    const nsec: i64 = @intCast(ts.tv_nsec);
    return sec * 1000 + @divTrunc(nsec, 1_000_000);
}

/// Nanoseconds on the same monotonic epoch as `nowMs`, for spans too
/// short for a millisecond to resolve (frame timings, microbenchmarks).
pub fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

/// Microseconds on the same monotonic epoch as `nowMs`, for spans a
/// millisecond would quantise away (a sub-ms round trip's distribution).
pub fn nowUs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    const sec: i64 = @intCast(ts.tv_sec);
    const nsec: i64 = @intCast(ts.tv_nsec);
    return sec * 1_000_000 + @divTrunc(nsec, 1_000);
}

/// Milliseconds since the Unix epoch, from the WALL clock.
///
/// NOT monotonic: NTP steps, suspend/resume and a user setting the
/// system time all move it, backwards included. Use it only for a
/// timestamp a human or another machine reads (log lines, records on
/// disk, "how long ago"); never for a deadline or an elapsed-time
/// measurement, which is what `nowMs` is for.
pub fn wallMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    const sec: i64 = @intCast(ts.tv_sec);
    const nsec: i64 = @intCast(ts.tv_nsec);
    return sec * 1000 + @divTrunc(nsec, 1_000_000);
}

/// `YYYY-MM-DD HH:MM` in LOCAL time for `ms` epoch milliseconds,
/// written into `buf` without a trailing NUL.
///
/// @return null when `ms` has no local representation, so each caller
/// keeps its own placeholder (the file browser shows an empty cell,
/// the MCP listing a "?").
pub fn localStamp(buf: []u8, ms: i64) ?[]const u8 {
    var t: c.time_t = @intCast(@divTrunc(ms, 1000));
    var tm: c.struct_tm = undefined;
    if (c.localtime_r(&t, &tm) == null) return null;
    const n = c.strftime(buf.ptr, buf.len, "%Y-%m-%d %H:%M", &tm);
    return buf[0..n];
}

/// The wall time (`wallMs` epoch) a `nowMs` reading `mono_ms` stands for,
/// by the offset between the two clocks now (a wall step since moves it).
pub fn wallOfMono(mono_ms: i64) i64 {
    return wallMs() - (nowMs() - mono_ms);
}

/// The length of an `isoLocal` stamp.
pub const ISO_LEN = 25;

/// ISO-8601 LOCAL time with its UTC offset, to the second
/// (`2026-10-04T11:32:50+02:00`), for `ms` epoch milliseconds.
/// @return null when `ms` has no local representation.
pub fn isoLocal(buf: *[ISO_LEN]u8, ms: i64) ?[]const u8 {
    var t: c.time_t = @intCast(@divFloor(ms, 1000));
    var tm: c.struct_tm = undefined;
    if (c.localtime_r(&t, &tm) == null) return null;
    var raw: [32]u8 = undefined;
    // `%z` is `+0200`: the colon ISO-8601's extended form wants goes in.
    const n = c.strftime(&raw, raw.len, "%Y-%m-%dT%H:%M:%S%z", &tm);
    if (n != ISO_LEN - 1) return null;
    @memcpy(buf[0..22], raw[0..22]);
    buf[22] = ':';
    @memcpy(buf[23..25], raw[22..24]);
    return buf[0..];
}

/// The `HH:MM` of an `isoLocal` stamp (the compact lines' time).
pub fn isoClock(iso: []const u8) []const u8 {
    return if (iso.len == ISO_LEN) iso[11..16] else "";
}

/// The `HH:MM:SS` of an `isoLocal` stamp.
pub fn isoTime(iso: []const u8) []const u8 {
    return if (iso.len == ISO_LEN) iso[11..19] else "";
}

/// How a `span` or an `ago` reads: "3 minutes" or "3m".
pub const SpanStyle = enum { long, short };

/// A duration in its largest unit the span overshoots (90 s is still
/// seconds, 90 min still minutes), so a list never shows "1 minutes"
/// rounding noise; negative reads as 0.
pub fn span(buf: []u8, ms: i64, style: SpanStyle) []const u8 {
    const secs = @divTrunc(@max(ms, 0), 1000);
    if (secs < 90) return unit(buf, secs, "s", "second", style);
    const mins = @divTrunc(secs, 60);
    if (mins < 90) return unit(buf, mins, "m", "minute", style);
    const hours = @divTrunc(mins, 60);
    if (hours < 48) return unit(buf, hours, "h", "hour", style);
    const days = @divTrunc(hours, 24);
    if (days < 14) return unit(buf, days, "d", "day", style);
    const weeks = @divTrunc(days, 7);
    if (weeks < 9) return unit(buf, weeks, "w", "week", style);
    const months = @divTrunc(days, 30);
    if (months < 24) return unit(buf, months, "mo", "month", style);
    return unit(buf, @divTrunc(days, 365), "y", "year", style);
}

fn unit(buf: []u8, n: i64, short: []const u8, long: []const u8, style: SpanStyle) []const u8 {
    return switch (style) {
        .short => std.fmt.bufPrint(buf, "{d}{s}", .{ n, short }),
        .long => std.fmt.bufPrint(buf, "{d} {s}{s}", .{ n, long, if (n == 1) "" else "s" }),
    } catch "a while";
}

/// How long before `now_ms` the wall time `then_ms` was ("3 minutes ago",
/// "3m ago"): "just now" under 90 s or for a time after now, and empty
/// for 0 (never), which must not read as "56 years ago".
pub fn ago(buf: []u8, now_ms: i64, then_ms: i64, style: SpanStyle) []const u8 {
    if (then_ms <= 0) return "";
    if (now_ms - then_ms < 90_000) return "just now";
    var b: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} ago", .{span(&b, now_ms - then_ms, style)}) catch "a while ago";
}

test "ago reads naturally at every scale, long and short" {
    const t = std.testing;
    var buf: [48]u8 = undefined;
    const now: i64 = 1_000_000_000_000;
    const sec = 1000;
    const min = 60 * sec;
    const hour = 60 * min;
    const day = 24 * hour;

    try t.expectEqualStrings("just now", ago(&buf, now, now, .long));
    try t.expectEqualStrings("just now", ago(&buf, now, now - 89 * sec, .long));
    try t.expectEqualStrings("1 minute ago", ago(&buf, now, now - 90 * sec, .long));
    try t.expectEqualStrings("5 minutes ago", ago(&buf, now, now - 5 * min, .long));
    try t.expectEqualStrings("89 minutes ago", ago(&buf, now, now - 89 * min, .long));
    try t.expectEqualStrings("1 hour ago", ago(&buf, now, now - 90 * min, .long));
    try t.expectEqualStrings("47 hours ago", ago(&buf, now, now - 47 * hour, .long));
    try t.expectEqualStrings("2 days ago", ago(&buf, now, now - 48 * hour, .long));
    try t.expectEqualStrings("13 days ago", ago(&buf, now, now - 13 * day, .long));
    try t.expectEqualStrings("2 weeks ago", ago(&buf, now, now - 14 * day, .long));
    try t.expectEqualStrings("8 weeks ago", ago(&buf, now, now - 60 * day, .long));
    try t.expectEqualStrings("2 months ago", ago(&buf, now, now - 63 * day, .long));
    try t.expectEqualStrings("23 months ago", ago(&buf, now, now - 700 * day, .long));
    try t.expectEqualStrings("2 years ago", ago(&buf, now, now - 730 * day, .long));
    try t.expectEqualStrings("16m ago", ago(&buf, now, now - 16 * min, .short));
    try t.expectEqualStrings("2mo ago", ago(&buf, now, now - 63 * day, .short));
    try t.expectEqualStrings("45s", span(&buf, 45 * sec, .short));
    try t.expectEqualStrings("18m", span(&buf, 18 * min, .short));
    try t.expectEqualStrings("0s", span(&buf, -5, .short));
    // Never says nothing rather than "56 years ago"; a clock that stepped
    // backwards must not print a negative age.
    try t.expectEqualStrings("", ago(&buf, now, 0, .long));
    try t.expectEqualStrings("just now", ago(&buf, now, now + 5 * min, .long));
}

test "isoLocal writes local time with its offset, and isoClock its HH:MM" {
    const t = std.testing;
    var buf: [ISO_LEN]u8 = undefined;
    const s = isoLocal(&buf, 1_000_000_000_000).?;
    try t.expectEqual(@as(usize, ISO_LEN), s.len);
    try t.expectEqual(@as(u8, 'T'), s[10]);
    try t.expect(s[19] == '+' or s[19] == '-');
    try t.expectEqual(@as(u8, ':'), s[22]);
    var short: [40]u8 = undefined;
    // The same local minute as localStamp's.
    try t.expectEqualStrings(localStamp(&short, 1_000_000_000_000).?[11..16], isoClock(s));
    try t.expectEqualStrings("", isoClock("11:32"));
    try t.expect(@abs(wallOfMono(nowMs()) - wallMs()) < 1000);
}

test "nowMs is monotonic and reads as milliseconds" {
    const t = std.testing;
    const a = nowMs();
    // Well above any plausible epoch-in-milliseconds rounding, and
    // below it if the function ever returned seconds or nanoseconds.
    try t.expect(a > 0);
    var spin: usize = 0;
    var b = nowMs();
    while (b == a and spin < 100_000_000) : (spin += 1) b = nowMs();
    try t.expect(b >= a);
}

test "nowNs shares nowMs's epoch and never runs backwards" {
    const t = std.testing;
    const a = nowNs();
    const b = nowNs();
    try t.expect(b >= a);
    // Same clock, so the nanosecond reading is within a millisecond of
    // the millisecond one for any plausible uptime.
    try t.expect(@abs(@as(i64, @intCast(a / 1_000_000)) - nowMs()) < 1_000);
}

test "wallMs reads as epoch milliseconds" {
    const t = std.testing;
    const now = wallMs();
    // 2020-01-01 and 2100-01-01 in epoch ms: seconds or nanoseconds
    // would fall outside on either side.
    try t.expect(now > 1_577_836_800_000);
    try t.expect(now < 4_102_444_800_000);
    // The wall clock may step, but two reads a few instructions apart
    // still have to land in the same window.
    try t.expect(@abs(wallMs() - now) < 60_000);
}

test "localStamp writes a fixed-width local timestamp" {
    const t = std.testing;
    var buf: [40]u8 = undefined;
    // The exact value is timezone dependent; the shape is not.
    const s = localStamp(&buf, 1_000_000_000_000).?;
    try t.expectEqual(@as(usize, 16), s.len);
    try t.expectEqual(@as(u8, '-'), s[4]);
    try t.expectEqual(@as(u8, '-'), s[7]);
    try t.expectEqual(@as(u8, ' '), s[10]);
    try t.expectEqual(@as(u8, ':'), s[13]);
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15 }) |i| {
        try t.expect(s[i] >= '0' and s[i] <= '9');
    }
    // strftime writes nothing it cannot terminate: a buffer too small
    // for the whole stamp yields an empty slice, never a partial one.
    var tiny: [4]u8 = undefined;
    try t.expectEqual(@as(usize, 0), localStamp(&tiny, 1_000_000_000_000).?.len);
}
