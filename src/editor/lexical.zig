//! Lexical structure for documents the syntax tree cannot answer for:
//! a language without a grammar, highlighting switched off, or a tree
//! that lags the text.
//!
//! A small state machine over a language row's comment and string rules
//! (`languages.Spec`) classifies every byte as code, string or comment,
//! so bracket matching and bracket folding skip `"a ( b"` and `// )`
//! the way the tree path does. It is not a tokenizer: regex literals,
//! heredocs, raw strings with custom delimiters and nested template
//! substitutions are outside what a row can describe, and a bracket in
//! one of those still counts.
//!
//! GTK-free and tree-sitter-free; reads the rope in place.

const std = @import("std");
const Allocator = std.mem.Allocator;
const languages = @import("languages.zig");
const Spec = languages.Spec;
const Rope = @import("rope.zig").Rope;
const Document = @import("document.zig").Document;
const structure = @import("structure.zig");
const BracketPair = structure.BracketPair;
const FoldRegion = structure.FoldRegion;

pub const Class = enum { code, string, comment };

/// A line comment is always ONE token (opener to newline), so it never
/// needs a mode of its own between tokens.
const Mode = union(enum) {
    code,
    /// Nesting depth, always >= 1.
    block_comment: u32,
    /// Index into `Spec.strings`.
    string: u8,
};

/// Forward reader over a rope range that keeps the last two leaves, so
/// a token's lookahead across a leaf boundary never costs a rope
/// descent. Anything outside that window (only possible with leaves
/// shorter than a token) falls back to a lookup.
const Source = struct {
    rope: *const Rope,
    end: usize,
    it: Rope.RangeIter,
    a: []const u8 = &.{},
    a_start: usize,
    b: []const u8 = &.{},
    b_start: usize,

    fn init(rope: *const Rope, start: usize, end: usize) Source {
        return .{
            .rope = rope,
            .end = end,
            .it = rope.iterateRange(start, end),
            .a_start = start,
            .b_start = start,
        };
    }

    /// Byte at `pos`, null past the end.
    fn at(self: *Source, pos: usize) ?u8 {
        if (pos >= self.end) return null;
        if (pos >= self.a_start and pos < self.a_start + self.a.len) return self.a[pos - self.a_start];
        if (pos >= self.b_start and pos < self.b_start + self.b.len) return self.b[pos - self.b_start];
        if (pos == self.b_start + self.b.len) {
            while (self.it.next()) |chunk| {
                if (chunk.len == 0) continue;
                self.a = self.b;
                self.a_start = self.b_start;
                self.b_start += self.b.len;
                self.b = chunk;
                return self.b[0];
            }
        }
        return structure.byteAt(self.rope, pos);
    }

    fn startsWith(self: *Source, pos: usize, tok: []const u8) bool {
        for (tok, 0..) |b, i| {
            if (self.at(pos + i) != b) return false;
        }
        return true;
    }
};

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

