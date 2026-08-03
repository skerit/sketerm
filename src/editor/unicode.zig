//! Grapheme-cluster and word boundaries for cursor movement.
//!
//! Implements the UAX #29 grapheme break rules GB1-GB5, GB6-GB8
//! (Hangul), GB9 (Extend/ZWJ), GB9a (SpacingMark), GB9b (Prepend),
//! GB11 (ExtPict ZWJ ExtPict), GB12/GB13 (regional-indicator pairs),
//! GB999 — over a COMPACT embedded property table, not the full UCD:
//! Extend covers the major combining-mark blocks, variation selectors,
//! skin-tone modifiers and tag characters; SpacingMark and Prepend
//! carry representative subsets; Extended_Pictographic is approximated
//! by the emoji/symbol planes. Rare scripts may therefore over-split;
//! the rule ENGINE is complete, the data is deliberately small.
//!
//! Byte offsets not on a UTF-8 codepoint boundary are never grapheme
//! boundaries. Invalid bytes are treated as one-cpoint clusters.

const std = @import("std");

pub const GbClass = enum {
    other,
    cr,
    lf,
    control,
    extend,
    zwj,
    ri,
    prepend,
    spacing_mark,
    hangul_l,
    hangul_v,
    hangul_t,
    hangul_lv,
    hangul_lvt,
    ext_pict,
};

const Range = struct { first: u21, last: u21, class: GbClass };

