//! Project-wide search: the result model, the daemon-grep prefilter and
//! the replace planner.
//!
//! ## One search engine, not two
//!
//! The daemon's `grep` job verb and the editor's own `search.zig` are
//! different engines and there is no honest way to pretend otherwise:
//! grep is a CASE-INSENSITIVE LITERAL SUBSTRING scan, line-oriented,
//! that skips binary files, caps matches per file and truncates very
//! long lines. The editor's find bar is literal-or-regex with
//! match-case and whole-word.
//!
//! So grep is used for exactly one thing: deciding WHICH FILES to read.
//! Every hit the user sees, and every byte a replace rewrites, comes
//! from running the editor's own engine over the file's real content —
//! so a project search means precisely what the same query means in the
//! open buffer. `literalSeed` extracts the literal grep can filter on;
//! when a pattern has none (`\w+`), the prefilter is skipped and the
//! caller enumerates files with the `find` verb instead, which is
//! slower and capped.
//!
//! The divergences that remain, and cannot be removed from the GUI
//! side, are the daemon's own caps: a file larger than the daemon's
//! grep limit, a file with more matches than its per-file cap, or a
//! line longer than its line buffer can hide a candidate FILE from the
//! prefilter. That is reported as a truncated result, never silently.
//!
//! ## Replace
//!
//! A replace is planned, previewed and only then applied. The plan
//! holds, per file, the rewritten content; applying it hands each file
//! to the SAME atomic-save path an ordinary Ctrl+S uses (temp file +
//! `install` with the expected mtime), so the same conflict guard
//! catches a file that changed under the preview. Undo is per file:
//! a file open in a tab is replaced through the document's transaction
//! log (one undo step), and a file that is not open is written
//! directly — reopening it and pressing undo cannot resurrect content
//! the editor never had, which is why the preview exists.
//!
//! ## Line endings
//!
//! Every offset the search engine reports is a DOCUMENT offset, and a
//! CRLF file's document is LF-normalized (`Document.initFromBytes`
//! strips the CR of every CRLF pair). Raw file bytes must therefore
//! never be indexed with one: a `\r` per preceding line of drift
//! silently shifts previews and, before this was fixed, spliced
//! replacements into the middle of words. `RawMap` translates, and is
//! the only thing allowed to turn a reported offset into an index into
//! the file's own bytes.
//!
//! Replace splices the RAW bytes at translated offsets rather than
//! rewriting a normalized copy, so a file keeps every byte it had
//! outside the matches: a CRLF file stays CRLF, and a mixed-ending
//! file is not quietly converted the way opening and saving it would.
//! The replacement text and its `$1` expansions are the exception --
//! those are document bytes, so their LFs are materialized as the
//! file's own line ending on the way in, exactly as saving the open
//! buffer would have written them.

const std = @import("std");
const doc_mod = @import("document.zig");
const Document = doc_mod.Document;
const LineEnding = doc_mod.LineEnding;
const search = @import("search.zig");
const paths = @import("../filebrowser/paths.zig");

pub const Options = search.Options;

/// Preview text kept per hit, in bytes.
pub const MAX_PREVIEW: usize = 300;
/// Hits kept per file, and in total. A project search is a navigation
/// aid; past these numbers the list is unusable anyway.
pub const MAX_HITS_PER_FILE: usize = 500;
pub const MAX_HITS: usize = 20_000;

pub const Hit = struct {
    /// Index into `Results.files`.
    file: u32,
    /// 0-based line and BYTE column of the match start. Both are the
    /// same in document and raw-file space (normalization only ever
    /// drops the CR that ends a line).
    line: u32,
    col: u32,
    /// DOCUMENT byte offsets, not file offsets; see the header. They
    /// differ for a CRLF file.
    start: u64,
    end: u64,
    text_off: u32,
    text_len: u32,
};

pub const FileState = enum {
    /// Candidate from the prefilter; not scanned yet.
    pending,
    /// Scanned, hits (if any) recorded.
    scanned,
    /// Could not be read or was binary. `note` says why.
    failed,
    /// Replace applied.
    replaced,
};