/// The lexer's whole state: a mode, the byte before the cursor, and the
/// number of newlines consumed so far.
const Lexer = struct {
    spec: *const Spec,
    mode: Mode = .code,
    prev: u8 = '\n',
    lines: usize = 0,

    pub fn init(spec: *const Spec) Lexer {
        return .{ .spec = spec };
    }

    const Token = struct { len: usize, class: Class };

    /// Classify the token at `pos` and move the state past it. A code
    /// token is always ONE byte, so every bracket is its own token.
    fn next(self: *Lexer, src: *Source, pos: usize) ?Token {
        const first = src.at(pos) orelse return null;
        const tok: Token = switch (self.mode) {
            .code => self.codeToken(src, pos, first),
            .block_comment => |depth| self.continueBlock(src, pos, 0, depth),
            .string => |idx| self.continueString(src, pos, 0, idx),
        };
        if (tok.class == .code and tok.len == 1 and first == '\n') self.lines += 1;
        self.prev = src.at(pos + tok.len - 1) orelse self.prev;
        return tok;
    }

    fn codeToken(self: *Lexer, src: *Source, pos: usize, first: u8) Token {
        const c = self.spec.comments;
        // Block before line: Lua's `--[[` and CMake's `#[[` start with
        // their line token.
        if (c.block) |blk| {
            if (first == blk.open[0] and src.startsWith(pos, blk.open)) {
                self.mode = .{ .block_comment = 1 };
                return self.continueBlock(src, pos, blk.open.len, 1);
            }
        }
        for (c.line) |t| {
            if (first != t[0] or !src.startsWith(pos, t)) continue;
            if (c.line_needs_boundary and !std.ascii.isWhitespace(self.prev)) continue;
            // Up to, not including, the newline, which stays code.
            var n = t.len;
            while (src.at(pos + n)) |b| : (n += 1) {
                if (b == '\n') break;
            }
            return .{ .len = n, .class = .comment };
        }
        for (self.spec.strings, 0..) |r, i| {
            if (first != r.open[0] or !src.startsWith(pos, r.open)) continue;
            if (!r.after_word and isWordByte(self.prev)) continue;
            if (r.max_len) |limit| {
                if (!closesWithin(src, pos + r.open.len, r, limit)) continue;
            }
            self.mode = .{ .string = @intCast(i) };
            return self.continueString(src, pos, r.open.len, @intCast(i));
        }
        return .{ .len = 1, .class = .code };
    }

    /// Scan a block comment from `pos + skip` until it closes (mode back
    /// to code) or the input ends.
    fn continueBlock(self: *Lexer, src: *Source, pos: usize, skip: usize, depth_in: u32) Token {
        const blk = self.spec.comments.block.?;
        var depth = depth_in;
        var n = skip;
        while (src.at(pos + n)) |b| {
            if (self.spec.comments.nested and b == blk.open[0] and src.startsWith(pos + n, blk.open)) {
                depth += 1;
                n += blk.open.len;
                continue;
            }
            if (b == blk.close[0] and src.startsWith(pos + n, blk.close)) {
                n += blk.close.len;
                depth -= 1;
                if (depth == 0) {
                    self.mode = .code;
                    return .{ .len = n, .class = .comment };
                }
                continue;
            }
            if (b == '\n') self.lines += 1;
            n += 1;
        }
        self.mode = .{ .block_comment = depth };
        return .{ .len = @max(n, 1), .class = .comment };
    }

    /// Scan a string body from `pos + skip`. A single-line string ends
    /// (unterminated) at the newline, which stays code.
    fn continueString(self: *Lexer, src: *Source, pos: usize, skip: usize, idx: u8) Token {
        const r = self.spec.strings[idx];
        var n = skip;
        while (src.at(pos + n)) |b| {
            if (r.escape) |e| {
                if (b == e) {
                    const esc = src.at(pos + n + 1);
                    if (esc == '\n') self.lines += 1;
                    n += if (esc != null) 2 else 1;
                    continue;
                }
            }
            if (b == r.close[0] and src.startsWith(pos + n, r.close)) {
                self.mode = .code;
                // A close token of "\n" (Zig's `\\` lines) is a newline.
                if (r.close[0] == '\n') self.lines += 1;
                return .{ .len = n + r.close.len, .class = .string };
            }
            if (b == '\n') {
                if (!r.multiline) {
                    self.mode = .code;
                    return .{ .len = @max(n, 1), .class = if (n == 0) .code else .string };
                }
                self.lines += 1;
            }
            n += 1;
        }
        return .{ .len = @max(n, 1), .class = .string };
    }
};

/// An escaped character literal's longest body (`'\u{10FFFF}'`).
const ESCAPED_CHAR_MAX: usize = 12;

/// Whether a literal opened just before `from` closes on the same line
/// within `limit` bytes, or `ESCAPED_CHAR_MAX` when the body starts
/// with the escape byte.
fn closesWithin(src: *Source, from: usize, r: languages.StringRule, max_len: u16) bool {
    const first = src.at(from) orelse return false;
    const limit: usize = if (r.escape != null and first == r.escape.?) ESCAPED_CHAR_MAX else max_len;
    var n: usize = 0;
    while (n <= limit) {
        const b = src.at(from + n) orelse return false;
        if (b == '\n') return false;
        if (r.escape) |e| {
            if (b == e) {
                n += 2;
                continue;
            }
        }
        if (b == r.close[0] and src.startsWith(from + n, r.close)) return true;
        n += 1;
    }
    return false;
}

// ======================================================================
// Bracket matching
// ======================================================================

/// How far matching looks in either direction, as `structure.SCAN_LIMIT`.
pub const SCAN_LIMIT: usize = structure.SCAN_LIMIT;

