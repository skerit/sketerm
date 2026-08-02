//! Tiny backtracking matcher over bytes — the pattern language behind
//! the MCP tools' `pattern` arguments (app_log grep, app_wait_log).
//!
//! Deliberately a SUBSET of regex: literal text, `.`, `[a-z]` /
//! `[^...]` classes, the `* + ?` quantifiers, `^` / `$` anchors, and
//! top-level `|` alternation. There are no groups, captures,
//! backreferences or lazy quantifiers, so `(` and `)` are LITERALS —
//! log lines are full of them and `focus(` should mean what it says.
//! The search is unanchored: a pattern matches if it matches anywhere
//! in the line.
//!
//! Everything is allocated from the caller's allocator (an arena in
//! every current caller), so a compiled Matcher has no deinit.

const std = @import("std");

pub const Error = error{ BadPattern, OutOfMemory };

const Atom = union(enum) {
    ch: u8,
    any,
    /// 256-bit membership bitmap; negation is folded in at parse time.
    class: [32]u8,
    /// Zero-width start-of-string.
    bol,
    /// Zero-width end-of-string.
    eol,
};

const INF: u32 = std.math.maxInt(u32);

const Piece = struct {
    atom: Atom,
    min: u32 = 1,
    max: u32 = 1,
};

const MAX_PIECES = 512;
const MAX_ALTS = 64;

pub const Matcher = struct {
    alts: []const []const Piece,
    ci: bool,

    /// True when any alternative matches anywhere in `s`.
    pub fn matches(self: Matcher, s: []const u8) bool {
        for (self.alts) |alt| {
            if (alt.len == 0) return true;
            var start: usize = 0;
            while (true) : (start += 1) {
                if (self.matchAlt(alt, 0, s, start)) return true;
                if (start >= s.len) break;
            }
        }
        return false;
    }

    fn fold(self: Matcher, b: u8) u8 {
        return if (self.ci) std.ascii.toLower(b) else b;
    }

    fn atomMatches(self: Matcher, atom: Atom, b: u8) bool {
        return switch (atom) {
            .ch => |c| self.fold(c) == self.fold(b),
            .any => true,
            .class => |bm| blk: {
                if (inClass(bm, b)) break :blk true;
                // A case-insensitive class matches either case; the
                // bitmap itself already carries both for literal
                // members, but ranges are cheaper to fold here.
                if (!self.ci) break :blk false;
                const other = if (std.ascii.isLower(b)) std.ascii.toUpper(b) else std.ascii.toLower(b);
                break :blk inClass(bm, other);
            },
            .bol, .eol => false,
        };
    }

    fn matchAlt(self: Matcher, alt: []const Piece, i: usize, s: []const u8, pos: usize) bool {
        if (i == alt.len) return true;
        const p = alt[i];
        switch (p.atom) {
            .bol => return pos == 0 and self.matchAlt(alt, i + 1, s, pos),
            .eol => return pos == s.len and self.matchAlt(alt, i + 1, s, pos),
            else => {},
        }
        // Greedy: consume as much as the quantifier allows, then give
        // characters back one at a time until the rest of the
        // alternative fits.
        var count: u32 = 0;
        var q = pos;
        while (count < p.max and q < s.len and self.atomMatches(p.atom, s[q])) {
            q += 1;
            count += 1;
        }
        if (count < p.min) return false;
        var n = count;
        while (true) {
            if (self.matchAlt(alt, i + 1, s, pos + n)) return true;
            if (n == p.min) return false;
            n -= 1;
        }
    }
};

fn inClass(bm: [32]u8, b: u8) bool {
    return bm[b >> 3] & (@as(u8, 1) << @intCast(b & 7)) != 0;
}

fn setBit(bm: *[32]u8, b: u8) void {
    bm[b >> 3] |= @as(u8, 1) << @intCast(b & 7);
}

fn setRange(bm: *[32]u8, lo: u8, hi: u8) void {
    var b: u16 = lo;
    while (b <= hi) : (b += 1) setBit(bm, @intCast(b));
}

/// Bitmap for a `\d`-style escape, or null when `e` is not one.
fn escapeClass(e: u8) ?[32]u8 {
    var bm = std.mem.zeroes([32]u8);
    switch (e) {
        'd', 'D' => setRange(&bm, '0', '9'),
        'w', 'W' => {
            setRange(&bm, '0', '9');
            setRange(&bm, 'a', 'z');
            setRange(&bm, 'A', 'Z');
            setBit(&bm, '_');
        },
        's', 'S' => {
            setBit(&bm, ' ');
            setBit(&bm, '\t');
            setBit(&bm, '\n');
            setBit(&bm, '\r');
            setBit(&bm, 0x0b);
            setBit(&bm, 0x0c);
        },
        else => return null,
    }
    if (e == 'D' or e == 'W' or e == 'S') {
        for (&bm) |*byte| byte.* = ~byte.*;
    }
    return bm;
}

