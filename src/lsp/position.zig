//! LSP position mapping: UTF-8 rope byte offsets <-> LSP `Position`
//! (zero-based line + `character`, counted in the negotiated
//! `positionEncoding`).
//!
//! The default LSP encoding is UTF-16 code units, so an astral-plane
//! codepoint (U+10000 and above) counts as TWO characters while
//! occupying four UTF-8 bytes and one Zig codepoint. Getting this wrong
//! silently shifts every diagnostic, completion range and rename edit
//! on any line containing an emoji, so the conversion is exhaustive in
//! both directions and both directions are property-tested against each
//! other.
//!
//! Gotcha: `character` is clamped to the line's end. Servers routinely
//! send `character: 0xFFFFFFFF`-ish end-of-line positions and a
//! `Position` one past the last line (the "end of document" range), and
//! neither may index out of the rope.

const std = @import("std");
const Rope = @import("../editor/rope.zig").Rope;
const jsonnum = @import("../util/jsonnum.zig");

/// `positionEncoding` values sketerm speaks. UTF-16 is the protocol
/// default and the only one a pre-3.17 server understands.
pub const Encoding = enum {
    utf8,
    utf16,
    utf32,

    pub fn wireName(self: Encoding) []const u8 {
        return switch (self) {
            .utf8 => "utf-8",
            .utf16 => "utf-16",
            .utf32 => "utf-32",
        };
    }

    /// Parse a `positionEncoding` string; unknown values fall back to
    /// the protocol default rather than failing the session.
    pub fn fromWire(s: []const u8) Encoding {
        if (std.mem.eql(u8, s, "utf-8")) return .utf8;
        if (std.mem.eql(u8, s, "utf-32")) return .utf32;
        return .utf16;
    }
};

pub const Position = struct {
    line: u32 = 0,
    character: u32 = 0,
};

pub const Range = struct {
    start: Position = .{},
    end: Position = .{},
};

/// Units `cp_bytes` (one whole UTF-8 sequence) contributes to a
/// `character` count under `enc`.
fn unitsOfSequence(lead: u8, seq_len: usize, enc: Encoding) u32 {
    return switch (enc) {
        .utf8 => @intCast(seq_len),
        .utf32 => 1,
        // Surrogate pair: exactly the four-byte sequences (U+10000+).
        .utf16 => if (lead >= 0xF0) 2 else 1,
    };
}

/// Byte offset -> LSP position. Offsets inside a multi-byte sequence
/// round DOWN to the sequence start (a caret can never sit there, but a
/// clamped/garbage offset must still produce a valid position).
pub fn offsetToPosition(rope: *const Rope, offset: usize, enc: Encoding) Position {
    const clamped = @min(offset, rope.len());
    const lc = rope.offsetToLineCol(clamped);
    const line_start = clamped - lc.col;
    return .{
        .line = @intCast(lc.line),
        .character = countUnits(rope, line_start, clamped, enc),
    };
}

/// `character` units between two byte offsets on the same line.
fn countUnits(rope: *const Rope, from: usize, to: usize, enc: Encoding) u32 {
    if (enc == .utf8) return @intCast(to - from);
    var units: u32 = 0;
    var it = rope.iterateRange(from, to);
    while (it.next()) |chunk| {
        for (chunk) |b| {
            // Continuation bytes carry no unit of their own.
            if (b & 0xC0 == 0x80) continue;
            units += if (enc == .utf16 and b >= 0xF0) 2 else 1;
        }
    }
    return units;
}

/// LSP position -> byte offset, clamped to the line's end and to the
/// document's end. A `character` landing INSIDE a surrogate pair (only
/// possible from a buggy server) resolves to the codepoint's start.
pub fn positionToOffset(rope: *const Rope, pos: Position, enc: Encoding) usize {
    const n_lines = rope.lineCount();
    if (pos.line >= n_lines) return rope.len();
    const line_start = rope.lineToOffset(pos.line);
    const line_end = lineEnd(rope, line_start);
    if (pos.character == 0) return line_start;
    if (enc == .utf8) return @min(line_start + pos.character, line_end);

    var off = line_start;
    var units: u32 = 0;
    var it = rope.iterateRange(line_start, line_end);
    outer: while (it.next()) |chunk| {
        var i: usize = 0;
        while (i < chunk.len) {
            const lead = chunk[i];
            const seq_len = std.unicode.utf8ByteSequenceLength(lead) catch 1;
            const step = @min(seq_len, chunk.len - i);
            const add = unitsOfSequence(lead, seq_len, enc);
            if (units + add > pos.character) break :outer;
            units += add;
            off += step;
            i += step;
            if (units == pos.character) break :outer;
        }
    }
    return @min(off, line_end);
}

