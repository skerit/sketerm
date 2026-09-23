//! Editing commands over Document + SelectionSet: line manipulation,
//! comment toggling, indentation, case conversion, occurrence-based
//! multi-caret creation, block selection and the typing behaviours
//! (language-aware newline indent, bracket/quote auto-close with
//! type-over and pair backspace, smart backspace through an indent
//! stop).
//!
//! Everything goes through ONE transaction per command via
//! `Document.applyTransactionSel`, so undo restores each command as a
//! single step with the pre-command selection — multi-caret included.
//! Commands whose resulting selection cannot be derived by mapping
//! (line moves, pair insertion with the caret INSIDE the pair) set the
//! selections explicitly after the apply; undo still restores the
//! snapshot recorded before the edit.
//!
//! GTK-free: the GUI resolves per-language inputs (the line-comment
//! prefix, the syntax gate) and passes them in.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Document = @import("document.zig").Document;
const tr = @import("transaction.zig");
const sel_mod = @import("selection.zig");
const strz = @import("../util/strz.zig");
const Selection = sel_mod.Selection;
const SelectionSet = sel_mod.SelectionSet;
const vm = @import("view_model.zig");
const indentation = @import("indentation.zig");

// ======================================================================
// Command registry (names, palette labels, default accelerators)
// ======================================================================

/// Every editor-face command. Each is bindable through
/// `editor_keybind.<name> = <accel>` config lines, listed in the command
/// palette while an editor face has focus, and dispatched by ONE switch
/// (`EditorView.runCommand`). The names are the stable config
/// vocabulary.
pub const Command = enum {
    // Line and text editing.
    duplicate_line_up,
    duplicate_line_down,
    move_line_up,
    move_line_down,
    join_lines,
    sort_lines,
    toggle_comment,
    indent,
    dedent,
    trim_trailing_ws,
    upper_case,
    lower_case,
    title_case,
    // Carets and selections.
    goto_line,
    select_next_occurrence,
    skip_occurrence,
    select_all_occurrences,
    add_caret_above,
    add_caret_below,
    split_selection_lines,
    select_all,
    expand_selection,
    shrink_selection,
    goto_matching_bracket,
    select_to_matching_bracket,
    // Clipboard and history.
    copy,
    cut,
    paste,
    undo,
    redo,
    // Find.
    find,
    replace,
    project_search,
    project_replace,
    // Documents.
    save,
    save_as,
    save_all,
    open_file,
    close_tab,
    // View.
    fold,
    unfold,
    fold_all,
    unfold_all,
    toggle_wrap,
    toggle_outline,
    next_hunk,
    prev_hunk,
    // Language server.
    trigger_completion,
    signature_help,
    show_hover,
    code_actions,
    format_document,
    rename_symbol,
    goto_definition,
    goto_declaration,
    goto_type_definition,
    find_references,
    workspace_symbols,
    next_diagnostic,
    prev_diagnostic,
    // Per-tab indentation (palette only, no default chord).
    indent_use_tabs,
    indent_use_spaces,
    indent_width_2,
    indent_width_4,
    indent_width_8,
    indent_auto,
};

pub const COMMAND_COUNT: usize = @typeInfo(Command).@"enum".fields.len;

/// Everything the UI says about one command. A single record per
/// command, so adding one is one switch arm and the build breaks
/// without it.
pub const Info = struct {
    label: [:0]const u8,
    describe: [:0]const u8,
    /// Default accelerators in GTK accel-string form; the FIRST is the
    /// one menus, prefs and the palette show. Several exist only where a
    /// keyboard reports one chord as distinct keyvals (a shifted
    /// bracket, the keypad period) or two chords are both common.
    accels: []const []const u8,
};

/// The command table. Accelerators follow what other editors already
/// put in people's fingers: VS Code for the line verbs, carets, LSP and
/// folding; Sublime for join (Ctrl+J) and sort (F9).
pub fn info(cmd: Command) Info {
    return switch (cmd) {
        .duplicate_line_up => .{
            .label = "Duplicate Line / Selection Up",
            .describe = "Copy the caret's line (or the selection) and keep the caret on the upper copy.",
            .accels = &.{"<Shift><Alt>Up"},
        },
        .duplicate_line_down => .{
            .label = "Duplicate Line / Selection Down",
            .describe = "Copy the caret's line (or the selection) and move the caret to the lower copy.",
            .accels = &.{"<Shift><Alt>Down"},
        },
        .move_line_up => .{ .label = "Move Line Up", .describe = "Swap the selected lines with the line above them.", .accels = &.{"<Alt>Up"} },
        .move_line_down => .{ .label = "Move Line Down", .describe = "Swap the selected lines with the line below them.", .accels = &.{"<Alt>Down"} },
        .join_lines => .{
            .label = "Join Lines",
            .describe = "Join each selected line with the next, collapsing the next line's leading whitespace to one space.",
            .accels = &.{"<Control>j"},
        },
        .sort_lines => .{ .label = "Sort Selected Lines", .describe = "Sort the lines covered by each selection in byte order.", .accels = &.{"F9"} },
        .toggle_comment => .{
            .label = "Toggle Line Comment",
            .describe = "Comment or uncomment the selected lines with the language's line-comment prefix.",
            .accels = &.{"<Control>slash"},
        },
        .indent => .{ .label = "Indent Lines", .describe = "Indent the selected lines by one tab stop.", .accels = &.{"<Control>bracketright"} },
        .dedent => .{ .label = "Dedent Lines", .describe = "Remove one leading tab stop from the selected lines.", .accels = &.{"<Control>bracketleft"} },
        .trim_trailing_ws => .{
            .label = "Trim Trailing Whitespace",
            .describe = "Delete trailing spaces and tabs on every line of the document.",
            .accels = &.{"<Control><Alt>t"},
        },
        .upper_case => .{ .label = "UPPERCASE", .describe = "Uppercase the selection (or the word at each caret).", .accels = &.{"<Control><Alt>u"} },
        .lower_case => .{ .label = "lowercase", .describe = "Lowercase the selection (or the word at each caret).", .accels = &.{"<Control><Alt>l"} },
        .title_case => .{ .label = "Title Case", .describe = "Title-case the selection (or the word at each caret).", .accels = &.{"<Control><Alt>i"} },
        .goto_line => .{ .label = "Go to Line\u{2026}", .describe = "Jump to a 1-based line (and optional column).", .accels = &.{"<Control>g"} },
        .select_next_occurrence => .{
            .label = "Select Next Occurrence",
            .describe = "Add a selection on the next match of the selected text (or the word at the caret).",
            .accels = &.{"<Control>d"},
        },
        .skip_occurrence => .{
            .label = "Skip Occurrence",
            .describe = "Drop the newest occurrence selection and take the next match instead.",
            .accels = &.{"<Control><Alt>d"},
        },
        .select_all_occurrences => .{
            .label = "Select All Occurrences",
            .describe = "Select every match of the selected text (or the word at the caret).",
            .accels = &.{"<Control><Shift>l"},
        },
        .add_caret_above => .{ .label = "Add Caret Above", .describe = "Add a caret on the line above each caret, same column.", .accels = &.{"<Control><Alt>Up"} },
        .add_caret_below => .{ .label = "Add Caret Below", .describe = "Add a caret on the line below each caret, same column.", .accels = &.{"<Control><Alt>Down"} },
        .split_selection_lines => .{
            .label = "Split Selection into Line Carets",
            .describe = "Replace each selection with one caret at the end of every line it covers.",
            .accels = &.{"<Shift><Alt>i"},
        },
        .select_all => .{ .label = "Select All", .describe = "Select the whole document.", .accels = &.{"<Control>a"} },
        .expand_selection => .{
            .label = "Expand Selection",
            .describe = "Grow every selection to the smallest syntax node around it.",
            .accels = &.{ "<Shift><Alt>Right", "<Shift><Alt>KP_Right" },
        },
        .shrink_selection => .{
            .label = "Shrink Selection",
            .describe = "Undo one Expand Selection step.",
            .accels = &.{ "<Shift><Alt>Left", "<Shift><Alt>KP_Left" },
        },
        .goto_matching_bracket => .{
            .label = "Go to Matching Bracket",
            .describe = "Jump every caret to the other half of its bracket pair.",
            .accels = &.{"<Control>m"},
        },
        .select_to_matching_bracket => .{
            .label = "Select to Matching Bracket",
            .describe = "Extend every selection to the other half of its bracket pair.",
            .accels = &.{"<Control><Shift>m"},
        },
        .copy => .{ .label = "Copy", .describe = "Copy the selections to the clipboard.", .accels = &.{"<Control>c"} },
        .cut => .{ .label = "Cut", .describe = "Copy the selections to the clipboard and delete them.", .accels = &.{"<Control>x"} },
        .paste => .{ .label = "Paste", .describe = "Insert the clipboard at every caret.", .accels = &.{"<Control>v"} },
        .undo => .{ .label = "Undo", .describe = "Undo the last edit, restoring the selection it was made from.", .accels = &.{"<Control>z"} },
        .redo => .{ .label = "Redo", .describe = "Redo the last undone edit.", .accels = &.{ "<Control>y", "<Control><Shift>z" } },
        .find => .{ .label = "Find\u{2026}", .describe = "Open the find bar over the document.", .accels = &.{"<Control>f"} },
        .replace => .{ .label = "Replace\u{2026}", .describe = "Open the find bar with its replace row.", .accels = &.{"<Control>h"} },
        .project_search => .{
            .label = "Find in Project\u{2026}",
            .describe = "Search every file of the document's project.",
            .accels = &.{"<Control><Shift>f"},
        },
        .project_replace => .{
            .label = "Replace in Project\u{2026}",
            .describe = "Preview and apply a replacement across the document's project.",
            .accels = &.{"<Control><Shift>h"},
        },
        .save => .{ .label = "Save", .describe = "Save the document.", .accels = &.{"<Control>s"} },
        .save_as => .{ .label = "Save As\u{2026}", .describe = "Save the document under a new name.", .accels = &.{"<Control><Shift>s"} },
        .save_all => .{ .label = "Save All", .describe = "Save every modified document that has a file.", .accels = &.{"<Control><Alt>s"} },
        .open_file => .{ .label = "Open File\u{2026}", .describe = "Open files in new document tabs.", .accels = &.{"<Control>o"} },
        .close_tab => .{ .label = "Close Document", .describe = "Close the document tab, asking first when it has unsaved changes.", .accels = &.{"<Control>w"} },
        .fold => .{
            .label = "Fold Region",
            .describe = "Fold the region headed by the caret's line, or the innermost one around it.",
            .accels = &.{ "<Control><Shift>bracketleft", "<Control><Shift>braceleft" },
        },
        .unfold => .{
            .label = "Unfold Region",
            .describe = "Unfold the region at or around the caret.",
            .accels = &.{ "<Control><Shift>bracketright", "<Control><Shift>braceright" },
        },
        .fold_all => .{
            .label = "Fold All",
            .describe = "Fold every foldable region of the document.",
            .accels = &.{ "<Control><Alt>bracketleft", "<Control><Alt>braceleft" },
        },
        .unfold_all => .{
            .label = "Unfold All",
            .describe = "Unfold every folded region.",
            .accels = &.{ "<Control><Alt>bracketright", "<Control><Alt>braceright" },
        },
        .toggle_wrap => .{ .label = "Toggle Soft Wrap", .describe = "Wrap long lines at the window edge, or stop wrapping them.", .accels = &.{"<Alt>z"} },
        .toggle_outline => .{
            .label = "Toggle Outline Panel",
            .describe = "Show or hide the document's symbol outline beside the text.",
            .accels = &.{"<Control><Shift>o"},
        },
        .next_hunk => .{ .label = "Next Change", .describe = "Jump to the next change against HEAD.", .accels = &.{"F7"} },
        .prev_hunk => .{ .label = "Previous Change", .describe = "Jump to the previous change against HEAD.", .accels = &.{"<Shift>F7"} },
        .trigger_completion => .{ .label = "Trigger Completion", .describe = "Ask the language server for completions at the caret.", .accels = &.{"<Control>space"} },
        .signature_help => .{ .label = "Signature Help", .describe = "Show the parameter list of the call around the caret.", .accels = &.{"<Control><Shift>space"} },
        .show_hover => .{
            .label = "Show Hover",
            .describe = "Show what the language server knows about the symbol at the caret, and its diagnostic.",
            .accels = &.{"<Control>i"},
        },
        .code_actions => .{
            .label = "Code Actions\u{2026}",
            .describe = "Quick fixes and refactorings for the selection or the caret.",
            .accels = &.{ "<Control>period", "<Control>KP_Decimal" },
        },
        .format_document => .{ .label = "Format Document", .describe = "Format the document, or the selection when there is one.", .accels = &.{"<Control><Shift>i"} },
        .rename_symbol => .{ .label = "Rename Symbol\u{2026}", .describe = "Rename the symbol at the caret across the project.", .accels = &.{"F2"} },
        .goto_definition => .{ .label = "Go to Definition", .describe = "Jump to where the symbol at the caret is defined.", .accels = &.{"F12"} },
        .goto_declaration => .{ .label = "Go to Declaration", .describe = "Jump to where the symbol at the caret is declared.", .accels = &.{"<Control><Shift>F12"} },
        .goto_type_definition => .{ .label = "Go to Type Definition", .describe = "Jump to the definition of the type of the symbol at the caret.", .accels = &.{"<Control>F12"} },
        .find_references => .{ .label = "Find References", .describe = "List every reference to the symbol at the caret.", .accels = &.{"<Shift>F12"} },
        .workspace_symbols => .{
            .label = "Workspace Symbols\u{2026}",
            .describe = "Search the project's symbols for the word at the caret or the selection.",
            .accels = &.{"<Control>t"},
        },
        .next_diagnostic => .{ .label = "Next Diagnostic", .describe = "Jump to the next problem the language server reported.", .accels = &.{"F8"} },
        .prev_diagnostic => .{ .label = "Previous Diagnostic", .describe = "Jump to the previous problem the language server reported.", .accels = &.{"<Shift>F8"} },
        // Per-tab settings, reached from the palette; no chord.
        .indent_use_tabs => .{ .label = "Indent Using Tabs", .describe = "Indent this tab's document with hard tabs, whatever the file or .editorconfig says.", .accels = &.{} },
        .indent_use_spaces => .{ .label = "Indent Using Spaces", .describe = "Indent this tab's document with spaces, whatever the file or .editorconfig says.", .accels = &.{} },
        .indent_width_2 => .{ .label = "Indent Width: 2", .describe = "Use an indent (and tab) width of 2 columns in this tab.", .accels = &.{} },
        .indent_width_4 => .{ .label = "Indent Width: 4", .describe = "Use an indent (and tab) width of 4 columns in this tab.", .accels = &.{} },
        .indent_width_8 => .{ .label = "Indent Width: 8", .describe = "Use an indent (and tab) width of 8 columns in this tab.", .accels = &.{} },
        .indent_auto => .{ .label = "Indent Automatically (Detect / .editorconfig)", .describe = "Drop this tab's indentation override and use .editorconfig, the file's content, then the defaults.", .accels = &.{} },
    };
}

