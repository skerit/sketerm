//! One document's language facts, owned by the tab that shows it: the
//! detected language, the effective indentation and where it came from,
//! the `.editorconfig` properties, and the grammar-less fallbacks for
//! brackets, folds and the quote gate.
//!
//! The view keeps ONE of these per tab and asks it instead of deciding
//! per call site; every answer derives from the language registry
//! (`languages.zig`). GTK-free, so every rule here is unit-tested.

const std = @import("std");
const Allocator = std.mem.Allocator;
const languages = @import("languages.zig");
const Lang = languages.Lang;
const Document = @import("document.zig").Document;
const tr = @import("transaction.zig");
const structure = @import("structure.zig");
const lexical = @import("lexical.zig");
const editorconfig = @import("editorconfig.zig");
const indentation = @import("indentation.zig");
const commands = @import("commands.zig");
const SelectionSet = @import("selection.zig").SelectionSet;
const vm = @import("view_model.zig");

pub const DocLang = struct {
    alloc: Allocator,
    /// Null = plain text.
    lang: ?Lang = null,
    ec: editorconfig.Props = .{},
    detected: ?indentation.Detected = null,
    override: indentation.Override = .{},
    config_spaces: bool = true,
    config_width: u16 = 4,
    indent: indentation.Settings = .{ .style = .spaces, .size = 4, .tab_width = 4, .source = .config },
    folds: lexical.FoldIndex,

    pub fn init(alloc: Allocator) DocLang {
        return .{ .alloc = alloc, .folds = lexical.FoldIndex.init(alloc) };
    }

    pub fn deinit(self: *DocLang) void {
        self.folds.deinit();
    }

    fn spec(self: *const DocLang) ?*const languages.Spec {
        const l = self.lang orelse return null;
        return l.spec();
    }

    // ---- language ------------------------------------------------------

    /// Re-detect the language from `path` and the document head.
    /// @return true when it changed.
    pub fn detectLanguage(self: *DocLang, path: ?[]const u8, doc: *const Document) bool {
        var buf: [languages.HEAD_PROBE]u8 = undefined;
        const want = languages.detect(path, headOf(doc, &buf));
        if (want == self.lang) return false;
        self.lang = want;
        self.folds.invalidate();
        self.resolveIndent();
        return true;
    }

    /// Up to `buf.len` leading bytes of `doc`.
    pub fn headOf(doc: *const Document, buf: []u8) []const u8 {
        const n = @min(buf.len, doc.rope.len());
        var it = doc.rope.iterateRange(0, n);
        var w: usize = 0;
        while (it.next()) |chunk| {
            @memcpy(buf[w .. w + chunk.len], chunk);
            w += chunk.len;
        }
        return buf[0..w];
    }

    /// The language to highlight with, when it has a grammar.
    pub fn grammarLang(self: *const DocLang) ?Lang {
        const l = self.lang orelse return null;
        return if (l.hasGrammar()) l else null;
    }

    /// LSP `languageId`, empty for none.
    pub fn lspId(self: *const DocLang) []const u8 {
        const l = self.lang orelse return "";
        return l.lspId();
    }

    // ---- indentation ---------------------------------------------------

    /// Adopt a fresh document's facts: its `.editorconfig` properties and
    /// the indentation its content already uses.
    pub fn loaded(self: *DocLang, doc: *Document, props: editorconfig.Props) void {
        self.ec = props;
        self.detected = indentation.detect(&doc.rope);
        if (props.end_of_line) |eol| switch (eol) {
            .lf => doc.line_ending = .lf,
            .crlf => doc.line_ending = .crlf,
            // A lone CR is not a style the document model can write.
            .cr => {},
        };
        self.resolveIndent();
    }

    /// Adopt the global defaults (on open and on every config reload).
    pub fn setConfig(self: *DocLang, spaces: bool, width: u16) void {
        self.config_spaces = spaces;
        self.config_width = width;
        self.resolveIndent();
    }

    /// Merge `delta` over the current override (a style command keeps
    /// an overridden width and vice versa).
    pub fn applyOverride(self: *DocLang, delta: indentation.Override) void {
        if (delta.style) |st| self.override.style = st;
        if (delta.width) |w| self.override.width = w;
        self.resolveIndent();
    }

    /// Drop the override and read the content again.
    pub fn resetIndent(self: *DocLang, doc: *const Document) void {
        self.override = .{};
        self.detected = indentation.detect(&doc.rope);
        self.resolveIndent();
    }

    fn resolveIndent(self: *DocLang) void {
        self.indent = indentation.resolve(.{
            .override = self.override,
            .tabs = if (self.lang) |l| l.spec().tabs else .none,
            .ec = self.ec,
            .detected = self.detected,
            .config_spaces = self.config_spaces,
            .config_width = self.config_width,
        });
    }

    // ---- comments ------------------------------------------------------

    /// Tokens toggle-comment uses: the line token, else the block pair
    /// wrapped around each line. Null when the language has neither.
    pub fn commentTokens(self: *const DocLang) ?commands.CommentTokens {
        const l = self.lang orelse return null;
        if (l.lineComment()) |t| return .{ .open = t };
        if (l.blockComment()) |b| return .{ .open = b.open, .close = b.close };
        return null;
    }

    // ---- structure fallbacks (no usable tree) ----------------------------

    /// The pair at `offset`: lexically, skipping strings and comments,
    /// when the language is known; the plain scanner otherwise.
    pub fn matchBracket(self: *const DocLang, doc: *const Document, offset: usize) ?structure.BracketPair {
        const s = self.spec() orelse return structure.scanMatch(&doc.rope, offset);
        return lexical.matchBracket(doc, s, offset);
    }

    /// Whether `offset` is code for the quote auto-close gate.
    pub fn isCodeAt(self: *const DocLang, doc: *const Document, offset: usize) bool {
        const s = self.spec() orelse return true;
        return lexical.classAt(doc, s, offset) == .code;
    }

    /// The bracket index when this language folds by brackets and the
    /// document is small enough to index.
    fn bracketFolds(self: *DocLang, doc: *const Document) ?*lexical.FoldIndex {
        const s = self.spec() orelse return null;
        if (s.fold != .brackets) return null;
        const ok = self.folds.ensure(doc, s) catch return null;
        return if (ok) &self.folds else null;
    }

    pub fn foldRegionAtLine(self: *DocLang, doc: *const Document, line: usize) ?structure.FoldRegion {
        if (self.bracketFolds(doc)) |idx| return idx.regionAtLine(line);
        return structure.indentRegionAt(doc, line, self.indent.tab_width);
    }

    pub fn foldRegionEnclosing(self: *DocLang, doc: *const Document, offset: usize) ?structure.FoldRegion {
        const line = doc.rope.offsetToLineCol(offset).line;
        if (self.bracketFolds(doc)) |idx| return idx.regionEnclosing(line);
        var l = line;
        while (l > 0) {
            l -= 1;
            const r = structure.indentRegionAt(doc, l, self.indent.tab_width) orelse continue;
            if (r.hides(line)) return r;
        }
        return null;
    }

    /// Regions headed in [from, to]; caller owns the slice.
    pub fn foldRegions(self: *DocLang, alloc: Allocator, doc: *const Document, from: usize, to: usize) Allocator.Error![]structure.FoldRegion {
        if (self.bracketFolds(doc)) |idx| return idx.regionsIn(alloc, from, to);
        return structure.indentRegions(alloc, doc, from, to, self.indent.tab_width);
    }

    // ---- saving ------------------------------------------------------------

    /// Apply the `.editorconfig` save-time properties to `doc` as ONE
    /// undoable transaction: trailing whitespace, the final newline and
    /// the UTF-8 BOM. @return true when the document changed.
    pub fn applySaveRules(self: *const DocLang, doc: *Document, sels: *SelectionSet) !bool {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var tx = tr.Transaction.init(doc.revision);
        defer tx.deinit(self.alloc);
        const n = doc.rope.len();
        const bom = "\xEF\xBB\xBF";
        var head: [3]u8 = undefined;
        const has_bom = std.mem.eql(u8, headOf(doc, &head), bom);
        if (self.ec.charset) |cs| switch (cs) {
            .utf_8_bom => if (!has_bom and n > 0) try tx.addInsert(self.alloc, 0, bom),
            .utf_8 => if (has_bom) try tx.addDelete(self.alloc, 0, 3),
            // The editor reads and writes UTF-8 only.
            .latin1, .utf_16be, .utf_16le => {},
        };
        if (self.ec.trim_trailing_whitespace == true) try commands.appendTrimEdits(self.alloc, a, doc, &tx);
        if (self.ec.insert_final_newline) |want| {
            // Trailing newlines, counted back from the end.
            var nl: usize = 0;
            while (nl < n) : (nl += 1) {
                const b = structure.byteAt(&doc.rope, n - 1 - nl) orelse break;
                if (b != '\n') break;
            }
            if (want and nl == 0 and n > 0) {
                try tx.addInsert(self.alloc, n, "\n");
            } else if (!want and nl > 0) {
                try tx.addDelete(self.alloc, n - nl, nl);
            }
        }
        if (tx.edits.items.len == 0) return false;
        _ = try doc.applyTransactionSel(&tx, vm.snapshotOf(sels));
        // `.other`: the user did not type these, so a caret at the end
        // stays before an added final newline.
        sels.mapThrough(tx.edits.items, .other);
        return true;
    }
};

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

