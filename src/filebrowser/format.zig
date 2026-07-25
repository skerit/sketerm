//! GTK-free display formatting for file-browser labels.

const std = @import("std");
const c = @import("../c.zig").c;

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
pub fn copyZN(buf: anytype, text: []const u8) [*:0]const u8 {
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    return @ptrCast(buf);
}

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

pub fn fmtTimeZ(buf: *[40:0]u8, ms: i64) [*:0]const u8 {
    var t: c.time_t = @intCast(@divTrunc(ms, 1000));
    var tm: c.struct_tm = undefined;
    if (c.localtime_r(&t, &tm) == null) return "";
    const n = c.strftime(buf, buf.len - 1, "%Y-%m-%d %H:%M", &tm);
    buf[n] = 0;
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
