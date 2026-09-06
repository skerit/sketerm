//! A small, non-backtracking regular-expression engine for the find bar.
//!
//! WHY THIS AND NOT A VENDORED LIBRARY
//!
//! The find bar compiles and runs a pattern the user is TYPING, over a
//! document that lives in a rope. That rules out most of the shelf:
//!
//! - A backtracking engine (PCRE-shaped, and every small Zig regex on
//!   GitHub) blows up exponentially on patterns a user types by
//!   accident — `(a+)+b` against a run of a's freezes the GUI, and the
//!   GUI is single-threaded by design. This engine is a Thompson NFA
//!   simulation (a "Pike VM"): every input position advances a thread
//!   list bounded by the PROGRAM size, so the cost is O(len * program)
//!   with no path that backtracks. `\1`-style backreferences are the
//!   feature that makes that guarantee impossible, which is why they
//!   are not supported and never will be here.
//! - Every C library worth vendoring (PCRE2, RE2, Oniguruma) wants ONE
//!   contiguous buffer, or a callback API that still assumes it. A rope
//!   would have to be materialized per keystroke.
//!
//! So the engine reads through a `Source` — a windowed byte reader —
//! exactly like `search.zig`'s literal scan does, and never sees more
//! than a few KB of the document at a time.
//!
//! SYNTAX SUPPORTED
//!
//!   literals (UTF-8), `.` (any codepoint except newline)
//!   `*` `+` `?` `{n}` `{n,}` `{n,m}`, each with a `?` suffix for lazy
//!   `|` alternation, `(...)` capture, `(?:...)` group without capture
//!   `[abc]` `[^abc]` `[a-z]` with `\d \w \s \D \W \S` and escapes inside
//!   `\d \D \w \W \s \S` `\n \r \t \f \v \0` and `\<punct>`
//!   `^` `$` — LINE anchors (start/end of any line), because this is a
//!       text editor and that is what a user means by them
//!   `\A` `\z` — buffer start/end, for when they mean the other thing
//!   `\b` `\B` — word boundary, using the same word classifier as
//!       double-click selection
//!
//! DELIBERATELY NOT SUPPORTED (each would be a lie at this size):
//!
//!   backreferences (`\1`), lookahead/lookbehind, atomic groups and
//!   possessive quantifiers, named groups, inline flags `(?i)`,
//!   Unicode property classes `\p{...}`, `\Q...\E`. Case-insensitive
//!   matching folds ASCII only — the same simplification the literal
//!   search documents. Capture groups are limited to 9 (`$1`..`$9`)
//!   plus group 0 for the whole match.
//!
//! GTK-free and allocator-explicit: part of the core test root, so it
//! must stay buildable in the `sketerm-mux` dependency set.

const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("unicode.zig");

/// Group 0 is the whole match, so nine user groups need ten slots.
pub const MAX_GROUPS: usize = 10;
/// A pattern that compiles to more instructions than this is refused
/// rather than allowed to eat memory (`a{1000}{1000}` is three bytes).
pub const MAX_PROGRAM: usize = 20000;
/// Largest accepted repetition bound.
pub const MAX_REPEAT: u32 = 1000;
/// Deepest accepted group nesting. The parser and the compiler both
/// recurse once per level, and NON-capturing groups are not counted by
/// `MAX_GROUPS`, so without this a pasted `(?:(?:(?:...x...)))` of a few
/// hundred thousand levels overflowed the stack and killed the process
/// instead of being refused. No real pattern comes near 200.
pub const MAX_DEPTH: u16 = 200;

pub const Error = error{
    InvalidPattern,
    UnsupportedPattern,
    PatternTooComplex,
} || Allocator.Error;

// ---- input ------------------------------------------------------------

/// A byte source the engine reads through a small window. `read` copies
/// up to `buf.len` bytes starting at `off` and returns what it copied,
/// so a rope can serve it without ever being materialized.
pub const Source = struct {
    ctx: *const anyopaque,
    len: usize,
    read: *const fn (ctx: *const anyopaque, off: usize, buf: []u8) []const u8,
};

fn sliceRead(ctx: *const anyopaque, off: usize, buf: []u8) []const u8 {
    const s: *const []const u8 = @ptrCast(@alignCast(ctx));
    if (off >= s.len) return buf[0..0];
    const n = @min(buf.len, s.len - off);
    @memcpy(buf[0..n], s.*[off .. off + n]);
    return buf[0..n];
}

/// Source over a contiguous slice. The slice pointer is borrowed, so
/// `bytes` must outlive the source.
pub fn sliceSource(bytes: *const []const u8) Source {
    return .{ .ctx = @ptrCast(bytes), .len = bytes.len, .read = sliceRead };
}

const WINDOW: usize = 4096;
/// Bytes kept behind the read position so `cpBefore` never has to
/// refill for a single codepoint.
const BEHIND: usize = 64;

