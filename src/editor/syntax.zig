//! Incremental syntax highlighting over the editor Document, backed by
//! the vendored Tree-sitter runtime + generated grammars
//! (`vendor/tree-sitter/`, see its PROVENANCE.txt).
//!
//! GTK-free and thread-free by construction: the daemon must never link
//! any of this (build.zig compiles the C only into the GUI/test targets),
//! and CLAUDE.md forbids a GUI-side worker thread, so the only
//! concurrency concession is that the CALLER may defer `parse` behind a
//! GLib idle/timeout (editorview.zig does exactly that above
//! `SYNC_PARSE_LIMIT`).
//!
//! ## The three things worth knowing
//!
//! **The parser reads the rope directly.** `ts_parser_parse` gets a
//! `TSInput` whose read callback hands back a pointer INTO the rope's
//! leaf storage (`Rope.iterateRange`), so a 1MB document is never
//! materialized into a flat buffer to be highlighted. `reads` counts
//! those callbacks — that is the proof, and a test asserts a document
//! larger than one leaf takes several of them.
//!
//! **Edits are replayed onto the old tree BEFORE the document applies
//! them.** `noteEdits` needs the PRE-transaction text to compute
//! Tree-sitter's start/old-end points, and it walks the edit list
//! back-to-front for the same reason `Document.applyEdits` does: every
//! edit is in pre-transaction coordinates, so applying the last one
//! first keeps the earlier offsets valid.
//!
//! **Results are revision-stamped and rejected when stale.** Everything
//! that hands out kinds checks `revision == doc.revision` and returns
//! `error.Stale` otherwise — the highlighter can legitimately lag the
//! document (debounced re-parse), and painting last revision's spans
//! onto this revision's bytes is exactly the class of bug the layout
//! cache's revision key already rules out for shaping.
//!
//! Highlight kinds are a small FIXED palette (`Kind`): grammars use the
//! nvim-flavoured capture vocabulary (`@keyword.import`,
//! `@variable.member`, `@markup.heading.1`), and `kindForCapture` folds
//! those onto the palette by stripping dotted components right-to-left
//! until the table hits. Themes then map kind -> colour + face.

const std = @import("std");
const Document = @import("document.zig").Document;
const Rope = @import("rope.zig").Rope;
const tr = @import("transaction.zig");
const pattern = @import("../util/pattern.zig");

/// Plain-C header; safe for the in-process `@cImport` that GTK headers
/// crash (see CLAUDE.md — the out-of-process TranslateC step exists for
/// gtk/gdk, not for every C dependency).
const ts = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_zig() ?*const ts.TSLanguage;
extern fn tree_sitter_c() ?*const ts.TSLanguage;
extern fn tree_sitter_json() ?*const ts.TSLanguage;
extern fn tree_sitter_markdown() ?*const ts.TSLanguage;
extern fn tree_sitter_markdown_inline() ?*const ts.TSLanguage;

// ======================================================================
// Highlight palette
// ======================================================================

/// The fixed set of things a theme can colour. Deliberately small: a
/// grammar's capture vocabulary is open-ended and per-language, a theme
/// is neither.
pub const Kind = enum(u8) {
    none = 0,
    keyword,
    string,
    number,
    comment,
    function,
    type,
    constant,
    operator,
    punctuation,
    variable,
    attribute,
    property,
    namespace,
    escape,
    label,
    heading,
    link,
    emphasis,
    strong,
};

pub const KIND_COUNT: usize = @typeInfo(Kind).@"enum".fields.len;

const CaptureMap = struct { name: []const u8, kind: Kind };

/// Capture name -> kind. Looked up by exact match first, then by
/// dropping dotted suffixes (`keyword.import` -> `keyword`), so an
/// unlisted refinement inherits its parent instead of vanishing.
const capture_table = [_]CaptureMap{
    .{ .name = "comment", .kind = .comment },
    .{ .name = "string", .kind = .string },
    .{ .name = "string.escape", .kind = .escape },
    .{ .name = "string.special.key", .kind = .property },
    .{ .name = "character", .kind = .string },
    .{ .name = "escape", .kind = .escape },
    .{ .name = "number", .kind = .number },
    .{ .name = "boolean", .kind = .constant },
    .{ .name = "constant", .kind = .constant },
    .{ .name = "function", .kind = .function },
    .{ .name = "constructor", .kind = .function },
    .{ .name = "keyword", .kind = .keyword },
    .{ .name = "keyword.operator", .kind = .operator },
    .{ .name = "conditional", .kind = .keyword },
    .{ .name = "repeat", .kind = .keyword },
    .{ .name = "exception", .kind = .keyword },
    .{ .name = "include", .kind = .keyword },
    .{ .name = "preproc", .kind = .keyword },
    .{ .name = "storageclass", .kind = .keyword },
    .{ .name = "type", .kind = .type },
    .{ .name = "attribute", .kind = .attribute },
    .{ .name = "property", .kind = .property },
    .{ .name = "field", .kind = .property },
    .{ .name = "variable", .kind = .variable },
    .{ .name = "variable.builtin", .kind = .constant },
    .{ .name = "variable.member", .kind = .property },
    .{ .name = "parameter", .kind = .variable },
    .{ .name = "module", .kind = .namespace },
    .{ .name = "namespace", .kind = .namespace },
    .{ .name = "label", .kind = .label },
    .{ .name = "operator", .kind = .operator },
    .{ .name = "punctuation", .kind = .punctuation },
    .{ .name = "delimiter", .kind = .punctuation },
    .{ .name = "tag", .kind = .keyword },
    // Markup (markdown, doc comments).
    .{ .name = "markup", .kind = .none },
    .{ .name = "markup.heading", .kind = .heading },
    .{ .name = "markup.link", .kind = .link },
    .{ .name = "markup.link.url", .kind = .link },
    .{ .name = "markup.link.label", .kind = .link },
    .{ .name = "markup.raw", .kind = .string },
    .{ .name = "markup.quote", .kind = .comment },
    .{ .name = "markup.italic", .kind = .emphasis },
    .{ .name = "markup.strong", .kind = .strong },
    .{ .name = "markup.strikethrough", .kind = .comment },
    .{ .name = "markup.list", .kind = .punctuation },
    .{ .name = "text", .kind = .none },
    .{ .name = "text.title", .kind = .heading },
    .{ .name = "text.uri", .kind = .link },
    .{ .name = "text.reference", .kind = .link },
    .{ .name = "text.literal", .kind = .string },
    .{ .name = "text.emphasis", .kind = .emphasis },
    .{ .name = "text.strong", .kind = .strong },
    // Explicitly nothing: nvim uses these for spell-check regions and
    // "clear whatever an outer pattern said".
    .{ .name = "none", .kind = .none },
    .{ .name = "spell", .kind = .none },
    .{ .name = "nospell", .kind = .none },
    .{ .name = "conceal", .kind = .none },
};