// Sorted by `first`; checked by a test. Kept compact on purpose (see
// module doc).
const ranges = [_]Range{
    .{ .first = 0x0000, .last = 0x0009, .class = .control },
    .{ .first = 0x000A, .last = 0x000A, .class = .lf },
    .{ .first = 0x000B, .last = 0x000C, .class = .control },
    .{ .first = 0x000D, .last = 0x000D, .class = .cr },
    .{ .first = 0x000E, .last = 0x001F, .class = .control },
    .{ .first = 0x007F, .last = 0x009F, .class = .control },
    .{ .first = 0x00AD, .last = 0x00AD, .class = .control }, // soft hyphen (Cf)
    .{ .first = 0x0300, .last = 0x036F, .class = .extend }, // combining diacriticals
    .{ .first = 0x0483, .last = 0x0489, .class = .extend }, // Cyrillic combining
    .{ .first = 0x0591, .last = 0x05BD, .class = .extend }, // Hebrew points
    .{ .first = 0x05BF, .last = 0x05BF, .class = .extend },
    .{ .first = 0x05C1, .last = 0x05C2, .class = .extend },
    .{ .first = 0x05C4, .last = 0x05C5, .class = .extend },
    .{ .first = 0x05C7, .last = 0x05C7, .class = .extend },
    .{ .first = 0x0600, .last = 0x0605, .class = .prepend }, // Arabic number signs
    .{ .first = 0x0610, .last = 0x061A, .class = .extend }, // Arabic marks
    .{ .first = 0x064B, .last = 0x065F, .class = .extend }, // Arabic harakat
    .{ .first = 0x0670, .last = 0x0670, .class = .extend },
    .{ .first = 0x06D6, .last = 0x06DC, .class = .extend },
    .{ .first = 0x06DD, .last = 0x06DD, .class = .prepend },
    .{ .first = 0x06DF, .last = 0x06E4, .class = .extend },
    .{ .first = 0x06E7, .last = 0x06E8, .class = .extend },
    .{ .first = 0x06EA, .last = 0x06ED, .class = .extend },
    .{ .first = 0x0711, .last = 0x0711, .class = .extend }, // Syriac
    .{ .first = 0x0730, .last = 0x074A, .class = .extend },
    .{ .first = 0x07A6, .last = 0x07B0, .class = .extend }, // Thaana
    .{ .first = 0x07EB, .last = 0x07F3, .class = .extend }, // NKo
    .{ .first = 0x0816, .last = 0x0819, .class = .extend }, // Samaritan
    .{ .first = 0x081B, .last = 0x0823, .class = .extend },
    .{ .first = 0x0825, .last = 0x0827, .class = .extend },
    .{ .first = 0x0829, .last = 0x082D, .class = .extend },
    .{ .first = 0x0859, .last = 0x085B, .class = .extend }, // Mandaic
    .{ .first = 0x08D3, .last = 0x08E1, .class = .extend }, // Arabic extended
    .{ .first = 0x08E2, .last = 0x08E2, .class = .prepend },
    .{ .first = 0x08E3, .last = 0x0902, .class = .extend }, // Arabic + Devanagari Mn
    .{ .first = 0x0903, .last = 0x0903, .class = .spacing_mark }, // Devanagari sign visarga
    .{ .first = 0x093A, .last = 0x093A, .class = .extend },
    .{ .first = 0x093B, .last = 0x093B, .class = .spacing_mark },
    .{ .first = 0x093C, .last = 0x093C, .class = .extend },
    .{ .first = 0x093E, .last = 0x0940, .class = .spacing_mark },
    .{ .first = 0x0941, .last = 0x0948, .class = .extend },
    .{ .first = 0x0949, .last = 0x094C, .class = .spacing_mark },
    .{ .first = 0x094D, .last = 0x094D, .class = .extend },
    .{ .first = 0x094E, .last = 0x094F, .class = .spacing_mark },
    .{ .first = 0x0951, .last = 0x0957, .class = .extend },
    .{ .first = 0x0962, .last = 0x0963, .class = .extend },
    .{ .first = 0x0981, .last = 0x0981, .class = .extend }, // Bengali
    .{ .first = 0x0982, .last = 0x0983, .class = .spacing_mark },
    .{ .first = 0x09BC, .last = 0x09BC, .class = .extend },
    .{ .first = 0x09BE, .last = 0x09BE, .class = .extend }, // Bengali AA (Extend per UAX)
    .{ .first = 0x09BF, .last = 0x09C0, .class = .spacing_mark },
    .{ .first = 0x09C1, .last = 0x09C4, .class = .extend },
    .{ .first = 0x09C7, .last = 0x09C8, .class = .spacing_mark },
    .{ .first = 0x09CB, .last = 0x09CC, .class = .spacing_mark },
    .{ .first = 0x09CD, .last = 0x09CD, .class = .extend },
    .{ .first = 0x09D7, .last = 0x09D7, .class = .extend },
    .{ .first = 0x0A01, .last = 0x0A02, .class = .extend }, // Gurmukhi
    .{ .first = 0x0A03, .last = 0x0A03, .class = .spacing_mark },
    .{ .first = 0x0A3C, .last = 0x0A3C, .class = .extend },
    .{ .first = 0x0A41, .last = 0x0A42, .class = .extend },
    .{ .first = 0x0A47, .last = 0x0A48, .class = .extend },
    .{ .first = 0x0A4B, .last = 0x0A4D, .class = .extend },
    .{ .first = 0x0B01, .last = 0x0B01, .class = .extend }, // Oriya
    .{ .first = 0x0BBE, .last = 0x0BBE, .class = .extend }, // Tamil AA
    .{ .first = 0x0BCD, .last = 0x0BCD, .class = .extend },
    .{ .first = 0x0C00, .last = 0x0C00, .class = .extend }, // Telugu
    .{ .first = 0x0C81, .last = 0x0C81, .class = .extend }, // Kannada
    .{ .first = 0x0D00, .last = 0x0D01, .class = .extend }, // Malayalam
    .{ .first = 0x0D4E, .last = 0x0D4E, .class = .prepend },
    .{ .first = 0x0E31, .last = 0x0E31, .class = .extend }, // Thai
    .{ .first = 0x0E33, .last = 0x0E33, .class = .spacing_mark }, // SARA AM
    .{ .first = 0x0E34, .last = 0x0E3A, .class = .extend },
    .{ .first = 0x0E47, .last = 0x0E4E, .class = .extend },
    .{ .first = 0x0EB1, .last = 0x0EB1, .class = .extend }, // Lao
    .{ .first = 0x0EB4, .last = 0x0EBC, .class = .extend },
    .{ .first = 0x0EC8, .last = 0x0ECD, .class = .extend },
    .{ .first = 0x0F35, .last = 0x0F35, .class = .extend }, // Tibetan
    .{ .first = 0x0F37, .last = 0x0F37, .class = .extend },
    .{ .first = 0x0F39, .last = 0x0F39, .class = .extend },
    .{ .first = 0x0F71, .last = 0x0F7E, .class = .extend },
    .{ .first = 0x0F80, .last = 0x0F84, .class = .extend },
    .{ .first = 0x102D, .last = 0x1030, .class = .extend }, // Myanmar
    .{ .first = 0x1032, .last = 0x1037, .class = .extend },
    .{ .first = 0x1039, .last = 0x103A, .class = .extend },
    .{ .first = 0x1100, .last = 0x115F, .class = .hangul_l },
    .{ .first = 0x1160, .last = 0x11A7, .class = .hangul_v },
    .{ .first = 0x11A8, .last = 0x11FF, .class = .hangul_t },
    .{ .first = 0x135D, .last = 0x135F, .class = .extend }, // Ethiopic
    .{ .first = 0x1712, .last = 0x1714, .class = .extend }, // Tagalog
    .{ .first = 0x17B4, .last = 0x17B5, .class = .extend }, // Khmer
    .{ .first = 0x17B7, .last = 0x17BD, .class = .extend },
    .{ .first = 0x17C6, .last = 0x17C6, .class = .extend },
    .{ .first = 0x17C9, .last = 0x17D3, .class = .extend },
    .{ .first = 0x180B, .last = 0x180D, .class = .extend }, // Mongolian FVS
    .{ .first = 0x180E, .last = 0x180E, .class = .control }, // Mongolian vowel sep (Cf)
    .{ .first = 0x1A17, .last = 0x1A18, .class = .extend }, // Buginese
    .{ .first = 0x1AB0, .last = 0x1AFF, .class = .extend }, // combining ext
    .{ .first = 0x1DC0, .last = 0x1DFF, .class = .extend }, // combining supplement
    .{ .first = 0x200B, .last = 0x200B, .class = .control }, // ZWSP
    .{ .first = 0x200C, .last = 0x200C, .class = .extend }, // ZWNJ
    .{ .first = 0x200D, .last = 0x200D, .class = .zwj },
    .{ .first = 0x200E, .last = 0x200F, .class = .control }, // LRM/RLM (Cf)
    .{ .first = 0x2028, .last = 0x202E, .class = .control }, // LS/PS + directional
    .{ .first = 0x2060, .last = 0x206F, .class = .control }, // word joiner etc. (Cf)
    .{ .first = 0x20D0, .last = 0x20F0, .class = .extend }, // combining for symbols
    .{ .first = 0x2CEF, .last = 0x2CF1, .class = .extend }, // Coptic
    .{ .first = 0x2DE0, .last = 0x2DFF, .class = .extend }, // Cyrillic ext-A
    .{ .first = 0x302A, .last = 0x302F, .class = .extend }, // CJK tone marks
    .{ .first = 0x3099, .last = 0x309A, .class = .extend }, // kana voicing
    .{ .first = 0xA66F, .last = 0xA672, .class = .extend },
    .{ .first = 0xA674, .last = 0xA67D, .class = .extend },
    .{ .first = 0xA69E, .last = 0xA69F, .class = .extend },
    .{ .first = 0xA8E0, .last = 0xA8F1, .class = .extend }, // Devanagari ext
    .{ .first = 0xA960, .last = 0xA97C, .class = .hangul_l },
    .{ .first = 0xAC00, .last = 0xD7A3, .class = .hangul_lv }, // LV/LVT resolved in classOf
    .{ .first = 0xD7B0, .last = 0xD7C6, .class = .hangul_v },
    .{ .first = 0xD7CB, .last = 0xD7FB, .class = .hangul_t },
    .{ .first = 0xFB1E, .last = 0xFB1E, .class = .extend }, // Hebrew point judeo-spanish
    .{ .first = 0xFE00, .last = 0xFE0F, .class = .extend }, // variation selectors
    .{ .first = 0xFE20, .last = 0xFE2F, .class = .extend }, // combining half marks
    .{ .first = 0xFEFF, .last = 0xFEFF, .class = .control }, // BOM/ZWNBSP
    .{ .first = 0xFF9E, .last = 0xFF9F, .class = .extend }, // halfwidth kana voicing
    .{ .first = 0xFFF9, .last = 0xFFFB, .class = .control }, // interlinear
    .{ .first = 0x101FD, .last = 0x101FD, .class = .extend },
    .{ .first = 0x10376, .last = 0x1037A, .class = .extend },
    .{ .first = 0x11000, .last = 0x11000, .class = .spacing_mark }, // Brahmi
    .{ .first = 0x11001, .last = 0x11001, .class = .extend },
    .{ .first = 0x11002, .last = 0x11002, .class = .spacing_mark },
    .{ .first = 0x110BD, .last = 0x110BD, .class = .prepend },
    .{ .first = 0x110CD, .last = 0x110CD, .class = .prepend },
    .{ .first = 0x11100, .last = 0x11102, .class = .extend }, // Chakma
    .{ .first = 0x1D165, .last = 0x1D169, .class = .extend }, // musical
    .{ .first = 0x1D16D, .last = 0x1D172, .class = .extend },
    .{ .first = 0x1D173, .last = 0x1D17A, .class = .control }, // musical Cf
    .{ .first = 0x1D17B, .last = 0x1D182, .class = .extend },
    .{ .first = 0x1D185, .last = 0x1D18B, .class = .extend },
    .{ .first = 0x1D1AA, .last = 0x1D1AD, .class = .extend },
    .{ .first = 0x1F1E6, .last = 0x1F1FF, .class = .ri },
    .{ .first = 0x1F3FB, .last = 0x1F3FF, .class = .extend }, // skin tone modifiers
    .{ .first = 0xE0001, .last = 0xE0001, .class = .control }, // language tag
    .{ .first = 0xE0020, .last = 0xE007F, .class = .extend }, // tag characters
    .{ .first = 0xE0100, .last = 0xE01EF, .class = .extend }, // VS supplement
};