pub fn name(cmd: Command) []const u8 {
    return @tagName(cmd);
}

pub fn fromName(s: []const u8) ?Command {
    inline for (@typeInfo(Command).@"enum".fields) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

pub fn label(cmd: Command) [:0]const u8 {
    return info(cmd).label;
}

/// One-line palette / prefs description.
pub fn describe(cmd: Command) [:0]const u8 {
    return info(cmd).describe;
}

/// The accelerator menus and the palette show for `cmd`.
pub fn defaultAccel(cmd: Command) []const u8 {
    const all = info(cmd).accels;
    return if (all.len == 0) "" else all[0];
}

pub fn defaultAccels(cmd: Command) []const []const u8 {
    return info(cmd).accels;
}

test "commands: no two default accelerators are spelled the same" {
    for (0..COMMAND_COUNT) |i| {
        for (info(@enumFromInt(i)).accels) |a| {
            for (0..COMMAND_COUNT) |j| {
                for (info(@enumFromInt(j)).accels) |b| {
                    if (i == j and a.ptr == b.ptr) continue;
                    try testing.expect(!std.ascii.eqlIgnoreCase(a, b));
                }
            }
        }
    }
}

/// The change an indentation command makes to the tab's override (a
/// style or a width, merged over what is already overridden); null for
/// every other command, `indent_auto` included, which clears instead.
pub fn indentOverrideOf(cmd: Command) ?indentation.Override {
    return switch (cmd) {
        .indent_use_tabs => .{ .style = .tabs },
        .indent_use_spaces => .{ .style = .spaces },
        .indent_width_2 => .{ .width = 2 },
        .indent_width_4 => .{ .width = 4 },
        .indent_width_8 => .{ .width = 8 },
        else => null,
    };
}

// ======================================================================
// Shared helpers
// ======================================================================

fn byteAt(doc: *const Document, offset: usize) ?u8 {
    if (offset >= doc.rope.len()) return null;
    var it = doc.rope.iterateRange(offset, offset + 1);
    const chunk = it.next() orelse return null;
    return chunk[0];
}

fn isWs(b: u8) bool {
    return b == ' ' or b == '\t';
}

const isWordByte = strz.isWordByte;

/// Content end (newline excluded) of `line`.
fn lineEndOf(doc: *const Document, line: usize) usize {
    const n = doc.rope.lineCount();
    return if (line + 1 < n) doc.rope.lineToOffset(line + 1) - 1 else doc.rope.len();
}

const LineSpan = struct { first: usize, last: usize };

/// Lines covered by `sel`. A non-caret selection ending exactly at a
/// line's first byte does NOT include that line (the usual editor
/// rule for full-line selections).
fn lineSpanOf(doc: *const Document, sel: Selection) LineSpan {
    const first = doc.rope.offsetToLineCol(sel.start()).line;
    var end_off = sel.end();
    if (!sel.isCaret() and end_off > sel.start() and
        end_off == doc.rope.lineToOffset(doc.rope.offsetToLineCol(end_off).line) and
        doc.rope.offsetToLineCol(end_off).line > first)
    {
        end_off -= 1;
    }
    const last = doc.rope.offsetToLineCol(end_off).line;
    return .{ .first = first, .last = @max(first, last) };
}

/// Deduplicated, ascending list of every line covered by any
/// selection. Arena-allocated by the caller.
fn coveredLines(a: Allocator, doc: *const Document, sels: *const SelectionSet) ![]usize {
    var lines: std.ArrayList(usize) = .empty;
    for (sels.sels.items) |s| {
        const span = lineSpanOf(doc, s);
        var l = span.first;
        while (l <= span.last) : (l += 1) {
            if (lines.items.len == 0 or lines.items[lines.items.len - 1] < l)
                try lines.append(a, l)
            else if (std.mem.indexOfScalar(usize, lines.items, l) == null)
                try lines.append(a, l);
        }
    }
    std.mem.sort(usize, lines.items, {}, std.sort.asc(usize));
    // Dedupe after sort (selections arrive normalized, but be safe).
    var w: usize = 0;
    for (lines.items) |l| {
        if (w > 0 and lines.items[w - 1] == l) continue;
        lines.items[w] = l;
        w += 1;
    }
    lines.shrinkRetainingCapacity(w);
    return lines.items;
}

/// Apply `tx` with the pre-edit selection recorded, then map the live
/// selections through with editor bias.
fn applyMapped(_: Allocator, doc: *Document, sels: *SelectionSet, tx: *tr.Transaction) !void {
    if (tx.edits.items.len == 0) return;
    _ = try doc.applyTransactionSel(tx, vm.snapshotOf(sels));
    sels.mapThrough(tx.edits.items, .editor);
}

/// Snap `offset` back to a UTF-8 sequence start.
fn snapBoundary(doc: *const Document, offset: usize) usize {
    var o = offset;
    while (o > 0) {
        const b = byteAt(doc, o) orelse break;
        if ((b & 0xC0) != 0x80) break;
        o -= 1;
    }
    return o;
}

// ======================================================================
// Part 1 — editing commands
// ======================================================================

/// Duplicate each caret's line (or each range selection's text).
/// `down` keeps the selection on the LOWER copy; up keeps the upper —
/// which for line duplication means the caret visually stays put (up)
/// or rides the copy (down), matching VS Code's Copy Line Up/Down.
pub fn duplicate(alloc: Allocator, doc: *Document, sels: *SelectionSet, down: bool) !void {
    if (sels.sels.items.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);

    const Ins = struct { offset: usize, len: usize };
    var inserts: std.ArrayList(Ins) = .empty;
    // Offset of the insert each selection "owns" (dedup means two
    // carets on one line share it).
    var own: std.ArrayList(usize) = .empty;
    var last_line: ?usize = null;

    for (sels.sels.items) |s| {
        if (s.isCaret()) {
            const lb = vm.lineBoundsAt(doc, s.head);
            if (last_line == null or last_line.? != lb.line) {
                last_line = lb.line;
                const content = try doc.rope.sliceAlloc(a, lb.start, lb.end);
                const text = try std.mem.concat(a, u8, &.{ content, "\n" });
                try tx.addInsert(alloc, lb.start, text);
                try inserts.append(a, .{ .offset = lb.start, .len = text.len });
            }
            try own.append(a, lb.start);
        } else {
            const text = try doc.rope.sliceAlloc(a, s.start(), s.end());
            try tx.addInsert(alloc, s.start(), text);
            try inserts.append(a, .{ .offset = s.start(), .len = text.len });
            try own.append(a, s.start());
        }
    }
    if (tx.edits.items.len == 0) return;
    _ = try doc.applyTransactionSel(&tx, vm.snapshotOf(sels));

    // Manual mapping. Inserting the copy at the selection's start puts
    // the COPY above and the original text below, so: shifting a
    // selection by its own insert's length lands it on the LOWER copy
    // (down), not shifting keeps it on the upper (up). Inserts from
    // earlier selections always shift.
    for (sels.sels.items, own.items) |*s, own_off| {
        var da: usize = 0;
        var dh: usize = 0;
        for (inserts.items) |ins| {
            const own_ins = ins.offset == own_off;
            if (ins.offset < own_off or (own_ins and down)) {
                if (ins.offset <= s.anchor) da += ins.len;
                if (ins.offset <= s.head) dh += ins.len;
            }
        }
        s.anchor += da;
        s.head += dh;
    }
    sels.normalize();
}

/// Move the line blocks covered by the selections up or down by one
/// line. Blocks that touch merge; a block already at the document
/// edge stays put. One transaction; selections ride their block.
pub fn moveLines(alloc: Allocator, doc: *Document, sels: *SelectionSet, down: bool) !void {
    if (sels.sels.items.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const line_count = doc.rope.lineCount();

    // Merge covered spans into disjoint blocks.
    var blocks: std.ArrayList(LineSpan) = .empty;
    for (sels.sels.items) |s| {
        const span = lineSpanOf(doc, s);
        if (blocks.items.len > 0 and span.first <= blocks.items[blocks.items.len - 1].last + 1) {
            blocks.items[blocks.items.len - 1].last = @max(blocks.items[blocks.items.len - 1].last, span.last);
        } else try blocks.append(a, span);
    }

    const Region = struct { start: usize, end: usize, shift: isize };
    var regions: std.ArrayList(Region) = .empty;
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);

    for (blocks.items) |b| {
        if (!down and b.first == 0) continue;
        if (down and b.last + 1 >= line_count) continue;
        const nb_line = if (down) b.last + 1 else b.first - 1;
        const nb_start = doc.rope.lineToOffset(nb_line);
        const nb_end = lineEndOf(doc, nb_line);
        const nb_text = try doc.rope.sliceAlloc(a, nb_start, nb_end);
        const blk_start = doc.rope.lineToOffset(b.first);
        const blk_end = lineEndOf(doc, b.last);
        const blk_text = try doc.rope.sliceAlloc(a, blk_start, blk_end);

        const region_start = @min(blk_start, nb_start);
        const region_end = @max(blk_end, nb_end);
        const replacement = if (down)
            try std.mem.concat(a, u8, &.{ nb_text, "\n", blk_text })
        else
            try std.mem.concat(a, u8, &.{ blk_text, "\n", nb_text });
        std.debug.assert(replacement.len == region_end - region_start);
        try tx.addReplace(alloc, region_start, region_end - region_start, replacement);
        const shift: isize = @intCast(nb_text.len + 1);
        try regions.append(a, .{
            .start = blk_start,
            .end = blk_end,
            .shift = if (down) shift else -shift,
        });
    }
    if (tx.edits.items.len == 0) return;
    _ = try doc.applyTransactionSel(&tx, vm.snapshotOf(sels));

    // Selections inside a moved block shift with it (total delta of
    // each region is zero, so everything else stays put).
    for (sels.sels.items) |*s| {
        for (regions.items) |r| {
            if (s.anchor >= r.start and s.anchor <= r.end)
                s.anchor = @intCast(@as(isize, @intCast(s.anchor)) + r.shift);
            if (s.head >= r.start and s.head <= r.end)
                s.head = @intCast(@as(isize, @intCast(s.head)) + r.shift);
        }
    }
    sels.normalize();
}

/// Join each caret's line with the next (ranges join every newline
/// they cover): the newline and the next line's leading whitespace
/// become a single space (nothing when either side is empty).
pub fn joinLines(alloc: Allocator, doc: *Document, sels: *SelectionSet) !void {
    if (sels.sels.items.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const line_count = doc.rope.lineCount();

    var joins: std.ArrayList(usize) = .empty; // line whose trailing \n goes
    for (sels.sels.items) |s| {
        const span = lineSpanOf(doc, s);
        var l = span.first;
        const last = if (s.isCaret()) span.first else span.last - 1;
        while (l <= last) : (l += 1) {
            if (l + 1 >= line_count) break;
            if (joins.items.len > 0 and joins.items[joins.items.len - 1] >= l) continue;
            try joins.append(a, l);
        }
    }
    if (joins.items.len == 0) return;

    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);
    for (joins.items) |l| {
        const end = lineEndOf(doc, l); // the \n sits here
        var ws_end = end + 1;
        const next_end = lineEndOf(doc, l + 1);
        while (ws_end < next_end) {
            const b = byteAt(doc, ws_end) orelse break;
            if (!isWs(b)) break;
            ws_end += 1;
        }
        const left_empty = end == doc.rope.lineToOffset(l);
        const right_empty = ws_end >= next_end;
        const sep: []const u8 = if (left_empty or right_empty) "" else " ";
        try tx.addReplace(alloc, end, ws_end - end, sep);
    }
    try applyMapped(alloc, doc, sels, &tx);
}

/// Sort the lines each range selection covers, byte-wise ascending.
/// Carets are skipped (sorting "the line under the caret" is a no-op
/// by definition). The selection ends up covering its sorted block.
pub fn sortLines(alloc: Allocator, doc: *Document, sels: *SelectionSet) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);
    const Region = struct { start: usize, end: usize };
    var regions: std.ArrayList(Region) = .empty;
    var prev_end: usize = 0;
    for (sels.sels.items) |s| {
        if (s.isCaret()) continue;
        const span = lineSpanOf(doc, s);
        if (span.last <= span.first) continue;
        const start = doc.rope.lineToOffset(span.first);
        const end = lineEndOf(doc, span.last);
        if (start < prev_end) continue;
        prev_end = end;
        const text = try doc.rope.sliceAlloc(a, start, end);
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| try lines.append(a, line);
        std.mem.sort([]const u8, lines.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        const joined = try std.mem.join(a, "\n", lines.items);
        std.debug.assert(joined.len == text.len);
        try tx.addReplace(alloc, start, end - start, joined);
        try regions.append(a, .{ .start = start, .end = end });
    }
    if (tx.edits.items.len == 0) return;
    _ = try doc.applyTransactionSel(&tx, vm.snapshotOf(sels));
    // Cover each sorted block (mapping through a same-length replace
    // would clamp interior carets to the block edge instead).
    var i: usize = 0;
    for (sels.sels.items) |*s| {
        if (s.isCaret()) continue;
        if (i < regions.items.len) {
            s.anchor = regions.items[i].start;
            s.head = regions.items[i].end;
            i += 1;
        }
    }
    sels.normalize();
}