pub const FileRow = struct {
    spec_off: u32,
    spec_len: u32,
    first_hit: u32 = 0,
    hit_count: u32 = 0,
    state: FileState = .pending,
    note_off: u32 = 0,
    note_len: u32 = 0,
    /// Replacement content for this file, when a plan has been built.
    /// Offsets into `Results.blobs`.
    new_off: u64 = 0,
    new_len: u64 = 0,
    /// Set once a plan exists; `new_off/new_len` are meaningless
    /// without it (an empty file is a legitimate result).
    planned: bool = false,
    /// mtime the plan was computed against; the save uses it as the
    /// conflict baseline.
    expected_mtime_ns: i64 = 0,
};

pub const Results = struct {
    allocator: std.mem.Allocator,
    strings: std.ArrayList(u8) = .empty,
    /// Rewritten file contents for a replace plan. Separate from
    /// `strings` because it is large and dropped as a unit.
    blobs: std.ArrayList(u8) = .empty,
    files: std.ArrayList(FileRow) = .empty,
    hits: std.ArrayList(Hit) = .empty,

    /// The query these results answer (owned copies).
    needle: []u8 = &.{},
    replacement: []u8 = &.{},
    opts: Options = .{},
    /// Project root spec the search ran under (owned).
    root: []u8 = &.{},

    /// The daemon (or a cap here) cut the result set short.
    truncated: bool = false,
    /// Files the prefilter offered, and files actually scanned.
    candidates: usize = 0,
    scanned: usize = 0,
    /// True while the search job is running.
    running: bool = false,

    pub fn init(allocator: std.mem.Allocator) Results {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Results) void {
        self.strings.deinit(self.allocator);
        self.blobs.deinit(self.allocator);
        self.files.deinit(self.allocator);
        self.hits.deinit(self.allocator);
        self.allocator.free(self.needle);
        self.allocator.free(self.replacement);
        self.allocator.free(self.root);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn reset(self: *Results, root: []const u8, needle: []const u8, opts: Options) !void {
        self.strings.clearRetainingCapacity();
        self.blobs.clearRetainingCapacity();
        self.files.clearRetainingCapacity();
        self.hits.clearRetainingCapacity();
        self.truncated = false;
        self.candidates = 0;
        self.scanned = 0;
        self.opts = opts;
        const new_needle = try self.allocator.dupe(u8, needle);
        self.allocator.free(self.needle);
        self.needle = new_needle;
        const new_root = try self.allocator.dupe(u8, root);
        self.allocator.free(self.root);
        self.root = new_root;
    }

    pub fn setReplacement(self: *Results, text: []const u8) !void {
        const copy = try self.allocator.dupe(u8, text);
        self.allocator.free(self.replacement);
        self.replacement = copy;
    }

    fn intern(self: *Results, text: []const u8) !struct { off: u32, len: u32 } {
        const off: u32 = @intCast(self.strings.items.len);
        try self.strings.appendSlice(self.allocator, text);
        return .{ .off = off, .len = @intCast(text.len) };
    }

    /// Register a candidate file, or return the existing index. Linear,
    /// but the daemon streams candidates in directory order so the hit
    /// is almost always the last row.
    pub fn addFile(self: *Results, spec: []const u8) !u32 {
        if (self.files.items.len > 0) {
            const last = self.files.items[self.files.items.len - 1];
            if (std.mem.eql(u8, self.fileSpec(@intCast(self.files.items.len - 1)), spec)) {
                _ = last;
                return @intCast(self.files.items.len - 1);
            }
        }
        for (self.files.items, 0..) |_, i| {
            if (std.mem.eql(u8, self.fileSpec(@intCast(i)), spec)) return @intCast(i);
        }
        const s = try self.intern(spec);
        try self.files.append(self.allocator, .{ .spec_off = s.off, .spec_len = s.len });
        self.candidates += 1;
        return @intCast(self.files.items.len - 1);
    }

    pub fn fileSpec(self: *const Results, i: u32) []const u8 {
        const f = self.files.items[i];
        return self.strings.items[f.spec_off .. f.spec_off + f.spec_len];
    }

    pub fn note(self: *const Results, i: u32) []const u8 {
        const f = self.files.items[i];
        return self.strings.items[f.note_off .. f.note_off + f.note_len];
    }

    pub fn preview(self: *const Results, hit: Hit) []const u8 {
        return self.strings.items[hit.text_off .. hit.text_off + hit.text_len];
    }

    pub fn setNote(self: *Results, i: u32, text: []const u8, state: FileState) !void {
        const s = try self.intern(text);
        self.files.items[i].note_off = s.off;
        self.files.items[i].note_len = s.len;
        self.files.items[i].state = state;
    }

    pub fn planned(self: *const Results, i: u32) ?[]const u8 {
        const f = self.files.items[i];
        if (!f.planned) return null;
        return self.blobs.items[@intCast(f.new_off)..@intCast(f.new_off + f.new_len)];
    }

    pub fn setPlan(self: *Results, i: u32, content: []const u8, expected_mtime_ns: i64) !void {
        const off: u64 = self.blobs.items.len;
        try self.blobs.appendSlice(self.allocator, content);
        self.files.items[i].new_off = off;
        self.files.items[i].new_len = content.len;
        self.files.items[i].planned = true;
        self.files.items[i].expected_mtime_ns = expected_mtime_ns;
    }

    pub fn hitCount(self: *const Results) usize {
        return self.hits.items.len;
    }

    /// Files that actually contributed at least one hit.
    pub fn matchedFiles(self: *const Results) usize {
        var n: usize = 0;
        for (self.files.items) |f| {
            if (f.hit_count > 0) n += 1;
        }
        return n;
    }

    /// Scan ONE candidate's content with the editor's own engine and
    /// record its hits. `content` is the file's real bytes.
    ///
    /// Returns the number of hits recorded. A file whose content
    /// contains a NUL is treated as binary and skipped, matching what
    /// the editor refuses to open.
    pub fn scanContent(self: *Results, file: u32, content: []const u8) !usize {
        self.scanned += 1;
        if (std.mem.indexOfScalar(u8, content, 0) != null) {
            try self.setNote(file, "binary", .failed);
            return 0;
        }
        var doc = Document.initFromBytes(self.allocator, content) catch {
            try self.setNote(file, "out of memory", .failed);
            return 0;
        };
        defer doc.deinit();
        var map = RawMap.init(content, doc.line_ending);
        const matches = search.findAll(self.allocator, &doc, self.needle, self.opts) catch {
            try self.setNote(file, "bad pattern", .failed);
            return 0;
        };
        defer self.allocator.free(matches);

        self.files.items[file].first_hit = @intCast(self.hits.items.len);
        var kept: usize = 0;
        for (matches) |m| {
            if (kept >= MAX_HITS_PER_FILE or self.hits.items.len >= MAX_HITS) {
                self.truncated = true;
                break;
            }
            const lc = doc.rope.offsetToLineCol(m.start);
            const line_start = doc.rope.lineToOffset(lc.line);
            // The preview is raw file text, so the line start has to
            // be translated; `trimPreview` drops the trailing CR.
            const raw_start = map.at(line_start);
            const line_end = lineEndOf(content, raw_start);
            const text = trimPreview(content[raw_start..line_end]);
            const s = try self.intern(text);
            try self.hits.append(self.allocator, .{
                .file = file,
                .line = @intCast(lc.line),
                .col = @intCast(m.start - line_start),
                .start = m.start,
                .end = m.end,
                .text_off = s.off,
                .text_len = s.len,
            });
            kept += 1;
        }
        self.files.items[file].hit_count = @intCast(kept);
        self.files.items[file].state = .scanned;
        return kept;
    }

    /// Build the replacement content for one already-scanned file.
    /// Returns null when the file has no hits.
    pub fn planReplace(
        self: *Results,
        file: u32,
        content: []const u8,
        expected_mtime_ns: i64,
    ) !?[]const u8 {
        if (self.files.items[file].hit_count == 0) return null;
        const out = try replaceAll(
            self.allocator,
            content,
            self.needle,
            self.replacement,
            self.opts,
        );
        defer self.allocator.free(out);
        try self.setPlan(file, out, expected_mtime_ns);
        return self.planned(file);
    }
};

/// Document offset -> index into the raw file bytes, for a document
/// whose CRLF pairs were normalized away on load.
///
/// `at(off)` is the index the first `off` document bytes end at, which
/// deliberately does NOT step over a `\r` waiting to be consumed: a
/// match ending at the newline has to swallow the whole `\r\n`, or a
/// replace leaves an orphan CR behind. Allocation-free, and a cursor
/// rather than a table, so it wants non-decreasing offsets; a
/// backwards one is answered correctly by rewinding, at the cost of
/// re-walking the file.
const RawMap = struct {
    content: []const u8,
    raw: usize = 0,
    doc: usize = 0,
    /// LF documents load byte for byte, so the map is the identity.
    identity: bool,

    fn init(content: []const u8, style: LineEnding) RawMap {
        return .{ .content = content, .identity = style == .lf };
    }

    fn at(self: *RawMap, off: usize) usize {
        if (self.identity) return @min(off, self.content.len);
        if (off < self.doc) {
            self.raw = 0;
            self.doc = 0;
        }
        while (self.doc < off and self.raw < self.content.len) {
            const stripped = self.content[self.raw] == '\r' and
                self.raw + 1 < self.content.len and
                self.content[self.raw + 1] == '\n';
            self.raw += 1;
            if (!stripped) self.doc += 1;
        }
        return self.raw;
    }
};

fn lineEndOf(content: []const u8, from: usize) usize {
    const nl = std.mem.indexOfScalarPos(u8, content, @min(from, content.len), '\n') orelse content.len;
    return nl;
}

fn trimPreview(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return trimmed[0..@min(trimmed.len, MAX_PREVIEW)];
}

/// Append `text` -- document bytes, so LF-terminated lines -- to `out`
/// in `style`, the way `Document.materialize` re-applies CRLF on the
/// way out.
///
/// Inserted text is the ONE part of a raw-bytes replace that is not
/// copied from the file, so it is the one part that has to be
/// converted: without this a multi-line replacement (or a capture
/// spanning a newline) leaves lone LFs in a CRLF file, which the
/// in-editor path would never produce.
fn appendInStyle(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    style: LineEnding,
) !void {
    if (style == .lf) return out.appendSlice(alloc, text);
    try out.ensureUnusedCapacity(alloc, text.len + std.mem.count(u8, text, "\n"));
    out.items.len += Document.writeInStyle(out.unusedCapacitySlice(), text, style);
}

/// Apply every match in `content`, expanding `$1`..`$9` in regex mode
/// exactly as the find bar's Replace All does. Caller frees.
///
/// Matches are found in document space and spliced into the RAW bytes
/// at translated offsets (see the header), so every byte outside a
/// match survives verbatim and a CRLF file stays CRLF. Bytes that come
/// from the replacement rather than from the file are document bytes,
/// so they go through `appendInStyle` and pick up the file's own line
/// ending -- the same text the in-editor path would have written.
pub fn replaceAll(
    alloc: std.mem.Allocator,
    content: []const u8,
    needle: []const u8,
    replacement: []const u8,
    opts: Options,
) ![]u8 {
    var doc = try Document.initFromBytes(alloc, content);
    defer doc.deinit();
    const doc_len = doc.rope.len();
    var map = RawMap.init(content, doc.line_ending);
    const matches = try search.findAll(alloc, &doc, needle, opts);
    defer alloc.free(matches);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var re: ?search.Regex = if (opts.regex) try search.Regex.init(alloc, needle, opts) else null;
    defer if (re) |*r| r.deinit();
    // `expand` writes document bytes; the conversion to the file's own
    // line ending happens once, on the whole expansion.
    var expanded: std.ArrayList(u8) = .empty;
    defer expanded.deinit(alloc);

    var cursor: usize = 0;
    var cursor_raw: usize = 0;
    for (matches) |m| {
        if (m.start < cursor) continue;
        const start_raw = map.at(m.start);
        try out.appendSlice(alloc, content[cursor_raw..start_raw]);
        if (re) |*r| {
            if (try r.capturesAt(&doc, m.start)) |caps| {
                expanded.clearRetainingCapacity();
                try r.expand(&doc, caps, replacement, &expanded);
                try appendInStyle(alloc, &out, expanded.items, doc.line_ending);
            } else {
                try appendInStyle(alloc, &out, replacement, doc.line_ending);
            }
        } else {
            try appendInStyle(alloc, &out, replacement, doc.line_ending);
        }
        cursor = m.end;
        cursor_raw = map.at(m.end);
        // A zero-width match must still advance, or the loop stalls.
        // The one document byte stepped over can be two raw ones.
        if (m.end == m.start and cursor < doc_len) {
            cursor += 1;
            const next_raw = map.at(cursor);
            try out.appendSlice(alloc, content[cursor_raw..next_raw]);
            cursor_raw = next_raw;
        }
    }
    try out.appendSlice(alloc, content[@min(cursor_raw, content.len)..]);
    return out.toOwnedSlice(alloc);
}

/// The longest literal substring every match must contain, for the
/// daemon's case-insensitive grep prefilter. Empty = no prefilter is
/// sound and the caller must enumerate files instead.
///
/// Deliberately conservative: only literal runs at nesting depth zero
/// count (a character inside a group or a class may be optional), and
/// a run loses its last character when a `?`, `*` or `{` follows it.
/// An alternation anywhere disqualifies the whole pattern.
pub fn literalSeed(pattern: []const u8, opts: Options) []const u8 {
    if (!opts.regex) return pattern;
    if (std.mem.indexOfScalar(u8, pattern, '|') != null) return "";
    var best_start: usize = 0;
    var best_len: usize = 0;
    var run_start: usize = 0;
    var run_len: usize = 0;
    var depth: usize = 0;
    var in_class = false;
    var i: usize = 0;
    // A run is only scored when it ENDS: the character before a
    // quantifier leaves the run, so scoring as we go would keep an
    // optional byte in the seed.
    while (i < pattern.len) : (i += 1) {
        const ch = pattern[i];
        if (ch == '\\') {
            // An escape is one unit; even `\.` (a literal dot) is
            // skipped rather than decoded -- the seed only has to be
            // sound, not maximal.
            i += 1;
            endRun(run_start, run_len, &best_start, &best_len);
            run_len = 0;
            continue;
        }
        if (in_class) {
            if (ch == ']') in_class = false;
            continue;
        }
        switch (ch) {
            '[', '(', ')' => {
                if (ch == '[') in_class = true;
                if (ch == '(') depth += 1;
                if (ch == ')' and depth > 0) depth -= 1;
                endRun(run_start, run_len, &best_start, &best_len);
                run_len = 0;
            },
            '?', '*', '{' => {
                // The preceding character is optional or repeated.
                endRun(run_start, run_len -| 1, &best_start, &best_len);
                run_len = 0;
            },
            '+', '.', '^', '$' => {
                endRun(run_start, run_len, &best_start, &best_len);
                run_len = 0;
            },
            else => {
                if (depth != 0) {
                    endRun(run_start, run_len, &best_start, &best_len);
                    run_len = 0;
                    continue;
                }
                if (run_len == 0) run_start = i;
                run_len += 1;
            },
        }
    }
    endRun(run_start, run_len, &best_start, &best_len);
    return pattern[best_start .. best_start + best_len];
}

fn endRun(start: usize, len: usize, best_start: *usize, best_len: *usize) void {
    if (len > best_len.*) {
        best_len.* = len;
        best_start.* = start;
    }
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

test "psearch: literal seeds for the daemon prefilter" {
    try testing.expectEqualStrings("hello", literalSeed("hello", .{}));
    try testing.expectEqualStrings("foo", literalSeed("foo", .{ .regex = true }));
    try testing.expectEqualStrings("bar", literalSeed("^bar$", .{ .regex = true }));
    // The character before a quantifier drops out of the run.
    try testing.expectEqualStrings("abc", literalSeed("abcd?", .{ .regex = true }));
    try testing.expectEqualStrings("ing", literalSeed("s*ing", .{ .regex = true }));
    // Groups and classes contribute nothing.
    try testing.expectEqualStrings("", literalSeed("(abc)", .{ .regex = true }));
    try testing.expectEqualStrings("", literalSeed("[a-z]+", .{ .regex = true }));
    try testing.expectEqualStrings("", literalSeed("\\w+", .{ .regex = true }));
    // Alternation disqualifies everything.
    try testing.expectEqualStrings("", literalSeed("cat|dog", .{ .regex = true }));
    // The longest sound run wins.
    try testing.expectEqualStrings("_value", literalSeed("x.*_value.*y", .{ .regex = true }));
}

test "psearch: scanning content records line, column and preview" {
    var r = Results.init(testing.allocator);
    defer r.deinit();
    try r.reset("/proj", "needle", .{});
    const f = try r.addFile("/proj/a.txt");
    const content = "first\n  a needle here\nlast needle\n";
    const n = try r.scanContent(f, content);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 2), r.hitCount());
    try testing.expectEqual(@as(u32, 1), r.hits.items[0].line);
    try testing.expectEqual(@as(u32, 4), r.hits.items[0].col);
    try testing.expectEqualStrings("a needle here", r.preview(r.hits.items[0]));
    try testing.expectEqual(@as(u32, 2), r.hits.items[1].line);
    try testing.expectEqual(@as(usize, 1), r.matchedFiles());
}