/// Where lexing must start so the state at `offset` is trustworthy: the
/// document start when it is within reach, else the start of the line
/// `SCAN_LIMIT` back (a restart inside a long comment or string there
/// is the documented limit).
fn lexStart(doc: *const Document, offset: usize) usize {
    if (offset <= SCAN_LIMIT) return 0;
    const line = doc.rope.offsetToLineCol(offset - SCAN_LIMIT).line;
    return doc.rope.lineToOffset(line);
}

/// Most recent unmatched openers of one bracket kind; older ones fall
/// off the bottom and are counted, so a pop past them is known to be
/// unanswerable rather than wrong.
const OpenStack = struct {
    const CAP = 512;
    buf: [CAP]usize = undefined,
    len: usize = 0,
    dropped: usize = 0,

    fn push(self: *OpenStack, pos: usize) void {
        if (self.len == CAP) {
            std.mem.copyForwards(usize, self.buf[0 .. CAP - 1], self.buf[1..CAP]);
            self.len -= 1;
            self.dropped += 1;
        }
        self.buf[self.len] = pos;
        self.len += 1;
    }

    fn pop(self: *OpenStack) void {
        if (self.len > 0) {
            self.len -= 1;
        } else if (self.dropped > 0) {
            self.dropped -= 1;
        }
    }

    fn top(self: *const OpenStack) ?usize {
        return if (self.len > 0) self.buf[self.len - 1] else null;
    }
};

const Candidate = struct {
    pos: usize,
    kind: structure.BracketKind,
    /// For a closer: the opener it pairs with, when known.
    opener: ?usize = null,
    /// Lexer state right after the bracket (for an opener's forward scan).
    after: Lexer,
};

/// The pair around/adjacent to `offset` (the byte at the caret first,
/// then the one before it, like `structure.bracketProbe`), counting only
/// brackets that are CODE under `spec`'s rules. A probe bracket inside a
/// string or comment is not a bracket.
pub fn matchBracket(doc: *const Document, spec: *const Spec, offset: usize) ?BracketPair {
    const rope = &doc.rope;
    const n = rope.len();
    if (n == 0) return null;
    const lo = if (offset > 0) offset - 1 else offset;
    const hi = @min(offset, n - 1);
    const start = lexStart(doc, lo);

    var lx = Lexer.init(spec);
    var src = Source.init(rope, start, n);
    var stacks = [_]OpenStack{ .{}, .{}, .{} };
    var cand_at: ?Candidate = null;
    var cand_before: ?Candidate = null;

    var pos = start;
    while (pos <= hi) {
        const tok = lx.next(&src, pos) orelse break;
        if (tok.class == .code) {
            const b = src.at(pos).?;
            if (structure.classifyBracket(b)) |kind| {
                const stack = &stacks[kind.idx];
                if (pos == offset or (offset > 0 and pos == offset - 1)) {
                    const c = Candidate{
                        .pos = pos,
                        .kind = kind,
                        .opener = if (kind.opening) null else stack.top(),
                        .after = lx,
                    };
                    if (pos == offset) cand_at = c else cand_before = c;
                }
                if (kind.opening) stack.push(pos) else stack.pop();
            }
        }
        pos += tok.len;
    }

    const cand = cand_at orelse cand_before orelse return null;
    if (!cand.kind.opening) {
        const op = cand.opener orelse return null;
        return .{ .open = .{ .start = op, .end = op + 1 }, .close = .{ .start = cand.pos, .end = cand.pos + 1 } };
    }
    const close = scanCloser(doc, cand) orelse return null;
    return .{ .open = .{ .start = cand.pos, .end = cand.pos + 1 }, .close = .{ .start = close, .end = close + 1 } };
}

/// Forward from an opener, depth-counting its kind in code only.
fn scanCloser(doc: *const Document, cand: Candidate) ?usize {
    const rope = &doc.rope;
    const open = structure.OPENERS[cand.kind.idx];
    const close = structure.CLOSERS[cand.kind.idx];
    const stop = @min(rope.len(), cand.pos + 1 + SCAN_LIMIT);
    var lx = cand.after;
    var src = Source.init(rope, cand.pos + 1, stop);
    var depth: usize = 1;
    var pos = cand.pos + 1;
    while (pos < stop) {
        const tok = lx.next(&src, pos) orelse break;
        if (tok.class == .code) {
            const b = src.at(pos).?;
            if (b == open) depth += 1 else if (b == close) {
                depth -= 1;
                if (depth == 0) return pos;
            }
        }
        pos += tok.len;
    }
    return null;
}

