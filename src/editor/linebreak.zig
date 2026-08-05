//! UAX #14 line-break opportunities for soft wrap.
//!
//! Same shape and rigour as `unicode.zig` (UAX #29 there): a complete
//! rule ENGINE over a deliberately COMPACT property table. Implemented
//! rules: LB7 (no break before space/ZW), LB8 (break after ZW), LB8a
//! (ZWJ glues), LB9 (combining marks attach to their base), LB11 (word
//! joiner), LB12/LB12a (glue, NBSP), LB13 (no break before closing
//! punctuation), LB14 (no break after opening punctuation, across
//! spaces), LB15 (quote-open), LB16 (closer + nonstarter), LB17 (B2
//! pairs), LB18 (break after spaces), LB19 (quotes glue both ways),
//! LB21 (break after, never before, hyphens/BA; no break before
//! nonstarters; no break after BB), LB22 (ellipsis), LB23/LB23a and
//! LB24 (letter/number/prefix affinity), a pairwise LB25 approximation
//! (numbers like "3.14", "-5", "1,234" hold together), LB28/LB29
//! (alphabetics glue; "e.g"), LB30 (narrow parens stick to words), and
//! LB31 (break everywhere else — which is what lets CJK break between
//! ideographs).
//!
//! Deliberately NOT implemented: LB21a (Hebrew letter + hyphen), the
//! full LB25 regex, LB30a (regional indicators — the grapheme layer
//! already keeps flag pairs whole and a break between flags is fine),
//! and dictionary-based breaking for SA scripts: Thai/Lao/Khmer
//! classify as AL, so runs of them glue like Latin words and long
//! passages fall back to the caller's cannot-fit break. The class
//! table carries representative subsets (the module doc of unicode.zig
//! explains the tradeoff); unlisted codepoints in the CJK/kana/Hangul/
//! emoji planes resolve to `id` via `isIdeographic`, everything else
//! to `al`.

const std = @import("std");
const unicode = @import("unicode.zig");

pub const LbClass = enum {
    sp,
    zw,
    wj,
    glue,
    op,
    cl,
    cp,
    quote,
    ex,
    is,
    sy,
    hy,
    ba,
    bb,
    b2,
    in,
    ns,
    nu,
    pr,
    po,
    id,
    al,
};

const Range = struct { first: u21, last: u21, class: LbClass };

