//! Font itemization for proportional editor text — the foundation piece
//! the spike identified as missing (shapeRun shapes against the primary
//! face only; a gid path cannot use the atlas's codepoint-keyed
//! fallback).
//!
//! FontBook segments a UTF-8 run into shaping runs by (a) caller-provided
//! style span boundaries, (b) script (compact UCD classes — Common and
//! Inherited merge into their neighbors), and (c) coverage of the chosen
//! face (FT_Get_Char_Index probe, then a fontconfig charset match via
//! Atlas.shapeFallbackForCp). Each run shapes with ITS face's hb_font
//! and rasterizes through the matching gid-keyed atlas path
//! (lookupOrLoadById for primary styles, lookupOrLoadFaceGid for
//! fallbacks — emoji fallback faces load colour strikes through the
//! existing FT_LOAD_COLOR path).
//!
//! Gotcha: a styled (bold/italic) codepoint missing from the styled
//! face but present in the regular one falls back to the REGULAR
//! primary face without synthesis — same degradation the terminal
//! lookupOrLoad path takes, but per-run here.

const std = @import("std");
const c = @import("../c.zig").c;
const atlas_mod = @import("atlas.zig");
const Atlas = atlas_mod.Atlas;
const Glyph = atlas_mod.Glyph;

/// Compact script classification — just enough to split shaping runs.
/// Not a full UCD table: scripts we don't distinguish land in `other`,
/// which still splits correctly against latin/arabic/etc neighbors.
pub const Script = enum {
    common,
    latin,
    greek,
    cyrillic,
    hebrew,
    arabic,
    devanagari,
    thai,
    hangul,
    hiragana,
    katakana,
    han,
    other,
};

pub fn scriptOf(cp: u21) Script {
    return switch (cp) {
        0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF => .latin,
        0x0370...0x03FF, 0x1F00...0x1FFF => .greek,
        0x0400...0x04FF, 0x0500...0x052F, 0x2DE0...0x2DFF, 0xA640...0xA69F => .cyrillic,
        0x0590...0x05FF, 0xFB1D...0xFB4F => .hebrew,
        0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF => .arabic,
        0x0900...0x097F, 0xA8E0...0xA8FF => .devanagari,
        0x0E00...0x0E7F => .thai,
        0x1100...0x11FF, 0xA960...0xA97F, 0xAC00...0xD7FF => .hangul,
        0x3041...0x309F => .hiragana,
        0x30A0...0x30FF, 0x31F0...0x31FF => .katakana,
        0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F => .han,
        // ASCII digits/punct/space, general punctuation, combining
        // marks (Inherited), symbols, emoji: merge into neighbors.
        else => .common,
    };
}

/// Which face a run shapes and rasterizes with.
pub const FaceSel = union(enum) {
    primary: struct { bold: bool, italic: bool },
    fallback: u16,

    pub fn eql(a: FaceSel, b: FaceSel) bool {
        return switch (a) {
            .primary => |p| switch (b) {
                .primary => |q| p.bold == q.bold and p.italic == q.italic,
                else => false,
            },
            .fallback => |i| switch (b) {
                .fallback => |j| i == j,
                else => false,
            },
        };
    }
};

/// A caller-provided style span: bytes [prev.end, end) carry this
/// style. Spans must be sorted; the last span's `end` must be >=
/// text.len. An empty slice means all-regular.
pub const StyleSpan = struct {
    end: u32,
    bold: bool = false,
    italic: bool = false,
};

/// One shaping run in LOGICAL byte order within the itemized slice.
pub const Run = struct {
    start: u32,
    end: u32,
    face: FaceSel,
    script: Script,
    rtl: bool,
};