/// Class of the byte at `offset` under `spec` (for the auto-close quote
/// gate when there is no tree).
pub fn classAt(doc: *const Document, spec: *const Spec, offset: usize) Class {
    const rope = &doc.rope;
    const n = rope.len();
    if (offset >= n) {
        // The caret at EOF sits after the last token: ask about the
        // state the lexer is left in.
        return stateClassAtEnd(doc, spec);
    }
    const start = lexStart(doc, offset);
    var lx = Lexer.init(spec);
    var src = Source.init(rope, start, n);
    var pos = start;
    while (pos <= offset) {
        const tok = lx.next(&src, pos) orelse break;
        if (offset < pos + tok.len) {
            // A caret AT a string's opening quote is outside the string.
            if (tok.class != .code and offset == pos) return .code;
            return tok.class;
        }
        pos += tok.len;
    }
    return .code;
}

fn stateClassAtEnd(doc: *const Document, spec: *const Spec) Class {
    const rope = &doc.rope;
    const n = rope.len();
    const start = lexStart(doc, n);
    var lx = Lexer.init(spec);
    var src = Source.init(rope, start, n);
    var pos = start;
    while (pos < n) {
        const tok = lx.next(&src, pos) orelse break;
        pos += tok.len;
    }
    return switch (lx.mode) {
        .code => .code,
        .block_comment => .comment,
        .string => .string,
    };
}

// ======================================================================
// Bracket folding
// ======================================================================

/// Documents larger than this get indentation folds instead: the index
/// is one full pass per revision, and that pass must stay a few ms.
pub const FOLD_INDEX_MAX: usize = 8 * 1024 * 1024;

/// Every multi-line code bracket pair of one revision, as fold regions
/// (header = the opener's line, closer's line left visible). Built in
/// one pass and reused until the revision moves.
pub const FoldIndex = struct {
    alloc: Allocator,
    regions: std.ArrayList(FoldRegion) = .empty,
    revision: u64 = 0,
    spec: ?*const Spec = null,
    valid: bool = false,

    pub fn init(alloc: Allocator) FoldIndex {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *FoldIndex) void {
        self.regions.deinit(self.alloc);
    }

    pub fn invalidate(self: *FoldIndex) void {
        self.valid = false;
    }

    /// Rebuild when `doc` or `spec` moved. False when the document is
    /// too large to index (the caller falls back to indentation).
    pub fn ensure(self: *FoldIndex, doc: *const Document, spec: *const Spec) Allocator.Error!bool {
        if (doc.rope.len() > FOLD_INDEX_MAX) return false;
        if (self.valid and self.revision == doc.revision and self.spec == spec) return true;
        self.regions.clearRetainingCapacity();
        try buildFolds(self.alloc, doc, spec, &self.regions);
        self.revision = doc.revision;
        self.spec = spec;
        self.valid = true;
        return true;
    }

    /// Narrowest region headed by `line`.
    pub fn regionAtLine(self: *const FoldIndex, line: usize) ?FoldRegion {
        const items = self.regions.items;
        const i = lowerBound(items, line);
        if (i < items.len and items[i].start_line == line) return items[i];
        return null;
    }

    /// Innermost region hiding `line`.
    pub fn regionEnclosing(self: *const FoldIndex, line: usize) ?FoldRegion {
        var best: ?FoldRegion = null;
        for (self.regions.items) |r| {
            if (r.start_line >= line) break;
            if (!r.hides(line)) continue;
            if (best == null or r.start_line >= best.?.start_line) best = r;
        }
        return best;
    }

    /// Regions whose header lies in [from, to]; caller owns the slice.
    pub fn regionsIn(self: *const FoldIndex, alloc: Allocator, from: usize, to: usize) Allocator.Error![]FoldRegion {
        const items = self.regions.items;
        var i = lowerBound(items, from);
        var out: std.ArrayList(FoldRegion) = .empty;
        errdefer out.deinit(alloc);
        while (i < items.len and items[i].start_line <= to) : (i += 1) try out.append(alloc, items[i]);
        return out.toOwnedSlice(alloc);
    }

    fn lowerBound(items: []const FoldRegion, line: usize) usize {
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].start_line < line) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
};

