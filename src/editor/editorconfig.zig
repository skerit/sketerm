//! `.editorconfig` support (https://spec.editorconfig.org): the file
//! format, the section-glob language, and property resolution for one
//! document path.
//!
//! Pure: the caller hands in the text of every `.editorconfig` between
//! the document and the filesystem root (`candidates` names them), so
//! remote documents resolve through the daemon file service exactly
//! like local ones and this module never touches a disk.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FILE_NAME = ".editorconfig";

/// Largest `.editorconfig` read; the spec caps sections and values far
/// below this, so anything bigger is not a real one.
pub const MAX_FILE_BYTES: usize = 64 * 1024;

pub const IndentStyle = enum { tab, space };
pub const IndentSize = union(enum) { tab, cols: u16 };
pub const EndOfLine = enum { lf, crlf, cr };
pub const Charset = enum { latin1, utf_8, utf_8_bom, utf_16be, utf_16le };

/// The properties the editor honours. Null = not set by any matching
/// section (or explicitly `unset`).
pub const Props = struct {
    indent_style: ?IndentStyle = null,
    indent_size: ?IndentSize = null,
    tab_width: ?u16 = null,
    end_of_line: ?EndOfLine = null,
    charset: ?Charset = null,
    trim_trailing_whitespace: ?bool = null,
    insert_final_newline: ?bool = null,
    /// Null for unset and for `off`.
    max_line_length: ?u32 = null,

    /// Whether any property is set at all.
    pub fn any(self: Props) bool {
        inline for (std.meta.fields(Props)) |f| {
            if (@field(self, f.name) != null) return true;
        }
        return false;
    }

    /// Indent width in columns once the spec's defaults are applied.
    pub fn indentCols(self: Props) ?u16 {
        const size = self.indent_size orelse return null;
        return switch (size) {
            .cols => |n| n,
            .tab => self.tab_width,
        };
    }

    /// The spec's cross-property defaults: `indent_style = tab` implies
    /// `indent_size = tab`, a numeric `indent_size` implies `tab_width`,
    /// and `indent_size = tab` takes `tab_width`'s value.
    fn applyDefaults(self: *Props) void {
        if (self.indent_style == .tab and self.indent_size == null) self.indent_size = .tab;
        if (self.indent_size) |s| switch (s) {
            .cols => |n| {
                if (self.tab_width == null) self.tab_width = n;
            },
            .tab => {},
        };
    }
};

// ======================================================================
// Parsing
// ======================================================================

/// Whether `text` declares `root = true` in its preamble.
pub fn isRoot(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') return false;
        const kv = splitPair(line) orelse continue;
        if (std.ascii.eqlIgnoreCase(kv.key, "root")) return std.ascii.eqlIgnoreCase(kv.value, "true");
    }
    return false;
}

const Pair = struct { key: []const u8, value: []const u8 };

fn splitPair(line: []const u8) ?Pair {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (key.len == 0) return null;
    return .{ .key = key, .value = value };
}

/// Section header text between `[` and the LAST `]`, or null.
fn sectionOf(line: []const u8) ?[]const u8 {
    if (line.len < 2 or line[0] != '[') return null;
    const close = std.mem.lastIndexOfScalar(u8, line, ']') orelse return null;
    if (close == 0) return null;
    return line[1..close];
}