pub const FontBook = struct {
    atlas: *Atlas,

    pub fn init(atlas: *Atlas) FontBook {
        return .{ .atlas = atlas };
    }

    /// True when SOME face (primary or a resolvable fallback) covers
    /// `cp` — used by callers to decide whether a no-tofu assertion is
    /// meaningful on this host.
    pub fn hasCoverage(self: *FontBook, cp: u21) bool {
        if (c.FT_Get_Char_Index(self.atlas.ft_face, cp) != 0) return true;
        return self.atlas.shapeFallbackForCp(cp) != null;
    }

    fn styleAt(spans: []const StyleSpan, span_idx: usize) struct { bold: bool, italic: bool } {
        if (spans.len == 0) return .{ .bold = false, .italic = false };
        const s = spans[@min(span_idx, spans.len - 1)];
        return .{ .bold = s.bold, .italic = s.italic };
    }

    /// Pick the face for one codepoint, preferring `prefer` (the current
    /// run's face) when it covers the codepoint — keeps Common-script
    /// punctuation/digits inside the surrounding run.
    fn pickFace(self: *FontBook, cp: u21, bold: bool, italic: bool, prefer: ?FaceSel) FaceSel {
        if (prefer) |p| {
            const face = switch (p) {
                .primary => |st| self.atlas.primaryShapeFace(st.bold, st.italic).face,
                .fallback => |idx| self.atlas.shapeFallback(idx).face,
            };
            if (c.FT_Get_Char_Index(face, cp) != 0) return p;
        }
        const styled = self.atlas.primaryShapeFace(bold, italic);
        if (c.FT_Get_Char_Index(styled.face, cp) != 0)
            return .{ .primary = .{ .bold = bold, .italic = italic } };
        if (c.FT_Get_Char_Index(self.atlas.ft_face, cp) != 0)
            return .{ .primary = .{ .bold = false, .italic = false } };
        if (self.atlas.shapeFallbackForCp(cp)) |idx| return .{ .fallback = idx };
        // Nothing covers it — shape with the styled primary (tofu).
        return .{ .primary = .{ .bold = bold, .italic = italic } };
    }

    /// Segment `text` into shaping runs. `rtl` is the bidi level of the
    /// whole slice (the caller splits bidi level runs FIRST); runs come
    /// back in LOGICAL order — for an RTL slice the caller lays them
    /// out in reverse. Caller frees the returned slice.
    pub fn itemize(
        self: *FontBook,
        alloc: std.mem.Allocator,
        text: []const u8,
        spans: []const StyleSpan,
        rtl: bool,
    ) ![]Run {
        var runs: std.ArrayList(Run) = .empty;
        errdefer runs.deinit(alloc);
        if (text.len == 0) return runs.toOwnedSlice(alloc);

        var span_idx: usize = 0;
        var cur_face: ?FaceSel = null;
        var cur_script: Script = .common;
        var run_start: u32 = 0;
        var i: usize = 0;
        while (i < text.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const cp: u21 = if (i + seq_len <= text.len)
                std.unicode.utf8Decode(text[i .. i + seq_len]) catch 0xFFFD
            else
                0xFFFD;
            const cp_len: usize = if (i + seq_len <= text.len) seq_len else 1;

            var style_changed = false;
            while (spans.len > 0 and span_idx < spans.len - 1 and spans[span_idx].end <= i) {
                span_idx += 1;
                style_changed = true;
            }
            const st = styleAt(spans, span_idx);
            const script = scriptOf(cp);
            const face = self.pickFace(cp, st.bold, st.italic, if (style_changed) null else cur_face);

            const script_breaks = script != .common and cur_script != .common and script != cur_script;
            const face_breaks = cur_face != null and !face.eql(cur_face.?);
            if (cur_face == null) {
                cur_face = face;
                cur_script = script;
            } else if (face_breaks or script_breaks) {
                try runs.append(alloc, .{
                    .start = run_start,
                    .end = @intCast(i),
                    .face = cur_face.?,
                    .script = cur_script,
                    .rtl = rtl,
                });
                run_start = @intCast(i);
                cur_face = face;
                cur_script = script;
            } else if (cur_script == .common and script != .common) {
                cur_script = script;
            }
            i += cp_len;
        }
        try runs.append(alloc, .{
            .start = run_start,
            .end = @intCast(text.len),
            .face = cur_face.?,
            .script = cur_script,
            .rtl = rtl,
        });
        return runs.toOwnedSlice(alloc);
    }

    /// Shape one itemized run's slice with the run's face. The returned
    /// slice is owned by the atlas (do not free); clusters are byte
    /// offsets within `slice`.
    pub fn shape(self: *FontBook, run: Run, slice: []const u8) ![]Atlas.ShapedGlyph {
        const font = switch (run.face) {
            .primary => |st| self.atlas.primaryShapeFace(st.bold, st.italic).hb,
            .fallback => |idx| self.atlas.shapeFallback(idx).hb,
        } orelse return error.NoHarfBuzzFont;
        return self.atlas.shapeWithFont(font, slice, run.rtl);
    }

    /// Rasterize (or fetch) the atlas glyph for a shaped gid of `run`.
    pub fn glyphFor(self: *FontBook, face: FaceSel, gid: u32) !Glyph {
        return switch (face) {
            .primary => |st| self.atlas.lookupOrLoadById(gid, st.bold, st.italic),
            .fallback => |idx| self.atlas.lookupOrLoadFaceGid(idx, gid),
        };
    }
};

