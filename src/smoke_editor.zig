//! smoke-editor — headless render of a real editor Document through
//! the production modules: editor_font (itemization + fallback faces),
//! editor_layout (bidi + tabs + cluster map + cache), editor_pass
//! (instanced GPU pass with gutter, selections, carets).
//!
//! EGL surfaceless context, same pattern as spike-editor-text. Exits 0
//! on PASS; writes zig-out/smoke-editor.png for visual inspection.

const std = @import("std");
const c = @import("c.zig").c;
const gl = @import("render/gl.zig");
const atlas_mod = @import("render/atlas.zig");
const Atlas = atlas_mod.Atlas;
const font_mod = @import("render/editor_font.zig");
const FontBook = font_mod.FontBook;
const layout_mod = @import("render/editor_layout.zig");
const Layout = layout_mod.Layout;
const editor_pass = @import("render/editor_pass.zig");
const EditorPass = editor_pass.EditorPass;
const viewport_mod = @import("render/editor_viewport.zig");
const search = @import("editor/search.zig");
const Document = @import("editor/document.zig").Document;
const tr = @import("editor/transaction.zig");
const sel_mod = @import("editor/selection.zig");
const SelectionSet = sel_mod.SelectionSet;
const Selection = sel_mod.Selection;
const unicode = @import("editor/unicode.zig");
const syntax = @import("editor/syntax.zig");
const structure = @import("editor/structure.zig");
const theme_mod = @import("editor/theme.zig");
const journal = @import("editor/journal.zig");
const gitdiff = @import("editor/gitdiff.zig");
const outline_mod = @import("editor/outline.zig");
const project_mod = @import("editor/project.zig");
const psearch = @import("editor/psearch.zig");
const reload = @import("editor/reload.zig");
const lsp_smoke = @import("smoke_editor_lsp.zig");
const lspStage = lsp_smoke.stage;

const eglboot = @import("smoke/eglboot.zig");

const W: c_int = 880;
const H: c_int = 560;
const FONT_SIZE: u16 = 18;

const ARABIC_LINE_IDX: usize = 4;
const HEBREW_LINE_IDX: usize = 5;
const SEL_LINE_A: usize = 8;
const SEL_LINE_B: usize = 9;
const CARET_LINE: usize = 10;

const SRC_TEXT =
    "fn main() !void { // ligatures: != => -> === }\n" ++
    "\tindented with a tab, then\ttwo stops\n" ++
    "The quick brown fox jumps over the lazy dog 0123456789.\n" ++
    "Ellinika: \u{0395}\u{03bb}\u{03bb}\u{03b7}\u{03bd}\u{03b9}\u{03ba}\u{03ac} \u{03b1}\u{03b2}\u{03b3}\n" ++
    "Latin then \u{0627}\u{0644}\u{0639}\u{0631}\u{0628}\u{064a}\u{0629} then latin again\n" ++
    "Ivrit: \u{05e9}\u{05dc}\u{05d5}\u{05dd} \u{05e2}\u{05d5}\u{05dc}\u{05dd} then latin\n" ++
    "symbols: \u{1fb00}\u{1fb01}\u{1fb02} sextants + \u{2764} heart\n" ++
    "e\u{301}toile — combining marks stay one caret stop\n" ++
    "select me across lines, please\n" ++
    "and me too, second selection here\n" ++
    "carets: one | two | three\n" ++
    "last line, hit-testing maps pixels back to bytes";

/// Assert itemization split + (coverage permitting) no tofu and RTL
/// visual reversal on a mixed-direction line. Returns an exit code on
/// failure, null on pass/skip.
fn checkRtlLine(
    layout: *Layout,
    book: *FontBook,
    doc: *const Document,
    line_idx: usize,
    name: []const u8,
    probe_cp: u21,
    marker: []const u8,
) !?u8 {
    const ll = try layout.line(doc, line_idx);
    std.debug.print(
        "smoke-editor: {s} line runs={d} notdef={d} clusters={d}\n",
        .{ name, ll.n_runs, ll.n_notdef, ll.clusters.len },
    );
    if (ll.n_runs < 2) {
        std.debug.print("smoke-editor: FAIL — mixed-script {s} line itemized as one run\n", .{name});
        return 2;
    }
    if (!book.hasCoverage(probe_cp)) {
        std.debug.print(
            "smoke-editor: NOTE — no face with {s} coverage on this host; tofu assertion skipped\n",
            .{name},
        );
        return null;
    }
    if (ll.n_notdef != 0) {
        std.debug.print("smoke-editor: FAIL — tofu despite {s} coverage on this host\n", .{name});
        return 2;
    }
    // RTL visual evidence: inside the RTL byte span, some later byte
    // renders LEFT of an earlier byte.
    const span_start = std.mem.indexOf(u8, ll.text, marker).?;
    var saw_reversal = false;
    for (ll.clusters) |a_cl| {
        if (a_cl.byte_start < span_start) continue;
        for (ll.clusters) |b_cl| {
            if (b_cl.byte_start > a_cl.byte_start and b_cl.x0 < a_cl.x0) saw_reversal = true;
        }
    }
    if (!saw_reversal) {
        std.debug.print("smoke-editor: FAIL — no RTL reversal in {s} span\n", .{name});
        return 2;
    }
    std.debug.print("smoke-editor: PASS {s} itemization + rtl order\n", .{name});
    return null;
}

/// Regex search + capture-group Replace All, exactly as the find bar
/// drives them: matches from `search.findAll`, replacements expanded
/// per match, all of it in ONE transaction so a single undo reverts it.
fn regexStage(allocator: std.mem.Allocator) !?u8 {
    const SRC =
        \\const a = call(one, two);
        \\const b = call(three, four);
        \\// call(x, y) in a comment too
    ;
    var doc = try Document.initFromBytes(allocator, SRC);
    defer doc.deinit();

    var re = search.Regex.init(allocator, "call\\((\\w+), (\\w+)\\)", .{ .case_sensitive = true }) catch |e| {
        std.debug.print("smoke-editor: FAIL - regex compile: {s}\n", .{@errorName(e)});
        return 12;
    };
    defer re.deinit();
    const matches = try re.findAll(&doc);
    defer allocator.free(matches);
    if (matches.len != 3) {
        std.debug.print("smoke-editor: FAIL - regex found {d} matches, want 3\n", .{matches.len});
        return 12;
    }

    // A pattern that cannot compile must be an error, not silence.
    if (search.findAll(allocator, &doc, "(unclosed", .{ .regex = true })) |m| {
        allocator.free(m);
        std.debug.print("smoke-editor: FAIL - invalid pattern compiled\n", .{});
        return 12;
    } else |_| {}

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (matches) |m| {
        buf.clearRetainingCapacity();
        const caps = (try re.capturesAt(&doc, m.start)) orelse {
            std.debug.print("smoke-editor: FAIL - no captures at a reported match\n", .{});
            return 12;
        };
        try re.expand(&doc, caps, "call($2, $1)", &buf);
        try tx.addReplace(allocator, m.start, m.end - m.start, try arena.dupe(u8, buf.items));
    }
    const before = try doc.textAlloc(allocator);
    defer allocator.free(before);
    _ = try doc.applyTransaction(&tx);
    const after = try doc.textAlloc(allocator);
    defer allocator.free(after);
    if (std.mem.indexOf(u8, after, "call(two, one)") == null or
        std.mem.indexOf(u8, after, "call(four, three)") == null or
        std.mem.indexOf(u8, after, "call(y, x)") == null)
    {
        std.debug.print("smoke-editor: FAIL - capture-group replace produced: {s}\n", .{after});
        return 12;
    }

    // ONE undo unit: a single undo has to restore the whole document.
    _ = try doc.undo();
    const undone = try doc.textAlloc(allocator);
    defer allocator.free(undone);
    if (!std.mem.eql(u8, undone, before)) {
        std.debug.print("smoke-editor: FAIL - replace-all was not one undo step\n", .{});
        return 12;
    }
    if (doc.canUndo()) {
        std.debug.print("smoke-editor: FAIL - replace-all left extra undo history\n", .{});
        return 12;
    }
    std.debug.print("smoke-editor: PASS regex replace-all ({d} matches, one undo step)\n", .{matches.len});
    return null;
}