/// A seekable codepoint reader over a `Source`, backed by one window
/// buffer. Both directions are supported because `\b`, `^` and `$` all
/// need the codepoint BEFORE a position.
const Cursor = struct {
    src: Source,
    buf: [WINDOW]u8 = undefined,
    win_start: usize = 0,
    win_len: usize = 0,

    fn init(src: Source) Cursor {
        return .{ .src = src };
    }

    /// Make sure [want_start, want_end) is inside the window.
    fn ensure(self: *Cursor, want_start: usize, want_end: usize) void {
        if (self.win_len > 0 and want_start >= self.win_start and want_end <= self.win_start + self.win_len) return;
        const start = want_start -| BEHIND;
        const got = self.src.read(self.src.ctx, start, &self.buf);
        self.win_start = start;
        self.win_len = got.len;
    }

    fn byteAt(self: *Cursor, off: usize) ?u8 {
        if (off >= self.src.len) return null;
        self.ensure(off, @min(self.src.len, off + 4));
        if (off < self.win_start or off >= self.win_start + self.win_len) return null;
        return self.buf[off - self.win_start];
    }

    /// Codepoint starting at `off` plus its byte length, or null at the
    /// end of the source. Invalid UTF-8 decodes as one replacement byte
    /// so a scan can never stall.
    fn cpAt(self: *Cursor, off: usize) ?struct { cp: u21, len: usize } {
        if (off >= self.src.len) return null;
        self.ensure(off, @min(self.src.len, off + 4));
        if (off < self.win_start or off >= self.win_start + self.win_len) return null;
        const rel = off - self.win_start;
        const avail = self.win_len - rel;
        const s = self.buf[rel .. rel + avail];
        const d = unicode.decodeAt(s, 0);
        return .{ .cp = d.cp, .len = @max(1, d.len) };
    }

    /// Codepoint ending at `off`, or null at the source start.
    fn cpBefore(self: *Cursor, off: usize) ?u21 {
        if (off == 0) return null;
        const start = off -| 4;
        self.ensure(start, off);
        if (start < self.win_start or off > self.win_start + self.win_len) return null;
        var i = off - self.win_start;
        const base = start - self.win_start;
        while (i > base) {
            i -= 1;
            if ((self.buf[i] & 0xC0) != 0x80) {
                const d = unicode.decodeAt(self.buf[i .. off - self.win_start], 0);
                return d.cp;
            }
        }
        return null;
    }
};

// ---- program ----------------------------------------------------------

pub const AssertKind = enum {
    /// Start of the buffer or just after a '\n'.
    line_start,
    /// End of the buffer or just before a '\n'.
    line_end,
    buf_start,
    buf_end,
    word_boundary,
    not_word_boundary,
};

const Inst = union(enum) {
    char: u21,
    class: u32,
    any,
    split: [2]u32,
    jmp: u32,
    save: u16,
    assert: AssertKind,
    match,
};

const Range = struct { lo: u21, hi: u21 };

const Class = struct {
    negated: bool,
    ranges: []Range,

    fn matches(self: Class, cp: u21, fold: bool) bool {
        var hit = self.contains(cp);
        if (!hit and fold) {
            if (cp >= 'a' and cp <= 'z') hit = self.contains(cp - 32);
            if (!hit and cp >= 'A' and cp <= 'Z') hit = self.contains(cp + 32);
        }
        return hit != self.negated;
    }

    fn contains(self: Class, cp: u21) bool {
        for (self.ranges) |r| {
            if (cp >= r.lo and cp <= r.hi) return true;
        }
        return false;
    }
};

pub const Options = struct {
    case_insensitive: bool = false,
};

pub const Program = struct {
    alloc: Allocator,
    insts: []Inst,
    classes: []Class,
    /// Capture groups actually used (including group 0).
    n_groups: usize,
    opts: Options,

    pub fn deinit(self: *Program) void {
        for (self.classes) |cl| self.alloc.free(cl.ranges);
        self.alloc.free(self.classes);
        self.alloc.free(self.insts);
        self.* = undefined;
    }
};

/// Byte spans of the whole match (`0`) and each capture group.
pub const Captures = struct {
    slots: [MAX_GROUPS * 2]?usize = @splat(null),
    n_groups: usize = 1,

    pub fn start(self: Captures) usize {
        return self.slots[0] orelse 0;
    }

    pub fn end(self: Captures) usize {
        return self.slots[1] orelse 0;
    }

    /// Span of group `i`, or null when the group did not participate.
    pub fn group(self: Captures, i: usize) ?struct { start: usize, end: usize } {
        if (i >= MAX_GROUPS) return null;
        const s = self.slots[i * 2] orelse return null;
        const e = self.slots[i * 2 + 1] orelse return null;
        if (e < s) return null;
        return .{ .start = s, .end = e };
    }
};

// ---- parser -----------------------------------------------------------

const Node = union(enum) {
    empty,
    lit: u21,
    class: u32,
    any,
    ass: AssertKind,
    cat: []*Node,
    alt: []*Node,
    group: struct { idx: ?u16, child: *Node },
    rep: struct { child: *Node, min: u32, max: ?u32, greedy: bool },
};