// Sorted by `first`; checked by a test. ASCII is handled by the fast
// switch in `classOf`, so the table starts at U+00A0.
const ranges = [_]Range{
    .{ .first = 0x00A0, .last = 0x00A0, .class = .glue },
    .{ .first = 0x00A1, .last = 0x00A1, .class = .op }, // inverted !
    .{ .first = 0x00A2, .last = 0x00A2, .class = .po },
    .{ .first = 0x00A3, .last = 0x00A5, .class = .pr },
    .{ .first = 0x00AB, .last = 0x00AB, .class = .quote },
    .{ .first = 0x00AD, .last = 0x00AD, .class = .ba }, // soft hyphen
    .{ .first = 0x00B0, .last = 0x00B0, .class = .po },
    .{ .first = 0x00B4, .last = 0x00B4, .class = .bb },
    .{ .first = 0x00BB, .last = 0x00BB, .class = .quote },
    .{ .first = 0x00BF, .last = 0x00BF, .class = .op }, // inverted ?
    .{ .first = 0x2000, .last = 0x2006, .class = .ba }, // breaking spaces
    .{ .first = 0x2007, .last = 0x2007, .class = .glue }, // figure space
    .{ .first = 0x2008, .last = 0x200A, .class = .ba },
    .{ .first = 0x200B, .last = 0x200B, .class = .zw },
    .{ .first = 0x2010, .last = 0x2010, .class = .ba }, // hyphen
    .{ .first = 0x2011, .last = 0x2011, .class = .glue }, // non-breaking hyphen
    .{ .first = 0x2012, .last = 0x2013, .class = .ba }, // figure/en dash
    .{ .first = 0x2014, .last = 0x2014, .class = .b2 }, // em dash
    .{ .first = 0x2018, .last = 0x2019, .class = .quote },
    .{ .first = 0x201A, .last = 0x201A, .class = .op },
    .{ .first = 0x201C, .last = 0x201D, .class = .quote },
    .{ .first = 0x201E, .last = 0x201E, .class = .op },
    .{ .first = 0x2024, .last = 0x2026, .class = .in }, // leaders, ellipsis
    .{ .first = 0x202F, .last = 0x202F, .class = .glue }, // narrow NBSP
    .{ .first = 0x2030, .last = 0x2037, .class = .po },
    .{ .first = 0x2039, .last = 0x203A, .class = .quote },
    .{ .first = 0x2044, .last = 0x2044, .class = .is }, // fraction slash
    .{ .first = 0x2060, .last = 0x2060, .class = .wj },
    .{ .first = 0x22EF, .last = 0x22EF, .class = .in }, // midline ellipsis
    .{ .first = 0x3000, .last = 0x3000, .class = .ba }, // ideographic space
    .{ .first = 0x3001, .last = 0x3002, .class = .cl }, // 、 。
    .{ .first = 0x3005, .last = 0x3005, .class = .ns }, // 々
    .{ .first = 0x3008, .last = 0x3008, .class = .op },
    .{ .first = 0x3009, .last = 0x3009, .class = .cl },
    .{ .first = 0x300A, .last = 0x300A, .class = .op },
    .{ .first = 0x300B, .last = 0x300B, .class = .cl },
    .{ .first = 0x300C, .last = 0x300C, .class = .op },
    .{ .first = 0x300D, .last = 0x300D, .class = .cl },
    .{ .first = 0x300E, .last = 0x300E, .class = .op },
    .{ .first = 0x300F, .last = 0x300F, .class = .cl },
    .{ .first = 0x3010, .last = 0x3010, .class = .op },
    .{ .first = 0x3011, .last = 0x3011, .class = .cl },
    .{ .first = 0x3014, .last = 0x3014, .class = .op },
    .{ .first = 0x3015, .last = 0x3015, .class = .cl },
    .{ .first = 0x3016, .last = 0x3016, .class = .op },
    .{ .first = 0x3017, .last = 0x3017, .class = .cl },
    .{ .first = 0x3018, .last = 0x3018, .class = .op },
    .{ .first = 0x3019, .last = 0x3019, .class = .cl },
    .{ .first = 0x301A, .last = 0x301A, .class = .op },
    .{ .first = 0x301B, .last = 0x301B, .class = .cl },
    .{ .first = 0x301C, .last = 0x301C, .class = .ns }, // wave dash
    .{ .first = 0x301D, .last = 0x301D, .class = .op },
    .{ .first = 0x301E, .last = 0x301F, .class = .cl },
    .{ .first = 0x3041, .last = 0x3041, .class = .ns }, // small hiragana
    .{ .first = 0x3043, .last = 0x3043, .class = .ns },
    .{ .first = 0x3045, .last = 0x3045, .class = .ns },
    .{ .first = 0x3047, .last = 0x3047, .class = .ns },
    .{ .first = 0x3049, .last = 0x3049, .class = .ns },
    .{ .first = 0x3063, .last = 0x3063, .class = .ns },
    .{ .first = 0x3083, .last = 0x3083, .class = .ns },
    .{ .first = 0x3085, .last = 0x3085, .class = .ns },
    .{ .first = 0x3087, .last = 0x3087, .class = .ns },
    .{ .first = 0x308E, .last = 0x308E, .class = .ns },
    .{ .first = 0x3095, .last = 0x3096, .class = .ns },
    .{ .first = 0x309B, .last = 0x309E, .class = .ns }, // kana voicing/iteration
    .{ .first = 0x30A0, .last = 0x30A1, .class = .ns }, // small katakana
    .{ .first = 0x30A3, .last = 0x30A3, .class = .ns },
    .{ .first = 0x30A5, .last = 0x30A5, .class = .ns },
    .{ .first = 0x30A7, .last = 0x30A7, .class = .ns },
    .{ .first = 0x30A9, .last = 0x30A9, .class = .ns },
    .{ .first = 0x30C3, .last = 0x30C3, .class = .ns },
    .{ .first = 0x30E3, .last = 0x30E3, .class = .ns },
    .{ .first = 0x30E5, .last = 0x30E5, .class = .ns },
    .{ .first = 0x30E7, .last = 0x30E7, .class = .ns },
    .{ .first = 0x30EE, .last = 0x30EE, .class = .ns },
    .{ .first = 0x30F5, .last = 0x30F6, .class = .ns },
    .{ .first = 0x30FB, .last = 0x30FE, .class = .ns }, // ・ ー ヽ ヾ
    .{ .first = 0x31F0, .last = 0x31FF, .class = .ns }, // small kana extension
    .{ .first = 0xFE19, .last = 0xFE19, .class = .in },
    .{ .first = 0xFEFF, .last = 0xFEFF, .class = .wj },
    .{ .first = 0xFF01, .last = 0xFF01, .class = .ex },
    .{ .first = 0xFF08, .last = 0xFF08, .class = .op },
    .{ .first = 0xFF09, .last = 0xFF09, .class = .cl },
    .{ .first = 0xFF0C, .last = 0xFF0C, .class = .cl },
    .{ .first = 0xFF0E, .last = 0xFF0E, .class = .cl },
    .{ .first = 0xFF1A, .last = 0xFF1B, .class = .ns },
    .{ .first = 0xFF1F, .last = 0xFF1F, .class = .ex },
    .{ .first = 0xFF3B, .last = 0xFF3B, .class = .op },
    .{ .first = 0xFF3D, .last = 0xFF3D, .class = .cl },
    .{ .first = 0xFF5B, .last = 0xFF5B, .class = .op },
    .{ .first = 0xFF5D, .last = 0xFF5D, .class = .cl },
    .{ .first = 0xFF5F, .last = 0xFF5F, .class = .op },
    .{ .first = 0xFF60, .last = 0xFF61, .class = .cl },
    .{ .first = 0xFF62, .last = 0xFF62, .class = .op },
    .{ .first = 0xFF63, .last = 0xFF64, .class = .cl },
    .{ .first = 0xFF65, .last = 0xFF65, .class = .ns },
    .{ .first = 0xFF67, .last = 0xFF70, .class = .ns }, // halfwidth small kana + ー
    .{ .first = 0xFF9E, .last = 0xFF9F, .class = .ns },
};