/// Longest-prefix capture lookup. Null when nothing in the table
/// matches even the leading component (an unknown vocabulary).
pub fn kindForCapture(name: []const u8) ?Kind {
    var probe = name;
    while (true) {
        for (capture_table) |m| {
            if (std.mem.eql(u8, m.name, probe)) return m.kind;
        }
        const dot = std.mem.lastIndexOfScalar(u8, probe, '.') orelse return null;
        probe = probe[0..dot];
    }
}

// ======================================================================
// Language registry
// ======================================================================

pub const Lang = enum {
    zig,
    c,
    json,
    markdown,

    pub fn displayName(self: Lang) []const u8 {
        return switch (self) {
            .zig => "Zig",
            .c => "C",
            .json => "JSON",
            .markdown => "Markdown",
        };
    }
};

const ExtMap = struct { ext: []const u8, lang: Lang };

const ext_table = [_]ExtMap{
    .{ .ext = "zig", .lang = .zig },
    .{ .ext = "zon", .lang = .zig },
    .{ .ext = "c", .lang = .c },
    .{ .ext = "h", .lang = .c },
    .{ .ext = "json", .lang = .json },
    .{ .ext = "jsonc", .lang = .json },
    .{ .ext = "md", .lang = .markdown },
    .{ .ext = "markdown", .lang = .markdown },
};

/// Whole-basename matches (no extension to key on).
const name_table = [_]ExtMap{
    .{ .ext = "build.zig.zon", .lang = .zig },
    .{ .ext = ".babelrc", .lang = .json },
    .{ .ext = "README", .lang = .markdown },
};

/// Language for a path (or bare filename). Case-insensitive on the
/// extension; null means "render as plain text".
pub fn detectFromPath(path: []const u8) ?Lang {
    const base = basenameOf(path);
    if (base.len == 0) return null;
    for (name_table) |m| {
        if (std.ascii.eqlIgnoreCase(m.ext, base)) return m.lang;
    }
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    const ext = base[dot + 1 ..];
    if (ext.len == 0) return null;
    for (ext_table) |m| {
        if (std.ascii.eqlIgnoreCase(m.ext, ext)) return m.lang;
    }
    return null;
}

fn basenameOf(path: []const u8) []const u8 {
    // Not std.fs.path.basename: a host-qualified spec ("box:/etc/x")
    // and a Windows-ish path both reduce correctly here, and we must
    // not depend on the host separator.
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '/' or ch == '\\' or ch == ':') start = i + 1;
    }
    return path[start..];
}

/// Shebang fallback for extensionless scripts. Only reports languages
/// we actually have a grammar for, so most shebangs yield null.
pub fn detectFromShebang(first_line: []const u8) ?Lang {
    if (!std.mem.startsWith(u8, first_line, "#!")) return null;
    const line = std.mem.trim(u8, first_line[2..], " \t\r\n");
    // The interpreter is the last path component of the first word, or
    // of the word after `env`.
    var it = std.mem.tokenizeAny(u8, line, " \t");
    var interp: []const u8 = "";
    while (it.next()) |word| {
        const b = basenameOf(word);
        if (std.mem.eql(u8, b, "env")) continue;
        if (b.len > 0 and b[0] == '-') continue;
        interp = b;
        break;
    }
    if (interp.len == 0) return null;
    if (std.mem.eql(u8, interp, "zig")) return .zig;
    return null;
}

/// Language for a document: extension first, shebang second.
pub fn detect(path: ?[]const u8, first_line: []const u8) ?Lang {
    if (path) |p| {
        if (detectFromPath(p)) |l| return l;
    }
    return detectFromShebang(first_line);
}

// ======================================================================
// Grammar + query layers
// ======================================================================

const query_zig = @embedFile("ts_query_zig");
const query_c = @embedFile("ts_query_c");
const query_json = @embedFile("ts_query_json");
const query_markdown = @embedFile("ts_query_markdown");
const query_markdown_inline = @embedFile("ts_query_markdown_inline");

const LayerSpec = struct {
    language: *const fn () callconv(.c) ?*const ts.TSLanguage,
    query: []const u8,
};

/// A language is one or more layers, painted in order (later wins).
/// Markdown is two: the block grammar plus the inline grammar run over
/// the SAME bytes — see the limitation note on `Highlighter`.
fn layerSpecs(lang: Lang) []const LayerSpec {
    return switch (lang) {
        .zig => &[_]LayerSpec{.{ .language = tree_sitter_zig, .query = query_zig }},
        .c => &[_]LayerSpec{.{ .language = tree_sitter_c, .query = query_c }},
        .json => &[_]LayerSpec{.{ .language = tree_sitter_json, .query = query_json }},
        .markdown => &[_]LayerSpec{
            .{ .language = tree_sitter_markdown, .query = query_markdown },
            .{ .language = tree_sitter_markdown_inline, .query = query_markdown_inline },
        },
    };
}

pub const Error = error{
    /// The grammar or its highlight query failed to load — a build
    /// problem, never a document problem.
    LanguageUnavailable,
    /// The highlighter has not caught up with `doc.revision`.
    Stale,
} || std.mem.Allocator.Error;

const Layer = struct {
    parser: *ts.TSParser,
    query: *ts.TSQuery,
    tree: ?*ts.TSTree = null,
    /// Kind per capture id, resolved once at load (the query's capture
    /// list is fixed).
    capture_kinds: []Kind,
    /// Compiled predicates per pattern; empty slice = unconditional.
    preds: [][]Predicate,
    alloc: std.mem.Allocator,

    fn deinit(self: *Layer) void {
        if (self.tree) |t| ts.ts_tree_delete(t);
        ts.ts_query_delete(self.query);
        ts.ts_parser_delete(self.parser);
        self.alloc.free(self.capture_kinds);
        for (self.preds) |p| {
            for (p) |*pp| pp.deinit(self.alloc);
            self.alloc.free(p);
        }
        self.alloc.free(self.preds);
    }
};