const Parser = struct {
    pat: []const u8,
    pos: usize = 0,
    arena: Allocator,
    classes: *std.ArrayList(Class),
    class_alloc: Allocator,
    n_groups: u16 = 1,
    /// Current group nesting; see `MAX_DEPTH`.
    depth: u16 = 0,

    fn node(self: *Parser, v: Node) Error!*Node {
        const n = try self.arena.create(Node);
        n.* = v;
        return n;
    }

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.pat.len) return null;
        return self.pat[self.pos];
    }

    fn eat(self: *Parser, ch: u8) bool {
        if (self.peek() == ch) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    /// Next codepoint of the PATTERN (patterns are UTF-8 too).
    fn nextCp(self: *Parser) Error!u21 {
        if (self.pos >= self.pat.len) return Error.InvalidPattern;
        const n = std.unicode.utf8ByteSequenceLength(self.pat[self.pos]) catch return Error.InvalidPattern;
        if (self.pos + n > self.pat.len) return Error.InvalidPattern;
        const cp = std.unicode.utf8Decode(self.pat[self.pos .. self.pos + n]) catch return Error.InvalidPattern;
        self.pos += n;
        return cp;
    }

    fn parseAlt(self: *Parser) Error!*Node {
        // The one recursion cycle in the grammar passes through here
        // (parseAlt -> parseCat -> parseRepeat -> parseAtom -> parseAlt),
        // so this is the only place that has to count.
        if (self.depth >= MAX_DEPTH) return Error.PatternTooComplex;
        self.depth += 1;
        defer self.depth -= 1;
        var branches: std.ArrayList(*Node) = .empty;
        defer branches.deinit(self.arena);
        try branches.append(self.arena, try self.parseCat());
        while (self.eat('|')) try branches.append(self.arena, try self.parseCat());
        if (branches.items.len == 1) return branches.items[0];
        return self.node(.{ .alt = try branches.toOwnedSlice(self.arena) });
    }

    fn parseCat(self: *Parser) Error!*Node {
        var items: std.ArrayList(*Node) = .empty;
        defer items.deinit(self.arena);
        while (self.peek()) |ch| {
            if (ch == '|' or ch == ')') break;
            try items.append(self.arena, try self.parseRepeat());
        }
        if (items.items.len == 0) return self.node(.empty);
        if (items.items.len == 1) return items.items[0];
        return self.node(.{ .cat = try items.toOwnedSlice(self.arena) });
    }

    fn parseRepeat(self: *Parser) Error!*Node {
        var atom = try self.parseAtom();
        while (self.peek()) |ch| {
            var min: u32 = 0;
            var max: ?u32 = null;
            switch (ch) {
                '*' => {
                    self.pos += 1;
                },
                '+' => {
                    self.pos += 1;
                    min = 1;
                },
                '?' => {
                    self.pos += 1;
                    max = 1;
                },
                '{' => {
                    const save_pos = self.pos;
                    if (try self.parseBounds(&min, &max)) {
                        // parsed
                    } else {
                        self.pos = save_pos;
                        return atom;
                    }
                },
                else => return atom,
            }
            // A quantifier on an anchor has no useful meaning and is
            // usually a typo; refusing it is clearer than looping.
            switch (atom.*) {
                .ass => return Error.UnsupportedPattern,
                else => {},
            }
            const greedy = !self.eat('?');
            atom = try self.node(.{ .rep = .{ .child = atom, .min = min, .max = max, .greedy = greedy } });
        }
        return atom;
    }

    /// `{n}` / `{n,}` / `{n,m}`. False (with `pos` untouched by the
    /// caller's save) when the brace is a literal.
    fn parseBounds(self: *Parser, min: *u32, max: *?u32) Error!bool {
        std.debug.assert(self.pat[self.pos] == '{');
        self.pos += 1;
        const lo = self.parseInt() orelse return false;
        if (self.eat('}')) {
            min.* = lo;
            max.* = lo;
        } else if (self.eat(',')) {
            if (self.eat('}')) {
                min.* = lo;
                max.* = null;
            } else {
                const hi = self.parseInt() orelse return false;
                if (!self.eat('}')) return false;
                if (hi < lo) return Error.InvalidPattern;
                min.* = lo;
                max.* = hi;
            }
        } else return false;
        if (min.* > MAX_REPEAT) return Error.PatternTooComplex;
        if (max.*) |m| {
            if (m > MAX_REPEAT) return Error.PatternTooComplex;
        }
        return true;
    }

    fn parseInt(self: *Parser) ?u32 {
        const start = self.pos;
        var v: u32 = 0;
        while (self.peek()) |ch| {
            if (ch < '0' or ch > '9') break;
            v = v *| 10 +| (ch - '0');
            self.pos += 1;
        }
        if (self.pos == start) return null;
        return v;
    }

    fn parseAtom(self: *Parser) Error!*Node {
        const ch = self.peek() orelse return Error.InvalidPattern;
        switch (ch) {
            '(' => {
                self.pos += 1;
                var idx: ?u16 = null;
                if (self.pos + 1 < self.pat.len and self.pat[self.pos] == '?') {
                    if (self.pat[self.pos + 1] == ':') {
                        self.pos += 2;
                    } else {
                        // (?=, (?!, (?<, (?i) ... — all unsupported, and
                        // silently treating them as a plain group would
                        // give WRONG matches rather than none.
                        return Error.UnsupportedPattern;
                    }
                } else {
                    if (self.n_groups >= MAX_GROUPS) return Error.UnsupportedPattern;
                    idx = self.n_groups;
                    self.n_groups += 1;
                }
                const child = try self.parseAlt();
                if (!self.eat(')')) return Error.InvalidPattern;
                return self.node(.{ .group = .{ .idx = idx, .child = child } });
            },
            ')' => return Error.InvalidPattern,
            '[' => {
                self.pos += 1;
                return self.parseClass();
            },
            '.' => {
                self.pos += 1;
                return self.node(.any);
            },
            '^' => {
                self.pos += 1;
                return self.node(.{ .ass = .line_start });
            },
            '$' => {
                self.pos += 1;
                return self.node(.{ .ass = .line_end });
            },
            '*', '+', '?' => return Error.InvalidPattern,
            '\\' => {
                self.pos += 1;
                return self.parseEscape();
            },
            else => return self.node(.{ .lit = try self.nextCp() }),
        }
    }

    fn addClass(self: *Parser, negated: bool, ranges: []const Range) Error!u32 {
        const owned = try self.class_alloc.dupe(Range, ranges);
        errdefer self.class_alloc.free(owned);
        try self.classes.append(self.class_alloc, .{ .negated = negated, .ranges = owned });
        return @intCast(self.classes.items.len - 1);
    }

    const digit_ranges = [_]Range{.{ .lo = '0', .hi = '9' }};
    const word_ranges = [_]Range{
        .{ .lo = '0', .hi = '9' },
        .{ .lo = 'A', .hi = 'Z' },
        .{ .lo = '_', .hi = '_' },
        .{ .lo = 'a', .hi = 'z' },
    };
    const space_ranges = [_]Range{
        .{ .lo = '\t', .hi = '\r' },
        .{ .lo = ' ', .hi = ' ' },
    };

    fn parseEscape(self: *Parser) Error!*Node {
        const ch = self.peek() orelse return Error.InvalidPattern;
        self.pos += 1;
        return switch (ch) {
            'd' => self.node(.{ .class = try self.addClass(false, &digit_ranges) }),
            'D' => self.node(.{ .class = try self.addClass(true, &digit_ranges) }),
            'w' => self.node(.{ .class = try self.addClass(false, &word_ranges) }),
            'W' => self.node(.{ .class = try self.addClass(true, &word_ranges) }),
            's' => self.node(.{ .class = try self.addClass(false, &space_ranges) }),
            'S' => self.node(.{ .class = try self.addClass(true, &space_ranges) }),
            'b' => self.node(.{ .ass = .word_boundary }),
            'B' => self.node(.{ .ass = .not_word_boundary }),
            'A' => self.node(.{ .ass = .buf_start }),
            'z' => self.node(.{ .ass = .buf_end }),
            'n' => self.node(.{ .lit = '\n' }),
            'r' => self.node(.{ .lit = '\r' }),
            't' => self.node(.{ .lit = '\t' }),
            'f' => self.node(.{ .lit = 0x0C }),
            'v' => self.node(.{ .lit = 0x0B }),
            '0' => self.node(.{ .lit = 0 }),
            // A backreference is exactly what an NFA simulation cannot
            // do; say so instead of matching something else.
            '1'...'9' => Error.UnsupportedPattern,
            else => blk: {
                self.pos -= 1;
                break :blk self.node(.{ .lit = try self.nextCp() });
            },
        };
    }

    fn parseClass(self: *Parser) Error!*Node {
        var ranges: std.ArrayList(Range) = .empty;
        defer ranges.deinit(self.arena);
        const negated = self.eat('^');
        var first = true;
        while (true) {
            const ch = self.peek() orelse return Error.InvalidPattern;
            if (ch == ']' and !first) {
                self.pos += 1;
                break;
            }
            first = false;
            if (ch == '\\') {
                self.pos += 1;
                const e = self.peek() orelse return Error.InvalidPattern;
                self.pos += 1;
                switch (e) {
                    'd' => try ranges.appendSlice(self.arena, &digit_ranges),
                    'w' => try ranges.appendSlice(self.arena, &word_ranges),
                    's' => try ranges.appendSlice(self.arena, &space_ranges),
                    // A negated shorthand inside a class would need set
                    // subtraction; refuse rather than approximate.
                    'D', 'W', 'S' => return Error.UnsupportedPattern,
                    else => {
                        self.pos -= 1;
                        const cp = try self.classEscapeCp();
                        try self.appendRange(&ranges, cp);
                    },
                }
                continue;
            }
            const cp = try self.nextCp();
            try self.appendRange(&ranges, cp);
        }
        if (ranges.items.len == 0) return Error.InvalidPattern;
        const idx = try self.addClass(negated, ranges.items);
        return self.node(.{ .class = idx });
    }

    /// One escaped member of a class (`\]`, `\n`, `\\`, …).
    fn classEscapeCp(self: *Parser) Error!u21 {
        const ch = self.peek() orelse return Error.InvalidPattern;
        self.pos += 1;
        return switch (ch) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'f' => 0x0C,
            'v' => 0x0B,
            '0' => 0,
            else => blk: {
                self.pos -= 1;
                break :blk try self.nextCp();
            },
        };
    }

    /// `cp` or, when a '-' follows and is not the closing bracket, the
    /// range `cp-hi`.
    fn appendRange(self: *Parser, ranges: *std.ArrayList(Range), cp: u21) Error!void {
        if (self.peek() == '-' and self.pos + 1 < self.pat.len and self.pat[self.pos + 1] != ']') {
            self.pos += 1;
            const hi = if (self.peek() == '\\') blk: {
                self.pos += 1;
                break :blk try self.classEscapeCp();
            } else try self.nextCp();
            if (hi < cp) return Error.InvalidPattern;
            try ranges.append(self.arena, .{ .lo = cp, .hi = hi });
            return;
        }
        try ranges.append(self.arena, .{ .lo = cp, .hi = cp });
    }
};