pub const CommentResult = enum { commented, uncommented, no_lines };

/// What toggle-comment writes around a line: a line token alone (`//`),
/// or a block pair wrapped around each line (`/* ... */`) for languages
/// with no line comment. The GUI takes it from the language registry.
pub const CommentTokens = struct {
    open: []const u8,
    close: []const u8 = "",
};

/// Toggle comments on every line any selection covers. Blank lines are
/// skipped. If every covered non-blank line is already commented the
/// block uncomments (token plus one adjacent space); otherwise every
/// non-blank line is commented (the usual mixed-selection rule).
pub fn toggleComment(alloc: Allocator, doc: *Document, sels: *SelectionSet, tokens: CommentTokens) !CommentResult {
    if (tokens.open.len == 0) return .no_lines;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const Line = struct { start: usize, lead: usize, body: []const u8 };
    const lines = try coveredLines(a, doc, sels);
    var content: std.ArrayList(Line) = .empty;
    var all_commented = true;
    for (lines) |l| {
        const start = doc.rope.lineToOffset(l);
        const text = try doc.rope.sliceAlloc(a, start, lineEndOf(doc, l));
        const lead = text.len - std.mem.trimStart(u8, text, " \t").len;
        const body = std.mem.trimEnd(u8, text[lead..], " \t");
        if (body.len == 0) continue;
        try content.append(a, .{ .start = start, .lead = lead, .body = body });
        const wrapped = std.mem.startsWith(u8, body, tokens.open) and
            body.len >= tokens.open.len + tokens.close.len and
            std.mem.endsWith(u8, body, tokens.close);
        if (!wrapped) all_commented = false;
    }
    if (content.items.len == 0) return .no_lines;

    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);
    const open_ins = try std.mem.concat(a, u8, &.{ tokens.open, " " });
    const close_ins = try std.mem.concat(a, u8, &.{ " ", tokens.close });
    for (content.items) |ln| {
        const at = ln.start + ln.lead;
        if (all_commented) {
            var del = tokens.open.len;
            if (ln.body.len > del and ln.body[del] == ' ') del += 1;
            try tx.addDelete(alloc, at, del);
            if (tokens.close.len > 0) {
                var cstart = ln.body.len - tokens.close.len;
                if (cstart > del and ln.body[cstart - 1] == ' ') cstart -= 1;
                cstart = @max(cstart, del);
                if (ln.body.len > cstart) try tx.addDelete(alloc, at + cstart, ln.body.len - cstart);
            }
        } else {
            try tx.addInsert(alloc, at, open_ins);
            if (tokens.close.len > 0) try tx.addInsert(alloc, at + ln.body.len, close_ins);
        }
    }
    try applyMapped(alloc, doc, sels, &tx);
    return if (all_commented) .uncommented else .commented;
}

