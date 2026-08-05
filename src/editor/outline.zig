//! Symbol outline for one document: a flat, depth-tagged list of the
//! symbols a panel shows and navigates by.
//!
//! ## Two sources, never three
//!
//! `documentSymbol` from a language server is authoritative when one is
//! attached (it knows about types, visibility and nesting we cannot
//! derive), and the Tree-sitter tree the highlighter already keeps is
//! the fallback when there is no server. Both already exist in this
//! codebase; nothing here adds a third parser. `Source` records which
//! one answered, so a UI can say so and so a test can assert it.
//!
//! ## Flat list, not a tree
//!
//! Nodes come out in DOCUMENT ORDER with a `depth` field. That is what
//! the panel renders (indentation), what caret tracking scans (the last
//! node whose range contains the caret is the deepest one, because a
//! parent always precedes its children), and what makes the
//! "did the shape change" comparison a cheap hash instead of a tree
//! diff.
//!
//! ## Surviving edits without flicker
//!
//! Ranges are byte offsets carried through every edit with
//! `transaction.mapOffset` — the same machinery folds, selections,
//! diagnostics and the git gutter use. A rebuild from a lagging source
//! is therefore never needed just to keep the highlight in the right
//! place, and the panel only re-creates its rows when `signature()`
//! changes, so typing inside a function body never rebuilds the list.

const std = @import("std");
const Document = @import("document.zig").Document;
const tr = @import("transaction.zig");
const syntax = @import("syntax.zig");

/// LSP `SymbolKind` folded onto what an outline can usefully show. The
/// numbering is ours; `fromLsp` does the translation.
pub const Kind = enum(u8) {
    file,
    module,
    namespace,
    class,
    method,
    property,
    field,
    constructor,
    enumeration,
    interface,
    function,
    variable,
    constant,
    structure,
    enum_member,
    type_alias,
    heading,
    key,
    unknown,

    /// Short label a compact panel shows before the name.
    pub fn tag(self: Kind) []const u8 {
        return switch (self) {
            .file => "file",
            .module => "mod",
            .namespace => "ns",
            .class => "class",
            .method => "fn",
            .property => "prop",
            .field => "field",
            .constructor => "init",
            .enumeration => "enum",
            .interface => "iface",
            .function => "fn",
            .variable => "var",
            .constant => "const",
            .structure => "struct",
            .enum_member => "case",
            .type_alias => "type",
            .heading => "#",
            .key => "key",
            .unknown => "?",
        };
    }
};

/// LSP SymbolKind (1..26) -> `Kind`. Out-of-range values answer
/// `.unknown` rather than being dropped: a symbol with a kind we do not
/// recognise is still a symbol worth navigating to.
pub fn fromLsp(n: i64) Kind {
    return switch (n) {
        1 => .file,
        2 => .module,
        3 => .namespace,
        4 => .module, // Package
        5 => .class,
        6 => .method,
        7 => .property,
        8 => .field,
        9 => .constructor,
        10 => .enumeration,
        11 => .interface,
        12 => .function,
        13 => .variable,
        14 => .constant,
        15...21 => .constant, // String/Number/Boolean/Array/Object/Key/Null
        22 => .enum_member,
        23 => .structure,
        24 => .constant, // Event
        25 => .function, // Operator
        26 => .type_alias,
        else => .unknown,
    };
}

pub const Source = enum { none, lsp, tree };

pub const Node = struct {
    kind: Kind,
    depth: u16,
    /// Full extent of the symbol (used for caret tracking).
    start: usize,
    end: usize,
    /// Where clicking the row puts the caret — the identifier, not the
    /// body. LSP calls this `selectionRange`.
    sel: usize,
    name_off: u32,
    name_len: u32,
    detail_off: u32,
    detail_len: u32,
};

/// One symbol handed to `push`.
pub const Item = struct {
    kind: Kind = .unknown,
    depth: u16 = 0,
    start: usize = 0,
    end: usize = 0,
    sel: usize = 0,
    name: []const u8 = "",
    detail: []const u8 = "",
};