/// Blocks whose unlisted codepoints break like ideographs (between
/// most characters). Checked AFTER the table so NS/CL/OP entries win.
fn isIdeographic(cp: u21) bool {
    return switch (cp) {
        0x1100...0x11FF => true, // Hangul jamo (grapheme layer keeps syllables whole)
        0x2E80...0x2FFF => true, // CJK radicals
        0x3006...0x3007 => true,
        0x3021...0x3029 => true,
        0x3030...0x303A => true,
        0x3040...0x30FF => true, // kana (small kana overridden above)
        0x3130...0x318F => true, // Hangul compatibility jamo
        0x31C0...0x31EF => true,
        0x3200...0x33FF => true,
        0x3400...0x4DBF => true,
        0x4E00...0x9FFF => true,
        0xA000...0xA4CF => true, // Yi
        0xAC00...0xD7A3 => true, // precomposed Hangul syllables
        0xF900...0xFAFF => true,
        0xFF66...0xFF9D => true, // halfwidth katakana (smalls overridden above)
        0x1F000...0x1FAFF => true, // emoji planes (clusters stay whole; break between)
        0x20000...0x2FFFD => true,
        0x30000...0x3FFFD => true,
        else => false,
    };
}

/// Line-break class of a codepoint.
pub fn classOf(cp: u21) LbClass {
    if (cp < 0x80) {
        return switch (cp) {
            '\t' => .ba,
            ' ' => .sp,
            '!' => .ex,
            '"', '\'' => .quote,
            '$', '+', '\\' => .pr,
            '%' => .po,
            '(', '[', '{' => .op,
            ')', ']' => .cp,
            ',', '.', ':', ';' => .is,
            '-' => .hy,
            '/' => .sy,
            '0'...'9' => .nu,
            '?' => .ex,
            '|' => .ba,
            '}' => .cl,
            else => .al,
        };
    }
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.first) {
            hi = mid;
        } else if (cp > r.last) {
            lo = mid + 1;
        } else {
            return r.class;
        }
    }
    if (isIdeographic(cp)) return .id;
    return .al;
}