// ======================================================================
// Tests (font-gated like atlas_test.zig — skip on fontless systems)
// ======================================================================

const testing = std.testing;

fn openTestAtlas(allocator: std.mem.Allocator) ?*Atlas {
    const path = atlas_mod.resolveFamilyPath(allocator, "DejaVu Sans") orelse
        atlas_mod.resolveFamilyPath(allocator, "Sans") orelse return null;
    defer allocator.free(path);
    return Atlas.init(allocator, path.ptr, 16) catch null;
}

test "itemize: plain ASCII is one primary run" {
    const a = testing.allocator;
    const atlas = openTestAtlas(a) orelse return error.SkipZigTest;
    defer atlas.deinit();
    var book = FontBook.init(atlas);
    const runs = try book.itemize(a, "hello world 123", &.{}, false);
    defer a.free(runs);
    try testing.expectEqual(@as(usize, 1), runs.len);
    try testing.expect(runs[0].face == .primary);
    try testing.expectEqual(@as(u32, 0), runs[0].start);
    try testing.expectEqual(@as(u32, 15), runs[0].end);
}

test "itemize: script change splits runs, common merges" {
    const a = testing.allocator;
    const atlas = openTestAtlas(a) orelse return error.SkipZigTest;
    defer atlas.deinit();
    var book = FontBook.init(atlas);
    // latin, space (common), greek — the space merges into a neighbor,
    // so exactly 2 runs when the same face covers both scripts, and
    // still >= 2 when coverage forces a fallback split.
    const runs = try book.itemize(a, "abc \u{03b1}\u{03b2}\u{03b3}", &.{}, false);
    defer a.free(runs);
    try testing.expect(runs.len >= 2);
    try testing.expectEqual(Script.latin, runs[0].script);
    try testing.expectEqual(Script.greek, runs[runs.len - 1].script);
    // Full coverage: runs tile the byte range.
    try testing.expectEqual(@as(u32, 0), runs[0].start);
    var prev_end: u32 = 0;
    for (runs) |r| {
        try testing.expectEqual(prev_end, r.start);
        prev_end = r.end;
    }
    try testing.expectEqual(@as(u32, 10), prev_end);
}

test "itemize: style span boundary splits primary runs" {
    const a = testing.allocator;
    const atlas = openTestAtlas(a) orelse return error.SkipZigTest;
    defer atlas.deinit();
    var book = FontBook.init(atlas);
    const spans = [_]StyleSpan{
        .{ .end = 5, .bold = false },
        .{ .end = 11, .bold = true },
    };
    const runs = try book.itemize(a, "hello world", &spans, false);
    defer a.free(runs);
    try testing.expectEqual(@as(usize, 2), runs.len);
    try testing.expectEqual(@as(u32, 5), runs[0].end);
    try testing.expect(!runs[0].face.primary.bold);
    try testing.expect(runs[1].face.primary.bold);
}

test "itemize + shape: arabic run shapes without tofu when covered" {
    const a = testing.allocator;
    const atlas = openTestAtlas(a) orelse return error.SkipZigTest;
    defer atlas.deinit();
    var book = FontBook.init(atlas);
    const arabic = "\u{0627}\u{0644}\u{0639}\u{0631}\u{0628}";
    if (!book.hasCoverage(0x0627)) return error.SkipZigTest;
    const runs = try book.itemize(a, arabic, &.{}, true);
    defer a.free(runs);
    try testing.expectEqual(@as(usize, 1), runs.len);
    const shaped = try book.shape(runs[0], arabic);
    try testing.expect(shaped.len > 0);
    for (shaped) |sg| {
        try testing.expect(sg.glyph_id != 0);
        const g = try book.glyphFor(runs[0].face, sg.glyph_id);
        _ = g;
    }
}