/// Names longer than this are truncated; a symbol name that long is a
/// generated identifier and the panel cannot show it anyway.
pub const MAX_NAME: usize = 160;

/// Hard cap on symbols. A minified JSON file is a legitimate document
/// with a million "symbols"; the panel must not become the reason the
/// editor stalls.
pub const MAX_NODES: usize = 4000;

pub const Outline = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    strings: std.ArrayList(u8) = .empty,
    source: Source = .none,
    /// Document revision the ranges were resolved at. Informational:
    /// the ranges themselves are kept current by `mapThrough`.
    revision: u64 = 0,
    /// True when the list was cut short by `MAX_NODES`.
    truncated: bool = false,

    pub fn init(allocator: std.mem.Allocator) Outline {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Outline) void {
        self.nodes.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn clear(self: *Outline) void {
        self.nodes.clearRetainingCapacity();
        self.strings.clearRetainingCapacity();
        self.source = .none;
        self.truncated = false;
    }

    pub fn isEmpty(self: *const Outline) bool {
        return self.nodes.items.len == 0;
    }

    pub fn push(self: *Outline, item: Item) std.mem.Allocator.Error!void {
        if (self.nodes.items.len >= MAX_NODES) {
            self.truncated = true;
            return;
        }
        const nm = item.name[0..@min(item.name.len, MAX_NAME)];
        const det = item.detail[0..@min(item.detail.len, MAX_NAME)];
        const name_off: u32 = @intCast(self.strings.items.len);
        try self.strings.appendSlice(self.allocator, nm);
        const detail_off: u32 = @intCast(self.strings.items.len);
        try self.strings.appendSlice(self.allocator, det);
        try self.nodes.append(self.allocator, .{
            .kind = item.kind,
            .depth = item.depth,
            .start = item.start,
            .end = @max(item.end, item.start),
            .sel = std.math.clamp(item.sel, item.start, @max(item.end, item.start)),
            .name_off = name_off,
            .name_len = @intCast(nm.len),
            .detail_off = detail_off,
            .detail_len = @intCast(det.len),
        });
    }

    pub fn name(self: *const Outline, i: usize) []const u8 {
        const n = self.nodes.items[i];
        return self.strings.items[n.name_off .. n.name_off + n.name_len];
    }

    pub fn detail(self: *const Outline, i: usize) []const u8 {
        const n = self.nodes.items[i];
        return self.strings.items[n.detail_off .. n.detail_off + n.detail_len];
    }

    /// Carry every range through one edit list.
    pub fn mapThrough(self: *Outline, edits: []const tr.Edit) void {
        if (self.nodes.items.len == 0 or edits.len == 0) return;
        for (self.nodes.items) |*n| {
            n.start = tr.mapOffset(edits, n.start, .other);
            n.end = tr.mapOffset(edits, n.end, .other);
            n.sel = std.math.clamp(tr.mapOffset(edits, n.sel, .other), n.start, n.end);
        }
    }

    /// Deepest symbol containing `offset` — the row a panel highlights
    /// as the caret moves. Nodes are in document order with parents
    /// first, so the LAST container wins.
    pub fn indexAt(self: *const Outline, offset: usize) ?usize {
        var best: ?usize = null;
        for (self.nodes.items, 0..) |n, i| {
            if (n.start > offset) break;
            if (offset <= n.end) best = i;
        }
        return best;
    }

    /// Hash of the SHAPE (names, kinds, depths) — not of the ranges.
    /// A panel rebuilds its rows only when this changes, which is what
    /// keeps typing inside a function from re-creating the list.
    pub fn signature(self: *const Outline) u64 {
        var h = std.hash.Wyhash.init(0x0177_1145);
        h.update(&[_]u8{@intFromEnum(self.source)});
        for (self.nodes.items, 0..) |n, i| {
            h.update(&[_]u8{ @intFromEnum(n.kind), @truncate(n.depth) });
            h.update(self.name(i));
            h.update(self.detail(i));
        }
        return h.final();
    }
};

// ======================================================================
// Tree-sitter fallback
// ======================================================================