fn docOf(text: []const u8) !Document {
    return Document.initFromBytes(testing.allocator, text);
}

test "doclang: language follows path and head, indentation follows the layers" {
    var doc = try docOf("all:\n\techo hi\n");
    defer doc.deinit();
    var dl = DocLang.init(testing.allocator);
    defer dl.deinit();
    dl.setConfig(true, 4);
    try testing.expect(dl.detectLanguage("/p/Makefile", &doc));
    try testing.expectEqual(Lang.make, dl.lang.?);
    dl.loaded(&doc, .{});
    // Make requires tabs whatever the content or config says.
    try testing.expectEqual(indentation.Style.tabs, dl.indent.style);
    try testing.expectEqual(indentation.Source.language, dl.indent.source);
    // The override still wins.
    dl.applyOverride(.{ .style = .spaces });
    dl.applyOverride(.{ .width = 2 });
    try testing.expectEqual(@as(u16, 2), dl.indent.size);
    try testing.expectEqual(indentation.Style.spaces, dl.indent.style);
    dl.resetIndent(&doc);
    try testing.expectEqual(indentation.Style.tabs, dl.indent.style);
    // A shebang settles an extensionless script.
    var sh = try docOf("#!/usr/bin/env python3\nprint(1)\n");
    defer sh.deinit();
    try testing.expect(dl.detectLanguage("/p/tool", &sh));
    try testing.expectEqual(Lang.python, dl.lang.?);
    try testing.expectEqualStrings("python", dl.lspId());
    try testing.expectEqualStrings("#", dl.commentTokens().?.open);
}