// ---- compiler ---------------------------------------------------------

const Compiler = struct {
    insts: std.ArrayList(Inst) = .empty,
    alloc: Allocator,

    fn emit(self: *Compiler, i: Inst) Error!u32 {
        if (self.insts.items.len >= MAX_PROGRAM) return Error.PatternTooComplex;
        try self.insts.append(self.alloc, i);
        return @intCast(self.insts.items.len - 1);
    }

    fn pc(self: *const Compiler) u32 {
        return @intCast(self.insts.items.len);
    }

    fn node(self: *Compiler, n: *const Node) Error!void {
        switch (n.*) {
            .empty => {},
            .lit => |cp| _ = try self.emit(.{ .char = cp }),
            .class => |idx| _ = try self.emit(.{ .class = idx }),
            .any => _ = try self.emit(.any),
            .ass => |k| _ = try self.emit(.{ .assert = k }),
            .cat => |items| for (items) |it| try self.node(it),
            .alt => |branches| try self.alt(branches),
            .group => |g| {
                if (g.idx) |i| _ = try self.emit(.{ .save = @intCast(i * 2) });
                try self.node(g.child);
                if (g.idx) |i| _ = try self.emit(.{ .save = @intCast(i * 2 + 1) });
            },
            .rep => |r| try self.repeat(r.child, r.min, r.max, r.greedy),
        }
    }

    fn alt(self: *Compiler, branches: []const *Node) Error!void {
        // split b0, (split b1, (… bn)); each branch jumps to the end.
        var jumps: std.ArrayList(u32) = .empty;
        defer jumps.deinit(self.alloc);
        for (branches, 0..) |b, i| {
            if (i + 1 == branches.len) {
                try self.node(b);
                break;
            }
            const s = try self.emit(.{ .split = .{ 0, 0 } });
            try self.node(b);
            const j = try self.emit(.{ .jmp = 0 });
            try jumps.append(self.alloc, j);
            self.insts.items[s].split = .{ s + 1, self.pc() };
        }
        const end = self.pc();
        for (jumps.items) |j| self.insts.items[j].jmp = end;
    }

    fn repeat(self: *Compiler, child: *const Node, min: u32, max: ?u32, greedy: bool) Error!void {
        // With no upper bound the LAST mandatory copy becomes the body
        // of the plus loop, so only min-1 copies are emitted ahead of
        // it — emitting all `min` would mean x{n+1,}.
        const prefix = if (max == null and min > 0) min - 1 else min;
        var i: u32 = 0;
        while (i < prefix) : (i += 1) try self.node(child);
        if (max) |m| {
            const optional = m - min;
            var splits: std.ArrayList(u32) = .empty;
            defer splits.deinit(self.alloc);
            var k: u32 = 0;
            while (k < optional) : (k += 1) {
                const s = try self.emit(.{ .split = .{ 0, 0 } });
                try splits.append(self.alloc, s);
                try self.node(child);
            }
            const end = self.pc();
            // Every split escapes to the SAME end, which is what makes
            // the flat chain mean nested optionals: skipping the k-th
            // copy skips every later one too.
            for (splits.items) |s| {
                self.insts.items[s].split = if (greedy) .{ s + 1, end } else .{ end, s + 1 };
            }
            return;
        }
        if (min > 0) {
            // x{n,} — n-1 copies emitted above, then a plus-shaped loop
            // on the last one, whose body is its own program slice.
            const l1 = self.pc();
            try self.node(child);
            const s = try self.emit(.{ .split = .{ 0, 0 } });
            self.insts.items[s].split = if (greedy) .{ l1, s + 1 } else .{ s + 1, l1 };
            return;
        }
        const l1 = try self.emit(.{ .split = .{ 0, 0 } });
        try self.node(child);
        _ = try self.emit(.{ .jmp = l1 });
        const end = self.pc();
        self.insts.items[l1].split = if (greedy) .{ l1 + 1, end } else .{ end, l1 + 1 };
    }
};