/// What a grammar's node types mean for an outline, plus the node types
/// whose insides are NOT worth walking (a function body's local
/// variables are noise in an outline, and skipping the body is also
/// what keeps the walk cheap).
const LangSpec = struct {
    /// (node type, kind) pairs. Matched by exact node type.
    symbols: []const Entry,
    /// Node types the walk refuses to descend into.
    opaque_bodies: []const []const u8,
    /// Node types whose child container declaration supplies the real
    /// kind (Zig's `const Foo = struct {...}`).
    wrapper: []const []const u8 = &.{},

    const Entry = struct { node: []const u8, kind: Kind };
};

const zig_spec = LangSpec{
    .symbols = &.{
        .{ .node = "function_declaration", .kind = .function },
        .{ .node = "test_declaration", .kind = .method },
        .{ .node = "struct_declaration", .kind = .structure },
        .{ .node = "union_declaration", .kind = .structure },
        .{ .node = "opaque_declaration", .kind = .structure },
        .{ .node = "enum_declaration", .kind = .enumeration },
        .{ .node = "error_set_declaration", .kind = .enumeration },
        .{ .node = "variable_declaration", .kind = .variable },
        .{ .node = "container_field", .kind = .field },
    },
    .opaque_bodies = &.{"block"},
    .wrapper = &.{"variable_declaration"},
};

const c_spec = LangSpec{
    .symbols = &.{
        .{ .node = "function_definition", .kind = .function },
        .{ .node = "struct_specifier", .kind = .structure },
        .{ .node = "union_specifier", .kind = .structure },
        .{ .node = "enum_specifier", .kind = .enumeration },
        .{ .node = "type_definition", .kind = .type_alias },
        .{ .node = "preproc_def", .kind = .constant },
        .{ .node = "preproc_function_def", .kind = .function },
        .{ .node = "field_declaration", .kind = .field },
        .{ .node = "enumerator", .kind = .enum_member },
    },
    .opaque_bodies = &.{"compound_statement"},
};

const json_spec = LangSpec{
    .symbols = &.{.{ .node = "pair", .kind = .key }},
    .opaque_bodies = &.{},
};

const markdown_spec = LangSpec{
    .symbols = &.{
        .{ .node = "atx_heading", .kind = .heading },
        .{ .node = "setext_heading", .kind = .heading },
    },
    .opaque_bodies = &.{},
};

fn specFor(lang: syntax.Lang) LangSpec {
    return switch (lang) {
        .zig => zig_spec,
        .c => c_spec,
        .json => json_spec,
        .markdown => markdown_spec,
    };
}

/// Node types that carry an identifier we can use as a name, in the
/// order they are preferred.
const name_nodes = [_][]const u8{
    "identifier",
    "type_identifier",
    "field_identifier",
    "string",
    "string_literal",
};

/// How deep below a symbol node the name search goes. C's
/// `function_definition -> declarator -> function_declarator ->
/// declarator -> identifier` is the deepest real case at four.
const NAME_DEPTH: usize = 5;

/// Recursion cap, mirroring `syntax.Highlighter.WALK_DEPTH`.
const WALK_DEPTH: usize = 64;

/// Fill `out` from the highlighter's tree.
///
/// Returns `error.Stale` when the highlighter has not caught up with
/// the document — the caller keeps the previous outline rather than
/// replacing it with a half-parsed one, exactly as folding does.
pub fn fromTree(
    out: *Outline,
    hl: *const syntax.Highlighter,
    doc: *const Document,
    lang: syntax.Lang,
) (syntax.Error || std.mem.Allocator.Error)!void {
    const root = (try hl.rootNode(doc)) orelse return;
    out.clear();
    const spec = specFor(lang);
    var buf: [MAX_NAME]u8 = undefined;
    try walk(out, doc, root, spec, 0, 0, &buf);
    out.source = .tree;
    out.revision = doc.revision;
}