fn buildFolds(alloc: Allocator, doc: *const Document, spec: *const Spec, out: *std.ArrayList(FoldRegion)) Allocator.Error!void {
    const rope = &doc.rope;
    const n = rope.len();
    var stacks: [3]std.ArrayList(usize) = .{ .empty, .empty, .empty };
    defer for (&stacks) |*s| s.deinit(alloc);
    var lx = Lexer.init(spec);
    var src = Source.init(rope, 0, n);
    var pos: usize = 0;
    while (pos < n) {
        // A bracket is a one-byte code token, so the line count BEFORE
        // the step is its line.
        const line = lx.lines;
        const tok = lx.next(&src, pos) orelse break;
        if (tok.class == .code and tok.len == 1) {
            if (structure.classifyBracket(src.at(pos).?)) |kind| {
                const stack = &stacks[kind.idx];
                if (kind.opening) {
                    try stack.append(alloc, line);
                } else if (stack.pop()) |open_line| {
                    if (line >= open_line + 2) try out.append(alloc, .{ .start_line = open_line, .end_line = line - 1 });
                }
            }
        }
        pos += tok.len;
    }
    const kept = structure.normalizeRegions(out.items);
    out.shrinkRetainingCapacity(kept.len);
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;
const Lang = languages.Lang;

fn docOf(text: []const u8) !Document {
    return Document.initFromBytes(testing.allocator, text);
}

fn expectPair(doc: *const Document, lang: Lang, caret: usize, open: usize, close: usize) !void {
    const p = matchBracket(doc, lang.spec(), caret) orelse return error.NoPair;
    try testing.expectEqual(open, p.open.start);
    try testing.expectEqual(close, p.close.start);
}

test "lexical: brackets inside strings and comments are skipped (C family)" {
    const src = "f(\")\", /* ) */ '(', // )\n x)";
    var doc = try docOf(src);
    defer doc.deinit();
    const close = std.mem.lastIndexOfScalar(u8, src, ')').?;
    try expectPair(&doc, .c, 1, 1, close);
    // Backwards from the real closer.
    try expectPair(&doc, .c, close, 1, close);
    // The ')' inside the string is not a bracket at all.
    try testing.expect(matchBracket(&doc, Lang.c.spec(), 3) == null);
    // Nor the one in the block comment.
    const in_block = std.mem.indexOf(u8, src, ") */").?;
    try testing.expect(matchBracket(&doc, Lang.c.spec(), in_block + 1) == null);
}

test "lexical: python triple quotes and hash comments" {
    const src =
        \\def f(a, b):
        \\    s = """ ( ] """
        \\    t = 'x)'  # ) [
        \\    return g(a)
        \\
    ;
    var doc = try docOf(src);
    defer doc.deinit();
    const open = std.mem.indexOfScalar(u8, src, '(').?;
    const close = std.mem.indexOf(u8, src, "):").?;
    try expectPair(&doc, .python, open, open, close);
    const g = std.mem.indexOf(u8, src, "g(").? + 1;
    try expectPair(&doc, .python, g, g, g + 2);
    // Nothing inside the triple-quoted string pairs.
    const in_str = std.mem.indexOf(u8, src, "( ]").?;
    try testing.expect(matchBracket(&doc, Lang.python.spec(), in_str) == null);
}

test "lexical: shell hash only comments at a word boundary" {
    const src = "echo ${#arr[@]} # ) (\nx=( a )\n";
    var doc = try docOf(src);
    defer doc.deinit();
    const brace = std.mem.indexOfScalar(u8, src, '{').?;
    try expectPair(&doc, .shell, brace, brace, std.mem.indexOfScalar(u8, src, '}').?);
    const sq = std.mem.indexOfScalar(u8, src, '[').?;
    try expectPair(&doc, .shell, sq, sq, std.mem.indexOfScalar(u8, src, ']').?);
    const arr = std.mem.indexOf(u8, src, "=(").? + 1;
    try expectPair(&doc, .shell, arr, arr, std.mem.lastIndexOfScalar(u8, src, ')').?);
}

test "lexical: rust lifetimes are not strings and block comments nest" {
    const src = "fn f<'a>(x: &'a str) { /* ( /* ) */ ] */ g('(') }";
    var doc = try docOf(src);
    defer doc.deinit();
    const paren = std.mem.indexOfScalar(u8, src, '(').?;
    try expectPair(&doc, .rust, paren, paren, std.mem.indexOf(u8, src, ") {").?);
    const brace = std.mem.indexOfScalar(u8, src, '{').?;
    try expectPair(&doc, .rust, brace, brace, std.mem.lastIndexOfScalar(u8, src, '}').?);
    const g = std.mem.indexOf(u8, src, "g(").? + 1;
    try expectPair(&doc, .rust, g, g, std.mem.lastIndexOfScalar(u8, src, ')').?);
}

test "lexical: javascript template literals span lines" {
    const src = "let s = `a ( \n ] `; f(s)";
    var doc = try docOf(src);
    defer doc.deinit();
    const f = std.mem.indexOf(u8, src, "f(").? + 1;
    try expectPair(&doc, .javascript, f, f, src.len - 1);
    try testing.expect(matchBracket(&doc, Lang.javascript.spec(), std.mem.indexOfScalar(u8, src, '(').?) == null);
}

test "lexical: yaml apostrophes are not quotes" {
    const src = "a: don't [x] # ]\nb: 'it ]'\n";
    var doc = try docOf(src);
    defer doc.deinit();
    const sq = std.mem.indexOfScalar(u8, src, '[').?;
    try expectPair(&doc, .yaml, sq, sq, sq + 2);
}

test "lexical: an unterminated string ends at the newline" {
    const src = "x = \"oops (\ny = (1)\n";
    var doc = try docOf(src);
    defer doc.deinit();
    const open = std.mem.lastIndexOfScalar(u8, src, '(').?;
    try expectPair(&doc, .c, open, open, open + 2);
}

test "lexical: classAt reports strings and comments" {
    const src = "a = \"s\" // c\n";
    var doc = try docOf(src);
    defer doc.deinit();
    try testing.expectEqual(Class.code, classAt(&doc, Lang.c.spec(), 0));
    try testing.expectEqual(Class.string, classAt(&doc, Lang.c.spec(), 5));
    try testing.expectEqual(Class.comment, classAt(&doc, Lang.c.spec(), 10));
    // The caret at an opening quote is still outside the literal.
    try testing.expectEqual(Class.code, classAt(&doc, Lang.c.spec(), 4));
}

test "lexical: fold index pairs multi-line brackets outside strings" {
    const src =
        \\obj = {
        \\  s: "{",
        \\  list: [
        \\    1,
        \\    2
        \\  ]
        \\}
        \\// {
        \\
    ;
    var doc = try docOf(src);
    defer doc.deinit();
    var idx = FoldIndex.init(testing.allocator);
    defer idx.deinit();
    try testing.expect(try idx.ensure(&doc, Lang.javascript.spec()));
    try testing.expectEqual(@as(usize, 2), idx.regions.items.len);
    try testing.expectEqual(FoldRegion{ .start_line = 0, .end_line = 5 }, idx.regionAtLine(0).?);
    try testing.expectEqual(FoldRegion{ .start_line = 2, .end_line = 4 }, idx.regionAtLine(2).?);
    try testing.expect(idx.regionAtLine(1) == null);
    try testing.expectEqual(@as(usize, 2), idx.regionEnclosing(3).?.start_line);
    try testing.expectEqual(@as(usize, 0), idx.regionEnclosing(1).?.start_line);
    const some = try idx.regionsIn(testing.allocator, 1, 6);
    defer testing.allocator.free(some);
    try testing.expectEqual(@as(usize, 1), some.len);
    // Cached per revision; an edit invalidates.
    const rev = doc.revision;
    try testing.expect(try idx.ensure(&doc, Lang.javascript.spec()));
    try testing.expectEqual(rev, idx.revision);
}

test "lexical: matching across rope leaves and long documents" {
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "f(\n");
    var i: usize = 0;
    while (i < 3000) : (i += 1) try buf.appendSlice(a, "  \"( ignored\", // )\n");
    try buf.appendSlice(a, ")\n");
    var doc = try Document.initFromBytes(a, buf.items);
    defer doc.deinit();
    const close = buf.items.len - 2;
    try expectPair(&doc, .c, 1, 1, close);
    try expectPair(&doc, .c, close, 1, close);
}