/// The literal byte an escape denotes (`\t` → tab, `\.` → '.').
fn escapeChar(e: u8) u8 {
    return switch (e) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '0' => 0,
        else => e,
    };
}

/// Compile `pat`. `ci` = ASCII case-insensitive. An empty pattern is
/// rejected rather than silently matching everything — a tool that
/// filtered on "" would look like it matched, which is exactly the
/// class of lie this module exists to avoid.
pub fn compile(allocator: std.mem.Allocator, pat: []const u8, ci: bool) Error!Matcher {
    if (pat.len == 0) return Error.BadPattern;
    var alts: std.ArrayList([]const Piece) = .empty;
    errdefer alts.deinit(allocator);

    var seg_start: usize = 0;
    var i: usize = 0;
    while (true) {
        const at_end = i >= pat.len;
        // A '|' inside a class or right after a backslash is literal.
        if (at_end or pat[i] == '|') {
            if (alts.items.len >= MAX_ALTS) return Error.BadPattern;
            const alt = try compileAlt(allocator, pat[seg_start..i]);
            try alts.append(allocator, alt);
            if (at_end) break;
            seg_start = i + 1;
            i += 1;
            continue;
        }
        if (pat[i] == '\\') {
            // Clamped: a trailing backslash must not step the segment
            // end past the pattern (compileAlt rejects it properly).
            i = @min(i + 2, pat.len);
            continue;
        }
        if (pat[i] == '[') {
            // Skip to the closing ']' so a '|' inside stays literal.
            var j = i + 1;
            if (j < pat.len and pat[j] == '^') j += 1;
            if (j < pat.len and pat[j] == ']') j += 1;
            while (j < pat.len and pat[j] != ']') : (j += 1) {
                if (pat[j] == '\\') j += 1;
            }
            if (j >= pat.len) return Error.BadPattern;
            i = j + 1;
            continue;
        }
        i += 1;
    }
    return .{ .alts = try alts.toOwnedSlice(allocator), .ci = ci };
}

fn compileAlt(allocator: std.mem.Allocator, src: []const u8) Error![]const Piece {
    var pieces: std.ArrayList(Piece) = .empty;
    errdefer pieces.deinit(allocator);
    var i: usize = 0;
    while (i < src.len) {
        if (pieces.items.len >= MAX_PIECES) return Error.BadPattern;
        var atom: Atom = undefined;
        var anchor = false;
        switch (src[i]) {
            '^' => {
                if (i == 0) {
                    atom = .bol;
                    anchor = true;
                } else atom = .{ .ch = '^' };
                i += 1;
            },
            '$' => {
                if (i == src.len - 1) {
                    atom = .eol;
                    anchor = true;
                } else atom = .{ .ch = '$' };
                i += 1;
            },
            '.' => {
                atom = .any;
                i += 1;
            },
            '\\' => {
                if (i + 1 >= src.len) return Error.BadPattern;
                const e = src[i + 1];
                atom = if (escapeClass(e)) |bm| .{ .class = bm } else .{ .ch = escapeChar(e) };
                i += 2;
            },
            '[' => {
                var bm = std.mem.zeroes([32]u8);
                var j = i + 1;
                var negate = false;
                if (j < src.len and src[j] == '^') {
                    negate = true;
                    j += 1;
                }
                // A ']' in first position is a literal member.
                if (j < src.len and src[j] == ']') {
                    setBit(&bm, ']');
                    j += 1;
                }
                var any_member = false;
                while (j < src.len and src[j] != ']') {
                    var lo: u8 = src[j];
                    if (lo == '\\' and j + 1 < src.len) {
                        j += 1;
                        if (escapeClass(src[j])) |sub| {
                            for (&bm, sub) |*b, sb| b.* |= sb;
                            any_member = true;
                            j += 1;
                            continue;
                        }
                        lo = escapeChar(src[j]);
                    }
                    // "a-z", but a trailing '-' is a literal member.
                    if (j + 2 < src.len and src[j + 1] == '-' and src[j + 2] != ']') {
                        var hi: u8 = src[j + 2];
                        var adv: usize = 3;
                        if (hi == '\\' and j + 3 < src.len) {
                            hi = escapeChar(src[j + 3]);
                            adv = 4;
                        }
                        if (hi < lo) return Error.BadPattern;
                        setRange(&bm, lo, hi);
                        j += adv;
                    } else {
                        setBit(&bm, lo);
                        j += 1;
                    }
                    any_member = true;
                }
                if (j >= src.len) return Error.BadPattern;
                if (!any_member) return Error.BadPattern;
                if (negate) {
                    for (&bm) |*b| b.* = ~b.*;
                }
                atom = .{ .class = bm };
                i = j + 1;
            },
            else => {
                atom = .{ .ch = src[i] };
                i += 1;
            },
        }
        var min: u32 = 1;
        var max: u32 = 1;
        if (i < src.len) {
            switch (src[i]) {
                '*' => {
                    min = 0;
                    max = INF;
                    i += 1;
                },
                '+' => {
                    min = 1;
                    max = INF;
                    i += 1;
                },
                '?' => {
                    min = 0;
                    max = 1;
                    i += 1;
                },
                else => {},
            }
        }
        // A quantified anchor is meaningless; reject rather than
        // silently matching something else than the caller wrote.
        if (anchor and (min != 1 or max != 1)) return Error.BadPattern;
        try pieces.append(allocator, .{ .atom = atom, .min = min, .max = max });
    }
    return pieces.toOwnedSlice(allocator);
}

