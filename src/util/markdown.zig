//! A compact Markdown reader: source text in, a flat list of blocks
//! made of styled inline spans out.
//!
//! It exists for the web face's reader mode, whose input is the
//! markdown `src/web/semantic.js` builds out of a page's main region,
//! so the dialect it must understand is exactly that generator's
//! output: ATX headings, paragraphs, fenced code, blockquotes, `-`/`N.`
//! list items, `---` rules, and the inline set `**bold**`, `*italic*`,
//! `` `code` ``, `[label](url)`, `![alt](src)`. Anything else stays
//! literal text rather than becoming an error — page content is
//! untrusted input, and a reader that refuses to render is worse than
//! one that shows an asterisk.
//!
//! No GTK here on purpose: the walker is pure data so it can be tested
//! without a display (`src/ui/webreader.zig` is what turns a `Doc` into
//! a GtkTextBuffer).

const std = @import("std");

pub const Kind = enum {
    heading,
    paragraph,
    /// Fenced code. One span, unstyled, newlines intact.
    code,
    quote,
    bullet,
    ordered,
    /// A thematic break; carries no spans.
    rule,
};

/// One run of inline text with the styles that apply to it. `href`
/// makes it a link (or, with `image`, the source of an image whose alt
/// text is `text`).
pub const Span = struct {
    text: []const u8,
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    href: ?[]const u8 = null,
    image: bool = false,
};

pub const Block = struct {
    kind: Kind,
    /// Heading level 1..6, or an ordered item's number. Zero elsewhere.
    level: u32 = 0,
    spans: []const Span = &.{},
};

/// A parsed document. Every slice in it — the blocks, the spans and the
/// text they point at — lives in the arena, so the source string may be
/// freed the moment `parse` returns.
pub const Doc = struct {
    arena: std.heap.ArenaAllocator,
    blocks: []const Block,

    pub fn deinit(self: *Doc) void {
        self.arena.deinit();
    }
};

/// Nesting cap for inline emphasis, so a pathological page cannot
/// recurse this walker to death.
const MAX_INLINE_DEPTH: u8 = 8;

pub fn parse(gpa: std.mem.Allocator, src: []const u8) !Doc {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const s = try a.dupe(u8, src);

    var blocks: std.ArrayList(Block) = .empty;

    var i: usize = 0;
    while (i < s.len) {
        const end = lineEnd(s, i);
        const line = std.mem.trim(u8, s[i..end], " \t\r");
        if (line.len == 0) {
            i = end + 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "```")) {
            i = try appendFence(a, &blocks, s, end + 1);
            continue;
        }
        if (headingLevel(line)) |lvl| {
            try appendInline(a, &blocks, .{ .kind = .heading, .level = lvl }, std.mem.trimStart(u8, line[lvl..], " \t"));
            i = end + 1;
            continue;
        }
        if (isRule(line)) {
            try blocks.append(a, .{ .kind = .rule });
            i = end + 1;
            continue;
        }
        if (line[0] == '>') {
            try appendInline(a, &blocks, .{ .kind = .quote }, std.mem.trimStart(u8, line[1..], " \t"));
            i = end + 1;
            continue;
        }
        if (bulletBody(line)) |body| {
            try appendInline(a, &blocks, .{ .kind = .bullet }, body);
            i = end + 1;
            continue;
        }
        if (orderedBody(line)) |ord| {
            try appendInline(a, &blocks, .{ .kind = .ordered, .level = ord.n }, ord.body);
            i = end + 1;
            continue;
        }

        // A paragraph runs to the next blank line or the next line that
        // starts a block of its own; the newlines inside it are kept, so
        // a `<br>` the generator turned into a bare newline still breaks.
        var stop = end;
        var j = end + 1;
        while (j < s.len) {
            const je = lineEnd(s, j);
            const l = std.mem.trim(u8, s[j..je], " \t\r");
            if (l.len == 0 or startsBlock(l)) break;
            stop = je;
            j = je + 1;
        }
        try appendInline(a, &blocks, .{ .kind = .paragraph }, std.mem.trim(u8, s[i..stop], " \t\r\n"));
        i = stop + 1;
    }

    return .{ .arena = arena, .blocks = try blocks.toOwnedSlice(a) };
}