/// Pairwise rules for adjacent (no intervening space) codepoints.
/// `cb`/`ca` are the classes before and after the candidate position.
fn allowPair(cb: LbClass, ca: LbClass, cp_b: u21, cp_a: u21) bool {
    _ = cp_b;
    // LB8: break after zero-width space (highest-priority ALLOW).
    if (cb == .zw) return true;
    // LB11: word joiner glues both ways.
    if (cb == .wj or ca == .wj) return false;
    // LB12: no break after glue (NBSP).
    if (cb == .glue) return false;
    // LB12a: no break before glue except after BA/HY (SP handled by
    // the space path).
    if (ca == .glue and cb != .ba and cb != .hy) return false;
    // LB13: no break before closers / terminators.
    if (ca == .cl or ca == .cp or ca == .ex or ca == .is or ca == .sy) return false;
    // LB14: no break after opening punctuation.
    if (cb == .op) return false;
    // LB19: quotes glue both ways.
    if (cb == .quote or ca == .quote) return false;
    // LB16: closer + nonstarter (」っ etc.).
    if ((cb == .cl or cb == .cp) and ca == .ns) return false;
    // LB17: em-dash pairs.
    if (cb == .b2 and ca == .b2) return false;
    // LB21: no break before BA/HY/NS; no break after BB.
    if (ca == .ba or ca == .hy or ca == .ns) return false;
    if (cb == .bb) return false;
    // LB22: no break before inseparables (…).
    if (ca == .in) return false;
    // LB23/LB23a: letters and numbers hold together; numeric prefixes
    // stick to ideographs.
    if (cb == .al and ca == .nu) return false;
    if (cb == .nu and ca == .al) return false;
    if (cb == .pr and ca == .id) return false;
    if (cb == .id and ca == .po) return false;
    // LB24: prefix/postfix + letters.
    if ((cb == .pr or cb == .po) and ca == .al) return false;
    if (cb == .al and (ca == .pr or ca == .po)) return false;
    // LB25 (pairwise approximation): "3.14", "-5", "1,234", "$5", "5%".
    if (ca == .nu and (cb == .nu or cb == .pr or cb == .po or cb == .hy or cb == .is or cb == .sy or cb == .op)) return false;
    if (cb == .nu and (ca == .po or ca == .pr)) return false;
    // LB28: no break inside alphabetic runs.
    if (cb == .al and ca == .al) return false;
    // LB29: "e.g" — IS followed by a letter.
    if (cb == .is and ca == .al) return false;
    // LB30: narrow parens stick to adjacent words/numbers.
    if ((cb == .al or cb == .nu) and ca == .op and cp_a < 0x3000) return false;
    // LB31: break everywhere else.
    return true;
}

/// True when UAX #14 permits a line break BEFORE byte offset `i`.
/// Offsets not on a codepoint boundary (or at the text edges) are
/// never opportunities.
pub fn isBreakOpportunity(text: []const u8, i: usize) bool {
    if (i == 0 or i >= text.len) return false;
    if (text[i] & 0xC0 == 0x80) return false;

    const after = unicode.decodeAt(text, i);
    const ca = classOf(after.cp);
    // LB7: never break before a space or ZW.
    if (ca == .sp or ca == .zw) return false;

    var before = decodeBeforePub(text, i);
    // LB8a: no break after ZWJ.
    if (unicode.classOf(before.cp) == .zwj) return false;
    // LB9: combining marks are transparent — the class before the
    // candidate is the class of the BASE character.
    while (true) {
        const g = unicode.classOf(before.cp);
        if ((g == .extend or g == .spacing_mark) and before.start > 0) {
            before = decodeBeforePub(text, before.start);
            continue;
        }
        break;
    }
    const cb = classOf(before.cp);

    if (cb == .sp) {
        // Walk to the last non-space before the run for the SP*-aware
        // rules; a run reaching the start of the text is plain LB18.
        var j = before;
        while (classOf(j.cp) == .sp) {
            if (j.start == 0) return true;
            j = decodeBeforePub(text, j.start);
        }
        const cp = classOf(j.cp);
        // LB8: ZW SP* allows the break.
        if (cp == .zw) return true;
        // LB14: OP SP* forbids it.
        if (cp == .op) return false;
        // LB15: QU SP* x OP.
        if (cp == .quote and ca == .op) return false;
        // LB16: (CL|CP) SP* x NS.
        if ((cp == .cl or cp == .cp) and ca == .ns) return false;
        // LB17: B2 SP* x B2.
        if (cp == .b2 and ca == .b2) return false;
        // LB18: break after spaces.
        return true;
    }

    return allowPair(cb, ca, before.cp, after.cp);
}

/// unicode.zig's decodeBefore is private; this mirrors it exactly via
/// prev/decode.
fn decodeBeforePub(text: []const u8, i: usize) struct { cp: u21, start: usize } {
    var j = i - 1;
    var back: usize = 0;
    while (j > 0 and (text[j] & 0xC0 == 0x80) and back < 3) {
        j -= 1;
        back += 1;
    }
    const seq_len = std.unicode.utf8ByteSequenceLength(text[j]) catch return .{ .cp = 0xFFFD, .start = i - 1 };
    if (j + seq_len != i) return .{ .cp = 0xFFFD, .start = i - 1 };
    const d = unicode.decodeAt(text, j);
    return .{ .cp = d.cp, .start = j };
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

test "linebreak range table is sorted and non-overlapping" {
    var prev_last: u21 = 0;
    for (ranges, 0..) |r, idx| {
        try testing.expect(r.first <= r.last);
        if (idx > 0) try testing.expect(r.first > prev_last);
        prev_last = r.last;
    }
}

fn opportunities(text: []const u8, out: []usize) []usize {
    var n: usize = 0;
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        if (isBreakOpportunity(text, i)) {
            out[n] = i;
            n += 1;
        }
    }
    return out[0..n];
}