/// Indent every covered non-blank line by one unit (`width` spaces,
/// or one tab when `spaces` is false).
pub fn indentLines(alloc: Allocator, doc: *Document, sels: *SelectionSet, width: usize, spaces: bool) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const unit: []const u8 = if (spaces) blk: {
        const u = try a.alloc(u8, @max(1, width));
        @memset(u, ' ');
        break :blk u;
    } else "\t";

    const lines = try coveredLines(a, doc, sels);
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);
    for (lines) |l| {
        const start = doc.rope.lineToOffset(l);
        if (start >= lineEndOf(doc, l)) continue; // blank line
        try tx.addInsert(alloc, start, unit);
    }
    try applyMapped(alloc, doc, sels, &tx);
}

/// Remove up to one leading indent unit from every covered line: a
/// tab, or up to `width` spaces.
pub fn dedentLines(alloc: Allocator, doc: *Document, sels: *SelectionSet, width: usize) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try coveredLines(a, doc, sels);
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);
    for (lines) |l| {
        const start = doc.rope.lineToOffset(l);
        const first = byteAt(doc, start) orelse continue;
        if (first == '\t') {
            try tx.addDelete(alloc, start, 1);
            continue;
        }
        var n: usize = 0;
        const w = @max(1, width);
        while (n < w) : (n += 1) {
            const b = byteAt(doc, start + n) orelse break;
            if (b != ' ') break;
        }
        if (n > 0) try tx.addDelete(alloc, start, n);
    }
    try applyMapped(alloc, doc, sels, &tx);
}

/// Delete trailing spaces/tabs on every line of the document. One
/// undo step; selections map through (a caret sitting in stripped
/// whitespace clamps to the new line end).
pub fn trimTrailingWhitespace(alloc: Allocator, doc: *Document, sels: *SelectionSet) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);
    try appendTrimEdits(alloc, arena.allocator(), doc, &tx);
    try applyMapped(alloc, doc, sels, &tx);
}

/// Append the edits that strip every line's trailing spaces and tabs to
/// `tx` (ascending, so a caller may add later edits after them).
/// `scratch` holds line copies and may be an arena.
pub fn appendTrimEdits(alloc: Allocator, scratch: Allocator, doc: *const Document, tx: *tr.Transaction) !void {
    const n = doc.rope.lineCount();
    var l: usize = 0;
    while (l < n) : (l += 1) {
        const start = doc.rope.lineToOffset(l);
        const end = lineEndOf(doc, l);
        if (end <= start) continue;
        const text = try doc.rope.sliceAlloc(scratch, start, end);
        var keep = text.len;
        while (keep > 0 and isWs(text[keep - 1])) keep -= 1;
        if (keep < text.len) try tx.addDelete(alloc, start + keep, text.len - keep);
    }
}

pub const CaseMode = enum { upper, lower, title };

/// Case-convert each selection (the word at the caret when there is
/// no selection). ASCII letters only — a non-ASCII codepoint passes
/// through untouched, which keeps lengths (and offsets) stable.
pub fn changeCase(alloc: Allocator, doc: *Document, sels: *SelectionSet, mode: CaseMode) !void {
    if (sels.sels.items.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const Range = struct { start: usize, end: usize };
    var ranges: std.ArrayList(Range) = .empty;
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);
    var prev_end: usize = 0;
    for (sels.sels.items) |s| {
        var start = s.start();
        var end = s.end();
        if (s.isCaret()) {
            const w = vm.wordRangeAt(a, doc, s.head);
            start = w.start();
            end = w.end();
        }
        if (start < prev_end) start = prev_end;
        if (end <= start) continue;
        prev_end = end;
        const text = try doc.rope.sliceAlloc(a, start, end);
        var out = try a.dupe(u8, text);
        var word_start = true;
        for (out, 0..) |ch, i| {
            switch (mode) {
                .upper => out[i] = std.ascii.toUpper(ch),
                .lower => out[i] = std.ascii.toLower(ch),
                .title => {
                    if (isWordByte(ch) and ch < 0x80) {
                        out[i] = if (word_start) std.ascii.toUpper(ch) else std.ascii.toLower(ch);
                    }
                    word_start = !isWordByte(ch);
                },
            }
        }
        if (std.mem.eql(u8, out, text)) continue;
        try tx.addReplace(alloc, start, end - start, out);
        try ranges.append(a, .{ .start = start, .end = end });
    }
    if (tx.edits.items.len == 0) return;
    _ = try doc.applyTransactionSel(&tx, vm.snapshotOf(sels));
    // Same-length replaces: offsets did not move; put each selection
    // over the converted range (covers the caret/word case too).
    if (ranges.items.len == sels.sels.items.len) {
        for (sels.sels.items, ranges.items) |*s, r| {
            const reversed = s.anchor > s.head;
            s.anchor = if (reversed) r.end else r.start;
            s.head = if (reversed) r.start else r.end;
        }
        sels.normalize();
    }
}

// ======================================================================
// Part 2 — multi-caret creation
// ======================================================================

/// The primary selection's text, or the word at the primary caret
/// (in which case the primary is grown to that word first). Null when
/// there is nothing usable.
fn occurrenceNeedle(a: Allocator, doc: *const Document, sels: *SelectionSet) !?[]u8 {
    var p = sels.sels.items[sels.primary_index];
    if (p.isCaret()) {
        const w = vm.wordRangeAt(a, doc, p.head);
        if (w.isCaret()) return null;
        sels.sels.items[sels.primary_index] = w;
        p = w;
    }
    const text = try doc.rope.sliceAlloc(a, p.start(), p.end());
    if (text.len == 0) return null;
    return text;
}

fn hasSelectionAt(sels: *const SelectionSet, start: usize, end: usize) bool {
    for (sels.sels.items) |s| {
        if (s.start() == start and s.end() == end) return true;
    }
    return false;
}

/// Ctrl+D: grow a caret to its word, or add a selection on the next
/// match of the primary's text (wrapping past the end). Case
/// sensitive, plain literal match.
pub fn selectNextOccurrence(alloc: Allocator, doc: *Document, sels: *SelectionSet) !bool {
    if (sels.sels.items.len == 0) return false;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const was_caret = sels.primary().isCaret();
    const needle = (try occurrenceNeedle(a, doc, sels)) orelse return false;
    if (was_caret) {
        sels.normalize();
        return true;
    }
    return try addOccurrenceAfter(a, alloc, doc, sels, needle, maxEnd(sels));
}

fn maxEnd(sels: *const SelectionSet) usize {
    var m: usize = 0;
    for (sels.sels.items) |s| m = @max(m, s.end());
    return m;
}

fn addOccurrenceAfter(a: Allocator, alloc: Allocator, doc: *Document, sels: *SelectionSet, needle: []const u8, from: usize) !bool {
    const text = try doc.textAlloc(a);
    var pos = from;
    var wrapped = false;
    while (true) {
        const found = std.mem.indexOfPos(u8, text, pos, needle) orelse {
            if (wrapped) return false;
            wrapped = true;
            pos = 0;
            continue;
        };
        const end = found + needle.len;
        if (!hasSelectionAt(sels, found, end)) {
            try sels.add(alloc, .{ .anchor = found, .head = end });
            return true;
        }
        if (wrapped and found >= from) return false;
        pos = found + 1;
        if (pos >= text.len) {
            if (wrapped) return false;
            wrapped = true;
            pos = 0;
        }
    }
}

/// Ctrl+K-style skip: drop the primary occurrence and take the next
/// match instead. With a single selection this just moves it.
pub fn skipOccurrence(alloc: Allocator, doc: *Document, sels: *SelectionSet) !bool {
    if (sels.sels.items.len == 0) return false;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const needle = (try occurrenceNeedle(a, doc, sels)) orelse return false;
    const p = sels.primary();
    const from = p.end();
    if (sels.sels.items.len > 1) {
        sels.remove(sels.primary_index);
    } else {
        // A lone selection: it becomes the placeholder that the next
        // match replaces.
        const added = try addOccurrenceAfter(a, alloc, doc, sels, needle, from);
        if (!added) return false;
        // Remove the original (now non-primary) selection.
        for (sels.sels.items, 0..) |s, i| {
            if (s.start() == p.start() and s.end() == p.end() and sels.sels.items.len > 1) {
                sels.remove(i);
                break;
            }
        }
        return true;
    }
    return try addOccurrenceAfter(a, alloc, doc, sels, needle, from);
}

/// Select every match of the primary's text (or the word at the
/// caret). Returns the match count.
pub fn selectAllOccurrences(alloc: Allocator, doc: *Document, sels: *SelectionSet) !usize {
    if (sels.sels.items.len == 0) return 0;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const needle = (try occurrenceNeedle(a, doc, sels)) orelse return 0;
    const text = try doc.textAlloc(a);
    var matches: std.ArrayList(Selection) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, needle)) |found| {
        try matches.append(a, .{ .anchor = found, .head = found + needle.len });
        pos = found + needle.len;
    }
    if (matches.items.len == 0) return 0;
    sels.sels.clearRetainingCapacity();
    try sels.sels.appendSlice(alloc, matches.items);
    sels.primary_index = sels.sels.items.len - 1;
    sels.normalize();
    return matches.items.len;
}