fn lineEnd(s: []const u8, from: usize) usize {
    return std.mem.indexOfScalarPos(u8, s, from, '\n') orelse s.len;
}

/// True when `line` (already trimmed) opens a block other than a
/// paragraph — the paragraph accumulator's stop condition.
fn startsBlock(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "```")) return true;
    if (headingLevel(line) != null) return true;
    if (isRule(line)) return true;
    if (line[0] == '>') return true;
    if (bulletBody(line) != null) return true;
    if (orderedBody(line) != null) return true;
    return false;
}

fn headingLevel(line: []const u8) ?u32 {
    var n: u32 = 0;
    while (n < line.len and line[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    // `#tag` is not a heading; `#` alone is an empty one.
    if (n < line.len and line[n] != ' ' and line[n] != '\t') return null;
    return n;
}

fn isRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const ch = line[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    for (line) |b| {
        if (b != ch) return false;
    }
    return true;
}

fn bulletBody(line: []const u8) ?[]const u8 {
    if (line.len < 2) return null;
    if (line[0] != '-' and line[0] != '*' and line[0] != '+') return null;
    if (line[1] != ' ' and line[1] != '\t') return null;
    return std.mem.trimStart(u8, line[2..], " \t");
}

fn orderedBody(line: []const u8) ?struct { n: u32, body: []const u8 } {
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i == 0 or i > 9 or i + 1 >= line.len) return null;
    if (line[i] != '.' and line[i] != ')') return null;
    if (line[i + 1] != ' ' and line[i + 1] != '\t') return null;
    const n = std.fmt.parseInt(u32, line[0..i], 10) catch return null;
    return .{ .n = n, .body = std.mem.trimStart(u8, line[i + 2 ..], " \t") };
}

/// Collect a fenced block whose body starts at `from`, returning the
/// offset just past its closing fence (or the end of input, since an
/// unterminated fence must still render).
fn appendFence(
    a: std.mem.Allocator,
    blocks: *std.ArrayList(Block),
    s: []const u8,
    from: usize,
) !usize {
    var body_end = from;
    var j = from;
    while (j < s.len) {
        const e = lineEnd(s, j);
        if (std.mem.startsWith(u8, std.mem.trim(u8, s[j..e], " \t\r"), "```")) {
            j = e + 1;
            break;
        }
        body_end = e;
        j = e + 1;
    }
    const body = if (body_end > from) s[from..body_end] else "";
    const spans = try a.alloc(Span, 1);
    spans[0] = .{ .text = body };
    try blocks.append(a, .{ .kind = .code, .spans = spans });
    return j;
}

/// Parse `text` as inline markup and append the resulting block. A
/// block whose inline content is empty is dropped: the generator emits
/// those for decorative wrappers and they read as blank gaps.
fn appendInline(
    a: std.mem.Allocator,
    blocks: *std.ArrayList(Block),
    proto: Block,
    text: []const u8,
) !void {
    var spans: std.ArrayList(Span) = .empty;
    try inlineInto(a, &spans, text, .{ .text = "" }, 0);
    if (spans.items.len == 0) return;
    var block = proto;
    block.spans = try spans.toOwnedSlice(a);
    try blocks.append(a, block);
}

fn inlineInto(
    a: std.mem.Allocator,
    out: *std.ArrayList(Span),
    text: []const u8,
    base: Span,
    depth: u8,
) !void {
    if (text.len == 0) return;
    if (depth >= MAX_INLINE_DEPTH) return emit(a, out, base, text);

    var lit: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            '`' => {
                const close = std.mem.indexOfScalarPos(u8, text, i + 1, '`') orelse {
                    i += 1;
                    continue;
                };
                try emit(a, out, base, text[lit..i]);
                var span = base;
                span.code = true;
                try emit(a, out, span, text[i + 1 .. close]);
                i = close + 1;
                lit = i;
            },
            // Only `*` opens emphasis. `_` deliberately does not: the
            // generator never emits it, while pages are full of
            // identifiers like `some_var and other_var`, which the
            // underscore rule would render as one italic run.
            '*' => {
                const double = i + 1 < text.len and text[i + 1] == '*';
                const marker: []const u8 = if (double) "**" else "*";
                const from = i + marker.len;
                const close = std.mem.indexOfPos(u8, text, from, marker) orelse {
                    i += 1;
                    continue;
                };
                if (close == from) {
                    i += 1;
                    continue;
                }
                try emit(a, out, base, text[lit..i]);
                var span = base;
                if (double) span.bold = true else span.italic = true;
                try inlineInto(a, out, text[from..close], span, depth + 1);
                i = close + marker.len;
                lit = i;
            },
            '!', '[' => {
                const image = text[i] == '!';
                if (image and (i + 1 >= text.len or text[i + 1] != '[')) {
                    i += 1;
                    continue;
                }
                const open = if (image) i + 1 else i;
                const parsed = parseLink(text, open) orelse {
                    i += 1;
                    continue;
                };
                try emit(a, out, base, text[lit..i]);
                if (image) {
                    try emit(a, out, .{
                        .text = parsed.label,
                        .href = parsed.url,
                        .image = true,
                        .italic = true,
                    }, parsed.label);
                } else {
                    var span = base;
                    span.href = parsed.url;
                    try inlineInto(a, out, parsed.label, span, depth + 1);
                }
                i = parsed.end;
                lit = i;
            },
            else => i += 1,
        }
    }
    try emit(a, out, base, text[lit..]);
}

