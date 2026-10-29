//! Text encodings read besides UTF-8: UTF-16 in either byte order, with
//! or without a byte-order mark.
//!
//! Every other byte of ASCII-range UTF-16 is NUL, so a NUL-means-binary
//! check alone refuses such a file (Windows tools write BOM-less
//! UTF-16LE freely). `detect` is the one sniffing rule the editor, its
//! project search and the file previews share, so a file one of them
//! shows as text is never refused as binary by another.
//!
//! A BOM-less file is only considered once it holds a NUL: text without
//! one already reads as UTF-8, and UTF-16 with few ASCII-range code
//! units cannot be told apart from UTF-8 or Latin-1 reliably.

const std = @import("std");

pub const Encoding = enum {
    utf8,
    utf16le,
    utf16be,

    /// The name users know the encoding by.
    pub fn label(self: Encoding) []const u8 {
        return switch (self) {
            .utf8 => "UTF-8",
            .utf16le => "UTF-16LE",
            .utf16be => "UTF-16BE",
        };
    }
};

pub const Detected = struct {
    encoding: Encoding = .utf8,
    /// A leading BOM was present; `decodeAlloc` drops it and a save
    /// should write it back.
    bom: bool = false,
};

/// How far `detect` looks, the same window as the editor's binary probe.
pub const PROBE_BYTES: usize = 8000;

/// Sniff the encoding of `bytes`, which are a whole file when `complete`
/// and a possibly truncated head otherwise (a split code unit or
/// surrogate pair at the end is then tolerated).
pub fn detect(bytes: []const u8, complete: bool) Detected {
    const truncated = !complete or bytes.len > PROBE_BYTES;
    // A whole UTF-16 file is a whole number of code units.
    if (complete and bytes.len % 2 != 0) return .{};
    const probe = bytes[0..@min(bytes.len, PROBE_BYTES)];
    if (probe.len >= 2) {
        const bom: ?Encoding = if (probe[0] == 0xFF and probe[1] == 0xFE)
            .utf16le
        else if (probe[0] == 0xFE and probe[1] == 0xFF)
            .utf16be
        else
            null;
        if (bom) |enc| {
            // FF FE 00 00 is the UTF-32LE BOM, which plausibleText
            // refuses through its NUL code unit.
            if (plausibleText(probe[2..], enc, truncated)) return .{ .encoding = enc, .bom = true };
            return .{};
        }
    }
    if (std.mem.indexOfScalar(u8, probe, 0) == null) return .{};
    // ASCII-range text puts its NULs in the high byte of each unit:
    // odd offsets for little-endian, even ones for big-endian. A quarter
    // of the units must be ASCII-range, or one stray NUL in UTF-8 text
    // would pair its bytes into CJK-looking units that all validate.
    var even: usize = 0;
    var odd: usize = 0;
    for (probe, 0..) |b, i| {
        if (b != 0) continue;
        if (i % 2 == 0) even += 1 else odd += 1;
    }
    const enc: Encoding = if (odd > even) .utf16le else if (even > odd) .utf16be else return .{};
    if (@max(odd, even) * 4 < probe.len / 2) return .{};
    if (plausibleText(probe, enc, truncated)) return .{ .encoding = enc };
    return .{};
}

fn unitAt(bytes: []const u8, i: usize, enc: Encoding) u16 {
    return switch (enc) {
        .utf16le => @as(u16, bytes[i]) | (@as(u16, bytes[i + 1]) << 8),
        .utf16be => (@as(u16, bytes[i]) << 8) | bytes[i + 1],
        .utf8 => unreachable,
    };
}

/// Whether `bytes` read as `enc` is well-formed text: no NUL or
/// non-whitespace C0 control unit (ESC is allowed for ANSI-coloured
/// logs), no reversed BOM and no unpaired surrogate. With `truncated`,
/// a lone trailing byte or high surrogate is the cut, not an error.
fn plausibleText(bytes: []const u8, enc: Encoding, truncated: bool) bool {
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        const u = unitAt(bytes, i, enc);
        if (u < 0x20) switch (u) {
            '\t', '\n', 0x0B, 0x0C, '\r', 0x1B => {},
            else => return false,
        };
        if (u == 0xFFFE) return false;
        if (u >= 0xDC00 and u <= 0xDFFF) return false;
        if (u >= 0xD800 and u <= 0xDBFF) {
            if (i + 3 >= bytes.len) return truncated;
            const lo = unitAt(bytes, i + 2, enc);
            if (lo < 0xDC00 or lo > 0xDFFF) return false;
            i += 2;
        }
    }
    return i == bytes.len or truncated;
}