/// Add a caret one line above/below each existing caret, same byte
/// column (clamped to the target line, snapped to a UTF-8 boundary).
/// Byte columns, not visual columns: a tab counts as one.
pub fn addCaretVertical(alloc: Allocator, doc: *Document, sels: *SelectionSet, down: bool) !void {
    const line_count = doc.rope.lineCount();
    var to_add: std.ArrayList(Selection) = .empty;
    defer to_add.deinit(alloc);
    for (sels.sels.items) |s| {
        const lc = doc.rope.offsetToLineCol(s.head);
        if (!down and lc.line == 0) continue;
        if (down and lc.line + 1 >= line_count) continue;
        const target = if (down) lc.line + 1 else lc.line - 1;
        const start = doc.rope.lineToOffset(target);
        const end = lineEndOf(doc, target);
        const col = s.head - doc.rope.lineToOffset(lc.line);
        const off = snapBoundary(doc, @min(start + col, end));
        try to_add.append(alloc, Selection.caret(off));
    }
    for (to_add.items) |s| try sels.add(alloc, s);
}

/// Shift+Alt+I: replace each range selection with one caret at the
/// end of every line it covers. Carets pass through unchanged.
pub fn splitSelectionIntoLines(alloc: Allocator, doc: *Document, sels: *SelectionSet) !void {
    var out: std.ArrayList(Selection) = .empty;
    defer out.deinit(alloc);
    for (sels.sels.items) |s| {
        if (s.isCaret()) {
            try out.append(alloc, s);
            continue;
        }
        const span = lineSpanOf(doc, s);
        var l = span.first;
        while (l <= span.last) : (l += 1) {
            const end = @min(lineEndOf(doc, l), s.end());
            try out.append(alloc, Selection.caret(@max(end, s.start())));
        }
    }
    if (out.items.len == 0) return;
    sels.sels.clearRetainingCapacity();
    try sels.sels.appendSlice(alloc, out.items);
    sels.primary_index = sels.sels.items.len - 1;
    sels.normalize();
}

/// Block (column) selection between two (line, byte-column) corners:
/// one range per line, clamped to each line's content and snapped to
/// UTF-8 boundaries. No virtual space — a short line contributes a
/// caret at its end. Byte columns, so tabs count as one column.
pub fn blockSelection(alloc: Allocator, doc: *Document, sels: *SelectionSet, anchor_line: usize, anchor_col: usize, head_line: usize, head_col: usize) !void {
    const line_count = doc.rope.lineCount();
    if (line_count == 0) return;
    const l0 = @min(@min(anchor_line, head_line), line_count - 1);
    const l1 = @min(@max(anchor_line, head_line), line_count - 1);
    const c0 = @min(anchor_col, head_col);
    const c1 = @max(anchor_col, head_col);
    sels.sels.clearRetainingCapacity();
    var l = l0;
    while (l <= l1) : (l += 1) {
        const start = doc.rope.lineToOffset(l);
        const end = lineEndOf(doc, l);
        const a_off = snapBoundary(doc, @min(start + c0, end));
        const h_off = snapBoundary(doc, @min(start + c1, end));
        try sels.sels.append(alloc, .{ .anchor = a_off, .head = h_off });
    }
    sels.primary_index = if (head_line >= anchor_line) sels.sels.items.len - 1 else 0;
    sels.normalize();
}

// ======================================================================
// Part 3 — typing behaviour
// ======================================================================

/// Per-caret syntax gate: answers whether an offset is plain code
/// (auto-close applies) or inside a string/comment (it does not).
/// A null callback means "no grammar" and gates nothing.
pub const Gate = struct {
    ctx: ?*anyopaque = null,
    is_code: ?*const fn (ctx: ?*anyopaque, offset: usize) bool = null,

    pub fn codeAt(self: Gate, offset: usize) bool {
        const f = self.is_code orelse return true;
        return f(self.ctx, offset);
    }
};

pub const IndentOpts = struct {
    width: usize,
    spaces: bool,
    /// Language-aware deepening after an opening bracket; false is a
    /// plain copy of the previous line's leading whitespace.
    auto_indent: bool,
};

fn indentUnit(a: Allocator, opts: IndentOpts) ![]const u8 {
    if (!opts.spaces) return "\t";
    const u = try a.alloc(u8, @max(1, opts.width));
    @memset(u, ' ');
    return u;
}

fn closerFor(open: u8) ?u8 {
    return switch (open) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        else => null,
    };
}

/// Enter with auto-indent: copies the line's leading whitespace
/// (clipped to the caret column); when `auto_indent` is on and the
/// character before the caret is an opening bracket, goes one unit
/// deeper — and when the character after the caret is the matching
/// closer, drops it onto its own line at the original depth with the
/// caret on the (indented) middle line.
///
/// Structure understanding is deliberately this shallow: bracket
/// adjacency, not a tree walk. See docs/editor.md for the limits.
pub fn newlineAutoIndent(alloc: Allocator, doc: *Document, sels: *SelectionSet, opts: IndentOpts) !void {
    if (sels.sels.items.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const unit = try indentUnit(a, opts);

    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);
    var carets: std.ArrayList(usize) = .empty; // caret pos within inserted text
    var prev_end: usize = 0;
    for (sels.sels.items) |s| {
        var start = s.start();
        var end = s.end();
        if (start < prev_end) start = prev_end;
        if (end < start) end = start;
        prev_end = end;

        const lb = vm.lineBoundsAt(doc, start);
        const line = try doc.rope.sliceAlloc(a, lb.start, lb.end);
        var ws: usize = 0;
        const caret_col = start - lb.start;
        while (ws < line.len and ws < caret_col and isWs(line[ws])) ws += 1;
        const base = line[0..ws];

        var deepen = false;
        var wrap_closer = false;
        if (opts.auto_indent and start > lb.start) {
            const prev = line[caret_col - 1];
            if (closerFor(prev)) |close| {
                deepen = true;
                if (byteAt(doc, end)) |next| wrap_closer = next == close;
            }
        }
        var text: []const u8 = undefined;
        var caret_in: usize = undefined;
        if (deepen and wrap_closer) {
            text = try std.mem.concat(a, u8, &.{ "\n", base, unit, "\n", base });
            caret_in = 1 + base.len + unit.len;
        } else if (deepen) {
            text = try std.mem.concat(a, u8, &.{ "\n", base, unit });
            caret_in = text.len;
        } else {
            text = try std.mem.concat(a, u8, &.{ "\n", base });
            caret_in = text.len;
        }
        try tx.addReplace(alloc, start, end - start, text);
        try carets.append(a, caret_in);
    }
    _ = try doc.applyTransactionSel(&tx, vm.snapshotOf(sels));
    // Place carets explicitly (the wrap-closer case wants the caret
    // INSIDE the insertion, which mapping cannot express).
    var delta: isize = 0;
    for (tx.edits.items, 0..) |e, i| {
        const base_pos: usize = @intCast(@as(isize, @intCast(e.offset)) + delta);
        if (i < sels.sels.items.len)
            sels.sels.items[i] = Selection.caret(base_pos + carets.items[i]);
        delta += @as(isize, @intCast(e.inserted.len)) - @as(isize, @intCast(e.deleted_len));
    }
    sels.normalize();
}

pub const AutoCloseResult = enum { not_handled, inserted_pair, typed_over, surrounded };

fn closingOf(cp: u8) ?u8 {
    return switch (cp) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '"' => '"',
        '\'' => '\'',
        '`' => '`',
        else => null,
    };
}

fn isCloser(cp: u8) bool {
    return cp == ')' or cp == ']' or cp == '}';
}

fn isQuote(cp: u8) bool {
    return cp == '"' or cp == '\'' or cp == '`';
}

/// A single typed ASCII character, before it is inserted. Handles:
/// type-over of a pending closer, surround-selection, and pair
/// insertion. Anything ambiguous returns `.not_handled` (the caller
/// inserts the character normally) — the feature must never fight
/// the user. Multi-caret: a behaviour applies only when EVERY caret
/// agrees on it.
pub fn autoClose(alloc: Allocator, doc: *Document, sels: *SelectionSet, ch: u8, gate: Gate) !AutoCloseResult {
    if (sels.sels.items.len == 0) return .not_handled;

    // Type-over: the typed char is a closer (or closing quote) and is
    // exactly what sits after every caret.
    if (isCloser(ch) or isQuote(ch)) {
        var all = true;
        for (sels.sels.items) |s| {
            if (!s.isCaret() or byteAt(doc, s.head) != ch) {
                all = false;
                break;
            }
        }
        if (all) {
            for (sels.sels.items) |*s| {
                s.head += 1;
                s.anchor = s.head;
            }
            sels.normalize();
            return .typed_over;
        }
        if (isCloser(ch)) return .not_handled;
    }

    const close = closingOf(ch) orelse return .not_handled;

    // Surround: every selection is a non-empty range.
    var all_ranges = true;
    var all_carets = true;
    for (sels.sels.items) |s| {
        if (s.isCaret()) all_ranges = false else all_carets = false;
    }
    if (all_ranges) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var tx = tr.Transaction.init(doc.revision);
        defer tx.deinit(alloc);
        for (sels.sels.items) |s| {
            try tx.addInsert(alloc, s.start(), try a.dupe(u8, &.{ch}));
            try tx.addInsert(alloc, s.end(), try a.dupe(u8, &.{close}));
        }
        _ = try doc.applyTransactionSel(&tx, vm.snapshotOf(sels));
        // Keep each selection around its original text: every earlier
        // insert shifts by 1; the own opener shifts the range by 1.
        var shift: usize = 0;
        for (sels.sels.items) |*s| {
            const reversed = s.anchor > s.head;
            const ns = s.start() + shift + 1;
            const ne = s.end() + shift + 1;
            s.anchor = if (reversed) ne else ns;
            s.head = if (reversed) ns else ne;
            shift += 2;
        }
        sels.normalize();
        return .surrounded;
    }
    if (!all_carets) return .not_handled;

    // Pair insertion at carets: only when every caret is in a spot
    // where the pair cannot fight the user.
    for (sels.sels.items) |s| {
        const next = byteAt(doc, s.head);
        const next_ok = next == null or isWs(next.?) or next.? == '\n' or
            isCloser(next.?) or next.? == ',' or next.? == ';' or next.? == ':';
        if (!next_ok) return .not_handled;
        if (isQuote(ch)) {
            // A quote next to a word character is an apostrophe or a
            // string continuation, not a new pair; a quote inside a
            // string or comment (per the grammar) is content.
            if (s.head > 0) {
                const prev = byteAt(doc, s.head - 1);
                if (prev != null and (isWordByte(prev.?) or prev.? == ch)) return .not_handled;
            }
            if (!gate.codeAt(s.head)) return .not_handled;
        }
    }
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const pair = try a.dupe(u8, &.{ ch, close });
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);
    for (sels.sels.items) |s| try tx.addInsert(alloc, s.head, pair);
    _ = try doc.applyTransactionSel(&tx, vm.snapshotOf(sels));
    // Caret between the pair: own insert contributes 1, earlier ones 2.
    var shift: usize = 0;
    for (sels.sels.items) |*s| {
        s.head = s.head + shift + 1;
        s.anchor = s.head;
        shift += 2;
    }
    sels.normalize();
    return .inserted_pair;
}