// Extended_Pictographic approximation: the emoji/symbol blocks. Checked
// AFTER the range table so RI and skin tones win.
fn isExtPict(cp: u21) bool {
    return switch (cp) {
        0x00A9, 0x00AE, 0x203C, 0x2049, 0x2122, 0x2139 => true,
        0x2194...0x21AA => true,
        0x231A...0x231B => true,
        0x2328, 0x23CF => true,
        0x23E9...0x23FA => true,
        0x24C2 => true,
        0x25AA...0x25FE => true,
        0x2600...0x27BF => true,
        0x2934...0x2935 => true,
        0x2B00...0x2BFF => true,
        0x3030, 0x303D, 0x3297, 0x3299 => true,
        0x1F000...0x1F0FF => true,
        0x1F10D...0x1F10F => true,
        0x1F12F, 0x1F16C...0x1F171, 0x1F17E...0x1F17F, 0x1F18E => true,
        0x1F191...0x1F19A => true,
        0x1F201...0x1F320 => true,
        0x1F321...0x1F3FA => true, // NOT 1F3FB-FF (skin tones, handled first)
        0x1F400...0x1FAFF => true,
        0x1FC00...0x1FFFD => true,
        else => false,
    };
}

/// Grapheme-break class of a codepoint.
pub fn classOf(cp: u21) GbClass {
    // Binary search the sorted range table.
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
            if (r.class == .hangul_lv) {
                // Precomposed syllable block: LV when T index is 0.
                const idx = cp - 0xAC00;
                return if (idx % 28 == 0) .hangul_lv else .hangul_lvt;
            }
            return r.class;
        }
    }
    if (isExtPict(cp)) return .ext_pict;
    return .other;
}