pub const DecodeError = error{ OutOfMemory, InvalidUtf16 };

/// Transcode UTF-16 `bytes` to caller-owned UTF-8, dropping a leading
/// BOM. With `lenient` an unpaired surrogate becomes U+FFFD and a split
/// unit or pair at the end is dropped; without it either is
/// `error.InvalidUtf16`.
pub fn decodeAlloc(alloc: std.mem.Allocator, bytes: []const u8, enc: Encoding, lenient: bool) DecodeError![]u8 {
    std.debug.assert(enc != .utf8);
    var src = bytes;
    if (src.len >= 2 and unitAt(src, 0, enc) == 0xFEFF) src = src[2..];
    if (src.len % 2 != 0) {
        if (!lenient) return error.InvalidUtf16;
        src = src[0 .. src.len - 1];
    }
    // A unit is at most three UTF-8 bytes; a pair is two units and four.
    var out: std.ArrayList(u8) = try .initCapacity(alloc, src.len / 2 * 3);
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < src.len) : (i += 2) {
        const u = unitAt(src, i, enc);
        var cp: u21 = u;
        if (u >= 0xD800 and u <= 0xDBFF) {
            const lo: ?u16 = if (i + 2 < src.len) unitAt(src, i + 2, enc) else null;
            if (lo != null and lo.? >= 0xDC00 and lo.? <= 0xDFFF) {
                cp = 0x10000 + ((@as(u21, u) - 0xD800) << 10) + (lo.? - 0xDC00);
                i += 2;
            } else if (lo == null and lenient) {
                break;
            } else if (lenient) {
                cp = 0xFFFD;
            } else return error.InvalidUtf16;
        } else if (u >= 0xDC00 and u <= 0xDFFF) {
            if (!lenient) return error.InvalidUtf16;
            cp = 0xFFFD;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        out.appendSliceAssumeCapacity(buf[0..n]);
    }
    return out.toOwnedSlice(alloc);
}

pub const EncodeError = error{ OutOfMemory, InvalidUtf8 };

/// Transcode UTF-8 `text` to caller-owned bytes in `enc`, led by a BOM
/// when `bom`. `.utf8` copies the text unchanged.
pub fn encodeAlloc(alloc: std.mem.Allocator, text: []const u8, enc: Encoding, bom: bool) EncodeError![]u8 {
    if (enc == .utf8) return alloc.dupe(u8, text);
    // Every UTF-8 byte yields at most one code unit's two bytes.
    var out: std.ArrayList(u8) = try .initCapacity(alloc, text.len * 2 + 2);
    errdefer out.deinit(alloc);
    if (bom) putUnit(&out, 0xFEFF, enc);
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return error.InvalidUtf8;
        if (i + n > text.len) return error.InvalidUtf8;
        const cp = std.unicode.utf8Decode(text[i .. i + n]) catch return error.InvalidUtf8;
        i += n;
        if (cp < 0x10000) {
            putUnit(&out, @intCast(cp), enc);
        } else {
            const v = cp - 0x10000;
            putUnit(&out, @intCast(0xD800 + (v >> 10)), enc);
            putUnit(&out, @intCast(0xDC00 + (v & 0x3FF)), enc);
        }
    }
    return out.toOwnedSlice(alloc);
}

