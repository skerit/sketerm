//! Bounded hex rendering for the preview fallback: offsets, hex
//! columns and an ASCII gutter, from a head-of-file byte range.
//!
//! The caller decides how many bytes to fetch; this only formats what
//! it is given, so the same code serves a local read and a remote one.

const std = @import("std");

pub const BYTES_PER_ROW: usize = 16;

/// Bytes whose hex dump is worth showing at all. Beyond this the
/// caller should say so rather than render a wall of digits.
pub const DEFAULT_CAP: usize = 2048;

/// True when `bytes` should be shown as hex rather than as text: a NUL
/// or a high share of non-printable, non-whitespace bytes.
pub fn looksBinary(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return true;
    var odd: usize = 0;
    for (bytes) |ch| {
        // >= 0x80 is left alone: that is ordinary UTF-8 text.
        if (ch >= 0x20 or ch == '\n' or ch == '\r' or ch == '\t') continue;
        odd += 1;
    }
    return odd * 100 > bytes.len * 5;
}

/// Render `bytes` starting at file offset `base`. A short final row
/// keeps the gutter aligned by padding the hex columns.
pub fn write(w: *std.Io.Writer, bytes: []const u8, base: u64) !void {
    var off: usize = 0;
    while (off < bytes.len) : (off += BYTES_PER_ROW) {
        const row = bytes[off..@min(off + BYTES_PER_ROW, bytes.len)];
        try w.print("{x:0>8}  ", .{base + off});
        for (0..BYTES_PER_ROW) |i| {
            if (i == BYTES_PER_ROW / 2) try w.writeByte(' ');
            if (i < row.len) try w.print("{x:0>2} ", .{row[i]}) else try w.writeAll("   ");
        }
        try w.writeAll(" |");
        for (row) |ch| try w.writeByte(if (ch >= 0x20 and ch < 0x7f) ch else '.');
        try w.writeAll("|\n");
    }
}

/// Convenience wrapper over `write` for a caller-owned buffer.
/// @return the formatted slice, or null when `buf` is too small.
pub fn render(buf: []u8, bytes: []const u8, base: u64) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    write(&w, bytes, base) catch return null;
    return w.buffered();
}

/// Bytes a full row occupies: 8 offset digits, two spaces, sixteen
/// "xx " groups with the mid-row gap, " |", the gutter and "|\n".
pub const ROW_WIDTH: usize = 8 + 2 + BYTES_PER_ROW * 3 + 1 + 2 + BYTES_PER_ROW + 2;

/// Buffer size that always holds `n` bytes of dump; a short final
/// row needs less, never more.
pub fn renderedSize(n: usize) usize {
    return ((n + BYTES_PER_ROW - 1) / BYTES_PER_ROW) * ROW_WIDTH;
}

test "write renders offsets, split hex columns and the ASCII gutter" {
    const t = std.testing;
    var buf: [512]u8 = undefined;
    const out = render(&buf, "\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00", 0).?;
    try t.expectEqualStrings(
        "00000000  7f 45 4c 46 02 01 01 00  00 00 00 00 00 00 00 00  |.ELF............|\n",
        out,
    );
}

test "write pads a partial final row so the gutter stays aligned" {
    const t = std.testing;
    var buf: [512]u8 = undefined;
    const out = render(&buf, "AB", 0x10).?;
    try t.expectEqualStrings(
        "00000010  41 42                                             |AB|\n",
        out,
    );
    // The gutter starts at the same column as a full row's.
    const full = render(&buf, "0123456789abcdef", 0).?;
    try t.expectEqual(
        std.mem.indexOfScalar(u8, out, '|').?,
        std.mem.indexOfScalar(u8, full, '|').?,
    );
}

test "non-printable bytes render as dots without losing their hex" {
    const t = std.testing;
    var buf: [512]u8 = undefined;
    const out = render(&buf, "a\nb\xffc", 0).?;
    try t.expectEqualStrings(
        "00000000  61 0a 62 ff 63                                    |a.b.c|\n",
        out,
    );
}

test "render refuses to truncate into an undersized buffer" {
    const t = std.testing;
    var small: [16]u8 = undefined;
    try t.expect(render(&small, "0123456789abcdef", 0) == null);
    var exact: [ROW_WIDTH]u8 = undefined;
    try t.expectEqual(ROW_WIDTH, render(&exact, "0123456789abcdef", 0).?.len);
    try t.expectEqual(ROW_WIDTH, renderedSize(16));
    // One byte less of buffer is a refusal.
    try t.expect(render(exact[0 .. ROW_WIDTH - 1], "0123456789abcdef", 0) == null);
}

test "an empty range renders as nothing, not as an empty row" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("", render(&buf, "", 0).?);
}

test "looksBinary keeps text and flags NUL or control-heavy data" {
    const t = std.testing;
    try t.expect(!looksBinary("hello\nworld\t!"));
    try t.expect(!looksBinary("caf\xc3\xa9 na\xc3\xafve"));
    try t.expect(!looksBinary(""));
    try t.expect(looksBinary("ok\x00then"));
    try t.expect(looksBinary("\x01\x02\x03\x04\x05\x06"));
    // One stray control byte in a long line is not enough.
    try t.expect(!looksBinary("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\x01"));
}

test "renderedSize covers whole and partial rows" {
    const t = std.testing;
    var buf: [4096]u8 = undefined;
    const bytes = [_]u8{0xAA} ** 33;
    const out = render(buf[0..renderedSize(bytes.len)], &bytes, 0);
    try t.expect(out != null);
    try t.expectEqual(@as(usize, 3), std.mem.count(u8, out.?, "\n"));
    // A dump of the size the preview fetches must still fit.
    const big = [_]u8{0} ** DEFAULT_CAP;
    try t.expect(render(buf[0..0], &big, 0) == null);
    try t.expectEqual(renderedSize(DEFAULT_CAP), (DEFAULT_CAP / BYTES_PER_ROW) * ROW_WIDTH);
}
