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

const std = @import("std");
const Document = @import("document.zig").Document;
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
    /// 0-based line and BYTE column of the match start.
    line: u32,
    col: u32,
    /// Byte offsets in the file content.
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
            const line_end = lineEndOf(content, line_start);
            const text = trimPreview(content[line_start..line_end]);
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

fn lineEndOf(content: []const u8, from: usize) usize {
    const nl = std.mem.indexOfScalarPos(u8, content, @min(from, content.len), '\n') orelse content.len;
    return nl;
}

fn trimPreview(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return trimmed[0..@min(trimmed.len, MAX_PREVIEW)];
}

/// Apply every match in `content`, expanding `$1`..`$9` in regex mode
/// exactly as the find bar's Replace All does. Caller frees.
pub fn replaceAll(
    alloc: std.mem.Allocator,
    content: []const u8,
    needle: []const u8,
    replacement: []const u8,
    opts: Options,
) ![]u8 {
    var doc = try Document.initFromBytes(alloc, content);
    defer doc.deinit();
    const matches = try search.findAll(alloc, &doc, needle, opts);
    defer alloc.free(matches);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var re: ?search.Regex = if (opts.regex) try search.Regex.init(alloc, needle, opts) else null;
    defer if (re) |*r| r.deinit();

    var cursor: usize = 0;
    for (matches) |m| {
        if (m.start < cursor) continue;
        try out.appendSlice(alloc, content[cursor..m.start]);
        if (re) |*r| {
            if (try r.capturesAt(&doc, m.start)) |caps| {
                try r.expand(&doc, caps, replacement, &out);
            } else {
                try out.appendSlice(alloc, replacement);
            }
        } else {
            try out.appendSlice(alloc, replacement);
        }
        cursor = m.end;
        // A zero-width match must still advance, or the loop stalls.
        if (m.end == m.start and cursor < content.len) {
            try out.append(alloc, content[cursor]);
            cursor += 1;
        }
    }
    try out.appendSlice(alloc, content[@min(cursor, content.len)..]);
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