test "linebreak: break after spaces, never before them" {
    var buf: [16]usize = undefined;
    // "foo bar  baz": opportunities at 4 (before bar) and 9 (before baz).
    try testing.expectEqualSlices(usize, &.{ 4, 9 }, opportunities("foo bar  baz", &buf));
    // Never inside a word.
    try testing.expectEqualSlices(usize, &.{}, opportunities("hello", &buf));
}

test "linebreak: break after a hyphen, but not inside numbers" {
    var buf: [16]usize = undefined;
    // "foo-bar": break permitted after the hyphen only.
    try testing.expectEqualSlices(usize, &.{4}, opportunities("foo-bar", &buf));
    // "-5" and "3.14" and "1,234" hold together.
    try testing.expectEqualSlices(usize, &.{}, opportunities("-5", &buf));
    try testing.expectEqualSlices(usize, &.{}, opportunities("3.14", &buf));
    try testing.expectEqualSlices(usize, &.{}, opportunities("1,234", &buf));
}

test "linebreak: forbidden before closing and after opening punctuation" {
    var buf: [16]usize = undefined;
    // "foo (bar)!" — the only opportunity is before "(" (after the
    // space); never after "(", before ")", or before "!".
    try testing.expectEqualSlices(usize, &.{4}, opportunities("foo (bar)!", &buf));
    // LB30: a paren glued to the word before it.
    try testing.expectEqualSlices(usize, &.{}, opportunities("f(x)", &buf));
}

test "linebreak: CJK breaks between ideographs" {
    var buf: [32]usize = undefined;
    // Three kanji: a break between each pair.
    const s = "\u{65E5}\u{672C}\u{8A9E}";
    try testing.expectEqualSlices(usize, &.{ 3, 6 }, opportunities(s, &buf));
    // Mixed Latin/CJK breaks at the script seam too.
    const m = "ab\u{4E00}cd";
    try testing.expectEqualSlices(usize, &.{ 2, 5 }, opportunities(m, &buf));
}

test "linebreak: kana nonstarters and CJK punctuation glue" {
    var buf: [32]usize = undefined;
    // katakana + prolonged sound mark: no break before ー.
    const s = "\u{30AB}\u{30FC}\u{30C9}"; // カード
    try testing.expectEqualSlices(usize, &.{6}, opportunities(s, &buf));
    // Ideograph + ideographic full stop: no break before 。, break after.
    const p = "\u{65E5}\u{3002}\u{672C}";
    try testing.expectEqualSlices(usize, &.{6}, opportunities(p, &buf));
    // No break after an opening CJK bracket, none before the closer.
    const q = "\u{300C}\u{65E5}\u{672C}\u{300D}";
    try testing.expectEqualSlices(usize, &.{6}, opportunities(q, &buf));
}

test "linebreak: NBSP glues, ZWSP breaks" {
    var buf: [16]usize = undefined;
    try testing.expectEqualSlices(usize, &.{}, opportunities("a\u{A0}b", &buf));
    // ZWSP between letters: break after it (byte 5, past the 3-byte
    // ZWSP), never before it.
    try testing.expectEqualSlices(usize, &.{5}, opportunities("ab\u{200B}cd", &buf));
}

test "linebreak: quotes glue to their neighbours" {
    var buf: [16]usize = undefined;
    // LB19: no break after an opening quote or before a closing one.
    try testing.expectEqualSlices(usize, &.{}, opportunities("\u{201C}hi\u{201D}", &buf));
}

test "linebreak: combining marks are transparent" {
    var buf: [16]usize = undefined;
    // "é" as e + U+0301, then a space, then x: opportunity only before x.
    const s = "e\u{301} x";
    try testing.expectEqualSlices(usize, &.{4}, opportunities(s, &buf));
    // A combining mark never creates an opportunity mid-cluster.
    try testing.expect(!isBreakOpportunity("e\u{301}x", 1));
}

test "linebreak: ellipsis and word joiner" {
    var buf: [16]usize = undefined;
    try testing.expectEqualSlices(usize, &.{}, opportunities("wait\u{2026}", &buf));
    try testing.expectEqualSlices(usize, &.{}, opportunities("a\u{2060}b", &buf));
}

test "linebreak: tab is break-after" {
    var buf: [16]usize = undefined;
    try testing.expectEqualSlices(usize, &.{2}, opportunities("a\tb", &buf));
}