// ---- predicates -------------------------------------------------------

const PredKind = enum { eq, not_eq, any_of, not_any_of, match, not_match, ignored };

/// One `(#eq? @cap "x")`-style constraint. Only the predicates the
/// vendored queries actually use are honoured; anything else (`#set!`,
/// `#is?`) is `.ignored` — a predicate we cannot evaluate must never
/// silently drop the pattern.
const Predicate = struct {
    kind: PredKind,
    /// Capture id the predicate constrains.
    capture: u32,
    /// Literal arguments (owned).
    args: [][]u8,
    /// Compiled matcher for `.match` / `.not_match` (arena-backed).
    matcher: ?pattern.Matcher = null,
    arena: ?*std.heap.ArenaAllocator = null,

    fn deinit(self: *Predicate, alloc: std.mem.Allocator) void {
        for (self.args) |a| alloc.free(a);
        alloc.free(self.args);
        if (self.arena) |ar| {
            ar.deinit();
            alloc.destroy(ar);
        }
    }
};

/// Rewrites the shorthands `pattern.zig` does not know about into plain
/// classes so ONE matcher serves both the regex (`#match?`) and Lua
/// (`#lua-match?`) flavours the grammars use. Both flavours only appear
/// here with anchors, literal classes and `*`/`+`, which the two
/// languages spell identically.
fn normalizePattern(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < src.len) {
        const ch = src[i];
        if ((ch == '\\' or ch == '%') and i + 1 < src.len) {
            const n = src[i + 1];
            const expand: ?[]const u8 = switch (n) {
                'd' => "0-9",
                'w' => "a-zA-Z0-9_",
                's' => " \\t\\r\\n",
                'a' => "a-zA-Z",
                'l' => "a-z",
                'u' => "A-Z",
                'x' => "0-9a-fA-F",
                else => null,
            };
            if (expand) |e| {
                // Outside a class the shorthand still means "one of";
                // wrap it so `%d+` stays valid.
                const in_class = inClassAt(src, i);
                if (!in_class) try out.append(alloc, '[');
                try out.appendSlice(alloc, e);
                if (!in_class) try out.append(alloc, ']');
                i += 2;
                continue;
            }
            // %. / \. — keep the escaped char, drop the escape.
            try out.append(alloc, n);
            i += 2;
            continue;
        }
        try out.append(alloc, ch);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// True when byte `i` of `src` sits inside an unclosed `[...]`.
fn inClassAt(src: []const u8, i: usize) bool {
    var open = false;
    var k: usize = 0;
    while (k < i) : (k += 1) {
        if (src[k] == '[') open = true else if (src[k] == ']') open = false;
    }
    return open;
}

fn predKindFromName(name: []const u8) PredKind {
    if (std.mem.eql(u8, name, "eq?")) return .eq;
    if (std.mem.eql(u8, name, "not-eq?")) return .not_eq;
    if (std.mem.eql(u8, name, "any-of?")) return .any_of;
    if (std.mem.eql(u8, name, "not-any-of?")) return .not_any_of;
    if (std.mem.eql(u8, name, "match?")) return .match;
    if (std.mem.eql(u8, name, "not-match?")) return .not_match;
    if (std.mem.eql(u8, name, "lua-match?")) return .match;
    if (std.mem.eql(u8, name, "not-lua-match?")) return .not_match;
    return .ignored;
}

// ======================================================================
// Highlighter
// ======================================================================

pub const Span = struct {
    start: u32,
    end: u32,
    kind: Kind,
};

/// Window of the document the kind cache currently covers. Several
/// viewports wide so ordinary scrolling stays inside it, but no wider:
/// the query cost is linear in the window, and it is paid in ONE frame
/// (the first line that falls outside) rather than amortized. 16KB
/// measures at ~2ms on dense source; 64KB was ~16ms, i.e. a visible
/// hitch per scroll jump.
const WINDOW_BYTES: usize = 16 * 1024;

/// Cap on a single captured node's text used for predicate tests —
/// every predicate in the vendored queries constrains an identifier.
const PRED_TEXT_MAX: usize = 512;

pub const Highlighter = struct {
    alloc: std.mem.Allocator,
    lang: Lang,
    layers: []Layer,

    /// Document revision the trees were parsed from. Meaningless while
    /// `parsed` is false.
    revision: u64 = 0,
    parsed: bool = false,
    /// Bumped on every successful parse — the cache-invalidation key
    /// for anything that CACHED a highlight result at a revision the
    /// highlighter had not yet caught up with (editor_layout's per-line
    /// cache does exactly that).
    gen: u64 = 1,
    /// True when edits landed since the last parse (the debounce flag
    /// the GUI polls).
    dirty: bool = true,
    /// TSInput read callbacks of the last parse — the zero-copy proof.
    reads: usize = 0,

    // Window cache.
    win_kinds: std.ArrayList(u8) = .empty,
    win_start: usize = 0,
    win_end: usize = 0,
    win_gen: u64 = 0,
    win_valid: bool = false,

    pub fn init(alloc: std.mem.Allocator, lang: Lang) Error!Highlighter {
        const specs = layerSpecs(lang);
        var layers = try alloc.alloc(Layer, specs.len);
        var built: usize = 0;
        errdefer {
            for (layers[0..built]) |*l| l.deinit();
            alloc.free(layers);
        }
        for (specs, 0..) |spec, i| {
            layers[i] = try buildLayer(alloc, spec);
            built = i + 1;
        }
        return .{ .alloc = alloc, .lang = lang, .layers = layers };
    }

    pub fn deinit(self: *Highlighter) void {
        for (self.layers) |*l| l.deinit();
        self.alloc.free(self.layers);
        self.win_kinds.deinit(self.alloc);
    }

    fn buildLayer(alloc: std.mem.Allocator, spec: LayerSpec) Error!Layer {
        const language = spec.language() orelse return Error.LanguageUnavailable;
        const parser = ts.ts_parser_new() orelse return Error.LanguageUnavailable;
        errdefer ts.ts_parser_delete(parser);
        if (!ts.ts_parser_set_language(parser, language)) return Error.LanguageUnavailable;

        var err_off: u32 = 0;
        var err_type: ts.TSQueryError = ts.TSQueryErrorNone;
        const query = ts.ts_query_new(
            language,
            spec.query.ptr,
            @intCast(spec.query.len),
            &err_off,
            &err_type,
        ) orelse return Error.LanguageUnavailable;
        errdefer ts.ts_query_delete(query);

        const n_caps = ts.ts_query_capture_count(query);
        const capture_kinds = try alloc.alloc(Kind, n_caps);
        errdefer alloc.free(capture_kinds);
        for (0..n_caps) |ci| {
            var len: u32 = 0;
            const name_ptr = ts.ts_query_capture_name_for_id(query, @intCast(ci), &len);
            const name = if (name_ptr) |p| p[0..len] else "";
            capture_kinds[ci] = kindForCapture(name) orelse .none;
        }

        const n_pat = ts.ts_query_pattern_count(query);
        const preds = try alloc.alloc([]Predicate, n_pat);
        var pat_built: usize = 0;
        errdefer {
            for (preds[0..pat_built]) |p| {
                for (p) |*pp| pp.deinit(alloc);
                alloc.free(p);
            }
            alloc.free(preds);
        }
        for (0..n_pat) |pi| {
            preds[pi] = try compilePredicates(alloc, query, @intCast(pi));
            pat_built = pi + 1;
        }

        return .{
            .parser = parser,
            .query = query,
            .capture_kinds = capture_kinds,
            .preds = preds,
            .alloc = alloc,
        };
    }

    fn compilePredicates(
        alloc: std.mem.Allocator,
        query: *ts.TSQuery,
        pattern_index: u32,
    ) Error![]Predicate {
        var count: u32 = 0;
        const steps_ptr = ts.ts_query_predicates_for_pattern(query, pattern_index, &count);
        var out: std.ArrayList(Predicate) = .empty;
        errdefer {
            for (out.items) |*p| p.deinit(alloc);
            out.deinit(alloc);
        }
        if (count == 0 or steps_ptr == null) return out.toOwnedSlice(alloc);
        const steps = steps_ptr[0..count];

        var i: usize = 0;
        while (i < steps.len) {
            // One predicate runs up to the Done sentinel.
            var j = i;
            while (j < steps.len and steps[j].type != ts.TSQueryPredicateStepTypeDone) j += 1;
            const group = steps[i..j];
            i = j + 1;
            if (group.len == 0) continue;
            if (group[0].type != ts.TSQueryPredicateStepTypeString) continue;

            const name = queryString(query, group[0].value_id);
            const kind = predKindFromName(name);
            if (kind == .ignored) continue;
            if (group.len < 2 or group[1].type != ts.TSQueryPredicateStepTypeCapture) continue;

            var args: std.ArrayList([]u8) = .empty;
            errdefer {
                for (args.items) |a| alloc.free(a);
                args.deinit(alloc);
            }
            for (group[2..]) |st| {
                const s = if (st.type == ts.TSQueryPredicateStepTypeString)
                    queryString(query, st.value_id)
                else
                    captureName(query, st.value_id);
                try args.append(alloc, try alloc.dupe(u8, s));
            }

            var pred = Predicate{
                .kind = kind,
                .capture = group[1].value_id,
                .args = try args.toOwnedSlice(alloc),
            };
            errdefer pred.deinit(alloc);
            if ((kind == .match or kind == .not_match) and pred.args.len > 0) {
                const arena = try alloc.create(std.heap.ArenaAllocator);
                arena.* = std.heap.ArenaAllocator.init(alloc);
                const aa = arena.allocator();
                const norm = normalizePattern(aa, pred.args[0]) catch {
                    arena.deinit();
                    alloc.destroy(arena);
                    pred.kind = .ignored;
                    try out.append(alloc, pred);
                    continue;
                };
                if (pattern.compile(aa, norm, false)) |m| {
                    pred.matcher = m;
                    pred.arena = arena;
                } else |_| {
                    arena.deinit();
                    alloc.destroy(arena);
                    pred.kind = .ignored;
                }
            }
            try out.append(alloc, pred);
        }
        return out.toOwnedSlice(alloc);
    }

    fn queryString(query: *ts.TSQuery, id: u32) []const u8 {
        var len: u32 = 0;
        const p = ts.ts_query_string_value_for_id(query, id, &len) orelse return "";
        return p[0..len];
    }

    fn captureName(query: *ts.TSQuery, id: u32) []const u8 {
        var len: u32 = 0;
        const p = ts.ts_query_capture_name_for_id(query, id, &len) orelse return "";
        return p[0..len];
    }

    // ---- parsing ------------------------------------------------------

    /// Drop every tree — a wholesale document replacement (file reload,
    /// language change) has no incremental relationship to the old one.
    pub fn reset(self: *Highlighter) void {
        for (self.layers) |*l| {
            if (l.tree) |t| ts.ts_tree_delete(t);
            l.tree = null;
            ts.ts_parser_reset(l.parser);
        }
        self.parsed = false;
        self.dirty = true;
        self.win_valid = false;
    }

    const ReadState = struct {
        rope: *const Rope,
        reads: usize = 0,
    };

    fn tsRead(
        payload: ?*anyopaque,
        byte_index: u32,
        _: ts.TSPoint,
        bytes_read: [*c]u32,
    ) callconv(.c) [*c]const u8 {
        const st: *ReadState = @ptrCast(@alignCast(payload.?));
        const n = st.rope.len();
        const idx: usize = byte_index;
        if (idx >= n) {
            bytes_read.* = 0;
            return null;
        }
        var it = st.rope.iterateRange(idx, n);
        const chunk = it.next() orelse {
            bytes_read.* = 0;
            return null;
        };
        st.reads += 1;
        bytes_read.* = @intCast(chunk.len);
        // Points INTO the rope leaf: valid until the next mutation, and
        // the rope cannot be mutated while ts_parser_parse runs.
        return chunk.ptr;
    }

    /// Replay `edits` (pre-transaction coordinates, sorted) onto the old
    /// trees. Call BEFORE `doc.applyTransaction` — `doc` must still be
    /// the pre-edit text.
    pub fn noteEdits(self: *Highlighter, doc: *const Document, edits: []const tr.Edit) void {
        self.dirty = true;
        self.win_valid = false;
        if (!self.parsed) return;
        // Back-to-front, exactly like Document.applyEdits: each edit is
        // in pre-transaction coordinates, so applying the LAST one first
        // keeps every earlier offset valid against the tree.
        var i = edits.len;
        while (i > 0) {
            i -= 1;
            const e = edits[i];
            const start_pt = pointAt(&doc.rope, e.offset);
            const old_end_pt = pointAt(&doc.rope, e.offset + e.deleted_len);
            const new_end_pt = advancePoint(start_pt, e.inserted);
            const edit = ts.TSInputEdit{
                .start_byte = @intCast(e.offset),
                .old_end_byte = @intCast(e.offset + e.deleted_len),
                .new_end_byte = @intCast(e.offset + e.inserted.len),
                .start_point = start_pt,
                .old_end_point = old_end_pt,
                .new_end_point = new_end_pt,
            };
            for (self.layers) |*l| {
                if (l.tree) |t| ts.ts_tree_edit(t, &edit);
            }
        }
    }

    /// Wire this highlighter into `doc` so EVERY mutation path — typing,
    /// paste, replace-all, undo, redo — replays onto the trees without
    /// each call site remembering to. Clears when the document is
    /// replaced wholesale, so re-attach after a reload.
    pub fn attach(self: *Highlighter, doc: *Document) void {
        doc.observer = .{ .ctx = self, .before_apply = observeEdits };
    }

    fn observeEdits(ctx: *anyopaque, doc: *const Document, edits: []const tr.Edit) void {
        const self: *Highlighter = @ptrCast(@alignCast(ctx));
        self.noteEdits(doc, edits);
    }

    /// (Re-)parse `doc`. Incremental when a previous tree survived
    /// `noteEdits`; a full parse otherwise. Cheap to call when already
    /// current — it returns immediately.
    pub fn parse(self: *Highlighter, doc: *const Document) Error!void {
        if (self.parsed and !self.dirty and self.revision == doc.revision) return;
        var st = ReadState{ .rope = &doc.rope };
        const input = ts.TSInput{
            .payload = &st,
            .read = tsRead,
            .encoding = ts.TSInputEncodingUTF8,
            .decode = null,
        };
        for (self.layers) |*l| {
            const new_tree = ts.ts_parser_parse(l.parser, l.tree, input);
            if (new_tree) |nt| {
                if (l.tree) |old| ts.ts_tree_delete(old);
                l.tree = nt;
            }
        }
        self.reads = st.reads;
        self.revision = doc.revision;
        self.parsed = true;
        self.dirty = false;
        self.gen += 1;
        self.win_valid = false;
    }

    /// True when the trees do not describe `doc` as it stands.
    pub fn isStale(self: *const Highlighter, doc: *const Document) bool {
        return !self.parsed or self.dirty or self.revision != doc.revision;
    }

    // ---- kinds --------------------------------------------------------

    /// Kind byte per document byte of [start, end). `out.len` must be
    /// `end - start`. `error.Stale` when the highlighter lags `doc` —
    /// the caller renders unhighlighted rather than mispainted.
    pub fn fillKinds(
        self: *Highlighter,
        doc: *const Document,
        start: usize,
        end: usize,
        out: []u8,
    ) Error!void {
        std.debug.assert(out.len == end - start);
        if (self.isStale(doc)) return Error.Stale;
        if (out.len == 0) return;
        if (!self.win_valid or start < self.win_start or end > self.win_end)
            try self.rebuildWindow(doc, start, end);
        const off = start - self.win_start;
        @memcpy(out, self.win_kinds.items[off .. off + out.len]);
    }

    fn rebuildWindow(self: *Highlighter, doc: *const Document, start: usize, end: usize) Error!void {
        const n = doc.rope.len();
        const ws = start;
        const we = @min(n, @max(end, start + WINDOW_BYTES));
        self.win_kinds.clearRetainingCapacity();
        try self.win_kinds.appendNTimes(self.alloc, 0, we - ws);
        self.win_start = ws;
        self.win_end = we;
        self.win_gen = self.gen;
        self.win_valid = true;
        for (self.layers) |*l| try self.paintLayer(doc, l, ws, we);
    }

    /// Paint one layer's captures over [ws, we). Painting order is
    /// (start asc, end desc, pattern index asc), so the LAST thing
    /// written — and therefore the winner — is the innermost node, and
    /// among equal ranges the pattern declared LATEST.
    ///
    /// That order is not arbitrary: the vendored queries are written in
    /// the nvim convention, where a later, more specific pattern
    /// refines an earlier catch-all. tree-sitter-c opens with
    /// `(identifier) @variable` and only then adds
    /// `((identifier) @constant (#match? ...))` — first-pattern-wins
    /// would make the second line dead code.
    ///
    /// Painting into a flat byte array (rather than merging span lists)
    /// is fine because a window is a few tens of KB.
    fn paintLayer(
        self: *Highlighter,
        doc: *const Document,
        layer: *Layer,
        ws: usize,
        we: usize,
    ) Error!void {
        const tree = layer.tree orelse return;
        const cursor = ts.ts_query_cursor_new() orelse return;
        defer ts.ts_query_cursor_delete(cursor);
        _ = ts.ts_query_cursor_set_byte_range(cursor, @intCast(ws), @intCast(we));
        const root = ts.ts_tree_root_node(tree);
        ts.ts_query_cursor_exec(cursor, layer.query, root);

        const Item = struct {
            start: u32,
            end: u32,
            pat: u16,
            kind: Kind,
        };
        var items: std.ArrayList(Item) = .empty;
        defer items.deinit(self.alloc);

        var m: ts.TSQueryMatch = undefined;
        while (ts.ts_query_cursor_next_match(cursor, &m)) {
            const caps = if (m.capture_count == 0) &[_]ts.TSQueryCapture{} else m.captures[0..m.capture_count];
            if (!self.predicatesHold(doc, layer, m.pattern_index, caps)) continue;
            for (caps) |cap| {
                const kind = if (cap.index < layer.capture_kinds.len)
                    layer.capture_kinds[cap.index]
                else
                    .none;
                if (kind == .none) continue;
                const s = ts.ts_node_start_byte(cap.node);
                const e = ts.ts_node_end_byte(cap.node);
                if (e <= s) continue;
                try items.append(self.alloc, .{
                    .start = s,
                    .end = e,
                    .pat = @intCast(m.pattern_index),
                    .kind = kind,
                });
            }
        }

        std.mem.sort(Item, items.items, {}, struct {
            fn lt(_: void, a: Item, b: Item) bool {
                if (a.start != b.start) return a.start < b.start;
                if (a.end != b.end) return a.end > b.end;
                return a.pat < b.pat;
            }
        }.lt);

        const buf = self.win_kinds.items;
        for (items.items) |it| {
            const s = @max(@as(usize, it.start), ws);
            const e = @min(@as(usize, it.end), we);
            if (e <= s) continue;
            @memset(buf[s - ws .. e - ws], @intFromEnum(it.kind));
        }
    }

    fn predicatesHold(
        self: *Highlighter,
        doc: *const Document,
        layer: *Layer,
        pattern_index: u32,
        caps: []const ts.TSQueryCapture,
    ) bool {
        if (pattern_index >= layer.preds.len) return true;
        const preds = layer.preds[pattern_index];
        if (preds.len == 0) return true;
        var buf: [PRED_TEXT_MAX]u8 = undefined;
        for (preds) |p| {
            if (p.kind == .ignored) continue;
            const node = nodeForCapture(caps, p.capture) orelse continue;
            const s = ts.ts_node_start_byte(node);
            const e = ts.ts_node_end_byte(node);
            const text = readText(&doc.rope, s, e, &buf);
            const ok = switch (p.kind) {
                .eq => p.args.len > 0 and std.mem.eql(u8, text, p.args[0]),
                .not_eq => p.args.len > 0 and !std.mem.eql(u8, text, p.args[0]),
                .any_of => anyOf(p.args, text),
                .not_any_of => !anyOf(p.args, text),
                .match => p.matcher != null and p.matcher.?.matches(text),
                .not_match => p.matcher != null and !p.matcher.?.matches(text),
                .ignored => true,
            };
            if (!ok) return false;
        }
        _ = self;
        return true;
    }

    fn anyOf(args: []const []u8, text: []const u8) bool {
        for (args) |a| {
            if (std.mem.eql(u8, a, text)) return true;
        }
        return false;
    }

    fn nodeForCapture(caps: []const ts.TSQueryCapture, id: u32) ?ts.TSNode {
        for (caps) |cap| {
            if (cap.index == id) return cap.node;
        }
        return null;
    }

    /// Spans for [start, end), coalesced and excluding `.none` — the
    /// test-facing / tooling view of `fillKinds`. Caller owns the slice.
    pub fn spansAlloc(
        self: *Highlighter,
        alloc: std.mem.Allocator,
        doc: *const Document,
        start: usize,
        end: usize,
    ) Error![]Span {
        const kinds = try alloc.alloc(u8, end - start);
        defer alloc.free(kinds);
        try self.fillKinds(doc, start, end, kinds);
        var out: std.ArrayList(Span) = .empty;
        errdefer out.deinit(alloc);
        var i: usize = 0;
        while (i < kinds.len) {
            const k = kinds[i];
            var j = i + 1;
            while (j < kinds.len and kinds[j] == k) j += 1;
            if (k != 0) {
                try out.append(alloc, .{
                    .start = @intCast(start + i),
                    .end = @intCast(start + j),
                    .kind = @enumFromInt(k),
                });
            }
            i = j;
        }
        return out.toOwnedSlice(alloc);
    }

    /// Kind at one byte (convenience for tests and hover tooling).
    pub fn kindAt(self: *Highlighter, doc: *const Document, offset: usize) Error!Kind {
        var one: [1]u8 = .{0};
        try self.fillKinds(doc, offset, offset + 1, &one);
        return @enumFromInt(one[0]);
    }
};

/// Copy [s, e) out of the rope into `buf`, truncating at its capacity.
fn readText(rope: *const Rope, s: u32, e: u32, buf: []u8) []const u8 {
    const end = @min(@as(usize, e), @as(usize, s) + buf.len);
    if (end <= s) return buf[0..0];
    var it = rope.iterateRange(s, end);
    var w: usize = 0;
    while (it.next()) |chunk| {
        @memcpy(buf[w .. w + chunk.len], chunk);
        w += chunk.len;
    }
    return buf[0..w];
}

fn pointAt(rope: *const Rope, offset: usize) ts.TSPoint {
    const lc = rope.offsetToLineCol(offset);
    return .{ .row = @intCast(lc.line), .column = @intCast(lc.col) };
}

fn advancePoint(start: ts.TSPoint, inserted: []const u8) ts.TSPoint {
    var row = start.row;
    var col = start.column;
    for (inserted) |b| {
        if (b == '\n') {
            row += 1;
            col = 0;
        } else col += 1;
    }
    return .{ .row = row, .column = col };
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

test "syntax: language detection by extension, name and shebang" {
    try testing.expectEqual(Lang.zig, detectFromPath("/home/x/src/main.zig").?);
    try testing.expectEqual(Lang.zig, detectFromPath("build.zig.zon").?);
    try testing.expectEqual(Lang.c, detectFromPath("box:/tmp/a.c").?);
    try testing.expectEqual(Lang.c, detectFromPath("stdio.H").?);
    try testing.expectEqual(Lang.json, detectFromPath("a/b/config.json").?);
    try testing.expectEqual(Lang.markdown, detectFromPath("README.md").?);
    try testing.expectEqual(Lang.markdown, detectFromPath("README").?);
    try testing.expect(detectFromPath("Makefile") == null);
    try testing.expect(detectFromPath("noext") == null);
    try testing.expect(detectFromPath("") == null);

    try testing.expectEqual(Lang.zig, detectFromShebang("#!/usr/bin/env zig run").?);
    try testing.expectEqual(Lang.zig, detectFromShebang("#!/usr/local/bin/zig").?);
    try testing.expect(detectFromShebang("#!/bin/sh") == null);
    try testing.expect(detectFromShebang("not a shebang") == null);

    // Extension wins over shebang; shebang is the fallback.
    try testing.expectEqual(Lang.c, detect("x.c", "#!/usr/bin/env zig").?);
    try testing.expectEqual(Lang.zig, detect("script", "#!/usr/bin/env zig").?);
    try testing.expect(detect(null, "plain text") == null);
}

test "syntax: capture names fold onto the fixed palette" {
    try testing.expectEqual(Kind.keyword, kindForCapture("keyword").?);
    try testing.expectEqual(Kind.keyword, kindForCapture("keyword.import").?);
    try testing.expectEqual(Kind.keyword, kindForCapture("keyword.function.weird").?);
    // A refinement with its own entry beats the parent.
    try testing.expectEqual(Kind.operator, kindForCapture("keyword.operator").?);
    try testing.expectEqual(Kind.constant, kindForCapture("variable.builtin").?);
    try testing.expectEqual(Kind.property, kindForCapture("variable.member").?);
    try testing.expectEqual(Kind.variable, kindForCapture("variable.parameter").?);
    try testing.expectEqual(Kind.heading, kindForCapture("markup.heading.1").?);
    try testing.expectEqual(Kind.escape, kindForCapture("string.escape").?);
    try testing.expectEqual(Kind.none, kindForCapture("spell").?);
    try testing.expect(kindForCapture("totally.unknown") == null);
}

test "syntax: pattern normalization expands both regex and lua classes" {
    const a = testing.allocator;
    const r = try normalizePattern(a, "^[A-Z][A-Z\\d_]*$");
    defer a.free(r);
    try testing.expectEqualStrings("^[A-Z][A-Z0-9_]*$", r);

    const l = try normalizePattern(a, "^%a%w*$");
    defer a.free(l);
    try testing.expectEqualStrings("^[a-zA-Z][a-zA-Z0-9_]*$", l);
}

fn openDoc(text: []const u8) !Document {
    return Document.initFromBytes(testing.allocator, text);
}

/// Kind of the first occurrence of `needle` in `text`.
fn kindOfFirst(hl: *Highlighter, doc: *const Document, text: []const u8, needle: []const u8) !Kind {
    const at = std.mem.indexOf(u8, text, needle) orelse return error.NeedleNotFound;
    return hl.kindAt(doc, at);
}

const ZIG_SRC =
    \\const std = @import("std");
    \\// a comment
    \\pub fn main() void {
    \\    const n: u32 = 42;
    \\    std.debug.print("hi\n", .{n});
    \\}
    \\
;

test "syntax: zig spans classify keywords, strings, numbers, comments" {
    const a = testing.allocator;
    var doc = try openDoc(ZIG_SRC);
    defer doc.deinit();
    var hl = try Highlighter.init(a, .zig);
    defer hl.deinit();
    try hl.parse(&doc);

    try testing.expectEqual(Kind.keyword, try kindOfFirst(&hl, &doc, ZIG_SRC, "const"));
    try testing.expectEqual(Kind.keyword, try kindOfFirst(&hl, &doc, ZIG_SRC, "pub"));
    try testing.expectEqual(Kind.string, try kindOfFirst(&hl, &doc, ZIG_SRC, "\"std\""));
    try testing.expectEqual(Kind.comment, try kindOfFirst(&hl, &doc, ZIG_SRC, "// a comment"));
    try testing.expectEqual(Kind.number, try kindOfFirst(&hl, &doc, ZIG_SRC, "42"));
    try testing.expectEqual(Kind.type, try kindOfFirst(&hl, &doc, ZIG_SRC, "u32"));

    // The span list is sorted, non-overlapping and never `.none`.
    const spans = try hl.spansAlloc(a, &doc, 0, doc.rope.len());
    defer a.free(spans);
    try testing.expect(spans.len > 8);
    var prev: u32 = 0;
    for (spans) |s| {
        try testing.expect(s.start >= prev);
        try testing.expect(s.end > s.start);
        try testing.expect(s.kind != .none);
        prev = s.end;
    }
}

test "syntax: c spans and the #match? constant predicate" {
    const a = testing.allocator;
    const src =
        \\#include <stdio.h>
        \\/* block */
        \\int main(void) {
        \\    int lower = MAX_THING + 7;
        \\    return 0;
        \\}
        \\
    ;
    var doc = try openDoc(src);
    defer doc.deinit();
    var hl = try Highlighter.init(a, .c);
    defer hl.deinit();
    try hl.parse(&doc);

    try testing.expectEqual(Kind.keyword, try kindOfFirst(&hl, &doc, src, "#include"));
    try testing.expectEqual(Kind.comment, try kindOfFirst(&hl, &doc, src, "/* block */"));
    try testing.expectEqual(Kind.type, try kindOfFirst(&hl, &doc, src, "int"));
    try testing.expectEqual(Kind.number, try kindOfFirst(&hl, &doc, src, "7"));
    // (#match? @constant "^[A-Z][A-Z\\d_]*$") holds for MAX_THING …
    try testing.expectEqual(Kind.constant, try kindOfFirst(&hl, &doc, src, "MAX_THING"));
    // … and must NOT fire for a lowercase identifier.
    try testing.expect((try kindOfFirst(&hl, &doc, src, "lower")) != .constant);
}

test "syntax: json spans keys, strings and numbers" {
    const a = testing.allocator;
    const src =
        \\{"name": "sketerm", "count": 7, "ok": true}
    ;
    var doc = try openDoc(src);
    defer doc.deinit();
    var hl = try Highlighter.init(a, .json);
    defer hl.deinit();
    try hl.parse(&doc);
    try testing.expectEqual(Kind.number, try kindOfFirst(&hl, &doc, src, "7"));
    try testing.expectEqual(Kind.string, try kindOfFirst(&hl, &doc, src, "\"sketerm\""));
    const spans = try hl.spansAlloc(a, &doc, 0, doc.rope.len());
    defer a.free(spans);
    try testing.expect(spans.len >= 4);
}

test "syntax: markdown block and inline layers both paint" {
    const a = testing.allocator;
    const src =
        \\# Title
        \\
        \\Some *emphasis* and `code`.
        \\
    ;
    var doc = try openDoc(src);
    defer doc.deinit();
    var hl = try Highlighter.init(a, .markdown);
    defer hl.deinit();
    try hl.parse(&doc);
    try testing.expectEqual(Kind.heading, try kindOfFirst(&hl, &doc, src, "Title"));
    // The inline layer paints over the block layer's plain paragraph.
    // The `*` itself is a delimiter capture; the word inside is the
    // emphasis run.
    try testing.expectEqual(Kind.emphasis, try kindOfFirst(&hl, &doc, src, "emphasis"));
    try testing.expectEqual(Kind.string, try kindOfFirst(&hl, &doc, src, "code`"));
}

test "syntax: incremental re-parse moves spans and rejects stale reads" {
    const a = testing.allocator;
    const src = "const a = 1;\nconst b = 2;\n";
    var doc = try openDoc(src);
    defer doc.deinit();
    var hl = try Highlighter.init(a, .zig);
    defer hl.deinit();
    try hl.parse(&doc);
    const gen0 = hl.gen;

    const before = try hl.spansAlloc(a, &doc, 0, doc.rope.len());
    defer a.free(before);
    const kw_at_13 = try hl.kindAt(&doc, 13);
    try testing.expectEqual(Kind.keyword, kw_at_13);

    // Insert a line at the top; every offset below shifts by 12.
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(a);
    try tx.addInsert(a, 0, "const z = 0;\n");
    hl.noteEdits(&doc, tx.edits.items);
    _ = try doc.applyTransaction(&tx);

    // Stale until re-parsed — never last revision's spans on this text.
    try testing.expect(hl.isStale(&doc));
    var one: [1]u8 = .{0};
    try testing.expectError(Error.Stale, hl.fillKinds(&doc, 0, 1, &one));

    try hl.parse(&doc);
    try testing.expect(hl.gen > gen0);
    try testing.expect(!hl.isStale(&doc));
    // The `const` that was at 13 is now at 26 (the insert is 13 bytes).
    try testing.expectEqual(Kind.keyword, try hl.kindAt(&doc, 26));
    const after = try hl.spansAlloc(a, &doc, 0, doc.rope.len());
    defer a.free(after);
    // Every pre-edit span reappears shifted by exactly the insert, in
    // the same order, at the tail of the new list.
    try testing.expect(after.len > before.len);
    const tail = after[after.len - before.len ..];
    for (before, tail) |b, x| {
        try testing.expectEqual(b.start + 13, x.start);
        try testing.expectEqual(b.end + 13, x.end);
        try testing.expectEqual(b.kind, x.kind);
    }
}

test "syntax: multi-edit transactions replay back-to-front" {
    const a = testing.allocator;
    var doc = try openDoc("const a = 1;\nvar b = 2;\n");
    defer doc.deinit();
    var hl = try Highlighter.init(a, .zig);
    defer hl.deinit();
    try hl.parse(&doc);

    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(a);
    try tx.addReplace(a, 0, 5, "comptime"); // const -> comptime
    try tx.addInsert(a, 13, "pub "); // before `var`
    hl.noteEdits(&doc, tx.edits.items);
    _ = try doc.applyTransaction(&tx);
    try hl.parse(&doc);

    const text = try doc.textAlloc(a);
    defer a.free(text);
    try testing.expectEqualStrings("comptime a = 1;\npub var b = 2;\n", text);
    try testing.expectEqual(Kind.keyword, try kindOfFirst(&hl, &doc, text, "comptime"));
    try testing.expectEqual(Kind.keyword, try kindOfFirst(&hl, &doc, text, "pub"));
    try testing.expectEqual(Kind.keyword, try kindOfFirst(&hl, &doc, text, "var"));
}

test "syntax: parsing reads through the rope in chunks, never materialized" {
    const a = testing.allocator;
    // Several leaves' worth (MAX_LEAF is 2048) of real Zig.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var i: usize = 0;
    while (i < 900) : (i += 1) {
        var line_buf: [80]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "const v{d}: u32 = {d}; // line {d}\n", .{ i, i, i });
        try buf.appendSlice(a, line);
    }
    var doc = try Document.initFromBytes(a, buf.items);
    defer doc.deinit();
    try testing.expect(doc.rope.len() > 8 * @import("rope.zig").MAX_LEAF);

    var hl = try Highlighter.init(a, .zig);
    defer hl.deinit();
    try hl.parse(&doc);
    // One read per leaf visited: proof the parser walked the rope's own
    // storage instead of a flattened copy.
    try testing.expect(hl.reads > 8);
    try testing.expectEqual(Kind.keyword, try hl.kindAt(&doc, 0));

    // A window far into the document highlights without re-parsing.
    const tail = doc.rope.len() - 200;
    const spans = try hl.spansAlloc(a, &doc, tail, doc.rope.len());
    defer a.free(spans);
    try testing.expect(spans.len > 0);
}

test "syntax: attach makes every mutation path incremental, undo included" {
    const a = testing.allocator;
    var doc = try openDoc("const a = 1;\n");
    defer doc.deinit();
    var hl = try Highlighter.init(a, .zig);
    defer hl.deinit();
    hl.attach(&doc);
    try hl.parse(&doc);

    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(a);
    try tx.addInsert(a, 12, "// tail");
    _ = try doc.applyTransaction(&tx); // observer fires, no explicit noteEdits
    try testing.expect(hl.isStale(&doc));
    try hl.parse(&doc);
    try testing.expectEqual(Kind.comment, try hl.kindAt(&doc, 12));

    _ = try doc.undo();
    try testing.expect(hl.isStale(&doc));
    try hl.parse(&doc);
    try testing.expectEqual(Kind.keyword, try hl.kindAt(&doc, 0));
    const spans = try hl.spansAlloc(a, &doc, 0, doc.rope.len());
    defer a.free(spans);
    for (spans) |s| try testing.expect(s.kind != .comment);
}

test "syntax: reset drops the incremental relationship" {
    const a = testing.allocator;
    var doc = try openDoc("const a = 1;\n");
    defer doc.deinit();
    var hl = try Highlighter.init(a, .zig);
    defer hl.deinit();
    try hl.parse(&doc);
    hl.reset();
    try testing.expect(hl.isStale(&doc));
    try hl.parse(&doc);
    try testing.expectEqual(Kind.keyword, try hl.kindAt(&doc, 0));
}