fn walk(
    out: *Outline,
    doc: *const Document,
    node: syntax.TreeNode,
    spec: LangSpec,
    depth: u16,
    recursion: usize,
    buf: []u8,
) std.mem.Allocator.Error!void {
    if (recursion >= WALK_DEPTH) return;
    const n = node.namedChildCount();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (out.nodes.items.len >= MAX_NODES) {
            out.truncated = true;
            return;
        }
        const child = node.namedChild(i) orelse continue;
        const type_name = child.kind();
        if (containsStr(spec.opaque_bodies, type_name)) continue;

        var kind: ?Kind = kindFor(spec, type_name);
        var body = child;
        if (kind != null and containsStr(spec.wrapper, type_name)) {
            // `const Foo = struct { … };` — the wrapper names the
            // symbol, the container decides what it IS.
            if (containerChild(spec, child)) |inner| {
                kind = kindFor(spec, inner.kind());
                body = inner;
            }
        }
        if (kind) |k| {
            const text = nameOf(doc, child, buf);
            try out.push(.{
                .kind = k,
                .depth = depth,
                .start = child.startByte(),
                .end = child.endByte(),
                .sel = nameOffset(child) orelse child.startByte(),
                .name = text,
            });
            try walk(out, doc, body, spec, depth + 1, recursion + 1, buf);
            continue;
        }
        // Not a symbol itself: keep looking inside it at the SAME depth
        // (a `declaration_list`, a `document`, a `section` — grammar
        // scaffolding the outline must see through).
        try walk(out, doc, child, spec, depth, recursion + 1, buf);
    }
}

fn kindFor(spec: LangSpec, type_name: []const u8) ?Kind {
    for (spec.symbols) |e| {
        if (std.mem.eql(u8, e.node, type_name)) return e.kind;
    }
    return null;
}

fn containsStr(list: []const []const u8, needle: []const u8) bool {
    for (list) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

/// The container declaration a wrapper node initialises, if any.
fn containerChild(spec: LangSpec, node: syntax.TreeNode) ?syntax.TreeNode {
    const n = node.namedChildCount();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const child = node.namedChild(i) orelse continue;
        const k = kindFor(spec, child.kind()) orelse continue;
        if (k == .structure or k == .enumeration) return child;
    }
    return null;
}

/// The identifier node that names `node`, searched breadth-first-ish
/// through the `name` field then the shallow named children.
fn nameNode(node: syntax.TreeNode, depth: usize) ?syntax.TreeNode {
    if (node.childByField("name")) |f| return f;
    if (depth >= NAME_DEPTH) return null;
    const n = node.namedChildCount();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const child = node.namedChild(i) orelse continue;
        if (containsStr(&name_nodes, child.kind())) return child;
    }
    i = 0;
    while (i < n) : (i += 1) {
        const child = node.namedChild(i) orelse continue;
        if (nameNode(child, depth + 1)) |found| return found;
    }
    return null;
}

fn nameOffset(node: syntax.TreeNode) ?usize {
    const nn = nameNode(node, 0) orelse return null;
    return nn.startByte();
}

/// Text of the node's name, or a trimmed first line when it has no
/// identifier (a Markdown heading is text, not an identifier).
fn nameOf(doc: *const Document, node: syntax.TreeNode, buf: []u8) []const u8 {
    if (nameNode(node, 0)) |nn| {
        return sliceInto(doc, nn.startByte(), nn.endByte(), buf);
    }
    const raw = sliceInto(doc, node.startByte(), node.endByte(), buf);
    const line_end = std.mem.indexOfScalar(u8, raw, '\n') orelse raw.len;
    return std.mem.trim(u8, raw[0..line_end], " \t#=");
}