/// The crash-recovery journal end to end: a dirty buffer snapshots, a
/// process that dies (its lock released without a discard) is offered
/// back with caret and content intact, and a clean close leaves nothing.
fn journalStage(allocator: std.mem.Allocator) !?u8 {
    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/sketerm-smoke-journal-{d}", .{c.getpid()});
    _ = c.mkdir(dir.ptr, 0o700);
    const saved = c.getenv("XDG_STATE_HOME");
    _ = c.setenv("XDG_STATE_HOME", dir.ptr, 1);
    defer {
        if (saved) |v| {
            _ = c.setenv("XDG_STATE_HOME", v, 1);
        } else {
            _ = c.unsetenv("XDG_STATE_HOME");
        }
        var cmd: [200]u8 = undefined;
        if (std.fmt.bufPrintZ(&cmd, "rm -rf '{s}'", .{dir})) |z| {
            _ = c.system(z.ptr);
        } else |_| {}
    }

    var doc = try Document.initFromBytes(allocator, "line one\nline two\n");
    defer doc.deinit();
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(allocator);
    try tx.addInsert(allocator, 9, "UNSAVED ");
    _ = try doc.applyTransaction(&tx);

    var h = try journal.open(allocator, "/tmp/smoke-target.txt");
    var hdr = journal.Header{ .spec = "/tmp/smoke-target.txt", .cursor = 17 };
    hdr.setBaseline(.{ .known = true, .present = true, .mtime_ns = 42, .size = 18, .ino = 7, .mode = 0o644 });
    try h.writeDocument(&doc, hdr);

    // A LIVE owner is never offered.
    {
        const live = try journal.list(allocator);
        defer journal.freeEntries(allocator, live);
        if (live.len != 0) {
            std.debug.print("smoke-editor: FAIL - a live editor's record was offered ({d})\n", .{live.len});
            return 13;
        }
    }

    // Process death: the lock goes, the record stays.
    const key = try allocator.dupe(u8, h.key);
    defer allocator.free(key);
    h.release();

    const entries = try journal.list(allocator);
    defer journal.freeEntries(allocator, entries);
    if (entries.len != 1) {
        std.debug.print("smoke-editor: FAIL - crashed record not offered ({d})\n", .{entries.len});
        return 13;
    }
    var rec = try journal.read(allocator, entries[0].key);
    defer rec.deinit(allocator);
    const want = try doc.textAlloc(allocator);
    defer allocator.free(want);
    if (!std.mem.eql(u8, want, rec.content) or rec.header.cursor != 17) {
        std.debug.print("smoke-editor: FAIL - recovered content/caret differ\n", .{});
        return 13;
    }
    // The verdict against a file that moved on is SHOWN, never applied.
    var moved = rec.baseline();
    moved.ino = 9;
    if (reload.compare(rec.baseline(), moved) != .replaced) {
        std.debug.print("smoke-editor: FAIL - baseline comparison lost\n", .{});
        return 13;
    }
    // Recovering consumes the record.
    try journal.remove(allocator, entries[0].key);

    // A clean save + close leaves nothing behind.
    var h2 = try journal.open(allocator, "/tmp/smoke-target.txt");
    try h2.writeDocument(&doc, hdr);
    doc.markSaved();
    h2.discard();
    const after = try journal.list(allocator);
    defer journal.freeEntries(allocator, after);
    if (after.len != 0) {
        std.debug.print("smoke-editor: FAIL - a cleanly closed buffer left a record\n", .{});
        return 13;
    }
    std.debug.print("smoke-editor: PASS crash-recovery journal round trip\n", .{});
    return null;
}

/// Only `/repo/.git` exists, so exactly one ancestor answers.
const FakeProjectFs = struct {
    fn exists(_: ?*anyopaque, dir: []const u8, name: []const u8) bool {
        return std.mem.eql(u8, dir, "/repo") and std.mem.eql(u8, name, ".git");
    }
};

fn ns2ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

/// True when a framebuffer pixel is (within AA slack) one of the
/// theme's kind colours.
fn nearColor(px: [3]u8, want: [4]f32) bool {
    inline for (0..3) |ch| {
        const w: i32 = @intFromFloat(@round(want[ch] * 255.0));
        const d = @as(i32, px[ch]) - w;
        if (d > 10 or d < -10) return false;
    }
    return true;
}

/// Zig source with at least one token of every kind the smoke asserts.
const HL_SRC =
    \\const std = @import("std");
    \\
    \\// The quick brown fox jumps over the lazy dog.
    \\pub fn main() void {
    \\    const count: u32 = 42;
    \\    const name = "sketerm";
    \\    var total: usize = 0;
    \\    while (total < count) : (total += 1) {
    \\        std.debug.print("{s} {d}\n", .{ name, total });
    \\    }
    \\}
    \\
;

const nowNs = @import("util/clock.zig").nowNs;

pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // --- EGL surfaceless context (same pattern as smoke-cell) ---
    _ = eglboot.surfaceless(.gles3) catch |e| {
        if (e == error.NoDisplay) std.debug.print("smoke-editor: eglGetDisplay failed\n", .{});
        return 1;
    };
    std.debug.print("smoke-editor: GL_VERSION={s}\n", .{c.glGetString(c.GL_VERSION)});

    // --- Offscreen framebuffer ---
    _ = eglboot.offscreenRgba8(W, H) catch {
        std.debug.print("smoke-editor: framebuffer incomplete\n", .{});
        return 1;
    };
    c.glClearColor(0.09, 0.09, 0.12, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);

    // --- Font + document + layout + selections ---
    const font_path = atlas_mod.resolveFamilyPath(allocator, "DejaVu Sans") orelse
        atlas_mod.resolveFamilyPath(allocator, "Sans") orelse {
            std.debug.print("smoke-editor: fontconfig found no Sans font\n", .{});
            return 1;
        };
    defer allocator.free(font_path);
    std.debug.print("smoke-editor: font={s}\n", .{font_path});
    const atlas = try Atlas.init(allocator, font_path.ptr, FONT_SIZE);
    defer atlas.deinit();
    atlas.realize();
    defer atlas.releaseGL();

    var book = FontBook.init(atlas);
    var layout = Layout.init(allocator, &book);
    defer layout.deinit();

    var doc = try Document.initFromBytes(allocator, SRC_TEXT);
    defer doc.deinit();

    var sels = SelectionSet.init();
    defer sels.deinit(allocator);
    // Multi-selection: a cross-line range, a same-line range, three carets.
    const la = doc.rope.lineToOffset(SEL_LINE_A);
    const lb = doc.rope.lineToOffset(SEL_LINE_B);
    const lc = doc.rope.lineToOffset(CARET_LINE);
    try sels.add(allocator, .{ .anchor = la + 7, .head = lb + 10 });
    try sels.add(allocator, .{ .anchor = lb + 12, .head = lb + 28 });
    try sels.add(allocator, Selection.caret(lc + 8));
    try sels.add(allocator, Selection.caret(lc + 14));
    try sels.add(allocator, Selection.caret(lc + 20));

    // --- Layout all lines (cold, includes first-touch raster) ---
    const n_lines = doc.rope.lineCount();
    const t_layout0 = nowNs();
    var total_glyphs: usize = 0;
    var total_runs: usize = 0;
    {
        var li: usize = 0;
        while (li < n_lines) : (li += 1) {
            const ll = try layout.line(&doc, li);
            total_glyphs += ll.glyphs.len;
            total_runs += ll.n_runs;
        }
    }
    const t_layout1 = nowNs();
    // Warm pass: every line served from the revision-checked cache.
    const t_warm0 = nowNs();
    {
        var li: usize = 0;
        while (li < n_lines) : (li += 1) _ = try layout.line(&doc, li);
    }
    const t_warm1 = nowNs();
    std.debug.print(
        "smoke-editor: lines={d} glyphs={d} itemized_runs={d}\n",
        .{ n_lines, total_glyphs, total_runs },
    );

    // --- Itemization evidence on the mixed-direction lines ---
    if (try checkRtlLine(&layout, &book, &doc, ARABIC_LINE_IDX, "arabic", 0x0627, "\u{0627}")) |code| return code;
    if (try checkRtlLine(&layout, &book, &doc, HEBREW_LINE_IDX, "hebrew", 0x05e9, "\u{05e9}")) |code| return code;
    // When ANY probe codepoint is missing from the primary but covered
    // by another installed font, the fallback-face registry must have
    // been used during the full-document layout above.
    {
        const probes = [_]u21{ 0x0627, 0x05e9, 0x1FB00, 0x2764 };
        var expects_fallback = false;
        for (probes) |cp| {
            if (c.FT_Get_Char_Index(atlas.ft_face, cp) == 0 and book.hasCoverage(cp))
                expects_fallback = true;
        }
        if (expects_fallback) {
            if (atlas.shape_fallbacks.items.len == 0) {
                std.debug.print("smoke-editor: FAIL — fallback coverage exists but no fallback face registered\n", .{});
                return 2;
            }
            std.debug.print(
                "smoke-editor: PASS fallback faces registered={d}\n",
                .{atlas.shape_fallbacks.items.len},
            );
        } else {
            std.debug.print("smoke-editor: NOTE — primary covers every probe; fallback registry not exercised\n", .{});
        }
    }

    // --- Hit-test round trips through grapheme boundaries ---
    {
        var checked: usize = 0;
        var failed: usize = 0;
        var li: usize = 0;
        while (li < n_lines) : (li += 1) {
            const ll = try layout.line(&doc, li);
            for (ll.clusters) |cl| {
                if (cl.x1 - cl.x0 < 0.01) continue;
                if (!unicode.isGraphemeBoundary(ll.text, cl.byte_start)) {
                    failed += 1;
                    continue;
                }
                const p = Layout.byteToX(ll, cl.byte_start) orelse {
                    failed += 1;
                    continue;
                };
                const back = Layout.xToByte(ll, p.row, p.x);
                checked += 1;
                if (back != cl.byte_start) {
                    failed += 1;
                    std.debug.print(
                        "smoke-editor: round-trip MISMATCH line={d} byte={d} -> byte={d}\n",
                        .{ li, cl.byte_start, back },
                    );
                }
            }
        }
        std.debug.print("smoke-editor: hit-test round-trips checked={d} failed={d}\n", .{ checked, failed });
        if (failed != 0 or checked < 100) {
            std.debug.print("smoke-editor: FAIL — hit testing broken\n", .{});
            return 3;
        }
    }

    // --- Edit-then-relayout: revision invalidation ---
    {
        const before = try layout.line(&doc, 2);
        const w_before = before.width;
        const n_before = before.clusters.len;
        var tx = tr.Transaction.init(doc.revision);
        defer tx.deinit(allocator);
        const line2 = doc.rope.lineToOffset(2);
        try tx.addInsert(allocator, line2, "EDITED >>> ");
        _ = try doc.applyTransaction(&tx);
        const after = try layout.line(&doc, 2);
        if (after.width <= w_before or after.clusters.len <= n_before) {
            std.debug.print("smoke-editor: FAIL — relayout after edit did not pick up new text\n", .{});
            return 4;
        }
        if (!std.mem.startsWith(u8, after.text, "EDITED >>> ")) {
            std.debug.print("smoke-editor: FAIL — cached stale text after revision bump\n", .{});
            return 4;
        }
        std.debug.print(
            "smoke-editor: PASS edit-relayout (clusters {d} -> {d}, width {d:.1} -> {d:.1})\n",
            .{ n_before, after.clusters.len, w_before, after.width },
        );
    }

    // --- Wrap segmentation sanity on a separate Layout ---
    {
        var wl = Layout.init(allocator, &book);
        defer wl.deinit();
        wl.wrap_width = 220;
        const ll = try wl.line(&doc, 2);
        if (ll.rows.len < 2) {
            std.debug.print("smoke-editor: FAIL — wrap at 220px produced {d} row(s)\n", .{ll.rows.len});
            return 5;
        }
        std.debug.print("smoke-editor: PASS wrap ({d} rows at 220px)\n", .{ll.rows.len});
    }

    // --- Word wrap: UAX #14 opportunities, hanging spaces, CJK ---
    {
        var wl = Layout.init(allocator, &book);
        defer wl.deinit();
        wl.wrap_width = 200;
        var wdoc = try Document.initFromBytes(
            allocator,
            "The quick brown fox jumps over the lazy dog once more\n" ++
                "\u{65E5}\u{672C}\u{8A9E}\u{306E}\u{6587}\u{7AE0}\u{306F}\u{7A7A}\u{767D}\u{306A}\u{3057}\u{3067}\u{3082}\u{6298}\u{308A}\u{8FD4}\u{305B}\u{307E}\u{3059}\n" ++
                "trailing        \n",
        );
        defer wdoc.deinit();

        const prose = try wl.line(&wdoc, 0);
        if (prose.rows.len < 2) {
            std.debug.print("smoke-editor: FAIL — word wrap produced {d} row(s)\n", .{prose.rows.len});
            return 5;
        }
        var r: u32 = 1;
        while (r < prose.rows.len) : (r += 1) {
            const first = for (prose.clusters) |cl| {
                if (cl.row == r) break cl;
            } else unreachable;
            if (first.byte_start == 0 or prose.text[first.byte_start - 1] != ' ') {
                std.debug.print("smoke-editor: FAIL — wrapped row {d} starts mid-word (byte {d})\n", .{ r, first.byte_start });
                return 5;
            }
        }

        const cjk = try wl.line(&wdoc, 1);
        const cjk_w = cjk.clusters[0].x1 - cjk.clusters[0].x0;
        if (cjk_w > 0.5) {
            // A CJK-capable font is present: the spaceless line must
            // wrap between ideographs and fill its rows.
            if (cjk.rows.len < 2) {
                std.debug.print("smoke-editor: FAIL — CJK line never wrapped\n", .{});
                return 5;
            }
            var row0: usize = 0;
            for (cjk.clusters) |cl| {
                if (cl.row == 0) row0 += 1;
                if (cl.x1 - cjk.rows[cl.row].x0 > 200.0 + 0.01) {
                    std.debug.print("smoke-editor: FAIL — CJK cluster overflows its wrap row\n", .{});
                    return 5;
                }
            }
            if (row0 < 2) {
                std.debug.print("smoke-editor: FAIL — CJK wrapped one character per row\n", .{});
                return 5;
            }
        }

        // Trailing spaces hang: the text fits one row even though the
        // spaces run past the wrap column.
        wl.wrap_width = (try wl.line(&wdoc, 2)).clusters[7].x1 + 2.0; // just past "trailing"
        wl.invalidateAll();
        const hang = try wl.line(&wdoc, 2);
        if (hang.rows.len != 1) {
            std.debug.print("smoke-editor: FAIL — trailing spaces forced a wrap ({d} rows)\n", .{hang.rows.len});
            return 5;
        }
        std.debug.print(
            "smoke-editor: PASS word wrap (prose rows={d}, cjk rows={d}, spaces hang)\n",
            .{ prose.rows.len, cjk.rows.len },
        );
    }

    // --- Reload preserves undo history (editor/diff.zig) ---
    {
        var rdoc = try Document.initFromBytes(allocator, "alpha\nbeta\ngamma\n");
        defer rdoc.deinit();
        // A user edit BEFORE the reload must survive underneath it.
        var tx = @import("editor/transaction.zig").Transaction.init(rdoc.revision);
        defer tx.deinit(allocator);
        try tx.addInsert(allocator, 6, "user-");
        _ = try rdoc.applyTransaction(&tx);

        const changed = try @import("editor/diff.zig").reloadFromBytes(
            allocator,
            &rdoc,
            "alpha\nuser-beta\nGAMMA\ndelta\n",
            null,
        );
        if (!changed or rdoc.isDirty()) {
            std.debug.print("smoke-editor: FAIL — reload did not apply cleanly\n", .{});
            return 5;
        }
        _ = try rdoc.undo(); // back through the reload…
        {
            const txt = try rdoc.textAlloc(allocator);
            defer allocator.free(txt);
            if (!std.mem.eql(u8, txt, "alpha\nuser-beta\ngamma\n")) {
                std.debug.print("smoke-editor: FAIL — undo past reload lost text: {s}\n", .{txt});
                return 5;
            }
        }
        _ = try rdoc.undo(); // …and through the user's own edit
        {
            const txt = try rdoc.textAlloc(allocator);
            defer allocator.free(txt);
            if (!std.mem.eql(u8, txt, "alpha\nbeta\ngamma\n")) {
                std.debug.print("smoke-editor: FAIL — pre-reload history gone: {s}\n", .{txt});
                return 5;
            }
        }
        _ = try rdoc.redo();
        _ = try rdoc.redo();
        {
            const txt = try rdoc.textAlloc(allocator);
            defer allocator.free(txt);
            if (!std.mem.eql(u8, txt, "alpha\nuser-beta\nGAMMA\ndelta\n")) {
                std.debug.print("smoke-editor: FAIL — redo did not return to reloaded text\n", .{});
                return 5;
            }
        }
        std.debug.print("smoke-editor: PASS reload-with-history (undo/redo across a reload)\n", .{});
    }

    // --- Build + draw the frame ---
    var pass = EditorPass.init(allocator);
    defer pass.deinit();
    try pass.realize();
    defer pass.releaseGL();

    const colors = editor_pass.Colors{};
    const view = editor_pass.View{
        .width_px = @floatFromInt(W),
        .height_px = @floatFromInt(H),
        .highlight_current_line = true,
    };
    // Find-bar matches: highlighted through the pass's bg kind, the
    // current one emphasized.
    const matches = try search.findAll(allocator, &doc, "the", .{});
    defer allocator.free(matches);
    std.debug.print("smoke-editor: literal search \"the\" matches={d}\n", .{matches.len});
    if (matches.len < 3) {
        std.debug.print("smoke-editor: FAIL — search found too few matches\n", .{});
        return 8;
    }
    const frame = editor_pass.Frame{
        .layout = &layout,
        .doc = &doc,
        .sels = &sels,
        .colors = colors,
        .view = view,
        .matches = matches,
        .current_match = 0,
    };

    const t_build0 = nowNs();
    try pass.buildFrame(frame);
    const t_build1 = nowNs();
    const n_instances = pass.instances.items.len;

    const t_draw0 = nowNs();
    pass.draw(atlas, W, H);
    c.glFinish();
    const t_draw1 = nowNs();
    // Steady-state: second build+draw with hot caches.
    const t_draw2a = nowNs();
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    try pass.buildFrame(frame);
    pass.draw(atlas, W, H);
    c.glFinish();
    const t_draw2b = nowNs();

    // --- Read back + pixel asserts + PNG ---
    const fb_bytes: usize = @intCast(W * H * 4);
    const fb = try allocator.alloc(u8, fb_bytes);
    defer allocator.free(fb);
    c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);
    var lit: usize = 0;
    var sel_px: usize = 0;
    var caret_px: usize = 0;
    var match_px: usize = 0;
    {
        var i: usize = 0;
        while (i < fb_bytes) : (i += 4) {
            const r = fb[i];
            const g = fb[i + 1];
            const b = fb[i + 2];
            if (r > 0x40 and g > 0x40) lit += 1;
            // Selection blue (0.20,0.35,0.60 over dark bg) — blue-dominant.
            if (b > 0x60 and b > r + 0x20 and b > g + 0x18) sel_px += 1;
            // Caret red (0.95,0.35,0.25) — red-dominant, green close to blue.
            if (r > 0xB0 and r > b + 0x50 and g < 0x90 and g < b + 0x28) caret_px += 1;
            // Match amber (0.85,0.72,0.25 blended) — green clearly
            // above blue, which no other element does.
            if (r > 0x50 and g > b + 0x28 and r > b + 0x40) match_px += 1;
        }
    }
    std.debug.print(
        "smoke-editor: instances={d} lit_pixels={d} selection_pixels={d} caret_pixels={d} match_pixels={d}\n",
        .{ n_instances, lit, sel_px, caret_px, match_px },
    );
    if (match_px < 100) {
        std.debug.print("smoke-editor: FAIL — find-match highlights not rendered\n", .{});
        return 8;
    }
    if (lit < 2000) {
        std.debug.print("smoke-editor: FAIL — too few lit pixels, text not rendered\n", .{});
        return 6;
    }
    if (sel_px < 100) {
        std.debug.print("smoke-editor: FAIL — selection highlight not rendered\n", .{});
        return 6;
    }
    if (caret_px < 20) {
        std.debug.print("smoke-editor: FAIL — caret bars not rendered\n", .{});
        return 6;
    }

    const flipped = try allocator.alloc(u8, fb_bytes);
    defer allocator.free(flipped);
    const row_bytes: usize = @intCast(W * 4);
    var row: usize = 0;
    while (row < H) : (row += 1) {
        const src = fb[(@as(usize, @intCast(H)) - 1 - row) * row_bytes ..][0..row_bytes];
        const dst = flipped[row * row_bytes ..][0..row_bytes];
        @memcpy(dst, src);
        var pxi: usize = 3;
        while (pxi < row_bytes) : (pxi += 4) dst[pxi] = 255;
    }
    _ = c.mkdir("zig-out", 0o755);
    const png_path = "zig-out/smoke-editor.png";
    if (c.stbi_write_png(png_path, W, H, 4, flipped.ptr, @intCast(row_bytes)) == 0) {
        std.debug.print("smoke-editor: FAIL — could not write {s}\n", .{png_path});
        return 7;
    }
    std.debug.print("smoke-editor: wrote {s}\n", .{png_path});

    // --- Viewport anchoring on a ~200k-line document -------------------
    // The V1 renderer laid out every line from 0 to the viewport
    // bottom; jumping to the end therefore cost O(document). Assert the
    // frame is O(viewport) both with wrap off (arithmetic anchor) and
    // wrap on (estimated row index).
    {
        var big_text: std.ArrayList(u8) = .empty;
        defer big_text.deinit(allocator);
        const BIG_LINES: usize = 200_000;
        var lbuf: [96]u8 = undefined;
        var li: usize = 0;
        while (li < BIG_LINES) : (li += 1) {
            const s = try std.fmt.bufPrint(
                &lbuf,
                "line {d}: the quick brown fox jumps over the lazy dog\n",
                .{li},
            );
            try big_text.appendSlice(allocator, s);
        }
        var big = try Document.initFromBytes(allocator, big_text.items);
        defer big.deinit();
        const big_lines = big.rope.lineCount();
        std.debug.print(
            "smoke-editor: big document lines={d} bytes={d}\n",
            .{ big_lines, big_text.items.len },
        );

        var big_sels = try SelectionSet.initSingle(allocator, Selection.caret(0));
        defer big_sels.deinit(allocator);
        var rows = viewport_mod.RowIndex.init(allocator);
        defer rows.deinit();

        const line_h: f32 = @floatFromInt(atlas.cell_h);
        const viewport_rows: usize = @intFromFloat(@ceil(@as(f32, @floatFromInt(H)) / line_h));
        // Generous ceiling: the visible rows plus the partially
        // scrolled one. Anything O(document) blows past it by 4 orders.
        const budget = viewport_rows + 4;

        inline for (.{ false, true }) |wrap| {
            var blayout = Layout.init(allocator, &book);
            defer blayout.deinit();
            if (wrap) blayout.wrap_width = 300;
            rows.reset(wrap, big_lines);

            var bview = editor_pass.View{
                .width_px = @floatFromInt(W),
                .height_px = @floatFromInt(H),
            };
            // Top of the document: cheap either way.
            var t0 = nowNs();
            try pass.buildFrame(.{
                .layout = &blayout,
                .doc = &big,
                .sels = &big_sels,
                .view = bview,
                .rows = &rows,
            });
            var t1 = nowNs();
            const top_lines = pass.lines_laid_out;
            const top_ms = @as(f64, @floatFromInt(t1 - t0)) / 1e6;

            // Jump to the very end — the case that used to be O(n).
            const total_rows = rows.totalRows(big_lines);
            bview.anchor = rows.anchorAtRow(big_lines, total_rows -| viewport_rows);
            t0 = nowNs();
            try pass.buildFrame(.{
                .layout = &blayout,
                .doc = &big,
                .sels = &big_sels,
                .view = bview,
                .rows = &rows,
            });
            t1 = nowNs();
            const end_lines = pass.lines_laid_out;
            const end_ms = @as(f64, @floatFromInt(t1 - t0)) / 1e6;
            std.debug.print(
                "smoke-editor: anchored frame wrap={} top(lines={d} {d:.2}ms) end(lines={d} {d:.2}ms) budget={d}\n",
                .{ wrap, top_lines, top_ms, end_lines, end_ms, budget },
            );
            if (top_lines > budget or end_lines > budget) {
                std.debug.print("smoke-editor: FAIL — frame laid out more lines than the viewport holds\n", .{});
                return 9;
            }
            if (bview.anchor.line < big_lines / 2) {
                std.debug.print("smoke-editor: FAIL — end anchor did not reach the document tail\n", .{});
                return 9;
            }

            // The V1 cost, for the record: laying out every line above
            // the anchor is what the absolute-scroll_y renderer did on
            // this exact jump. Off by default — it takes seconds.
            if (c.getenv("SKETERM_EDITOR_BASELINE") != null) {
                blayout.invalidateAll();
                const b0 = nowNs();
                var k: usize = 0;
                while (k <= bview.anchor.line) : (k += 1) _ = try blayout.line(&big, k);
                const b1 = nowNs();
                std.debug.print(
                    "smoke-editor: BASELINE wrap={} prefix layout of {d} lines = {d:.1}ms\n",
                    .{ wrap, bview.anchor.line + 1, @as(f64, @floatFromInt(b1 - b0)) / 1e6 },
                );
                blayout.invalidateAll();
            }
        }
    }

    // --- Syntax highlighting: distinct glyph colours in the FB -------
    // The renderer must actually PAINT per-kind colours, not just carry
    // kinds around: assert the theme's keyword / string / comment /
    // number colours all appear in the framebuffer.
    {
        const th = &theme_mod.dark;
        var zdoc = try Document.initFromBytes(allocator, HL_SRC);
        defer zdoc.deinit();
        var hl = try syntax.Highlighter.init(allocator, .zig);
        defer hl.deinit();
        hl.attach(&zdoc);
        const p0 = nowNs();
        try hl.parse(&zdoc);
        const p1 = nowNs();
        const spans = try hl.spansAlloc(allocator, &zdoc, 0, zdoc.rope.len());
        defer allocator.free(spans);
        const p2 = nowNs();
        std.debug.print(
            "smoke-editor: syntax small({d} bytes) parse={d:.3}ms query={d:.3}ms spans={d} reads={d}\n",
            .{ zdoc.rope.len(), ns2ms(p1 - p0), ns2ms(p2 - p1), spans.len, hl.reads },
        );

        var zlayout = Layout.init(allocator, &book);
        defer zlayout.deinit();
        zlayout.hl = &hl;
        zlayout.theme = th;
        var zsels = try SelectionSet.initSingle(allocator, Selection.caret(0));
        defer zsels.deinit(allocator);

        c.glClearColor(th.bg[0], th.bg[1], th.bg[2], th.bg[3]);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        try pass.buildFrame(.{
            .layout = &zlayout,
            .doc = &zdoc,
            .sels = &zsels,
            .view = .{ .width_px = @floatFromInt(W), .height_px = @floatFromInt(H) },
            .colors = .{
                .text = th.fg,
                .gutter_bg = th.gutter_bg,
                .gutter_fg = th.gutter_fg,
                .caret = th.caret,
            },
            .theme = th,
        });
        pass.draw(atlas, W, H);
        c.glFinish();
        c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);

        const probes = [_]syntax.Kind{ .keyword, .string, .comment, .number, .type };
        var hits = [_]usize{0} ** probes.len;
        var distinct = std.AutoHashMap(u32, void).init(allocator);
        defer distinct.deinit();
        var i: usize = 0;
        while (i < fb_bytes) : (i += 4) {
            const px = [3]u8{ fb[i], fb[i + 1], fb[i + 2] };
            for (probes, 0..) |k, pi| {
                if (nearColor(px, th.colorOf(k))) hits[pi] += 1;
            }
            // Quantised palette of the strongly-lit pixels (glyph
            // cores; AA edges quantise onto the background).
            if (@as(u16, px[0]) + px[1] + px[2] > 0x140) {
                const q: u32 = (@as(u32, px[0] >> 4) << 8) |
                    (@as(u32, px[1] >> 4) << 4) | (px[2] >> 4);
                try distinct.put(q, {});
            }
        }
        std.debug.print(
            "smoke-editor: syntax pixels keyword={d} string={d} comment={d} number={d} type={d} distinct_colours={d}\n",
            .{ hits[0], hits[1], hits[2], hits[3], hits[4], distinct.count() },
        );
        for (probes, hits) |k, n| {
            if (n < 8) {
                std.debug.print(
                    "smoke-editor: FAIL — no {s} pixels rendered\n",
                    .{@tagName(k)},
                );
                return 10;
            }
        }
        if (distinct.count() < 4) {
            std.debug.print("smoke-editor: FAIL — highlighting produced too few distinct colours\n", .{});
            return 10;
        }

        var flipped2 = try allocator.alloc(u8, fb_bytes);
        defer allocator.free(flipped2);
        const rb: usize = @intCast(W * 4);
        var r2: usize = 0;
        while (r2 < H) : (r2 += 1) {
            const src = fb[(@as(usize, @intCast(H)) - 1 - r2) * rb ..][0..rb];
            const dst = flipped2[r2 * rb ..][0..rb];
            @memcpy(dst, src);
            var pxi: usize = 3;
            while (pxi < rb) : (pxi += 4) dst[pxi] = 255;
        }
        if (c.stbi_write_png("zig-out/smoke-editor-syntax.png", W, H, 4, flipped2.ptr, @intCast(rb)) != 0)
            std.debug.print("smoke-editor: wrote zig-out/smoke-editor-syntax.png\n", .{});

        // Typing latency: an incremental re-parse after a one-character
        // insert, which is what the editor pays per keystroke.
        {
            const tr2 = @import("editor/transaction.zig");
            var tx = tr2.Transaction.init(zdoc.revision);
            defer tx.deinit(allocator);
            try tx.addInsert(allocator, zdoc.rope.len(), "x");
            const e0 = nowNs();
            _ = try zdoc.applyTransaction(&tx);
            try hl.parse(&zdoc);
            const e1 = nowNs();
            std.debug.print(
                "smoke-editor: syntax incremental keystroke reparse={d:.3}ms\n",
                .{ns2ms(e1 - e0)},
            );
        }
    }

    // --- Structure: brackets, folding, expand-selection ---------------
    // All three read the SAME trees the highlighting does. This stage
    // proves the RENDERED result, not just the query: bracket boxes
    // must appear as pixels, and folding must make the frame lay out
    // FEWER lines while the hidden text stays out of the picture.
    {
        const th = &theme_mod.dark;
        var zdoc = try Document.initFromBytes(allocator, HL_SRC);
        defer zdoc.deinit();
        var hl = try syntax.Highlighter.init(allocator, .zig);
        defer hl.deinit();
        hl.attach(&zdoc);
        try hl.parse(&zdoc);

        var zlayout = Layout.init(allocator, &book);
        defer zlayout.deinit();
        zlayout.hl = &hl;
        zlayout.theme = th;

        // 1. Bracket matching through the tree, including the two
        //    cases a naive scanner gets wrong.
        const body_open = std.mem.indexOfScalar(u8, HL_SRC, '{').?;
        const pair = (try hl.bracketAt(&zdoc, body_open)) orelse {
            std.debug.print("smoke-editor: FAIL — no bracket pair for the fn body\n", .{});
            return 11;
        };
        if (pair.close.start != std.mem.lastIndexOfScalar(u8, HL_SRC, '}').?) {
            std.debug.print("smoke-editor: FAIL — fn body brace matched the wrong closer\n", .{});
            return 11;
        }
        // The '{' inside the format string "{s} {d}" is inside a string
        // token, so the tree reports NO pair for it.
        const in_string = std.mem.indexOf(u8, HL_SRC, "{s}").?;
        if ((try hl.bracketAt(&zdoc, in_string)) != null) {
            std.debug.print("smoke-editor: FAIL — a brace inside a string literal matched\n", .{});
            return 11;
        }
        // …and the fallback scanner, which has no tree, does match it —
        // the documented difference.
        if (structure.scanMatch(&zdoc.rope, in_string) == null) {
            std.debug.print("smoke-editor: FAIL — fallback scanner found no pair at all\n", .{});
            return 11;
        }

        var zsels = try SelectionSet.initSingle(allocator, Selection.caret(body_open));
        defer zsels.deinit(allocator);

        c.glClearColor(th.bg[0], th.bg[1], th.bg[2], th.bg[3]);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        try pass.buildFrame(.{
            .layout = &zlayout,
            .doc = &zdoc,
            .sels = &zsels,
            .view = .{
                .width_px = @floatFromInt(W),
                .height_px = @floatFromInt(H),
                .show_fold_column = true,
            },
            .colors = .{ .text = th.fg, .bracket = th.bracket, .fold_fg = th.fold_fg, .fold_badge = th.fold_badge },
            .theme = th,
            .brackets = &[_]structure.Range{ pair.open, pair.close },
        });
        pass.draw(atlas, W, H);
        c.glFinish();
        c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);
        // The box is translucent, so look for the COMPOSITE of the
        // bracket colour over the theme background.
        var want: [4]f32 = .{ 0, 0, 0, 1 };
        inline for (0..3) |ci| {
            want[ci] = th.bracket[ci] * th.bracket[3] + th.bg[ci] * (1 - th.bracket[3]);
        }
        var bracket_px: usize = 0;
        var bi: usize = 0;
        while (bi < fb_bytes) : (bi += 4) {
            if (nearColor(.{ fb[bi], fb[bi + 1], fb[bi + 2] }, want)) bracket_px += 1;
        }
        const unfolded_lines = pass.lines_laid_out;
        std.debug.print(
            "smoke-editor: structure bracket boxes px={d} unfolded_lines={d}\n",
            .{ bracket_px, unfolded_lines },
        );
        if (bracket_px < 20) {
            std.debug.print("smoke-editor: FAIL — bracket pair drew no visible box\n", .{});
            return 11;
        }

        // 2. Folding. The tree heads a region at the `pub fn` line;
        //    folding it must hide its body and cost FEWER laid-out
        //    lines, and the row index must agree.
        const fn_line = zdoc.rope.offsetToLineCol(std.mem.indexOf(u8, HL_SRC, "pub fn").?).line;
        const region = (try hl.foldRegionAtLine(&zdoc, fn_line)) orelse {
            std.debug.print("smoke-editor: FAIL — no foldable region at the fn line\n", .{});
            return 11;
        };
        var folds = structure.FoldState.init(allocator);
        defer folds.deinit();
        try folds.fold(structure.firstNonBlankOffset(&zdoc, fn_line), region);

        var rows = viewport_mod.RowIndex.init(allocator);
        defer rows.deinit();
        const zlines = zdoc.rope.lineCount();
        rows.reset(true, zlines);
        for (folds.hidden.items) |sp| {
            var l = sp.start_line;
            while (l <= sp.end_line and l < zlines) : (l += 1) rows.setHidden(l, true);
        }
        if (rows.totalRows(zlines) != zlines - folds.hiddenLines()) {
            std.debug.print("smoke-editor: FAIL — row index disagrees with the hidden set\n", .{});
            return 11;
        }

        c.glClear(c.GL_COLOR_BUFFER_BIT);
        try pass.buildFrame(.{
            .layout = &zlayout,
            .doc = &zdoc,
            .sels = &zsels,
            .view = .{
                .width_px = @floatFromInt(W),
                .height_px = @floatFromInt(H),
                .show_fold_column = true,
            },
            .colors = .{ .text = th.fg, .bracket = th.bracket, .fold_fg = th.fold_fg, .fold_badge = th.fold_badge },
            .theme = th,
            .folds = &folds,
            .fold_markers = &[_]editor_pass.FoldMarker{.{ .line = fn_line, .folded = true }},
            .rows = &rows,
        });
        pass.draw(atlas, W, H);
        c.glFinish();
        const folded_lines = pass.lines_laid_out;
        std.debug.print(
            "smoke-editor: structure folded region {d}..{d} hidden={d} folded_lines={d}\n",
            .{ region.start_line, region.end_line, folds.hiddenLines(), folded_lines },
        );
        if (folded_lines + folds.hiddenLines() != unfolded_lines) {
            std.debug.print(
                "smoke-editor: FAIL — folding did not remove exactly the hidden lines from the frame\n",
                .{},
            );
            return 11;
        }

        // 3. Expand / shrink retraces exactly.
        var stack = structure.SelectionStack.init(allocator);
        defer stack.deinit();
        const name_at = std.mem.indexOf(u8, HL_SRC, "\"sketerm\"").? + 2;
        zsels.keepPrimaryOnly();
        zsels.sels.items[0] = Selection.caret(name_at);
        var widths: [4]usize = undefined;
        var steps: usize = 0;
        while (steps < widths.len) : (steps += 1) {
            const cur = zsels.sels.items[0];
            const r = (try hl.expandRange(&zdoc, cur.start(), cur.end())) orelse break;
            try stack.push(&zsels);
            zsels.sels.items[0] = .{ .anchor = r.start, .head = r.end };
            widths[steps] = r.end - r.start;
            if (steps > 0 and widths[steps] <= widths[steps - 1]) {
                std.debug.print("smoke-editor: FAIL — expand did not grow the selection\n", .{});
                return 11;
            }
        }
        if (steps < 3) {
            std.debug.print("smoke-editor: FAIL — expand stopped after {d} steps\n", .{steps});
            return 11;
        }
        while (try stack.pop(&zsels)) {}
        if (!zsels.sels.items[0].isCaret() or zsels.sels.items[0].head != name_at) {
            std.debug.print("smoke-editor: FAIL — shrink did not retrace expand\n", .{});
            return 11;
        }
        std.debug.print("smoke-editor: PASS structure (brackets, folding, expand/shrink {d} steps)\n", .{steps});
    }

    // --- Project layer: git gutter, outline, project-wide search ------
    //
    // The daemon round trips these features make are covered by the GUI
    // rig; what is coverable HERE is everything downstream of the bytes
    // the daemon hands back, which is where the logic actually lives.
    {
        const th = &theme_mod.dark;
        var gdoc = try Document.initFromBytes(allocator, HL_SRC);
        defer gdoc.deinit();
        var glayout = Layout.init(allocator, &book);
        defer glayout.deinit();
        glayout.theme = th;
        var gsels = try SelectionSet.initSingle(allocator, Selection.caret(0));
        defer gsels.deinit(allocator);

        // 1. A real `git diff -U0` payload becomes anchored marks.
        const DIFF =
            "diff --git a/x.zig b/x.zig\n" ++
            "index 1111111..2222222 100644\n" ++
            "--- a/x.zig\n" ++
            "+++ b/x.zig\n" ++
            "@@ -1,1 +1,1 @@\n" ++
            "-const old = 1;\n" ++
            "+const std = @import(\"std\");\n" ++
            "@@ -3,0 +4,2 @@\n" ++
            "+added one\n" ++
            "+added two\n" ++
            "@@ -9,2 +11,0 @@\n" ++
            "-gone a\n" ++
            "-gone b\n";
        const line_marks = try gitdiff.parseUnified(allocator, DIFF);
        defer allocator.free(line_marks);
        var marks = gitdiff.Marks.init(allocator);
        defer marks.deinit();
        try marks.setFromLines(&gdoc, line_marks);
        if (marks.list.items.len != 4 or !marks.known) {
            std.debug.print("smoke-editor: FAIL — git marks {d} (want 4)\n", .{marks.list.items.len});
            return 12;
        }
        if (marks.list.items[0].kind != .modified or marks.list.items[1].kind != .added) {
            std.debug.print("smoke-editor: FAIL — git mark kinds wrong\n", .{});
            return 12;
        }
        const hunks = marks.hunkCount(&gdoc);
        if (hunks != 3) {
            std.debug.print("smoke-editor: FAIL — hunk count {d} (want 3)\n", .{hunks});
            return 12;
        }
        // Hunk navigation walks forward and wraps.
        const first = marks.nextHunk(&gdoc, 0, true).?;
        const second = marks.nextHunk(&gdoc, first, true).?;
        if (second <= first) {
            std.debug.print("smoke-editor: FAIL — hunk navigation did not advance\n", .{});
            return 12;
        }

        // 2. Marks survive an edit ABOVE them, the way diagnostics do.
        const before_anchor = marks.list.items[3].anchor;
        const edits = [_]tr.Edit{.{ .offset = 0, .deleted_len = 0, .inserted = "// prefix\n" }};
        marks.mapThrough(&edits);
        if (marks.list.items[3].anchor != before_anchor + 10) {
            std.debug.print("smoke-editor: FAIL — git marks did not map through an edit\n", .{});
            return 12;
        }
        marks.mapThrough(&[_]tr.Edit{}); // no-op guard
        try marks.setFromLines(&gdoc, line_marks);

        // 3. The gutter actually paints them.
        c.glClearColor(th.bg[0], th.bg[1], th.bg[2], th.bg[3]);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        const gcolors = editor_pass.Colors{ .text = th.fg, .gutter_bg = th.gutter_bg, .gutter_fg = th.gutter_fg };
        try pass.buildFrame(.{
            .layout = &glayout,
            .doc = &gdoc,
            .sels = &gsels,
            .view = .{
                .width_px = @floatFromInt(W),
                .height_px = @floatFromInt(H),
                .show_line_numbers = true,
            },
            .colors = gcolors,
            .theme = th,
            .git_marks = marks.list.items,
        });
        pass.draw(atlas, W, H);
        c.glFinish();
        c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);
        var added_px: usize = 0;
        var modified_px: usize = 0;
        var deleted_px: usize = 0;
        var gi: usize = 0;
        while (gi < fb_bytes) : (gi += 4) {
            const px = [3]u8{ fb[gi], fb[gi + 1], fb[gi + 2] };
            if (nearColor(px, gcolors.git_added)) added_px += 1;
            if (nearColor(px, gcolors.git_modified)) modified_px += 1;
            if (nearColor(px, gcolors.git_deleted)) deleted_px += 1;
        }
        std.debug.print(
            "smoke-editor: git gutter added={d}px modified={d}px deleted={d}px hunks={d}\n",
            .{ added_px, modified_px, deleted_px, hunks },
        );
        if (added_px == 0 or modified_px == 0 or deleted_px == 0) {
            std.debug.print("smoke-editor: FAIL — a gutter mark kind painted nothing\n", .{});
            return 12;
        }

        // 4. Outline from the syntax tree, with caret tracking and a
        //    signature that does NOT move when only ranges do.
        var ohl = try syntax.Highlighter.init(allocator, .zig);
        defer ohl.deinit();
        try ohl.parse(&gdoc);
        var ol = outline_mod.Outline.init(allocator);
        defer ol.deinit();
        try outline_mod.fromTree(&ol, &ohl, &gdoc, .zig);
        if (ol.source != .tree or ol.isEmpty()) {
            std.debug.print("smoke-editor: FAIL — tree outline is empty\n", .{});
            return 12;
        }
        const main_off = std.mem.indexOf(u8, HL_SRC, "pub fn main").?;
        const at = ol.indexAt(main_off + 4) orelse {
            std.debug.print("smoke-editor: FAIL — outline does not track the caret\n", .{});
            return 12;
        };
        const sig_before = ol.signature();
        ol.mapThrough(&edits);
        if (ol.signature() != sig_before) {
            std.debug.print("smoke-editor: FAIL — an edit changed the outline SHAPE\n", .{});
            return 12;
        }
        std.debug.print(
            "smoke-editor: outline symbols={d} source=tree caret_row={d} name={s}\n",
            .{ ol.nodes.items.len, at, ol.name(at) },
        );

        // 5. Project-wide search semantics: the daemon's grep only
        //    chooses candidate FILES, the editor's own engine produces
        //    every hit and every replacement.
        var res = psearch.Results.init(allocator);
        defer res.deinit();
        try res.reset("/proj", "std", .{});
        try res.setReplacement("STD");
        const f0 = try res.addFile("/proj/x.zig");
        const hits = try res.scanContent(f0, HL_SRC);
        if (hits == 0) {
            std.debug.print("smoke-editor: FAIL — project search found nothing\n", .{});
            return 12;
        }
        const plan = (try res.planReplace(f0, HL_SRC, 42)).?;
        if (std.mem.indexOf(u8, plan, "STD") == null) {
            std.debug.print("smoke-editor: FAIL — replace plan did not replace\n", .{});
            return 12;
        }
        if (std.mem.indexOf(u8, plan, "\nconst std") != null) {
            std.debug.print("smoke-editor: FAIL — replace plan missed an occurrence\n", .{});
            return 12;
        }
        // The seed a regex hands the daemon must be SOUND: every match
        // of the pattern contains it.
        if (!std.mem.eql(u8, psearch.literalSeed("std.debug", .{ .regex = true }), "std.")) {
            // `.` ends the run, so the seed is the literal prefix.
            if (!std.mem.eql(u8, psearch.literalSeed("std.debug", .{ .regex = true }), "debug")) {
                std.debug.print("smoke-editor: FAIL — unsound regex literal seed\n", .{});
                return 12;
            }
        }
        std.debug.print(
            "smoke-editor: project search hits={d} files={d} plan_bytes={d}\n",
            .{ res.hitCount(), res.matchedFiles(), plan.len },
        );

        // 6. Root discovery is the LSP machinery, one marker list wider.
        var fake = FakeProjectFs{};
        const found = project_mod.discover("/repo/src/main.zig", "", FakeProjectFs.exists, &fake) orelse {
            std.debug.print("smoke-editor: FAIL — no project root discovered\n", .{});
            return 12;
        };
        if (!std.mem.eql(u8, found.root, "/repo") or !found.isVcs()) {
            std.debug.print("smoke-editor: FAIL — wrong project root {s}\n", .{found.root});
            return 12;
        }
        if (project_mod.discover("/loose/file.txt", "", FakeProjectFs.exists, &fake) != null) {
            std.debug.print("smoke-editor: FAIL — a loose file was given a project\n", .{});
            return 12;
        }
        std.debug.print("smoke-editor: PASS project layer (gutter, outline, search, roots)\n", .{});
    }

    // --- Syntax perf on a ~1MB source ---------------------------------
    {
        var big: std.ArrayList(u8) = .empty;
        defer big.deinit(allocator);
        while (big.items.len < 1024 * 1024) try big.appendSlice(allocator, HL_SRC);
        var bdoc = try Document.initFromBytes(allocator, big.items);
        defer bdoc.deinit();
        var bhl = try syntax.Highlighter.init(allocator, .zig);
        defer bhl.deinit();
        bhl.attach(&bdoc);
        const b0 = nowNs();
        try bhl.parse(&bdoc);
        const b1 = nowNs();
        const full_reads = bhl.reads;
        // One viewport's worth of highlighting, deep in the document —
        // the only query cost a frame actually pays.
        const mid = bdoc.rope.len() / 2;
        const win = try bhl.spansAlloc(allocator, &bdoc, mid, mid + 4096);
        defer allocator.free(win);
        const b2 = nowNs();
        const tr2 = @import("editor/transaction.zig");
        var tx = tr2.Transaction.init(bdoc.revision);
        defer tx.deinit(allocator);
        try tx.addInsert(allocator, mid, "x");
        const b3 = nowNs();
        _ = try bdoc.applyTransaction(&tx);
        try bhl.parse(&bdoc);
        const b4 = nowNs();
        std.debug.print(
            "smoke-editor: syntax big({d} bytes) full_parse={d:.2}ms viewport_query={d:.3}ms incremental_reparse={d:.2}ms reads={d} spans={d}\n",
            .{ bdoc.rope.len(), ns2ms(b1 - b0), ns2ms(b2 - b1), ns2ms(b4 - b3), full_reads, win.len },
        );
    }

    std.debug.print(
        "smoke-editor: timing layout(cold)={d:.2}ms layout(cached)={d:.3}ms build={d:.2}ms draw(first)={d:.2}ms frame(steady)={d:.2}ms for {d} glyphs / {d} lines\n",
        .{
            @as(f64, @floatFromInt(t_layout1 - t_layout0)) / 1e6,
            @as(f64, @floatFromInt(t_warm1 - t_warm0)) / 1e6,
            @as(f64, @floatFromInt(t_build1 - t_build0)) / 1e6,
            @as(f64, @floatFromInt(t_draw1 - t_draw0)) / 1e6,
            @as(f64, @floatFromInt(t_draw2b - t_draw2a)) / 1e6,
            total_glyphs,
            n_lines,
        },
    );
    // ---- regex find/replace ------------------------------------------
    if (try regexStage(allocator)) |code| return code;

    // ---- crash-recovery journal round trip ---------------------------
    if (try journalStage(allocator)) |code| return code;

    // ---- LSP against a REAL stub server process ----------------------
    if (try lspStage(allocator)) |code| return code;

    std.debug.print("smoke-editor: PASS\n", .{});
    return 0;
}