fn setProp(p: *Props, key: []const u8, value: []const u8) void {
    const unset = std.ascii.eqlIgnoreCase(value, "unset");
    if (std.ascii.eqlIgnoreCase(key, "indent_style")) {
        if (unset) p.indent_style = null else if (std.ascii.eqlIgnoreCase(value, "tab")) p.indent_style = .tab else if (std.ascii.eqlIgnoreCase(value, "space")) p.indent_style = .space;
    } else if (std.ascii.eqlIgnoreCase(key, "indent_size")) {
        if (unset) p.indent_size = null else if (std.ascii.eqlIgnoreCase(value, "tab")) p.indent_size = .tab else if (parseCols(value)) |n| p.indent_size = .{ .cols = n };
    } else if (std.ascii.eqlIgnoreCase(key, "tab_width")) {
        if (unset) p.tab_width = null else if (parseCols(value)) |n| p.tab_width = n;
    } else if (std.ascii.eqlIgnoreCase(key, "end_of_line")) {
        var buf: [4]u8 = undefined;
        const v = if (value.len <= buf.len) std.ascii.lowerString(buf[0..value.len], value) else value;
        if (unset) p.end_of_line = null else if (std.meta.stringToEnum(EndOfLine, v)) |e| p.end_of_line = e;
    } else if (std.ascii.eqlIgnoreCase(key, "charset")) {
        if (unset) p.charset = null else if (charsetOf(value)) |cs| p.charset = cs;
    } else if (std.ascii.eqlIgnoreCase(key, "trim_trailing_whitespace")) {
        if (unset) p.trim_trailing_whitespace = null else if (boolOf(value)) |b| p.trim_trailing_whitespace = b;
    } else if (std.ascii.eqlIgnoreCase(key, "insert_final_newline")) {
        if (unset) p.insert_final_newline = null else if (boolOf(value)) |b| p.insert_final_newline = b;
    } else if (std.ascii.eqlIgnoreCase(key, "max_line_length")) {
        if (unset or std.ascii.eqlIgnoreCase(value, "off")) {
            p.max_line_length = null;
        } else if (std.fmt.parseInt(u32, value, 10)) |n| {
            if (n > 0) p.max_line_length = n;
        } else |_| {}
    }
}

/// Positive column counts up to a sane cap; anything else is invalid
/// and, per the spec, ignored.
fn parseCols(value: []const u8) ?u16 {
    const n = std.fmt.parseInt(u16, value, 10) catch return null;
    if (n == 0 or n > 64) return null;
    return n;
}

fn boolOf(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    return null;
}

fn charsetOf(value: []const u8) ?Charset {
    const table = [_]struct { name: []const u8, cs: Charset }{
        .{ .name = "latin1", .cs = .latin1 },
        .{ .name = "utf-8", .cs = .utf_8 },
        .{ .name = "utf-8-bom", .cs = .utf_8_bom },
        .{ .name = "utf-16be", .cs = .utf_16be },
        .{ .name = "utf-16le", .cs = .utf_16le },
    };
    for (table) |t| {
        if (std.ascii.eqlIgnoreCase(t.name, value)) return t.cs;
    }
    return null;
}

// ======================================================================
// Globs
// ======================================================================

/// Whether section `glob` of an `.editorconfig` in directory `dir`
/// applies to the absolute `path`. A glob without `/` matches the
/// basename in any directory below `dir`; one with `/` is anchored at
/// `dir` (a leading `/` is the same anchor).
pub fn sectionMatches(glob: []const u8, dir: []const u8, path: []const u8) bool {
    const base = std.mem.trimEnd(u8, dir, "/");
    if (!std.mem.startsWith(u8, path, base) or path.len <= base.len or path[base.len] != '/') return false;
    const rel = path[base.len + 1 ..];
    if (!globHasSlash(glob)) {
        // `**/<glob>`: try the glob at every component boundary.
        var start: usize = 0;
        while (true) {
            if (globMatch(glob, rel[start..])) return true;
            const slash = std.mem.indexOfScalarPos(u8, rel, start, '/') orelse return false;
            start = slash + 1;
        }
    }
    const g = if (glob.len > 0 and glob[0] == '/') glob[1..] else glob;
    return globMatch(g, rel);
}

/// A `/` outside brackets and escapes anchors a glob.
fn globHasSlash(glob: []const u8) bool {
    var i: usize = 0;
    var in_class = false;
    while (i < glob.len) : (i += 1) {
        switch (glob[i]) {
            '\\' => i += 1,
            '[' => in_class = true,
            ']' => in_class = false,
            '/' => if (!in_class) return true,
            else => {},
        }
    }
    return false;
}

/// Most pattern pieces one match may have pending (a brace alternative
/// pushes one); deeper nesting simply fails to match.
const MAX_SEGS = 16;