// ---- UTF-8 walking ---------------------------------------------------

fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// Decodes the codepoint starting at `i`; invalid bytes decode as
/// U+FFFD with length 1.
pub fn decodeAt(text: []const u8, i: usize) struct { cp: u21, len: usize } {
    const b = text[i];
    const seq_len = std.unicode.utf8ByteSequenceLength(b) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (i + seq_len > text.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(text[i .. i + seq_len]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = seq_len };
}

/// Byte index of the codepoint that ENDS at `i` (i > 0).
fn prevCpStart(text: []const u8, i: usize) usize {
    var j = i - 1;
    var back: usize = 0;
    while (j > 0 and isContinuation(text[j]) and back < 3) {
        j -= 1;
        back += 1;
    }
    // Validate that the lead byte really spans to i; else treat the
    // byte before i as a 1-byte (invalid) codepoint.
    const seq_len = std.unicode.utf8ByteSequenceLength(text[j]) catch return i - 1;
    if (j + seq_len != i) return i - 1;
    return j;
}

fn decodeBefore(text: []const u8, i: usize) struct { cp: u21, start: usize } {
    const s = prevCpStart(text, i);
    const d = decodeAt(text, s);
    if (s + d.len != i) return .{ .cp = 0xFFFD, .start = i - 1 };
    return .{ .cp = d.cp, .start = s };
}

// ---- grapheme boundaries ---------------------------------------------

/// True when a grapheme cluster boundary lies at byte offset `i`.
pub fn isGraphemeBoundary(text: []const u8, i: usize) bool {
    if (i == 0 or i >= text.len) return true;
    if (isContinuation(text[i])) return false;

    const before = decodeBefore(text, i);
    const after = decodeAt(text, i);
    const cb = classOf(before.cp);
    const ca = classOf(after.cp);

    // GB3: CR x LF.
    if (cb == .cr and ca == .lf) return false;
    // GB4: break after Control | CR | LF.
    if (cb == .control or cb == .cr or cb == .lf) return true;
    // GB5: break before Control | CR | LF.
    if (ca == .control or ca == .cr or ca == .lf) return true;
    // GB6: L x (L | V | LV | LVT).
    if (cb == .hangul_l and (ca == .hangul_l or ca == .hangul_v or ca == .hangul_lv or ca == .hangul_lvt)) return false;
    // GB7: (LV | V) x (V | T).
    if ((cb == .hangul_lv or cb == .hangul_v) and (ca == .hangul_v or ca == .hangul_t)) return false;
    // GB8: (LVT | T) x T.
    if ((cb == .hangul_lvt or cb == .hangul_t) and ca == .hangul_t) return false;
    // GB9: x (Extend | ZWJ).
    if (ca == .extend or ca == .zwj) return false;
    // GB9a: x SpacingMark.
    if (ca == .spacing_mark) return false;
    // GB9b: Prepend x.
    if (cb == .prepend) return false;
    // GB11: ExtPict Extend* ZWJ x ExtPict.
    if (cb == .zwj and ca == .ext_pict) {
        var j = before.start;
        while (j > 0) {
            const p = decodeBefore(text, j);
            const pc = classOf(p.cp);
            if (pc == .extend) {
                j = p.start;
                continue;
            }
            if (pc == .ext_pict) return false;
            break;
        }
    }
    // GB12/GB13: RI pairs — break only between complete pairs.
    if (cb == .ri and ca == .ri) {
        var count: usize = 1; // the RI just before i
        var j = before.start;
        while (j > 0) {
            const p = decodeBefore(text, j);
            if (classOf(p.cp) != .ri) break;
            count += 1;
            j = p.start;
        }
        if (count % 2 == 1) return false;
    }
    // GB999.
    return true;
}

/// Next grapheme boundary strictly after `i` (clamps to text.len).
pub fn nextGrapheme(text: []const u8, i: usize) usize {
    if (i >= text.len) return text.len;
    var j = i + decodeAt(text, i).len;
    while (j < text.len and !isGraphemeBoundary(text, j)) {
        j += decodeAt(text, j).len;
    }
    return @min(j, text.len);
}

/// Previous grapheme boundary strictly before `i` (clamps to 0).
pub fn prevGrapheme(text: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var j = @min(i, text.len);
    j = decodeBefore(text, j).start;
    while (j > 0 and !isGraphemeBoundary(text, j)) {
        j = decodeBefore(text, j).start;
    }
    return j;
}

// ---- word boundaries -------------------------------------------------

pub const WordClass = enum { space, word, punct };

/// Simple three-way classification: whitespace, word (alphanumeric,
/// underscore, and any letter-ish cp >= 0x80 that isn't punctuation),
/// punct otherwise.
pub fn wordClassOf(cp: u21) WordClass {
    switch (cp) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C => return .space,
        0xA0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000 => return .space,
        '_' => return .word,
        '0'...'9', 'a'...'z', 'A'...'Z' => return .word,
        0x2010...0x2027, 0x2030...0x205E => return .punct, // general punctuation
        0x3001...0x3003, 0x3008...0x3011, 0x3014...0x301F => return .punct, // CJK punct
        0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65 => return .punct,
        else => {
            if (cp < 0x80) return .punct; // remaining ASCII
            return .word;
        },
    }
}