/// Offset of the newline that ends the line starting at `line_start`
/// (or the document end for the last line).
fn lineEnd(rope: *const Rope, line_start: usize) usize {
    var off = line_start;
    var it = rope.iterateRange(line_start, rope.len());
    while (it.next()) |chunk| {
        if (std.mem.indexOfScalar(u8, chunk, '\n')) |nl| return off + nl;
        off += chunk.len;
    }
    return rope.len();
}

pub fn offsetToRange(rope: *const Rope, start: usize, end: usize, enc: Encoding) Range {
    return .{
        .start = offsetToPosition(rope, start, enc),
        .end = offsetToPosition(rope, end, enc),
    };
}

pub fn rangeToOffsets(rope: *const Rope, r: Range, enc: Encoding) struct { start: usize, end: usize } {
    const s = positionToOffset(rope, r.start, enc);
    const e = positionToOffset(rope, r.end, enc);
    return .{ .start = @min(s, e), .end = @max(s, e) };
}

/// Position one past the document's last character — the `end` of a
/// whole-document range.
pub fn endPosition(rope: *const Rope, enc: Encoding) Position {
    return offsetToPosition(rope, rope.len(), enc);
}

/// Parse `{"line":N,"character":N}`; missing fields default to 0 so a
/// partial position from a sloppy server still lands somewhere sane.
pub fn parsePosition(v: std.json.Value) Position {
    const obj = switch (v) {
        .object => |o| o,
        else => return .{},
    };
    return .{
        .line = jsonU32(obj.get("line")),
        .character = jsonU32(obj.get("character")),
    };
}

pub fn parseRange(v: std.json.Value) Range {
    const obj = switch (v) {
        .object => |o| o,
        else => return .{},
    };
    return .{
        .start = parsePosition(obj.get("start") orelse .null),
        .end = parsePosition(obj.get("end") orelse .null),
    };
}

const jsonU32 = jsonnum.u32Of;

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

fn ropeOf(text: []const u8) !Rope {
    return Rope.initFromBytes(testing.allocator, text);
}

test "lsp position: ascii round trip" {
    var rope = try ropeOf("hello\nworld\n");
    defer rope.deinit();
    for ([_]Encoding{ .utf8, .utf16, .utf32 }) |enc| {
        const p = offsetToPosition(&rope, 8, enc);
        try testing.expectEqual(@as(u32, 1), p.line);
        try testing.expectEqual(@as(u32, 2), p.character);
        try testing.expectEqual(@as(usize, 8), positionToOffset(&rope, p, enc));
    }
}

test "lsp position: astral plane counts two utf-16 units" {
    // U+1F600 GRINNING FACE: 4 UTF-8 bytes, 2 UTF-16 units, 1 UTF-32.
    var rope = try ropeOf("a\u{1F600}b\n");
    defer rope.deinit();
    // Offset 5 = just after 'a' (1) + emoji (4).
    try testing.expectEqual(@as(u32, 3), offsetToPosition(&rope, 5, .utf16).character);
    try testing.expectEqual(@as(u32, 5), offsetToPosition(&rope, 5, .utf8).character);
    try testing.expectEqual(@as(u32, 2), offsetToPosition(&rope, 5, .utf32).character);

    try testing.expectEqual(@as(usize, 5), positionToOffset(&rope, .{ .line = 0, .character = 3 }, .utf16));
    try testing.expectEqual(@as(usize, 5), positionToOffset(&rope, .{ .line = 0, .character = 5 }, .utf8));
    try testing.expectEqual(@as(usize, 5), positionToOffset(&rope, .{ .line = 0, .character = 2 }, .utf32));
}