/// Compile `pattern`. Every error is a user-visible "bad pattern"; the
/// find bar shows the kind rather than silently searching for nothing.
pub fn compile(alloc: Allocator, pattern: []const u8, opts: Options) Error!Program {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var classes: std.ArrayList(Class) = .empty;
    errdefer {
        for (classes.items) |cl| alloc.free(cl.ranges);
        classes.deinit(alloc);
    }

    var p = Parser{
        .pat = pattern,
        .arena = arena,
        .classes = &classes,
        .class_alloc = alloc,
    };
    const root = try p.parseAlt();
    if (p.pos != pattern.len) return Error.InvalidPattern;

    var comp = Compiler{ .alloc = alloc };
    errdefer comp.insts.deinit(alloc);
    _ = try comp.emit(.{ .save = 0 });
    try comp.node(root);
    _ = try comp.emit(.{ .save = 1 });
    _ = try comp.emit(.match);

    return .{
        .alloc = alloc,
        .insts = try comp.insts.toOwnedSlice(alloc),
        .classes = try classes.toOwnedSlice(alloc),
        .n_groups = p.n_groups,
        .opts = opts,
    };
}

// ---- the VM -----------------------------------------------------------

const Thread = struct {
    pc: u32,
    caps: [MAX_GROUPS * 2]?usize,
};

const Task = union(enum) {
    visit: u32,
    restore: struct { slot: u16, val: ?usize },
};

/// A compiled program plus the scratch a scan needs. Reused across the
/// many `search` calls one find-all makes, so the allocation happens
/// once per pattern rather than once per match.
pub const Matcher = struct {
    prog: *const Program,
    alloc: Allocator,
    clist: std.ArrayList(Thread) = .empty,
    nlist: std.ArrayList(Thread) = .empty,
    stack: std.ArrayList(Task) = .empty,
    /// Per-instruction "already added at this input position" stamps.
    seen: []u64,
    gen: u64 = 0,

    pub fn init(alloc: Allocator, prog: *const Program) Error!Matcher {
        const seen = try alloc.alloc(u64, prog.insts.len);
        @memset(seen, 0);
        return .{ .prog = prog, .alloc = alloc, .seen = seen };
    }

    pub fn deinit(self: *Matcher) void {
        self.clist.deinit(self.alloc);
        self.nlist.deinit(self.alloc);
        self.stack.deinit(self.alloc);
        self.alloc.free(self.seen);
        self.* = undefined;
    }

    fn foldCp(cp: u21, fold: bool) u21 {
        if (!fold) return cp;
        return if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
    }

    fn isWord(cp: u21) bool {
        return unicode.wordClassOf(cp) == .word;
    }

    fn assertHolds(self: *Matcher, cur: *Cursor, kind: AssertKind, pos: usize) bool {
        _ = self;
        switch (kind) {
            .buf_start => return pos == 0,
            .buf_end => return pos == cur.src.len,
            .line_start => {
                if (pos == 0) return true;
                return cur.byteAt(pos - 1) == '\n';
            },
            .line_end => {
                if (pos == cur.src.len) return true;
                return cur.byteAt(pos) == '\n';
            },
            .word_boundary, .not_word_boundary => {
                const before = if (cur.cpBefore(pos)) |cp| isWord(cp) else false;
                const after = if (cur.cpAt(pos)) |d| isWord(d.cp) else false;
                const b = before != after;
                return if (kind == .word_boundary) b else !b;
            },
        }
    }

    /// Follow every epsilon transition from `pc` and park the resulting
    /// threads on `list`, in priority (DFS preorder) order.
    fn addThread(
        self: *Matcher,
        list: *std.ArrayList(Thread),
        cur: *Cursor,
        start_pc: u32,
        pos: usize,
        caps: *[MAX_GROUPS * 2]?usize,
    ) Error!void {
        self.stack.clearRetainingCapacity();
        try self.stack.append(self.alloc, .{ .visit = start_pc });
        while (self.stack.pop()) |task| {
            switch (task) {
                .restore => |r| caps[r.slot] = r.val,
                .visit => |pc| {
                    if (self.seen[pc] == self.gen) continue;
                    self.seen[pc] = self.gen;
                    switch (self.prog.insts[pc]) {
                        .jmp => |t| try self.stack.append(self.alloc, .{ .visit = t }),
                        .split => |t| {
                            // LIFO: push the low-priority branch first.
                            try self.stack.append(self.alloc, .{ .visit = t[1] });
                            try self.stack.append(self.alloc, .{ .visit = t[0] });
                        },
                        .save => |slot| {
                            if (slot < MAX_GROUPS * 2) {
                                try self.stack.append(self.alloc, .{ .restore = .{ .slot = slot, .val = caps[slot] } });
                                caps[slot] = pos;
                            }
                            try self.stack.append(self.alloc, .{ .visit = pc + 1 });
                        },
                        .assert => |k| {
                            if (self.assertHolds(cur, k, pos)) {
                                try self.stack.append(self.alloc, .{ .visit = pc + 1 });
                            }
                        },
                        else => try list.append(self.alloc, .{ .pc = pc, .caps = caps.* }),
                    }
                },
            }
        }
    }

    /// Leftmost match starting at or after `from`, with captures. Null
    /// when the rest of the source holds no match.
    ///
    /// Leftmost-first (Perl alternation order), never leftmost-longest:
    /// new start threads are added at the LOWEST priority, and reaching
    /// `.match` cuts every thread below it.
    pub fn search(self: *Matcher, src: Source, from: usize) Error!?Captures {
        var cur = Cursor.init(src);
        self.clist.clearRetainingCapacity();
        self.nlist.clearRetainingCapacity();
        var matched: ?Captures = null;
        var caps: [MAX_GROUPS * 2]?usize = @splat(null);
        const fold = self.prog.opts.case_insensitive;

        // One generation per input position, carried from the step that
        // BUILT the current thread list — so a fresh start thread
        // dedupes against it without the list being rebuilt.
        self.gen += 1;
        var pos = from;
        while (true) {
            const at = cur.cpAt(pos);

            if (matched == null) {
                var fresh: [MAX_GROUPS * 2]?usize = @splat(null);
                try self.addThread(&self.clist, &cur, 0, pos, &fresh);
            }
            // An empty list only ends the scan once a match is in hand:
            // with none, a LATER position can still start one (`^b` on
            // "a\nb" has no live thread at the newline).
            if (self.clist.items.len == 0 and matched != null) break;
            if (at == null) {
                // End of input: nothing can consume, and any surviving
                // `.match` was already taken below on the last pass.
                var i: usize = 0;
                while (i < self.clist.items.len) : (i += 1) {
                    if (self.prog.insts[self.clist.items[i].pc] == .match) {
                        var m = Captures{ .n_groups = self.prog.n_groups };
                        m.slots = self.clist.items[i].caps;
                        matched = m;
                        break;
                    }
                }
                break;
            }

            self.nlist.clearRetainingCapacity();
            self.gen += 1;
            const next_pos = pos + at.?.len;
            var i: usize = 0;
            while (i < self.clist.items.len) : (i += 1) {
                const th = self.clist.items[i];
                caps = th.caps;
                switch (self.prog.insts[th.pc]) {
                    .char => |want| {
                        const d = at orelse continue;
                        if (foldCp(d.cp, fold) != foldCp(want, fold)) continue;
                        try self.addThread(&self.nlist, &cur, th.pc + 1, next_pos, &caps);
                    },
                    .class => |idx| {
                        const d = at orelse continue;
                        if (!self.prog.classes[idx].matches(d.cp, fold)) continue;
                        try self.addThread(&self.nlist, &cur, th.pc + 1, next_pos, &caps);
                    },
                    .any => {
                        const d = at orelse continue;
                        if (d.cp == '\n') continue;
                        try self.addThread(&self.nlist, &cur, th.pc + 1, next_pos, &caps);
                    },
                    .match => {
                        var m = Captures{ .n_groups = self.prog.n_groups };
                        m.slots = th.caps;
                        matched = m;
                        // Everything below this thread is lower
                        // priority and can no longer win.
                        break;
                    },
                    else => unreachable, // epsilon ops never reach a list
                }
            }
            std.mem.swap(std.ArrayList(Thread), &self.clist, &self.nlist);
            pos = next_pos;
        }
        return matched;
    }
};

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