/// Moves right to the end of the current-or-next word run: skips
/// whitespace, then one run of a single class.
pub fn nextWordBoundary(text: []const u8, i: usize) usize {
    var j = @min(i, text.len);
    // Skip whitespace.
    while (j < text.len) {
        const d = decodeAt(text, j);
        if (wordClassOf(d.cp) != .space) break;
        j += d.len;
    }
    if (j >= text.len) return text.len;
    const cls = wordClassOf(decodeAt(text, j).cp);
    while (j < text.len) {
        const d = decodeAt(text, j);
        if (wordClassOf(d.cp) != cls) break;
        j += d.len;
    }
    return j;
}

/// Moves left to the start of the current-or-previous word run.
pub fn prevWordBoundary(text: []const u8, i: usize) usize {
    var j = @min(i, text.len);
    while (j > 0) {
        const d = decodeBefore(text, j);
        if (wordClassOf(d.cp) != .space) break;
        j = d.start;
    }
    if (j == 0) return 0;
    const cls = wordClassOf(decodeBefore(text, j).cp);
    while (j > 0) {
        const d = decodeBefore(text, j);
        if (wordClassOf(d.cp) != cls) break;
        j = d.start;
    }
    return j;
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

test "range table is sorted and non-overlapping" {
    var prev_last: u21 = 0;
    for (ranges, 0..) |r, idx| {
        try testing.expect(r.first <= r.last);
        if (idx > 0) try testing.expect(r.first > prev_last);
        prev_last = r.last;
    }
}

fn collectBoundaries(text: []const u8, out: []usize) []usize {
    var n: usize = 0;
    var i: usize = 0;
    out[n] = 0;
    n += 1;
    while (i < text.len) {
        i = nextGrapheme(text, i);
        out[n] = i;
        n += 1;
    }
    return out[0..n];
}

test "grapheme ASCII splits per byte" {
    var buf: [16]usize = undefined;
    const b = collectBoundaries("abc", &buf);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, b);
}