/// EditorConfig glob match of the WHOLE string: `*` (not `/`), `**`,
/// `?`, `[set]`/`[!set]` with ranges, `{a,b}` (nestable), `{n..m}`
/// numeric ranges, `\` escapes.
pub fn globMatch(glob: []const u8, s: []const u8) bool {
    const segs = [_][]const u8{glob};
    return matchSegs(&segs, s);
}

/// Match `s` against the concatenation of `segs`.
fn matchSegs(segs_in: []const []const u8, s_in: []const u8) bool {
    var segs = segs_in;
    var s = s_in;
    var seg: []const u8 = &.{};
    while (true) {
        while (seg.len == 0) {
            if (segs.len == 0) return s.len == 0;
            seg = segs[0];
            segs = segs[1..];
        }
        const c = seg[0];
        switch (c) {
            '*' => {
                const double = seg.len > 1 and seg[1] == '*';
                var after = if (double) seg[2..] else seg[1..];
                // Collapse runs of `*` the way the reference does.
                while (after.len > 0 and after[0] == '*') after = after[1..];
                // `a/**/b` also matches `a/b`: zero directories.
                if (double and after.len > 0 and after[0] == '/' and matchWith(after[1..], segs, s)) return true;
                var j: usize = 0;
                while (true) : (j += 1) {
                    if (matchWith(after, segs, s[j..])) return true;
                    if (j >= s.len) return false;
                    if (!double and s[j] == '/') return false;
                }
            },
            '?' => {
                if (s.len == 0 or s[0] == '/') return false;
                seg = seg[1..];
                s = s[1..];
            },
            '[' => {
                const cls = parseClass(seg) orelse {
                    // No closing `]`: a literal `[`.
                    if (s.len == 0 or s[0] != '[') return false;
                    seg = seg[1..];
                    s = s[1..];
                    continue;
                };
                if (s.len == 0 or s[0] == '/') return false;
                if (!cls.matches(s[0])) return false;
                seg = seg[cls.len..];
                s = s[1..];
            },
            '{' => {
                const close = braceEnd(seg) orelse {
                    if (s.len == 0 or s[0] != '{') return false;
                    seg = seg[1..];
                    s = s[1..];
                    continue;
                };
                const inner = seg[1..close];
                const rest = seg[close + 1 ..];
                if (numericRange(inner)) |range| {
                    return matchNumber(range, rest, segs, s);
                }
                if (!hasTopComma(inner)) {
                    // `{single}` is literal, braces included.
                    if (!std.mem.startsWith(u8, s, seg[0 .. close + 1])) return false;
                    s = s[close + 1 ..];
                    seg = rest;
                    continue;
                }
                var alt_start: usize = 0;
                var depth: usize = 0;
                var k: usize = 0;
                while (k <= inner.len) : (k += 1) {
                    const at_end = k == inner.len;
                    if (!at_end) {
                        switch (inner[k]) {
                            '\\' => {
                                k += 1;
                                continue;
                            },
                            '{' => depth += 1,
                            '}' => depth -|= 1,
                            else => {},
                        }
                    }
                    if (at_end or (inner[k] == ',' and depth == 0)) {
                        const alt = inner[alt_start..k];
                        if (matchWith2(alt, rest, segs, s)) return true;
                        alt_start = k + 1;
                    }
                }
                return false;
            },
            '\\' => {
                if (seg.len < 2) return false;
                if (s.len == 0 or s[0] != seg[1]) return false;
                seg = seg[2..];
                s = s[1..];
            },
            else => {
                if (s.len == 0 or s[0] != c) return false;
                seg = seg[1..];
                s = s[1..];
            },
        }
    }
}

fn matchWith(head: []const u8, tail: []const []const u8, s: []const u8) bool {
    if (tail.len + 1 > MAX_SEGS) return false;
    var buf: [MAX_SEGS][]const u8 = undefined;
    buf[0] = head;
    @memcpy(buf[1 .. 1 + tail.len], tail);
    return matchSegs(buf[0 .. 1 + tail.len], s);
}