fn sliceInto(doc: *const Document, start: usize, end: usize, buf: []u8) []const u8 {
    const hi = @min(end, doc.rope.len());
    const lo = @min(start, hi);
    const want = @min(hi - lo, buf.len);
    var it = doc.rope.iterateRange(lo, lo + want);
    var w: usize = 0;
    while (it.next()) |chunk| {
        const take = @min(chunk.len, buf.len - w);
        @memcpy(buf[w .. w + take], chunk[0..take]);
        w += take;
        if (w == buf.len) break;
    }
    return buf[0..w];
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

test "outline: push, read back and caret tracking" {
    var o = Outline.init(testing.allocator);
    defer o.deinit();
    try o.push(.{ .kind = .structure, .depth = 0, .start = 0, .end = 100, .sel = 6, .name = "Foo" });
    try o.push(.{ .kind = .method, .depth = 1, .start = 20, .end = 60, .sel = 24, .name = "bar", .detail = "() void" });
    try o.push(.{ .kind = .function, .depth = 0, .start = 120, .end = 200, .sel = 124, .name = "main" });
    o.source = .lsp;

    try testing.expectEqualStrings("Foo", o.name(0));
    try testing.expectEqualStrings("bar", o.name(1));
    try testing.expectEqualStrings("() void", o.detail(1));
    try testing.expectEqualStrings("", o.detail(0));

    // The deepest containing node wins.
    try testing.expectEqual(@as(usize, 0), o.indexAt(10).?);
    try testing.expectEqual(@as(usize, 1), o.indexAt(30).?);
    try testing.expectEqual(@as(usize, 0), o.indexAt(80).?);
    try testing.expectEqual(@as(usize, 2), o.indexAt(150).?);
    try testing.expect(o.indexAt(110) == null);
}

test "outline: ranges survive an edit above them" {
    var o = Outline.init(testing.allocator);
    defer o.deinit();
    try o.push(.{ .kind = .function, .start = 50, .end = 90, .sel = 53, .name = "f" });
    const before = o.signature();
    const edits = [_]tr.Edit{.{ .offset = 0, .deleted_len = 0, .inserted = "// hi\n" }};
    o.mapThrough(&edits);
    try testing.expectEqual(@as(usize, 56), o.nodes.items[0].start);
    try testing.expectEqual(@as(usize, 96), o.nodes.items[0].end);
    try testing.expectEqual(@as(usize, 59), o.nodes.items[0].sel);
    // Shape is unchanged, so a panel must not rebuild.
    try testing.expectEqual(before, o.signature());
}

test "outline: signature changes when the shape does" {
    var a = Outline.init(testing.allocator);
    defer a.deinit();
    var b = Outline.init(testing.allocator);
    defer b.deinit();
    try a.push(.{ .kind = .function, .name = "one" });
    try b.push(.{ .kind = .function, .name = "one" });
    try testing.expectEqual(a.signature(), b.signature());
    try b.push(.{ .kind = .function, .name = "two" });
    try testing.expect(a.signature() != b.signature());
}

test "outline: lsp symbol kinds fold onto the palette" {
    try testing.expectEqual(Kind.function, fromLsp(12));
    try testing.expectEqual(Kind.method, fromLsp(6));
    try testing.expectEqual(Kind.structure, fromLsp(23));
    try testing.expectEqual(Kind.enum_member, fromLsp(22));
    try testing.expectEqual(Kind.unknown, fromLsp(0));
    try testing.expectEqual(Kind.unknown, fromLsp(99));
}

test "outline: node cap is enforced" {
    var o = Outline.init(testing.allocator);
    defer o.deinit();
    for (0..MAX_NODES + 10) |i| {
        try o.push(.{ .kind = .variable, .start = i, .end = i, .name = "x" });
    }
    try testing.expectEqual(MAX_NODES, o.nodes.items.len);
    try testing.expect(o.truncated);
}

fn buildTree(src: []const u8, lang: syntax.Lang, o: *Outline) !Document {
    var doc = try Document.initFromBytes(testing.allocator, src);
    errdefer doc.deinit();
    var hl = try syntax.Highlighter.init(testing.allocator, lang);
    defer hl.deinit();
    try hl.parse(&doc);
    try fromTree(o, &hl, &doc, lang);
    return doc;
}

test "outline: zig tree gives functions, tests and container fields" {
    var o = Outline.init(testing.allocator);
    defer o.deinit();
    var doc = try buildTree(
        \\const std = @import("std");
        \\
        \\pub const Point = struct {
        \\    x: i32,
        \\    y: i32,
        \\
        \\    pub fn add(self: Point) i32 {
        \\        var local: i32 = 0;
        \\        return self.x + self.y + local;
        \\    }
        \\};
        \\
        \\pub fn main() void {}
        \\
        \\test "adds" {}
        \\
    , .zig, &o);
    defer doc.deinit();

    try testing.expectEqual(Source.tree, o.source);
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(testing.allocator);
    for (0..o.nodes.items.len) |i| {
        try names.appendSlice(testing.allocator, o.name(i));
        try names.append(testing.allocator, '|');
    }
    // The struct is named by its wrapper and typed by its container;
    // its fields and method nest under it; the function body's `local`
    // is NOT a symbol.
    try testing.expect(std.mem.indexOf(u8, names.items, "Point|") != null);
    try testing.expect(std.mem.indexOf(u8, names.items, "add|") != null);
    try testing.expect(std.mem.indexOf(u8, names.items, "main|") != null);
    try testing.expect(std.mem.indexOf(u8, names.items, "local|") == null);

    var saw_struct = false;
    var saw_field = false;
    for (o.nodes.items, 0..) |nd, i| {
        if (std.mem.eql(u8, o.name(i), "Point")) {
            saw_struct = nd.kind == .structure and nd.depth == 0;
        }
        if (std.mem.eql(u8, o.name(i), "x")) {
            saw_field = nd.kind == .field and nd.depth == 1;
        }
    }
    try testing.expect(saw_struct);
    try testing.expect(saw_field);
}

test "outline: zig selection offset lands on the identifier" {
    var o = Outline.init(testing.allocator);
    defer o.deinit();
    const src =
        \\pub fn hello() void {}
        \\
    ;
    var doc = try buildTree(src, .zig, &o);
    defer doc.deinit();
    try testing.expect(o.nodes.items.len >= 1);
    const idx = for (0..o.nodes.items.len) |i| {
        if (std.mem.eql(u8, o.name(i), "hello")) break i;
    } else unreachable;
    try testing.expectEqualStrings("hello", src[o.nodes.items[idx].sel..][0..5]);
}

test "outline: c tree gives functions and structs, not locals" {
    var o = Outline.init(testing.allocator);
    defer o.deinit();
    var doc = try buildTree(
        \\struct Point { int x; int y; };
        \\
        \\int add(int a, int b) {
        \\    int sum = a + b;
        \\    return sum;
        \\}
        \\
    , .c, &o);
    defer doc.deinit();

    var saw_add = false;
    var saw_sum = false;
    var saw_point = false;
    for (0..o.nodes.items.len) |i| {
        const nm = o.name(i);
        if (std.mem.eql(u8, nm, "add")) saw_add = true;
        if (std.mem.eql(u8, nm, "sum")) saw_sum = true;
        if (std.mem.eql(u8, nm, "Point")) saw_point = true;
    }
    try testing.expect(saw_add);
    try testing.expect(saw_point);
    try testing.expect(!saw_sum);
}

test "outline: markdown headings become the outline" {
    var o = Outline.init(testing.allocator);
    defer o.deinit();
    var doc = try buildTree(
        \\# Title
        \\
        \\some text
        \\
        \\## Section
        \\
    , .markdown, &o);
    defer doc.deinit();
    try testing.expect(o.nodes.items.len >= 2);
    try testing.expectEqual(Kind.heading, o.nodes.items[0].kind);
    try testing.expectEqualStrings("Title", o.name(0));
}

test "outline: a stale highlighter refuses rather than half-answering" {
    var doc = try Document.initFromBytes(testing.allocator, "pub fn a() void {}\n");
    defer doc.deinit();
    var hl = try syntax.Highlighter.init(testing.allocator, .zig);
    defer hl.deinit();
    var o = Outline.init(testing.allocator);
    defer o.deinit();
    // Never parsed: stale by definition.
    try testing.expectError(syntax.Error.Stale, fromTree(&o, &hl, &doc, .zig));
    try testing.expectEqual(Source.none, o.source);
}