const Link = struct { label: []const u8, url: []const u8, end: usize };

/// `[label](url)` starting at the `[` in `at`. Bracket nesting inside
/// the label is honoured so `[**a**](u)` and `[[x]](u)` both work.
fn parseLink(text: []const u8, at: usize) ?Link {
    if (at >= text.len or text[at] != '[') return null;
    var depth: usize = 1;
    var i = at + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '[') depth += 1;
        if (text[i] == ']') {
            depth -= 1;
            if (depth == 0) break;
        }
    }
    if (i >= text.len or i + 1 >= text.len or text[i + 1] != '(') return null;
    const close = std.mem.indexOfScalarPos(u8, text, i + 2, ')') orelse return null;
    return .{
        .label = text[at + 1 .. i],
        .url = std.mem.trim(u8, text[i + 2 .. close], " \t"),
        .end = close + 1,
    };
}

/// Append `text` under `style`, dropping empty runs — except an image,
/// whose empty alt text is still a thing the reader must show.
fn emit(a: std.mem.Allocator, out: *std.ArrayList(Span), style: Span, text: []const u8) !void {
    if (text.len == 0 and !style.image) return;
    var span = style;
    span.text = text;
    try out.append(a, span);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

/// A one-line rendering of a parsed doc, so a fixture can assert the
/// whole structure at once instead of block by block.
fn debugRender(alloc: std.mem.Allocator, doc: Doc) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;
    for (doc.blocks, 0..) |b, bi| {
        if (bi != 0) try w.writeByte('\n');
        switch (b.kind) {
            .heading => try w.print("h{d}:", .{b.level}),
            .paragraph => try w.writeAll("p:"),
            .code => try w.writeAll("code:"),
            .quote => try w.writeAll("quote:"),
            .bullet => try w.writeAll("li:"),
            .ordered => try w.print("li{d}:", .{b.level}),
            .rule => try w.writeAll("hr:"),
        }
        for (b.spans) |s| {
            if (s.image) {
                try w.print("[img {s} -> {s}]", .{ s.text, s.href orelse "" });
                continue;
            }
            if (s.href) |h| try w.print("[link {s}]", .{h});
            if (s.bold) try w.writeAll("<b>");
            if (s.italic) try w.writeAll("<i>");
            if (s.code) try w.writeAll("<c>");
            try w.writeAll(s.text);
            if (s.code) try w.writeAll("</c>");
            if (s.italic) try w.writeAll("</i>");
            if (s.bold) try w.writeAll("</b>");
        }
    }
    return alloc.dupe(u8, aw.written());
}