/// Backspace between an empty pair deletes both halves — for every
/// caret, or not at all.
pub fn backspacePair(alloc: Allocator, doc: *Document, sels: *SelectionSet) !bool {
    if (sels.sels.items.len == 0) return false;
    for (sels.sels.items) |s| {
        if (!s.isCaret() or s.head == 0) return false;
        const prev = byteAt(doc, s.head - 1) orelse return false;
        const close = closingOf(prev) orelse return false;
        if (byteAt(doc, s.head) != close) return false;
    }
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);
    var prev_end: usize = 0;
    for (sels.sels.items) |s| {
        if (s.head - 1 < prev_end) continue;
        prev_end = s.head + 1;
        try tx.addDelete(alloc, s.head - 1, 2);
    }
    try applyMapped(alloc, doc, sels, &tx);
    return true;
}

/// Backspace in leading whitespace retreats to the previous tab stop
/// (space-indented lines only — a tab already deletes as one unit).
/// Returns false when NO caret qualifies; carets that do not qualify
/// keep the ordinary one-grapheme delete inside the same transaction.
pub fn smartBackspace(alloc: Allocator, doc: *Document, sels: *SelectionSet, width: usize) !bool {
    if (sels.sels.items.len == 0) return false;
    const w = @max(1, width);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var any = false;
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);
    var prev_end: usize = 0;
    for (sels.sels.items) |s| {
        var start: usize = undefined;
        var end: usize = undefined;
        if (!s.isCaret()) {
            start = s.start();
            end = s.end();
        } else {
            const lb = vm.lineBoundsAt(doc, s.head);
            const col = s.head - lb.start;
            var all_spaces = col > 0;
            if (col > 0) {
                const prefix = try doc.rope.sliceAlloc(a, lb.start, s.head);
                for (prefix) |b| {
                    if (b != ' ') {
                        all_spaces = false;
                        break;
                    }
                }
            }
            if (all_spaces) {
                const target = ((col - 1) / w) * w;
                start = lb.start + target;
                end = s.head;
                any = true;
            } else {
                start = vm.prevPos(alloc, doc, s.head, false);
                end = s.head;
            }
        }
        if (start < prev_end) start = prev_end;
        if (end <= start) continue;
        prev_end = end;
        try tx.addDelete(alloc, start, end - start);
    }
    if (!any) return false;
    try applyMapped(alloc, doc, sels, &tx);
    return true;
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

fn docOf(text: []const u8) !Document {
    return try Document.initFromBytes(testing.allocator, text);
}

fn expectText(doc: *const Document, expected: []const u8) !void {
    const got = try doc.textAlloc(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "commands registry round trip" {
    inline for (@typeInfo(Command).@"enum".fields) |f| {
        const cmd: Command = @enumFromInt(f.value);
        try testing.expectEqual(cmd, fromName(name(cmd)).?);
        try testing.expect(label(cmd).len > 0);
        try testing.expect(describe(cmd).len > 0);
        // An empty default is a palette-only command; a chord, when
        // there is one, belongs to exactly one command.
        const accel = defaultAccel(cmd);
        if (accel.len > 0) {
            for (0..COMMAND_COUNT) |j| {
                const other: Command = @enumFromInt(j);
                if (other != cmd) try testing.expect(!std.mem.eql(u8, accel, defaultAccel(other)));
            }
        }
    }
    try testing.expect(fromName("no_such_command") == null);
    // Every indentation command either overrides or clears.
    try testing.expect(indentOverrideOf(.indent_use_tabs).?.style.? == .tabs);
    try testing.expect(indentOverrideOf(.indent_width_8).?.width.? == 8);
    try testing.expect(indentOverrideOf(.indent_auto) == null);
    try testing.expect(indentOverrideOf(.join_lines) == null);
}

test "commands duplicate line down moves caret to the copy" {
    const a = testing.allocator;
    var doc = try docOf("aaa\nbbb\nccc");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(5)); // in bbb
    defer sels.deinit(a);
    try duplicate(a, &doc, &sels, true);
    try expectText(&doc, "aaa\nbbb\nbbb\nccc");
    try testing.expectEqual(@as(usize, 9), sels.primary().head); // lower copy
    try vm.undo(a, &doc, &sels);
    try expectText(&doc, "aaa\nbbb\nccc");
    try testing.expectEqual(@as(usize, 5), sels.primary().head);
}

test "commands duplicate line up keeps caret on the upper copy" {
    const a = testing.allocator;
    var doc = try docOf("aaa\nbbb");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(1));
    defer sels.deinit(a);
    try duplicate(a, &doc, &sels, false);
    try expectText(&doc, "aaa\naaa\nbbb");
    try testing.expectEqual(@as(usize, 1), sels.primary().head);
}

test "commands duplicate three carets on three lines is one undo unit" {
    const a = testing.allocator;
    var doc = try docOf("a\nb\nc");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(0));
    defer sels.deinit(a);
    try sels.add(a, Selection.caret(2));
    try sels.add(a, Selection.caret(4));
    try duplicate(a, &doc, &sels, true);
    try expectText(&doc, "a\na\nb\nb\nc\nc");
    try testing.expectEqual(@as(usize, 3), sels.count());
    try vm.undo(a, &doc, &sels);
    try expectText(&doc, "a\nb\nc");
    try testing.expectEqual(@as(usize, 3), sels.count());
}

test "commands duplicate two carets on one line duplicates it once" {
    const a = testing.allocator;
    var doc = try docOf("hello");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(1));
    defer sels.deinit(a);
    try sels.add(a, Selection.caret(3));
    try duplicate(a, &doc, &sels, true);
    try expectText(&doc, "hello\nhello");
}

test "commands duplicate selection duplicates the text" {
    const a = testing.allocator;
    var doc = try docOf("abc def");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 0, .head = 3 });
    defer sels.deinit(a);
    try duplicate(a, &doc, &sels, true);
    try expectText(&doc, "abcabc def");
    // Selection rides the lower/second copy.
    try testing.expectEqual(@as(usize, 3), sels.primary().start());
    try testing.expectEqual(@as(usize, 6), sels.primary().end());
}

test "commands move line down and back up" {
    const a = testing.allocator;
    var doc = try docOf("one\ntwo\nthree");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(1)); // on "one"
    defer sels.deinit(a);
    try moveLines(a, &doc, &sels, true);
    try expectText(&doc, "two\none\nthree");
    try testing.expectEqual(@as(usize, 5), sels.primary().head); // still in "one"
    try moveLines(a, &doc, &sels, false);
    try expectText(&doc, "one\ntwo\nthree");
    try testing.expectEqual(@as(usize, 1), sels.primary().head);
}

test "commands move line at the edge is a no-op" {
    const a = testing.allocator;
    var doc = try docOf("one\ntwo");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(0));
    defer sels.deinit(a);
    try moveLines(a, &doc, &sels, false);
    try expectText(&doc, "one\ntwo");
    try testing.expect(!doc.canUndo());
}

test "commands move multi-line selection block down over last line" {
    const a = testing.allocator;
    var doc = try docOf("a\nb\nc\nd");
    defer doc.deinit();
    // Select lines b and c.
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 2, .head = 5 });
    defer sels.deinit(a);
    try moveLines(a, &doc, &sels, true);
    try expectText(&doc, "a\nd\nb\nc");
    // One undo restores text and selection.
    try vm.undo(a, &doc, &sels);
    try expectText(&doc, "a\nb\nc\nd");
    try testing.expectEqual(@as(usize, 2), sels.primary().start());
}

test "commands move two carets in adjacent lines merge into one block" {
    const a = testing.allocator;
    var doc = try docOf("a\nb\nc");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(0));
    defer sels.deinit(a);
    try sels.add(a, Selection.caret(2));
    try moveLines(a, &doc, &sels, true);
    try expectText(&doc, "c\na\nb");
}

test "commands join lines collapses next line's indent to one space" {
    const a = testing.allocator;
    var doc = try docOf("foo\n    bar\nbaz");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(1));
    defer sels.deinit(a);
    try joinLines(a, &doc, &sels);
    try expectText(&doc, "foo bar\nbaz");
    try vm.undo(a, &doc, &sels);
    try expectText(&doc, "foo\n    bar\nbaz");
}

test "commands join range joins every covered newline" {
    const a = testing.allocator;
    var doc = try docOf("a\nb\nc\nd");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 0, .head = 5 }); // a..c
    defer sels.deinit(a);
    try joinLines(a, &doc, &sels);
    try expectText(&doc, "a b c\nd");
}