fn matchWith2(a: []const u8, b: []const u8, tail: []const []const u8, s: []const u8) bool {
    if (tail.len + 2 > MAX_SEGS) return false;
    var buf: [MAX_SEGS][]const u8 = undefined;
    buf[0] = a;
    buf[1] = b;
    @memcpy(buf[2 .. 2 + tail.len], tail);
    return matchSegs(buf[0 .. 2 + tail.len], s);
}

const Class = struct {
    body: []const u8,
    negate: bool,
    /// Bytes of the glob the class occupies, brackets included.
    len: usize,

    fn matches(self: Class, ch: u8) bool {
        var hit = false;
        var i: usize = 0;
        while (i < self.body.len) {
            var lo = self.body[i];
            if (lo == '\\' and i + 1 < self.body.len) {
                i += 1;
                lo = self.body[i];
            }
            if (i + 2 < self.body.len and self.body[i + 1] == '-') {
                var hi = self.body[i + 2];
                var step: usize = 3;
                if (hi == '\\' and i + 3 < self.body.len) {
                    hi = self.body[i + 3];
                    step = 4;
                }
                if (ch >= lo and ch <= hi) hit = true;
                i += step;
                continue;
            }
            if (ch == lo) hit = true;
            i += 1;
        }
        return hit != self.negate;
    }
};

fn parseClass(seg: []const u8) ?Class {
    var i: usize = 1;
    var negate = false;
    if (i < seg.len and (seg[i] == '!' or seg[i] == '^')) {
        negate = true;
        i += 1;
    }
    const body_start = i;
    // A `]` right after the opener is a member, not the close.
    if (i < seg.len and seg[i] == ']') i += 1;
    while (i < seg.len) : (i += 1) {
        if (seg[i] == '\\') {
            i += 1;
            continue;
        }
        if (seg[i] == '/') return null;
        if (seg[i] == ']') return .{ .body = seg[body_start..i], .negate = negate, .len = i + 1 };
    }
    return null;
}

/// Index of the `}` closing the `{` at seg[0], honouring nesting.
fn braceEnd(seg: []const u8) ?usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < seg.len) : (i += 1) {
        switch (seg[i]) {
            '\\' => i += 1,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn hasTopComma(inner: []const u8) bool {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        switch (inner[i]) {
            '\\' => i += 1,
            '{' => depth += 1,
            '}' => depth -|= 1,
            ',' => if (depth == 0) return true,
            else => {},
        }
    }
    return false;
}

const Range = struct { lo: i64, hi: i64 };

fn numericRange(inner: []const u8) ?Range {
    const dots = std.mem.indexOf(u8, inner, "..") orelse return null;
    const a = std.fmt.parseInt(i64, inner[0..dots], 10) catch return null;
    const b = std.fmt.parseInt(i64, inner[dots + 2 ..], 10) catch return null;
    return .{ .lo = @min(a, b), .hi = @max(a, b) };
}

/// `{n..m}`: an optionally signed decimal in range, then the rest.
fn matchNumber(range: Range, rest: []const u8, tail: []const []const u8, s: []const u8) bool {
    var n: usize = 0;
    if (n < s.len and (s[n] == '-' or s[n] == '+')) n += 1;
    const digits_start = n;
    while (n < s.len and std.ascii.isDigit(s[n])) n += 1;
    if (n == digits_start) return false;
    // Every prefix that is itself a number is a candidate split.
    var end = n;
    while (end > digits_start) : (end -= 1) {
        const v = std.fmt.parseInt(i64, s[0..end], 10) catch continue;
        // The reference rejects leading zeros ("01" is not 1).
        if (end - digits_start > 1 and s[digits_start] == '0') continue;
        if (v >= range.lo and v <= range.hi and matchWith(rest, tail, s[end..])) return true;
    }
    return false;
}

// ======================================================================
// Resolution
// ======================================================================

/// One `.editorconfig` found above the document.
pub const Found = struct {
    /// Directory holding it (no trailing slash; "" for the root).
    dir: []const u8,
    text: []const u8,
};

/// The `.editorconfig` paths to consult for `path`, NEAREST first,
/// every ancestor directory up to `/`. Caller frees each and the slice.
pub fn candidates(alloc: Allocator, path: []const u8) Allocator.Error![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| alloc.free(p);
        out.deinit(alloc);
    }
    var dir = path[0 .. std.mem.lastIndexOfScalar(u8, path, '/') orelse return out.toOwnedSlice(alloc)];
    while (true) {
        const p = try std.fmt.allocPrint(alloc, "{s}/" ++ FILE_NAME, .{dir});
        errdefer alloc.free(p);
        try out.append(alloc, p);
        if (dir.len == 0) break;
        const slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse break;
        dir = dir[0..slash];
    }
    return out.toOwnedSlice(alloc);
}