test "lsp position: character inside a surrogate pair resolves to the codepoint start" {
    var rope = try ropeOf("\u{1F600}x\n");
    defer rope.deinit();
    // character 1 is the pair's LOW surrogate — no byte offset of its
    // own; the sequence start is the only defensible answer.
    try testing.expectEqual(@as(usize, 0), positionToOffset(&rope, .{ .line = 0, .character = 1 }, .utf16));
    try testing.expectEqual(@as(usize, 4), positionToOffset(&rope, .{ .line = 0, .character = 2 }, .utf16));
}

test "lsp position: bmp multibyte" {
    // é (2 bytes, 1 utf-16 unit), 世 (3 bytes, 1 utf-16 unit).
    var rope = try ropeOf("\u{e9}\u{4e16}z\n");
    defer rope.deinit();
    try testing.expectEqual(@as(u32, 2), offsetToPosition(&rope, 5, .utf16).character);
    try testing.expectEqual(@as(usize, 5), positionToOffset(&rope, .{ .line = 0, .character = 2 }, .utf16));
    try testing.expectEqual(@as(u32, 5), offsetToPosition(&rope, 5, .utf8).character);
}

test "lsp position: character past the line end clamps to the newline" {
    var rope = try ropeOf("ab\ncdef\n");
    defer rope.deinit();
    try testing.expectEqual(@as(usize, 2), positionToOffset(&rope, .{ .line = 0, .character = 99 }, .utf16));
    try testing.expectEqual(@as(usize, 7), positionToOffset(&rope, .{ .line = 1, .character = 99 }, .utf16));
    // A line past the end is the document end (LSP's whole-doc range).
    try testing.expectEqual(rope.len(), positionToOffset(&rope, .{ .line = 900, .character = 0 }, .utf16));
}

test "lsp position: every offset round-trips in every encoding" {
    var rope = try ropeOf(
        "plain\n" ++
            "caf\u{e9} \u{4e16}\u{754c} \u{1F600}\u{1F1E7}\u{1F1EA}\n" ++
            "\ttabs and \u{301}combining\n" ++
            "last",
    );
    defer rope.deinit();
    for ([_]Encoding{ .utf8, .utf16, .utf32 }) |enc| {
        var off: usize = 0;
        while (off <= rope.len()) {
            // Only codepoint boundaries are meaningful positions.
            const bytes = try rope.sliceAlloc(testing.allocator, off, @min(off + 1, rope.len()));
            defer testing.allocator.free(bytes);
            const is_boundary = bytes.len == 0 or (bytes[0] & 0xC0) != 0x80;
            if (is_boundary) {
                const p = offsetToPosition(&rope, off, enc);
                try testing.expectEqual(off, positionToOffset(&rope, p, enc));
            }
            off += 1;
        }
    }
}

test "lsp position: endPosition sits past the last character" {
    var rope = try ropeOf("one\ntwo");
    defer rope.deinit();
    const e = endPosition(&rope, .utf16);
    try testing.expectEqual(@as(u32, 1), e.line);
    try testing.expectEqual(@as(u32, 3), e.character);
}

test "lsp position: encoding wire names round-trip" {
    try testing.expectEqual(Encoding.utf8, Encoding.fromWire("utf-8"));
    try testing.expectEqual(Encoding.utf16, Encoding.fromWire("utf-16"));
    try testing.expectEqual(Encoding.utf32, Encoding.fromWire("utf-32"));
    // Unknown falls back to the protocol default, never an error.
    try testing.expectEqual(Encoding.utf16, Encoding.fromWire("ebcdic"));
    try testing.expectEqualStrings("utf-8", Encoding.utf8.wireName());
}

test "lsp position: json parse helpers clamp junk" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"start\":{\"line\":2,\"character\":7},\"end\":{\"line\":-4}}",
        .{},
    );
    defer parsed.deinit();
    const r = parseRange(parsed.value);
    try testing.expectEqual(@as(u32, 2), r.start.line);
    try testing.expectEqual(@as(u32, 7), r.start.character);
    try testing.expectEqual(@as(u32, 0), r.end.line);
    try testing.expectEqual(@as(u32, 0), r.end.character);
}