test "commands join with empty neighbour adds no space" {
    const a = testing.allocator;
    var doc = try docOf("a\n\nb");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(0));
    defer sels.deinit(a);
    try joinLines(a, &doc, &sels);
    try expectText(&doc, "a\nb");
}

test "commands sort selected lines" {
    const a = testing.allocator;
    var doc = try docOf("pear\napple\nzebra\nmango");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 0, .head = 16 }); // pear..zebra
    defer sels.deinit(a);
    try sortLines(a, &doc, &sels);
    try expectText(&doc, "apple\npear\nzebra\nmango");
    // Selection covers the sorted block.
    try testing.expectEqual(@as(usize, 0), sels.primary().start());
    try testing.expectEqual(@as(usize, 16), sels.primary().end());
    try vm.undo(a, &doc, &sels);
    try expectText(&doc, "pear\napple\nzebra\nmango");
}

test "commands toggle comment comments and uncomments" {
    const a = testing.allocator;
    var doc = try docOf("one\n  two\nthree");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 0, .head = 14 });
    defer sels.deinit(a);
    try testing.expectEqual(CommentResult.commented, try toggleComment(a, &doc, &sels, .{ .open = "//" }));
    try expectText(&doc, "// one\n  // two\n// three");
    try testing.expectEqual(CommentResult.uncommented, try toggleComment(a, &doc, &sels, .{ .open = "//" }));
    try expectText(&doc, "one\n  two\nthree");
}

test "commands toggle comment mixed selection comments everything" {
    const a = testing.allocator;
    var doc = try docOf("// one\ntwo");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 0, .head = 10 });
    defer sels.deinit(a);
    try testing.expectEqual(CommentResult.commented, try toggleComment(a, &doc, &sels, .{ .open = "//" }));
    try expectText(&doc, "// // one\n// two");
}

test "commands toggle comment skips blank lines and multi-caret dedupes" {
    const a = testing.allocator;
    var doc = try docOf("one\n\ntwo");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(0));
    defer sels.deinit(a);
    try sels.add(a, Selection.caret(2)); // same line
    try sels.add(a, Selection.caret(6)); // "two"
    _ = try toggleComment(a, &doc, &sels, .{ .open = "#" });
    try expectText(&doc, "# one\n\n# two");
    try vm.undo(a, &doc, &sels);
    try expectText(&doc, "one\n\ntwo");
    try testing.expectEqual(@as(usize, 3), sels.count());
}

test "commands toggle comment wraps each line in a block pair" {
    const a = testing.allocator;
    var doc = try docOf("a { x: 1; }\n  b { }\n");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 0, .head = 17 });
    defer sels.deinit(a);
    const css = CommentTokens{ .open = "/*", .close = "*/" };
    try testing.expectEqual(CommentResult.commented, try toggleComment(a, &doc, &sels, css));
    try expectText(&doc, "/* a { x: 1; } */\n  /* b { } */\n");
    try testing.expectEqual(CommentResult.uncommented, try toggleComment(a, &doc, &sels, css));
    try expectText(&doc, "a { x: 1; }\n  b { }\n");
    // A tight wrap without spaces uncomments too.
    var tight = try docOf("<!--x-->");
    defer tight.deinit();
    var s2 = try SelectionSet.initSingle(a, Selection.caret(0));
    defer s2.deinit(a);
    try testing.expectEqual(CommentResult.uncommented, try toggleComment(a, &tight, &s2, .{ .open = "<!--", .close = "-->" }));
    try expectText(&tight, "x");
}

test "commands toggle comment on blank-only selection reports no_lines" {
    const a = testing.allocator;
    var doc = try docOf("\n\n");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(0));
    defer sels.deinit(a);
    try testing.expectEqual(CommentResult.no_lines, try toggleComment(a, &doc, &sels, .{ .open = "//" }));
}

test "commands indent and dedent respect width and spaces" {
    const a = testing.allocator;
    var doc = try docOf("one\ntwo");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 0, .head = 7 });
    defer sels.deinit(a);
    try indentLines(a, &doc, &sels, 2, true);
    try expectText(&doc, "  one\n  two");
    try dedentLines(a, &doc, &sels, 2);
    try expectText(&doc, "one\ntwo");
    try indentLines(a, &doc, &sels, 4, false);
    try expectText(&doc, "\tone\n\ttwo");
    try dedentLines(a, &doc, &sels, 4);
    try expectText(&doc, "one\ntwo");
}

test "commands dedent removes partial indents" {
    const a = testing.allocator;
    var doc = try docOf("   x\n y");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 0, .head = 7 });
    defer sels.deinit(a);
    try dedentLines(a, &doc, &sels, 4);
    try expectText(&doc, "x\ny");
}

test "commands indent multi-caret one undo unit" {
    const a = testing.allocator;
    var doc = try docOf("a\nb\nc");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(0));
    defer sels.deinit(a);
    try sels.add(a, Selection.caret(4));
    try indentLines(a, &doc, &sels, 4, true);
    try expectText(&doc, "    a\nb\n    c");
    try vm.undo(a, &doc, &sels);
    try expectText(&doc, "a\nb\nc");
}

test "commands trim trailing whitespace" {
    const a = testing.allocator;
    var doc = try docOf("one  \ntwo\t\nthree");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(4));
    defer sels.deinit(a);
    try trimTrailingWhitespace(a, &doc, &sels);
    try expectText(&doc, "one\ntwo\nthree");
    try testing.expectEqual(@as(usize, 3), sels.primary().head);
    try vm.undo(a, &doc, &sels);
    try expectText(&doc, "one  \ntwo\t\nthree");
}

test "commands case conversion on selections and words" {
    const a = testing.allocator;
    var doc = try docOf("hello world");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 0, .head = 5 });
    defer sels.deinit(a);
    try changeCase(a, &doc, &sels, .upper);
    try expectText(&doc, "HELLO world");
    // Selection still covers the word.
    try testing.expectEqual(@as(usize, 5), sels.primary().end());
    try changeCase(a, &doc, &sels, .lower);
    try expectText(&doc, "hello world");

    // Caret only: acts on the word under it.
    sels.sels.items[0] = Selection.caret(8);
    try changeCase(a, &doc, &sels, .title);
    try expectText(&doc, "hello World");
}

test "commands title case over multiple words" {
    const a = testing.allocator;
    var doc = try docOf("foo bar_baz qux");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 0, .head = 15 });
    defer sels.deinit(a);
    try changeCase(a, &doc, &sels, .title);
    try expectText(&doc, "Foo Bar_baz Qux");
}

test "commands case conversion keeps UTF-8 untouched" {
    const a = testing.allocator;
    var doc = try docOf("caf\u{e9} time");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 0, .head = 5 });
    defer sels.deinit(a);
    try changeCase(a, &doc, &sels, .upper);
    try expectText(&doc, "CAF\u{e9} time");
}

test "commands select next occurrence grows word then adds matches" {
    const a = testing.allocator;
    var doc = try docOf("foo bar foo baz foo");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(1));
    defer sels.deinit(a);
    try testing.expect(try selectNextOccurrence(a, &doc, &sels));
    try testing.expectEqual(@as(usize, 1), sels.count());
    try testing.expectEqual(@as(usize, 0), sels.primary().start());
    try testing.expectEqual(@as(usize, 3), sels.primary().end());
    try testing.expect(try selectNextOccurrence(a, &doc, &sels));
    try testing.expectEqual(@as(usize, 2), sels.count());
    try testing.expectEqual(@as(usize, 8), sels.primary().start());
    try testing.expect(try selectNextOccurrence(a, &doc, &sels));
    try testing.expectEqual(@as(usize, 3), sels.count());
    // All matches taken: another call finds nothing new.
    try testing.expect(!try selectNextOccurrence(a, &doc, &sels));
}

test "commands select next occurrence wraps" {
    const a = testing.allocator;
    var doc = try docOf("aa bb aa");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 6, .head = 8 });
    defer sels.deinit(a);
    try testing.expect(try selectNextOccurrence(a, &doc, &sels));
    try testing.expectEqual(@as(usize, 2), sels.count());
    try testing.expectEqual(@as(usize, 0), sels.sels.items[0].start());
}

test "commands skip occurrence moves to the next match" {
    const a = testing.allocator;
    var doc = try docOf("x1 x2 x3");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 0, .head = 1 }); // "x"
    defer sels.deinit(a);
    try testing.expect(try selectNextOccurrence(a, &doc, &sels)); // adds x at 3
    try testing.expect(try skipOccurrence(a, &doc, &sels)); // skip -> x at 6
    try testing.expectEqual(@as(usize, 2), sels.count());
    try testing.expectEqual(@as(usize, 6), sels.primary().start());
}

test "commands select all occurrences" {
    const a = testing.allocator;
    var doc = try docOf("ab ab ab");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(0));
    defer sels.deinit(a);
    try testing.expectEqual(@as(usize, 3), try selectAllOccurrences(a, &doc, &sels));
    try testing.expectEqual(@as(usize, 3), sels.count());
    // Typing over all three edits all three (one undo).
    try vm.insertText(a, &doc, &sels, "X");
    try expectText(&doc, "X X X");
    try vm.undo(a, &doc, &sels);
    try expectText(&doc, "ab ab ab");
}

test "commands add caret above/below clamps to short lines" {
    const a = testing.allocator;
    var doc = try docOf("long line\nab\nlonger line");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(7)); // col 7 line 0
    defer sels.deinit(a);
    try addCaretVertical(a, &doc, &sels, true);
    try testing.expectEqual(@as(usize, 2), sels.count());
    try testing.expectEqual(@as(usize, 12), sels.sels.items[1].head); // clamped to "ab" end
    try addCaretVertical(a, &doc, &sels, true);
    try testing.expectEqual(@as(usize, 3), sels.count());
    // At the last line, below adds nothing further.
    try addCaretVertical(a, &doc, &sels, true);
    try testing.expectEqual(@as(usize, 3), sels.count());
}