/// Directory part of a candidate path from `candidates`.
pub fn dirOf(candidate: []const u8) []const u8 {
    return candidate[0 .. std.mem.lastIndexOfScalar(u8, candidate, '/') orelse 0];
}

/// Properties for `path` from `found` (NEAREST first, as `candidates`
/// orders them; files past the first `root = true` are ignored). The
/// farthest file applies first and nearer files override it, and within
/// a file later sections override earlier ones.
pub fn resolve(found: []const Found, path: []const u8) Props {
    var last = found.len;
    for (found, 0..) |f, i| {
        if (isRoot(f.text)) {
            last = i + 1;
            break;
        }
    }
    var props: Props = .{};
    var i = last;
    while (i > 0) {
        i -= 1;
        applyFile(&props, found[i], path);
    }
    props.applyDefaults();
    return props;
}

fn applyFile(props: *Props, f: Found, path: []const u8) void {
    var active = false;
    var it = std.mem.splitScalar(u8, f.text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (sectionOf(line)) |glob| {
            active = glob.len <= 4096 and sectionMatches(glob, f.dir, path);
            continue;
        }
        if (!active) continue;
        const kv = splitPair(line) orelse continue;
        setProp(props, kv.key, kv.value);
    }
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

test "editorconfig: glob basics" {
    try testing.expect(globMatch("*.py", "a.py"));
    try testing.expect(!globMatch("*.py", "d/a.py"));
    try testing.expect(globMatch("**.py", "d/e/a.py"));
    try testing.expect(globMatch("a?c", "abc"));
    try testing.expect(!globMatch("a?c", "a/c"));
    try testing.expect(globMatch("[ab].txt", "b.txt"));
    try testing.expect(!globMatch("[!ab].txt", "a.txt"));
    try testing.expect(globMatch("[!ab].txt", "c.txt"));
    try testing.expect(globMatch("[a-c]x", "bx"));
    try testing.expect(globMatch("*.{js,ts}", "m.ts"));
    try testing.expect(!globMatch("*.{js,ts}", "m.rs"));
    try testing.expect(globMatch("{a,{b,c}}.x", "c.x"));
    try testing.expect(globMatch("{single}", "{single}"));
    try testing.expect(!globMatch("{single}", "single"));
    try testing.expect(globMatch("file{1..3}.txt", "file2.txt"));
    try testing.expect(!globMatch("file{1..3}.txt", "file4.txt"));
    try testing.expect(globMatch("file{-2..2}", "file-1"));
    try testing.expect(!globMatch("file{1..3}.txt", "file02.txt"));
    try testing.expect(globMatch("a\\*b", "a*b"));
    try testing.expect(!globMatch("a\\*b", "axb"));
    try testing.expect(globMatch("[", "["));
    try testing.expect(globMatch("*", ""));
    try testing.expect(globMatch("lib/**/x.js", "lib/a/b/x.js"));
    try testing.expect(globMatch("lib/**/x.js", "lib/x.js"));
    try testing.expect(!globMatch("lib/*/x.js", "lib/x.js"));
}

test "editorconfig: sections without a slash match in any directory" {
    try testing.expect(sectionMatches("*", "/p", "/p/a/b/c.zig"));
    try testing.expect(sectionMatches("*.zig", "/p", "/p/a/b/c.zig"));
    try testing.expect(sectionMatches("Makefile", "/p", "/p/sub/Makefile"));
    try testing.expect(!sectionMatches("*.zig", "/p", "/q/c.zig"));
    // A slash anchors at the file's directory.
    try testing.expect(sectionMatches("lib/*.js", "/p", "/p/lib/a.js"));
    try testing.expect(!sectionMatches("lib/*.js", "/p", "/p/x/lib/a.js"));
    try testing.expect(sectionMatches("/lib/**.js", "/p", "/p/lib/a/b.js"));
    try testing.expect(sectionMatches("*", "", "/etc/x"));
    try testing.expect(sectionMatches("{Makefile,*.mk}", "/p/", "/p/a.mk"));
}

test "editorconfig: nearer files and later sections win; root stops the walk" {
    const outer = Found{ .dir = "", .text =
        \\[*]
        \\indent_style = space
        \\indent_size = 8
        \\trim_trailing_whitespace = true
    };
    const proj = Found{ .dir = "/home/u/proj", .text =
        \\root = true
        \\
        \\[*]
        \\indent_style = space
        \\indent_size = 4
        \\insert_final_newline = true
        \\end_of_line = LF
        \\
        \\[*.py]
        \\indent_size = 2
        \\
        \\[Makefile]
        \\indent_style = tab
    };
    const sub = Found{ .dir = "/home/u/proj/web", .text =
        \\[*.py]
        \\indent_size = 3
        \\max_line_length = 100
    };
    const found = [_]Found{ sub, proj, outer };

    const py = resolve(&found, "/home/u/proj/web/a.py");
    try testing.expectEqual(IndentStyle.space, py.indent_style.?);
    try testing.expectEqual(@as(u16, 3), py.indentCols().?);
    try testing.expectEqual(@as(u16, 3), py.tab_width.?);
    try testing.expectEqual(@as(u32, 100), py.max_line_length.?);
    try testing.expectEqual(EndOfLine.lf, py.end_of_line.?);
    try testing.expect(py.insert_final_newline.?);
    // `root = true` in proj hides the outer file.
    try testing.expect(py.trim_trailing_whitespace == null);

    const mk = resolve(&found, "/home/u/proj/Makefile");
    try testing.expectEqual(IndentStyle.tab, mk.indent_style.?);
    // indent_size was 4 from [*]; tab style does not override a set size.
    try testing.expectEqual(@as(u16, 4), mk.indentCols().?);

    const other = resolve(&found, "/home/u/proj/b.zig");
    try testing.expectEqual(@as(u16, 4), other.indentCols().?);
}

test "editorconfig: unset, invalid values and the tab defaults" {
    const f = Found{ .dir = "/p", .text =
        \\# comment
        \\; also a comment
        \\[*]
        \\indent_style = tab
        \\tab_width = 6
        \\charset = utf-8-bom
        \\[*.txt]
        \\indent_style = unset
        \\indent_size = banana
        \\max_line_length = off
    };
    const found = [_]Found{f};
    const c = resolve(&found, "/p/x.c");
    try testing.expectEqual(IndentStyle.tab, c.indent_style.?);
    // indent_style = tab implies indent_size = tab, which takes tab_width.
    try testing.expectEqual(@as(u16, 6), c.indentCols().?);
    try testing.expectEqual(Charset.utf_8_bom, c.charset.?);
    const t = resolve(&found, "/p/x.txt");
    try testing.expect(t.indent_style == null);
    try testing.expect(t.max_line_length == null);
    try testing.expect(!(Props{}).any());
    try testing.expect(t.any());
}

test "editorconfig: candidate paths run nearest first to the root" {
    const a = testing.allocator;
    const c = try candidates(a, "/home/u/p/f.zig");
    defer {
        for (c) |p| a.free(p);
        a.free(c);
    }
    try testing.expectEqual(@as(usize, 4), c.len);
    try testing.expectEqualStrings("/home/u/p/.editorconfig", c[0]);
    try testing.expectEqualStrings("/.editorconfig", c[3]);
    try testing.expectEqualStrings("/home/u/p", dirOf(c[0]));
    try testing.expectEqualStrings("", dirOf(c[3]));
    try testing.expect(isRoot("root=true\n[*]\n"));
    try testing.expect(!isRoot("[*]\nroot = true\n"));
}