test "grapheme CRLF is one cluster, lone CR and LF are not" {
    try testing.expect(!isGraphemeBoundary("a\r\nb", 2));
    var buf: [16]usize = undefined;
    const b = collectBoundaries("a\r\nb", &buf);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 3, 4 }, b);
    const b2 = collectBoundaries("\n\n", &buf);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, b2);
}

test "grapheme combining marks attach" {
    // e + U+0301 combining acute = one cluster.
    const s = "e\u{301}x";
    try testing.expect(!isGraphemeBoundary(s, 1));
    try testing.expectEqual(@as(usize, 3), nextGrapheme(s, 0));
    try testing.expectEqual(@as(usize, 0), prevGrapheme(s, 3));
    try testing.expectEqual(@as(usize, 3), prevGrapheme(s, 4));
}

test "grapheme multiple combining marks" {
    const s = "a\u{300}\u{301}\u{302}b";
    try testing.expectEqual(@as(usize, 7), nextGrapheme(s, 0));
    try testing.expectEqual(@as(usize, 0), prevGrapheme(s, 7));
}

test "grapheme ZWJ emoji family is one cluster" {
    // 👨‍👩‍👧 = MAN ZWJ WOMAN ZWJ GIRL.
    const s = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    try testing.expectEqual(s.len, nextGrapheme(s, 0));
    try testing.expectEqual(@as(usize, 0), prevGrapheme(s, s.len));
}