test "psearch: options are honoured exactly as the find bar does" {
    var r = Results.init(testing.allocator);
    defer r.deinit();
    try r.reset("/p", "Needle", .{ .case_sensitive = true });
    const f = try r.addFile("/p/a");
    try testing.expectEqual(@as(usize, 0), try r.scanContent(f, "needle\n"));

    var w = Results.init(testing.allocator);
    defer w.deinit();
    try w.reset("/p", "cat", .{ .whole_word = true });
    const g = try w.addFile("/p/b");
    try testing.expectEqual(@as(usize, 1), try w.scanContent(g, "concat cat\n"));

    var x = Results.init(testing.allocator);
    defer x.deinit();
    try x.reset("/p", "n[e]+dle", .{ .regex = true });
    const h = try x.addFile("/p/c");
    try testing.expectEqual(@as(usize, 1), try x.scanContent(h, "a neeedle\n"));
}

test "psearch: binary candidates are refused, not scanned" {
    var r = Results.init(testing.allocator);
    defer r.deinit();
    try r.reset("/p", "x", .{});
    const f = try r.addFile("/p/bin");
    try testing.expectEqual(@as(usize, 0), try r.scanContent(f, "a\x00x"));
    try testing.expectEqual(FileState.failed, r.files.items[f].state);
    try testing.expectEqualStrings("binary", r.note(f));
}