/// One-shot convenience: compile and test. Errors propagate so the
/// caller can report a bad pattern instead of "no matches".
pub fn matches(allocator: std.mem.Allocator, pat: []const u8, s: []const u8, ci: bool) Error!bool {
    const m = try compile(allocator, pat, ci);
    return m.matches(s);
}

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

fn hit(pat: []const u8, s: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    return matches(arena.allocator(), pat, s, false);
}

fn hitCi(pat: []const u8, s: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    return matches(arena.allocator(), pat, s, true);
}

test "literal substring search is unanchored" {
    try t.expect(try hit("death", "DIAG death: 'fente'"));
    try t.expect(!try hit("death", "DIAG born"));
    try t.expect(try hit("DIAG", "DIAG death"));
}

test "alternation" {
    try t.expect(try hit("WINTEST|DIAG death", "DIAG death: x"));
    try t.expect(try hit("WINTEST|DIAG death", "a WINTEST b"));
    try t.expect(!try hit("WINTEST|DIAG death", "ECON p11: 40"));
}

test "character classes and ranges" {
    try t.expect(try hit("ECON p[0-4]:", "ECON p3: 100"));
    try t.expect(!try hit("ECON p[0-4]:", "ECON p11: 100"));
    try t.expect(try hit("[^0-9]+", "abc"));
    try t.expect(!try hit("^[0-9]+$", "12a"));
    try t.expect(try hit("^[0-9]+$", "1234"));
}

test "quantifiers backtrack" {
    try t.expect(try hit("a*b", "aaab"));
    try t.expect(try hit("a*b", "b"));
    try t.expect(try hit(".*end", "the end"));
    try t.expect(try hit("x?y", "y"));
    try t.expect(!try hit("a+b", "b"));
}

test "anchors" {
    try t.expect(try hit("^DIAG", "DIAG x"));
    try t.expect(!try hit("^DIAG", " DIAG x"));
    try t.expect(try hit("fired$", "end_opening_cin fired"));
    try t.expect(!try hit("fired$", "fired at t=54"));
}

test "parens and brackets outside a class are literal" {
    try t.expect(try hit("focus(", "DIAG cam: focus(5751,40,1043)"));
    try t.expect(try hit("(5751,", "focus(5751,40)"));
}

test "escapes" {
    try t.expect(try hit("3\\.14", "pi=3.14"));
    try t.expect(!try hit("3\\.14", "pi=3x14"));
    try t.expect(try hit("t=\\d+", "fired at t=54.0"));
    try t.expect(try hit("a\\sb", "a b"));
}

test "case insensitivity" {
    try t.expect(try hitCi("beamfx", "BEAMFX: 3 hulls"));
    try t.expect(!try hit("beamfx", "BEAMFX: 3 hulls"));
    try t.expect(try hitCi("[a-z]+", "ABC"));
}

test "empty and malformed patterns are errors, never silent matches" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(Error.BadPattern, compile(a, "", false));
    try t.expectError(Error.BadPattern, compile(a, "[abc", false));
    try t.expectError(Error.BadPattern, compile(a, "[]", false));
    try t.expectError(Error.BadPattern, compile(a, "a\\", false));
    try t.expectError(Error.BadPattern, compile(a, "[z-a]", false));
}

test "alternation separator inside a class stays literal" {
    try t.expect(try hit("[|]", "a|b"));
    try t.expect(!try hit("[|]", "ab"));
}