const Found = struct { start: usize, end: usize };

/// Monotonic milliseconds (std.time.Timer is gone in Zig 0.16, and
/// util/clock.zig pulls in the C bindings this module deliberately
/// does not need).
fn monoMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Every non-overlapping match in `hay` — the same walk `search.zig`
/// performs, kept here so the engine is testable on its own.
fn findAllSlice(alloc: Allocator, pattern: []const u8, hay: []const u8, opts: Options) ![]Found {
    var prog = try compile(alloc, pattern, opts);
    defer prog.deinit();
    var m = try Matcher.init(alloc, &prog);
    defer m.deinit();
    const bytes: []const u8 = hay;
    const src = sliceSource(&bytes);

    var out: std.ArrayList(Found) = .empty;
    errdefer out.deinit(alloc);
    var pos: usize = 0;
    while (pos <= hay.len) {
        const caps = (try m.search(src, pos)) orelse break;
        try out.append(alloc, .{ .start = caps.start(), .end = caps.end() });
        if (caps.end() > caps.start()) {
            pos = caps.end();
        } else {
            // An empty match must not be reported twice at the same
            // spot; step one CODEPOINT, never one byte.
            var pv: usize = caps.end();
            if (pv >= hay.len) break;
            const n = std.unicode.utf8ByteSequenceLength(hay[pv]) catch 1;
            pv += n;
            pos = pv;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn expectMatches(pattern: []const u8, hay: []const u8, expect: []const Found) !void {
    const a = testing.allocator;
    const got = try findAllSlice(a, pattern, hay, .{});
    defer a.free(got);
    testing.expectEqual(expect.len, got.len) catch |e| {
        std.debug.print("pattern '{s}' on '{s}': got {any}\n", .{ pattern, hay, got });
        return e;
    };
    for (expect, got) |e, g| {
        try testing.expectEqual(e.start, g.start);
        try testing.expectEqual(e.end, g.end);
    }
}

test "regex: literals, dot and alternation" {
    try expectMatches("abc", "xxabcyyabc", &.{ .{ .start = 2, .end = 5 }, .{ .start = 7, .end = 10 } });
    try expectMatches("a.c", "abc a\nc axc", &.{ .{ .start = 0, .end = 3 }, .{ .start = 8, .end = 11 } });
    try expectMatches("cat|dog", "a cat and a dog", &.{ .{ .start = 2, .end = 5 }, .{ .start = 12, .end = 15 } });
    // Leftmost-FIRST: the earlier branch wins at the same start.
    try expectMatches("foo|foobar", "foobar", &.{.{ .start = 0, .end = 3 }});
}

test "regex: quantifiers greedy and lazy" {
    try expectMatches("a*", "baa", &.{
        .{ .start = 0, .end = 0 },
        .{ .start = 1, .end = 3 },
        .{ .start = 3, .end = 3 },
    });
    try expectMatches("a+", "baaac", &.{.{ .start = 1, .end = 4 }});
    try expectMatches("ab?c", "ac abc", &.{ .{ .start = 0, .end = 2 }, .{ .start = 3, .end = 6 } });
    try expectMatches("<.*>", "<a> <b>", &.{.{ .start = 0, .end = 7 }});
    try expectMatches("<.*?>", "<a> <b>", &.{ .{ .start = 0, .end = 3 }, .{ .start = 4, .end = 7 } });
    try expectMatches("a{2}", "a aa aaa", &.{ .{ .start = 2, .end = 4 }, .{ .start = 5, .end = 7 } });
    try expectMatches("a{2,}", "a aa aaaa", &.{ .{ .start = 2, .end = 4 }, .{ .start = 5, .end = 9 } });
    try expectMatches("a{2,3}", "aaaaa", &.{ .{ .start = 0, .end = 3 }, .{ .start = 3, .end = 5 } });
    // A brace that is not a bound stays a literal.
    try expectMatches("a{x}", "a{x}", &.{.{ .start = 0, .end = 4 }});
}

test "regex: character classes" {
    try expectMatches("[abc]+", "xxabcabxx", &.{.{ .start = 2, .end = 7 }});
    try expectMatches("[^a-z ]+", "ab CD ef 99", &.{ .{ .start = 3, .end = 5 }, .{ .start = 9, .end = 11 } });
    try expectMatches("[0-9]{2,}", "a1 b23 c456", &.{ .{ .start = 4, .end = 6 }, .{ .start = 8, .end = 11 } });
    try expectMatches("\\d+", "x42y", &.{.{ .start = 1, .end = 3 }});
    try expectMatches("\\w+", "a_1 %%", &.{.{ .start = 0, .end = 3 }});
    try expectMatches("\\s+", "a \t b\nc", &.{ .{ .start = 1, .end = 4 }, .{ .start = 5, .end = 6 } });
    // ']' first in a class is a literal, '-' last is a literal.
    try expectMatches("[]-]+", "a]-b", &.{.{ .start = 1, .end = 3 }});
    try expectMatches("[\\]]", "]", &.{.{ .start = 0, .end = 1 }});
}

test "regex: anchors are LINE anchors, \\A and \\z are not" {
    try expectMatches("^b", "a\nb\nb", &.{ .{ .start = 2, .end = 3 }, .{ .start = 4, .end = 5 } });
    try expectMatches("a$", "a\nba\nc", &.{ .{ .start = 0, .end = 1 }, .{ .start = 3, .end = 4 } });
    try expectMatches("\\Aa", "a\na", &.{.{ .start = 0, .end = 1 }});
    try expectMatches("a\\z", "a\na", &.{.{ .start = 2, .end = 3 }});
    try expectMatches("^$", "a\n\nb", &.{.{ .start = 2, .end = 2 }});
}

test "regex: word boundaries" {
    try expectMatches("\\bcat\\b", "cat category scat cat.", &.{ .{ .start = 0, .end = 3 }, .{ .start = 18, .end = 21 } });
    try expectMatches("\\Bcat", "scatter cat", &.{.{ .start = 1, .end = 4 }});
}

test "regex: groups and captures" {
    const a = testing.allocator;
    var prog = try compile(a, "(\\w+)@(\\w+)\\.com", .{});
    defer prog.deinit();
    var m = try Matcher.init(a, &prog);
    defer m.deinit();
    const bytes: []const u8 = "mail: jelle@example.com!";
    const caps = (try m.search(sliceSource(&bytes), 0)).?;
    try testing.expectEqual(@as(usize, 6), caps.start());
    try testing.expectEqual(@as(usize, 23), caps.end());
    const g1 = caps.group(1).?;
    try testing.expectEqualStrings("jelle", bytes[g1.start..g1.end]);
    const g2 = caps.group(2).?;
    try testing.expectEqualStrings("example", bytes[g2.start..g2.end]);
    try testing.expectEqual(@as(?usize, null), if (caps.group(3)) |_| @as(?usize, 0) else null);
}

test "regex: a group that repeats reports its LAST iteration" {
    const a = testing.allocator;
    var prog = try compile(a, "(?:(a)|(b))+", .{});
    defer prog.deinit();
    var m = try Matcher.init(a, &prog);
    defer m.deinit();
    const bytes: []const u8 = "abab";
    const caps = (try m.search(sliceSource(&bytes), 0)).?;
    try testing.expectEqual(@as(usize, 0), caps.start());
    try testing.expectEqual(@as(usize, 4), caps.end());
    const g2 = caps.group(2).?;
    try testing.expectEqualStrings("b", bytes[g2.start..g2.end]);
}

test "regex: non-capturing groups do not consume a slot" {
    const a = testing.allocator;
    var prog = try compile(a, "(?:ab)+(c)", .{});
    defer prog.deinit();
    var m = try Matcher.init(a, &prog);
    defer m.deinit();
    const bytes: []const u8 = "ababc";
    const caps = (try m.search(sliceSource(&bytes), 0)).?;
    const g1 = caps.group(1).?;
    try testing.expectEqualStrings("c", bytes[g1.start..g1.end]);
}

test "regex: case-insensitive folds ASCII only" {
    const a = testing.allocator;
    {
        const got = try findAllSlice(a, "foo", "Foo FOO foo", .{ .case_insensitive = true });
        defer a.free(got);
        try testing.expectEqual(@as(usize, 3), got.len);
    }
    {
        // Non-ASCII keeps its case, documented simplification.
        const got = try findAllSlice(a, "\u{00e9}", "\u{00c9}\u{00e9}", .{ .case_insensitive = true });
        defer a.free(got);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqual(@as(usize, 2), got[0].start);
    }
    {
        const got = try findAllSlice(a, "[a-f]+", "ABCxyz", .{ .case_insensitive = true });
        defer a.free(got);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqual(@as(usize, 3), got[0].end);
    }
}

test "regex: non-ASCII text matches per CODEPOINT" {
    // '.' is one codepoint, not one byte.
    try expectMatches(".", "\u{00e9}", &.{.{ .start = 0, .end = 2 }});
    try expectMatches("caf\u{00e9}", "un caf\u{00e9}!", &.{.{ .start = 3, .end = 8 }});
    try expectMatches("\u{4f60}\u{597d}+", "\u{4f60}\u{597d}\u{597d}", &.{.{ .start = 0, .end = 9 }});
    // A negated class must not match half a codepoint.
    try expectMatches("[^x]+", "a\u{00e9}b", &.{.{ .start = 0, .end = 4 }});
}

test "regex: empty matches terminate and never repeat at one spot" {
    try expectMatches("", "ab", &.{
        .{ .start = 0, .end = 0 },
        .{ .start = 1, .end = 1 },
        .{ .start = 2, .end = 2 },
    });
    try expectMatches("x*", "", &.{.{ .start = 0, .end = 0 }});
    // A pattern whose body can match empty must not loop forever.
    try expectMatches("(?:a*)*b", "aab", &.{.{ .start = 0, .end = 3 }});
}

test "regex: invalid and unsupported patterns are refused" {
    const a = testing.allocator;
    try testing.expectError(Error.InvalidPattern, compile(a, "(", .{}));
    try testing.expectError(Error.InvalidPattern, compile(a, ")", .{}));
    try testing.expectError(Error.InvalidPattern, compile(a, "[a", .{}));
    try testing.expectError(Error.InvalidPattern, compile(a, "*a", .{}));
    try testing.expectError(Error.InvalidPattern, compile(a, "a{3,1}", .{}));
    try testing.expectError(Error.UnsupportedPattern, compile(a, "(a)\\1", .{}));
    try testing.expectError(Error.UnsupportedPattern, compile(a, "(?=a)", .{}));
    try testing.expectError(Error.UnsupportedPattern, compile(a, "(?i)a", .{}));
    try testing.expectError(Error.PatternTooComplex, compile(a, "a{2000}", .{}));
    try testing.expectError(Error.UnsupportedPattern, compile(a, "(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)", .{}));
}

test "regex: a deeply nested pattern is refused, not a stack overflow" {
    // MAX_GROUPS only counts CAPTURING groups, so `(?:` nests without
    // limit; the parser and compiler each recurse once per level and a
    // pasted pattern of a few hundred thousand levels killed the
    // process.
    const a = testing.allocator;
    const n = MAX_DEPTH * 4;
    var pat: std.ArrayList(u8) = .empty;
    defer pat.deinit(a);
    var i: usize = 0;
    while (i < n) : (i += 1) try pat.appendSlice(a, "(?:");
    try pat.append(a, 'x');
    i = 0;
    while (i < n) : (i += 1) try pat.append(a, ')');
    try testing.expectError(Error.PatternTooComplex, compile(a, pat.items, .{}));

    // Nesting that stays inside the limit still compiles and matches.
    var ok: std.ArrayList(u8) = .empty;
    defer ok.deinit(a);
    i = 0;
    while (i < 20) : (i += 1) try ok.appendSlice(a, "(?:");
    try ok.append(a, 'x');
    i = 0;
    while (i < 20) : (i += 1) try ok.append(a, ')');
    const got = try findAllSlice(a, ok.items, "axb", .{});
    defer a.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
}

test "regex: catastrophic backtracking patterns still complete quickly" {
    const a = testing.allocator;
    // The classic exponential blowup for a backtracking engine: 30 a's
    // with no trailing b is 2^30 paths. A Thompson simulation walks it
    // in one pass, so this finishes in milliseconds.
    const hay = "a" ** 40;
    const t0 = monoMs();
    {
        const got = try findAllSlice(a, "(a+)+b", hay, .{});
        defer a.free(got);
        try testing.expectEqual(@as(usize, 0), got.len);
    }
    {
        const got = try findAllSlice(a, "(a|aa)*c", hay, .{});
        defer a.free(got);
        try testing.expectEqual(@as(usize, 0), got.len);
    }
    {
        const got = try findAllSlice(a, "(x+x+)+y", "x" ** 40, .{});
        defer a.free(got);
        try testing.expectEqual(@as(usize, 0), got.len);
    }
    const ms = monoMs() - t0;
    if (ms > 2000) {
        std.debug.print("regex: backtracking guard took {d}ms\n", .{ms});
        return error.TooSlow;
    }
}

test "regex: a match spanning a window refill is still found" {
    const a = testing.allocator;
    // Longer than the cursor window, with the needle straddling it.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    try text.appendNTimes(a, 'x', WINDOW - 3);
    try text.appendSlice(a, "NEEDLE-42");
    try text.appendNTimes(a, 'y', WINDOW * 2);
    try text.appendSlice(a, "NEEDLE-7");

    const got = try findAllSlice(a, "NEEDLE-(\\d+)", text.items, .{});
    defer a.free(got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(WINDOW - 3, got[0].start);
    try testing.expectEqualStrings("NEEDLE-42", text.items[got[0].start..got[0].end]);
    try testing.expectEqualStrings("NEEDLE-7", text.items[got[1].start..got[1].end]);
}

test "regex: search from an offset only finds later matches" {
    const a = testing.allocator;
    var prog = try compile(a, "a.", .{});
    defer prog.deinit();
    var m = try Matcher.init(a, &prog);
    defer m.deinit();
    const bytes: []const u8 = "ax ay az";
    const src = sliceSource(&bytes);
    try testing.expectEqual(@as(usize, 0), (try m.search(src, 0)).?.start());
    try testing.expectEqual(@as(usize, 3), (try m.search(src, 1)).?.start());
    try testing.expectEqual(@as(usize, 6), (try m.search(src, 4)).?.start());
    try testing.expect((try m.search(src, 7)) == null);
}