test "markdown: the shape semantic.js emits" {
    const alloc = std.testing.allocator;
    const fixture =
        \\# Page Title
        \\
        \\## A section
        \\
        \\Plain text with **bold**, *italic*, `code()` and a [link](https://example.com/a).
        \\
        \\> A quote from somewhere
        \\
        \\- first item
        \\- second **item**
        \\
        \\1. one
        \\2. two
        \\
        \\```
        \\fn main() void {}
        \\    indented
        \\```
        \\
        \\---
        \\
        \\![a cat](/img/cat.png)
        \\
    ;
    var doc = try parse(alloc, fixture);
    defer doc.deinit();
    const got = try debugRender(alloc, doc);
    defer alloc.free(got);

    const want =
        \\h1:Page Title
        \\h2:A section
        \\p:Plain text with <b>bold</b>, <i>italic</i>, <c>code()</c> and a [link https://example.com/a]link.
        \\quote:A quote from somewhere
        \\li:first item
        \\li:second <b>item</b>
        \\li1:one
        \\li2:two
        \\code:fn main() void {}
        \\    indented
        \\hr:
        \\p:[img a cat -> /img/cat.png]
    ;
    try std.testing.expectEqualStrings(want, got);
}

test "markdown: the source string may die before the doc" {
    const alloc = std.testing.allocator;
    const src = try alloc.dupe(u8, "# Gone\n\nstill **here**\n");
    var doc = try parse(alloc, src);
    defer doc.deinit();
    alloc.free(src);

    try std.testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try std.testing.expectEqualStrings("Gone", doc.blocks[0].spans[0].text);
    try std.testing.expectEqualStrings("here", doc.blocks[1].spans[1].text);
    try std.testing.expect(doc.blocks[1].spans[1].bold);
}

test "markdown: unmatched markup stays literal" {
    const alloc = std.testing.allocator;
    var doc = try parse(alloc, "a * b ` c [d](  and #notahead\n");
    defer doc.deinit();
    const got = try debugRender(alloc, doc);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("p:a * b ` c [d](  and #notahead", got);
}

test "markdown: nested emphasis inside a link label" {
    const alloc = std.testing.allocator;
    var doc = try parse(alloc, "[see **this** now](http://x/y)\n");
    defer doc.deinit();
    const got = try debugRender(alloc, doc);
    defer alloc.free(got);
    try std.testing.expectEqualStrings(
        "p:[link http://x/y]see [link http://x/y]<b>this</b>[link http://x/y] now",
        got,
    );
}

test "markdown: a paragraph keeps its interior newlines" {
    const alloc = std.testing.allocator;
    var doc = try parse(alloc, "line one\nline two\n\nnext\n");
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try std.testing.expectEqualStrings("line one\nline two", doc.blocks[0].spans[0].text);
}

test "markdown: an unterminated fence still renders" {
    const alloc = std.testing.allocator;
    var doc = try parse(alloc, "```\nno end in sight\n");
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expectEqual(Kind.code, doc.blocks[0].kind);
    try std.testing.expectEqualStrings("no end in sight", doc.blocks[0].spans[0].text);
}

test "markdown: empty input yields no blocks" {
    const alloc = std.testing.allocator;
    var doc = try parse(alloc, "");
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 0), doc.blocks.len);
}