test "psearch: files are deduplicated by spec" {
    var r = Results.init(testing.allocator);
    defer r.deinit();
    try r.reset("/p", "x", .{});
    const a = try r.addFile("/p/one");
    const b = try r.addFile("/p/two");
    const c = try r.addFile("/p/one");
    try testing.expectEqual(a, c);
    try testing.expect(a != b);
    try testing.expectEqual(@as(usize, 2), r.files.items.len);
}

test "psearch: replaceAll matches the find bar, including captures" {
    const out = try replaceAll(testing.allocator, "one two one\n", "one", "X", .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("X two X\n", out);

    const re = try replaceAll(
        testing.allocator,
        "a=1\nb=22\n",
        "([a-z])=([0-9]+)",
        "$2:$1",
        .{ .regex = true },
    );
    defer testing.allocator.free(re);
    try testing.expectEqualStrings("1:a\n22:b\n", re);
}

test "psearch: raw offsets swallow the CR that ends a line" {
    const content = "aaa\r\nfoo\r\nbbb\r\n";
    var map = RawMap.init(content, .crlf);
    // Before the newline the CR is still the next line's business...
    try testing.expectEqual(@as(usize, 3), map.at(3));
    // ...and consuming the newline consumes it.
    try testing.expectEqual(@as(usize, 5), map.at(4));
    try testing.expectEqual(@as(usize, 8), map.at(7));
    try testing.expectEqual(@as(usize, 15), map.at(12));
    // A backwards query rewinds instead of answering nonsense.
    try testing.expectEqual(@as(usize, 5), map.at(4));

    var lf = RawMap.init(content, .lf);
    try testing.expectEqual(@as(usize, 4), lf.at(4));
}

test "psearch: replaceAll keeps a CRLF file's line endings" {
    const out = try replaceAll(
        testing.allocator,
        "aaa\r\nfoo\r\nbbb\r\n",
        "foo",
        "bar",
        .{},
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("aaa\r\nbar\r\nbbb\r\n", out);

    // A match on the first line (offset 0, nothing to translate) and
    // one on the last, so the tail splice is covered too.
    const edges = try replaceAll(
        testing.allocator,
        "x\r\nmid\r\nx\r\n",
        "x",
        "yy",
        .{},
    );
    defer testing.allocator.free(edges);
    try testing.expectEqualStrings("yy\r\nmid\r\nyy\r\n", edges);
}

test "psearch: replacing across a CRLF newline takes the CR with it" {
    // The document has no CR, so `\s+` matches just "\n" -- the raw
    // splice must not leave the stripped CR behind as a stray byte.
    const out = try replaceAll(
        testing.allocator,
        "aaa\r\nfoo\r\n",
        "\\s+",
        " ",
        .{ .regex = true },
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("aaa foo ", out);
}

test "psearch: replaceAll expands captures in a CRLF file" {
    const out = try replaceAll(
        testing.allocator,
        "a=1\r\nb=22\r\n",
        "([a-z])=([0-9]+)",
        "$2:$1",
        .{ .regex = true },
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("1:a\r\n22:b\r\n", out);
}

// Inserted text is the one part of the output that is not copied from
// the file, so it is the one part that can carry the wrong line
// ending; saving the same replace from an open buffer writes CRLF.
test "psearch: a multi-line replacement into a CRLF file stays CRLF" {
    const out = try replaceAll(
        testing.allocator,
        "aaa\r\nfoo\r\nbbb\r\n",
        "foo",
        "one\ntwo",
        .{},
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("aaa\r\none\r\ntwo\r\nbbb\r\n", out);

    // An LF file is untouched by the conversion.
    const lf = try replaceAll(testing.allocator, "aaa\nfoo\n", "foo", "one\ntwo", .{});
    defer testing.allocator.free(lf);
    try testing.expectEqualStrings("aaa\none\ntwo\n", lf);
}

test "psearch: a capture spanning a newline comes back CRLF" {
    // The capture is document text, so it holds a lone LF; splicing it
    // back verbatim would leave that LF in a CRLF file.
    const out = try replaceAll(
        testing.allocator,
        "one\r\ntwo\r\ntail\r\n",
        "(one\ntwo)",
        "[$1]",
        .{ .regex = true },
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[one\r\ntwo]\r\ntail\r\n", out);
}

test "psearch: an LF file keeps every byte it had, strays included" {
    // Majority LF, so the document is loaded byte for byte and the
    // lone CRLF must survive the rewrite untouched.
    const out = try replaceAll(
        testing.allocator,
        "one\nold\r\ntwo\nold\n",
        "old",
        "new",
        .{},
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("one\nnew\r\ntwo\nnew\n", out);
}

test "psearch: CRLF previews and columns are the line's own text" {
    var r = Results.init(testing.allocator);
    defer r.deinit();
    try r.reset("/p", "needle", .{});
    const f = try r.addFile("/p/dos.txt");
    const content = "first\r\n  a needle here\r\nlast needle\r\n";
    try testing.expectEqual(@as(usize, 2), try r.scanContent(f, content));
    try testing.expectEqual(@as(u32, 1), r.hits.items[0].line);
    try testing.expectEqual(@as(u32, 4), r.hits.items[0].col);
    try testing.expectEqualStrings("a needle here", r.preview(r.hits.items[0]));
    try testing.expectEqual(@as(u32, 2), r.hits.items[1].line);
    try testing.expectEqual(@as(u32, 5), r.hits.items[1].col);
    try testing.expectEqualStrings("last needle", r.preview(r.hits.items[1]));
}

test "psearch: a zero-width match steps over a whole CRLF pair" {
    const out = try replaceAll(testing.allocator, "a\r\nb\r\n", "x*", "-", .{ .regex = true });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("-a-\r\n-b-\r\n-", out);
}

test "psearch: a CRLF plan rewrites the file, not its line endings" {
    var r = Results.init(testing.allocator);
    defer r.deinit();
    try r.reset("/p", "old", .{});
    try r.setReplacement("new");
    const f = try r.addFile("/p/dos.txt");
    const content = "old thing\r\nkeep\r\nold again\r\n";
    _ = try r.scanContent(f, content);
    const plan = (try r.planReplace(f, content, 7)).?;
    try testing.expectEqualStrings("new thing\r\nkeep\r\nnew again\r\n", plan);
}

test "psearch: a zero-width regex replacement still terminates" {
    const out = try replaceAll(testing.allocator, "ab\n", "x*", "-", .{ .regex = true });
    defer testing.allocator.free(out);
    try testing.expect(out.len > 0);
    try testing.expect(std.mem.indexOfScalar(u8, out, '-') != null);
}

test "psearch: a plan holds the rewritten content per file" {
    var r = Results.init(testing.allocator);
    defer r.deinit();
    try r.reset("/p", "old", .{});
    try r.setReplacement("new");
    const f = try r.addFile("/p/a.txt");
    const content = "old thing\nkeep\nold again\n";
    _ = try r.scanContent(f, content);
    const plan = (try r.planReplace(f, content, 12345)).?;
    try testing.expectEqualStrings("new thing\nkeep\nnew again\n", plan);
    try testing.expectEqual(@as(i64, 12345), r.files.items[f].expected_mtime_ns);
    // A file with no hits is never planned.
    const g = try r.addFile("/p/b.txt");
    _ = try r.scanContent(g, "nothing here\n");
    try testing.expect((try r.planReplace(g, "nothing here\n", 1)) == null);
    try testing.expect(r.planned(g) == null);
}

test "psearch: per-file hit cap trips the truncated flag" {
    var r = Results.init(testing.allocator);
    defer r.deinit();
    try r.reset("/p", "a", .{});
    const f = try r.addFile("/p/many");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (0..MAX_HITS_PER_FILE + 5) |_| try buf.appendSlice(testing.allocator, "a\n");
    const n = try r.scanContent(f, buf.items);
    try testing.expectEqual(MAX_HITS_PER_FILE, n);
    try testing.expect(r.truncated);
}

test "psearch: reset clears results but keeps the model usable" {
    var r = Results.init(testing.allocator);
    defer r.deinit();
    try r.reset("/p", "a", .{});
    _ = try r.addFile("/p/x");
    try r.reset("/q", "b", .{ .regex = true });
    try testing.expectEqual(@as(usize, 0), r.files.items.len);
    try testing.expectEqual(@as(usize, 0), r.hitCount());
    try testing.expectEqualStrings("b", r.needle);
    try testing.expectEqualStrings("/q", r.root);
    try testing.expect(r.opts.regex);
}

test "psearch: specs keep their host qualification" {
    var r = Results.init(testing.allocator);
    defer r.deinit();
    try r.reset("box:/srv", "x", .{});
    const f = try r.addFile("box:/srv/a.zig");
    try testing.expectEqualStrings("box:/srv/a.zig", r.fileSpec(f));
    const loc = paths.parseSpec(r.fileSpec(f));
    try testing.expectEqualStrings("box", loc.host.?);
    try testing.expectEqualStrings("/srv/a.zig", loc.path);
}