test "doclang: .editorconfig beats content and sets the line ending" {
    var doc = try docOf("def f():\n  return 1\n");
    defer doc.deinit();
    var dl = DocLang.init(testing.allocator);
    defer dl.deinit();
    dl.setConfig(true, 8);
    _ = dl.detectLanguage("/p/a.py", &doc);
    dl.loaded(&doc, .{});
    try testing.expectEqual(@as(u16, 2), dl.indent.size);
    try testing.expectEqual(indentation.Source.detected, dl.indent.source);
    dl.loaded(&doc, .{ .indent_style = .space, .indent_size = .{ .cols = 4 }, .tab_width = 4, .end_of_line = .crlf });
    try testing.expectEqual(@as(u16, 4), dl.indent.size);
    try testing.expectEqual(indentation.Source.editorconfig, dl.indent.source);
    try testing.expectEqual(@import("document.zig").LineEnding.crlf, doc.line_ending);
}

test "doclang: block-only languages toggle with their block pair" {
    var dl = DocLang.init(testing.allocator);
    defer dl.deinit();
    dl.lang = .css;
    const t = dl.commentTokens().?;
    try testing.expectEqualStrings("/*", t.open);
    try testing.expectEqualStrings("*/", t.close);
    dl.lang = .json;
    try testing.expect(dl.commentTokens() == null);
    dl.lang = null;
    try testing.expect(dl.commentTokens() == null);
}

test "doclang: bracket and fold fallbacks follow the language" {
    const src = "x = {\n  s: \"}\",\n  y: 1\n}\n";
    var doc = try docOf(src);
    defer doc.deinit();
    var dl = DocLang.init(testing.allocator);
    defer dl.deinit();
    dl.lang = .javascript;
    const open = std.mem.indexOfScalar(u8, src, '{').?;
    const p = dl.matchBracket(&doc, open).?;
    try testing.expectEqual(std.mem.lastIndexOfScalar(u8, src, '}').?, p.close.start);
    try testing.expectEqual(structure.FoldRegion{ .start_line = 0, .end_line = 2 }, dl.foldRegionAtLine(&doc, 0).?);
    try testing.expect(dl.isCodeAt(&doc, 0));
    try testing.expect(!dl.isCodeAt(&doc, std.mem.indexOf(u8, src, "}\"").?));
    // Plain text still gets the old scanner and indentation folds.
    dl.lang = null;
    try testing.expect(dl.matchBracket(&doc, open) != null);
}

test "doclang: save rules trim, fix the final newline and the BOM in one step" {
    var doc = try docOf("a  \nb\t\nc");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(testing.allocator, .{ .anchor = 0, .head = 0 });
    defer sels.deinit(testing.allocator);
    var dl = DocLang.init(testing.allocator);
    defer dl.deinit();
    dl.ec = .{ .trim_trailing_whitespace = true, .insert_final_newline = true, .charset = .utf_8_bom };
    try testing.expect(try dl.applySaveRules(&doc, &sels));
    const text = try doc.textAlloc(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("\xEF\xBB\xBFa\nb\nc\n", text);
    // One undo step restores everything.
    _ = try doc.undo();
    const back = try doc.textAlloc(testing.allocator);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("a  \nb\t\nc", back);
    // Already conforming: nothing to do.
    var ok = try docOf("x\n");
    defer ok.deinit();
    dl.ec = .{ .insert_final_newline = true, .charset = .utf_8 };
    try testing.expect(!try dl.applySaveRules(&ok, &sels));
    // insert_final_newline = false strips them.
    var extra = try docOf("x\n\n");
    defer extra.deinit();
    dl.ec = .{ .insert_final_newline = false };
    try testing.expect(try dl.applySaveRules(&extra, &sels));
    const stripped = try extra.textAlloc(testing.allocator);
    defer testing.allocator.free(stripped);
    try testing.expectEqualStrings("x", stripped);
}