test "commands split selection into line carets" {
    const a = testing.allocator;
    var doc = try docOf("one\ntwo\nthree");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 0, .head = 13 });
    defer sels.deinit(a);
    try splitSelectionIntoLines(a, &doc, &sels);
    try testing.expectEqual(@as(usize, 3), sels.count());
    try testing.expectEqual(@as(usize, 3), sels.sels.items[0].head);
    try testing.expectEqual(@as(usize, 7), sels.sels.items[1].head);
    try testing.expectEqual(@as(usize, 13), sels.sels.items[2].head);
    for (sels.sels.items) |s| try testing.expect(s.isCaret());
}

test "commands block selection clamps and skips virtual space" {
    const a = testing.allocator;
    var doc = try docOf("alpha\nhi\ngamma");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(0));
    defer sels.deinit(a);
    try blockSelection(a, &doc, &sels, 0, 1, 2, 4);
    try testing.expectEqual(@as(usize, 3), sels.count());
    // Line 0: cols 1..4.
    try testing.expectEqual(@as(usize, 1), sels.sels.items[0].start());
    try testing.expectEqual(@as(usize, 4), sels.sels.items[0].end());
    // Line 1 ("hi", len 2): cols clamp to the content -> [7, 8).
    try testing.expectEqual(@as(usize, 7), sels.sels.items[1].start());
    try testing.expectEqual(@as(usize, 8), sels.sels.items[1].end());
    // Line 2: cols 1..4 within "gamma".
    try testing.expectEqual(@as(usize, 10), sels.sels.items[2].start());
    try testing.expectEqual(@as(usize, 13), sels.sels.items[2].end());
}

test "commands newline auto-indent copies, deepens, and wraps closer" {
    const a = testing.allocator;
    const opts: IndentOpts = .{ .width = 4, .spaces = true, .auto_indent = true };

    // Plain copy.
    var doc = try docOf("  code");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(6));
    defer sels.deinit(a);
    try newlineAutoIndent(a, &doc, &sels, opts);
    try expectText(&doc, "  code\n  ");
    try testing.expectEqual(@as(usize, 9), sels.primary().head);

    // Deepen after an opener.
    var doc2 = try docOf("if {");
    defer doc2.deinit();
    var sels2 = try SelectionSet.initSingle(a, Selection.caret(4));
    defer sels2.deinit(a);
    try newlineAutoIndent(a, &doc2, &sels2, opts);
    try expectText(&doc2, "if {\n    ");
    try testing.expectEqual(@as(usize, 9), sels2.primary().head);

    // Split "{|}" onto three lines, caret on the indented middle.
    var doc3 = try docOf("  f() {}");
    defer doc3.deinit();
    var sels3 = try SelectionSet.initSingle(a, Selection.caret(7));
    defer sels3.deinit(a);
    try newlineAutoIndent(a, &doc3, &sels3, opts);
    try expectText(&doc3, "  f() {\n      \n  }");
    try testing.expectEqual(@as(usize, 14), sels3.primary().head);
    // One undo restores everything.
    try vm.undo(a, &doc3, &sels3);
    try expectText(&doc3, "  f() {}");
}

test "commands newline auto-indent multi-caret" {
    const a = testing.allocator;
    const opts: IndentOpts = .{ .width = 2, .spaces = true, .auto_indent = true };
    var doc = try docOf("a {\nb {");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(3));
    defer sels.deinit(a);
    try sels.add(a, Selection.caret(7));
    try newlineAutoIndent(a, &doc, &sels, opts);
    try expectText(&doc, "a {\n  \nb {\n  ");
    try testing.expectEqual(@as(usize, 2), sels.count());
    try testing.expectEqual(@as(usize, 6), sels.sels.items[0].head);
    try testing.expectEqual(@as(usize, 13), sels.sels.items[1].head);
    try vm.undo(a, &doc, &sels);
    try expectText(&doc, "a {\nb {");
}

test "commands auto-close inserts pair with caret inside" {
    const a = testing.allocator;
    var doc = try docOf("f");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(1));
    defer sels.deinit(a);
    try testing.expectEqual(AutoCloseResult.inserted_pair, try autoClose(a, &doc, &sels, '(', .{}));
    try expectText(&doc, "f()");
    try testing.expectEqual(@as(usize, 2), sels.primary().head);
    // Typing the closer types over instead of doubling.
    try testing.expectEqual(AutoCloseResult.typed_over, try autoClose(a, &doc, &sels, ')', .{}));
    try expectText(&doc, "f()");
    try testing.expectEqual(@as(usize, 3), sels.primary().head);
}

test "commands auto-close declines before a word character" {
    const a = testing.allocator;
    var doc = try docOf("word");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(0));
    defer sels.deinit(a);
    try testing.expectEqual(AutoCloseResult.not_handled, try autoClose(a, &doc, &sels, '(', .{}));
    try expectText(&doc, "word");
}

test "commands auto-close quote declines after a word character" {
    const a = testing.allocator;
    var doc = try docOf("it");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(2));
    defer sels.deinit(a);
    // Apostrophe after "it" must not become a pair.
    try testing.expectEqual(AutoCloseResult.not_handled, try autoClose(a, &doc, &sels, '\'', .{}));
}

test "commands auto-close quote respects the syntax gate" {
    const a = testing.allocator;
    var doc = try docOf("x = ");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(4));
    defer sels.deinit(a);
    const gate = Gate{
        .ctx = null,
        .is_code = struct {
            fn f(_: ?*anyopaque, _: usize) bool {
                return false; // "inside a string/comment"
            }
        }.f,
    };
    try testing.expectEqual(AutoCloseResult.not_handled, try autoClose(a, &doc, &sels, '"', gate));
    try testing.expectEqual(AutoCloseResult.inserted_pair, try autoClose(a, &doc, &sels, '"', .{}));
    try expectText(&doc, "x = \"\"");
}

test "commands auto-close surrounds a selection" {
    const a = testing.allocator;
    var doc = try docOf("hello world");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 0, .head = 5 });
    defer sels.deinit(a);
    try sels.add(a, .{ .anchor = 6, .head = 11 });
    try testing.expectEqual(AutoCloseResult.surrounded, try autoClose(a, &doc, &sels, '[', .{}));
    try expectText(&doc, "[hello] [world]");
    // Selections still cover the words.
    try testing.expectEqual(@as(usize, 1), sels.sels.items[0].start());
    try testing.expectEqual(@as(usize, 6), sels.sels.items[0].end());
    try testing.expectEqual(@as(usize, 9), sels.sels.items[1].start());
    try testing.expectEqual(@as(usize, 14), sels.sels.items[1].end());
    try vm.undo(a, &doc, &sels);
    try expectText(&doc, "hello world");
}

test "commands auto-close multi-caret all-or-nothing" {
    const a = testing.allocator;
    var doc = try docOf(" \nword");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(0));
    defer sels.deinit(a);
    try sels.add(a, Selection.caret(2)); // before "word": would fight
    try testing.expectEqual(AutoCloseResult.not_handled, try autoClose(a, &doc, &sels, '(', .{}));
    // Both in the clear: pair at every caret, carets inside.
    var doc2 = try docOf("x \ny ");
    defer doc2.deinit();
    var sels2 = try SelectionSet.initSingle(a, Selection.caret(2));
    defer sels2.deinit(a);
    try sels2.add(a, Selection.caret(5));
    try testing.expectEqual(AutoCloseResult.inserted_pair, try autoClose(a, &doc2, &sels2, '{', .{}));
    try expectText(&doc2, "x {}\ny {}");
    try testing.expectEqual(@as(usize, 3), sels2.sels.items[0].head);
    try testing.expectEqual(@as(usize, 8), sels2.sels.items[1].head);
    try vm.undo(a, &doc2, &sels2);
    try expectText(&doc2, "x \ny ");
}

test "commands type-over multi-caret requires every caret to agree" {
    const a = testing.allocator;
    var doc = try docOf("()\n(x");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(1));
    defer sels.deinit(a);
    try sels.add(a, Selection.caret(4)); // next char is 'x', not ')'
    try testing.expectEqual(AutoCloseResult.not_handled, try autoClose(a, &doc, &sels, ')', .{}));
}

test "commands backspace deletes an empty pair" {
    const a = testing.allocator;
    var doc = try docOf("f()");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(2));
    defer sels.deinit(a);
    try testing.expect(try backspacePair(a, &doc, &sels));
    try expectText(&doc, "f");
    try testing.expectEqual(@as(usize, 1), sels.primary().head);
    // Not between a pair: declined.
    var doc2 = try docOf("ab");
    defer doc2.deinit();
    var sels2 = try SelectionSet.initSingle(a, Selection.caret(1));
    defer sels2.deinit(a);
    try testing.expect(!try backspacePair(a, &doc2, &sels2));
}

test "commands smart backspace retreats one tab stop" {
    const a = testing.allocator;
    var doc = try docOf("      x");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(6));
    defer sels.deinit(a);
    try testing.expect(try smartBackspace(a, &doc, &sels, 4));
    try expectText(&doc, "    x");
    try testing.expectEqual(@as(usize, 4), sels.primary().head);
    try testing.expect(try smartBackspace(a, &doc, &sels, 4));
    try expectText(&doc, "x");
}

test "commands smart backspace declines outside leading whitespace" {
    const a = testing.allocator;
    var doc = try docOf("  ab");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(4));
    defer sels.deinit(a);
    try testing.expect(!try smartBackspace(a, &doc, &sels, 4));
    try expectText(&doc, "  ab");
}

test "commands smart backspace mixed carets in one transaction" {
    const a = testing.allocator;
    var doc = try docOf("    a\nxy");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(4)); // leading ws
    defer sels.deinit(a);
    try sels.add(a, Selection.caret(8)); // after "xy"
    try testing.expect(try smartBackspace(a, &doc, &sels, 4));
    try expectText(&doc, "a\nx");
    try vm.undo(a, &doc, &sels);
    try expectText(&doc, "    a\nxy");
}