test "grapheme skin tone modifier attaches" {
    const s = "\u{1F44D}\u{1F3FD}x"; // thumbs up + medium skin tone
    try testing.expectEqual(@as(usize, 8), nextGrapheme(s, 0));
}

test "grapheme regional indicator pairs" {
    // Two flags: BE (B+E) then NL (N+L) — boundary between pairs only.
    const s = "\u{1F1E7}\u{1F1EA}\u{1F1F3}\u{1F1F1}";
    var buf: [8]usize = undefined;
    const b = collectBoundaries(s, &buf);
    try testing.expectEqualSlices(usize, &.{ 0, 8, 16 }, b);
    // Odd RI run: three RIs = pair + single.
    const s3 = "\u{1F1E7}\u{1F1EA}\u{1F1F3}";
    const b3 = collectBoundaries(s3, &buf);
    try testing.expectEqualSlices(usize, &.{ 0, 8, 12 }, b3);
}

test "grapheme Hangul syllable sequences" {
    // L + V + T conjoining jamo = one cluster.
    const s = "\u{1100}\u{1161}\u{11A8}";
    try testing.expectEqual(s.len, nextGrapheme(s, 0));
    // Precomposed LV + T.
    const s2 = "\u{AC00}\u{11A8}x";
    try testing.expectEqual(@as(usize, 6), nextGrapheme(s2, 0));
}

test "grapheme keycap and variation selector" {
    const s = "1\u{FE0F}\u{20E3}"; // keycap-1: digit + VS16 + combining keycap
    try testing.expectEqual(s.len, nextGrapheme(s, 0));
}

test "grapheme non-boundary offsets inside UTF-8 sequences" {
    const s = "\u{1F600}"; // 4 bytes
    try testing.expect(isGraphemeBoundary(s, 0));
    try testing.expect(!isGraphemeBoundary(s, 1));
    try testing.expect(!isGraphemeBoundary(s, 2));
    try testing.expect(!isGraphemeBoundary(s, 3));
    try testing.expect(isGraphemeBoundary(s, 4));
}

test "word boundaries simple" {
    const s = "foo bar_baz, qux";
    try testing.expectEqual(@as(usize, 3), nextWordBoundary(s, 0));
    try testing.expectEqual(@as(usize, 11), nextWordBoundary(s, 3)); // skips space, eats bar_baz
    try testing.expectEqual(@as(usize, 12), nextWordBoundary(s, 11)); // the comma
    try testing.expectEqual(@as(usize, 16), nextWordBoundary(s, 12));
    try testing.expectEqual(@as(usize, 13), prevWordBoundary(s, 16));
    try testing.expectEqual(@as(usize, 11), prevWordBoundary(s, 12));
    try testing.expectEqual(@as(usize, 4), prevWordBoundary(s, 11));
    try testing.expectEqual(@as(usize, 0), prevWordBoundary(s, 3));
    try testing.expectEqual(@as(usize, 0), prevWordBoundary(s, 0));
    try testing.expectEqual(s.len, nextWordBoundary(s, s.len));
}

test "word boundaries with non-ASCII letters" {
    const s = "caf\u{e9} au";
    try testing.expectEqual(@as(usize, 5), nextWordBoundary(s, 0));
    try testing.expectEqual(@as(usize, 6), prevWordBoundary(s, 8));
    try testing.expectEqual(@as(usize, 0), prevWordBoundary(s, 5));
}