fn putUnit(out: *std.ArrayList(u8), u: u16, enc: Encoding) void {
    const pair: [2]u8 = switch (enc) {
        .utf16le => .{ @truncate(u), @truncate(u >> 8) },
        .utf16be => .{ @truncate(u >> 8), @truncate(u) },
        .utf8 => unreachable,
    };
    out.appendSliceAssumeCapacity(&pair);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "detect: plain UTF-8 and binary stay utf8" {
    try testing.expectEqual(Detected{}, detect("plain text\n", true));
    try testing.expectEqual(Detected{}, detect("", true));
    // An ELF-ish header: NULs, but control units in either byte order.
    try testing.expectEqual(Detected{}, detect("\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00", true));
    // A run of NULs is a NUL code unit either way.
    try testing.expectEqual(Detected{}, detect("ab\x00\x00cd", true));
    // One stray NUL in UTF-8 text pairs into valid but non-ASCII units.
    try testing.expectEqual(Detected{}, detect("hello\x00world!", true));
}

test "detect: BOM-less and BOM'd UTF-16 in both byte orders" {
    try testing.expectEqual(Detected{ .encoding = .utf16le }, detect("#\x00 \x00T\x00i\x00\n\x00", true));
    try testing.expectEqual(Detected{ .encoding = .utf16be }, detect("\x00#\x00 \x00T\x00i\x00\n", true));
    try testing.expectEqual(Detected{ .encoding = .utf16le, .bom = true }, detect("\xFF\xFEh\x00i\x00", true));
    try testing.expectEqual(Detected{ .encoding = .utf16be, .bom = true }, detect("\xFE\xFF\x00h\x00i", true));
    // A BOM alone is an empty UTF-16 file.
    try testing.expectEqual(Detected{ .encoding = .utf16le, .bom = true }, detect("\xFF\xFE", true));
    // The UTF-32LE BOM is not UTF-16.
    try testing.expectEqual(Detected{}, detect("\xFF\xFE\x00\x00h\x00\x00\x00", true));
}

test "detect: an odd-length whole file is not UTF-16, a cut head may be" {
    try testing.expectEqual(Detected{}, detect("h\x00i\x00!", true));
    try testing.expectEqual(Detected{ .encoding = .utf16le }, detect("h\x00i\x00!", false));
    // A head cut inside a surrogate pair (U+1F600 = D83D DE00).
    try testing.expectEqual(Detected{ .encoding = .utf16le }, detect("h\x00=\xD8", false));
    try testing.expectEqual(Detected{}, detect("h\x00=\xD8", true));
}

test "detect: unpaired surrogate or reversed BOM refuses" {
    try testing.expectEqual(Detected{}, detect("h\x00\x00\xDCi\x00", true));
    try testing.expectEqual(Detected{}, detect("h\x00\xFE\xFFi\x00", true));
}

test "decodeAlloc: BMP, supplementary and BOM" {
    const a = testing.allocator;
    const le = try decodeAlloc(a, "\xFF\xFEh\x00\xA7\x00=\xD8\x00\xDE", .utf16le, false);
    defer a.free(le);
    try testing.expectEqualStrings("h\u{A7}\u{1F600}", le);
    const be = try decodeAlloc(a, "\x00h\x20\xAC", .utf16be, false);
    defer a.free(be);
    try testing.expectEqualStrings("h\u{20AC}", be);
}

test "decodeAlloc: strict refuses what lenient repairs" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidUtf16, decodeAlloc(a, "h\x00\x00\xDCi\x00", .utf16le, false));
    try testing.expectError(error.InvalidUtf16, decodeAlloc(a, "h\x00=\xD8", .utf16le, false));
    try testing.expectError(error.InvalidUtf16, decodeAlloc(a, "h\x00i", .utf16le, false));
    const fixed = try decodeAlloc(a, "h\x00\x00\xDCi\x00", .utf16le, true);
    defer a.free(fixed);
    try testing.expectEqualStrings("h\u{FFFD}i", fixed);
    const cut = try decodeAlloc(a, "h\x00=\xD8\x00", .utf16le, true);
    defer a.free(cut);
    try testing.expectEqualStrings("h", cut);
}

test "encodeAlloc round-trips decodeAlloc and writes the BOM" {
    const a = testing.allocator;
    const raw = "\xFE\xFF\x00h\x00\xA7\xD8\x3D\xDE\x00\x00\n";
    const text = try decodeAlloc(a, raw, .utf16be, false);
    defer a.free(text);
    const back = try encodeAlloc(a, text, .utf16be, true);
    defer a.free(back);
    try testing.expectEqualSlices(u8, raw, back);
    const le = try encodeAlloc(a, "hi", .utf16le, false);
    defer a.free(le);
    try testing.expectEqualSlices(u8, "h\x00i\x00", le);
    try testing.expectError(error.InvalidUtf8, encodeAlloc(a, "bad \xC3", .utf16le, false));
}
