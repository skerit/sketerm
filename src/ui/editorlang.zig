//! The editor face's side of per-document language facts
//! (`editor/doclang.zig`): reading `.editorconfig` through the daemon
//! file service, pushing the effective indentation into a tab's layout,
//! the status-line fragment, the per-tab indentation commands, the
//! save-time `.editorconfig` rules, and the `editor-lang` control-socket
//! answer the smoke rig asserts through.
//!
//! The models are GTK-free and unit-tested; this file only wires them to
//! the view, so every call site in `editorview.zig` stays one line.

const std = @import("std");
const c = @import("../c.zig").c;
const ev = @import("editorview.zig");
const EditorView = ev.EditorView;
const ETab = ev.ETab;
const fsdrive = @import("../ipc/fsdrive.zig");
const editorconfig = @import("../editor/editorconfig.zig");
const indentation = @import("../editor/indentation.zig");
const ecmd = @import("../editor/commands.zig");
const syntax = @import("../editor/syntax.zig");

/// Read every `.editorconfig` above `path` in ONE pipelined round trip
/// on `fs` and resolve `path`'s properties. Runs on an IO thread; the
/// GUI never reads the disk, local or remote.
pub fn readEditorconfig(fs: *fsdrive.Fs, path: []const u8) editorconfig.Props {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cands = editorconfig.candidates(a, path) catch return .{};
    const reqs = a.alloc(?u32, cands.len) catch return .{};
    for (cands, 0..) |p, i| reqs[i] = fs.readSubmit(p, 0, editorconfig.MAX_FILE_BYTES) catch null;
    var found: std.ArrayList(editorconfig.Found) = .empty;
    for (cands, 0..) |p, i| {
        const req = reqs[i] orelse continue;
        var op = fs.awaitSubmitted(req, fsdrive.OP_TIMEOUT_MS) catch |err| {
            // A missing file is an ordinary failed op; a dead or slow
            // link must not leave half the reads queued on the
            // connection the document read is about to use.
            if (err == fsdrive.Error.FsOpFailed) continue;
            fs.cancelSubmitted();
            break;
        };
        defer op.data.deinit(fs.allocator);
        const text = a.dupe(u8, op.data.items) catch continue;
        found.append(a, .{ .dir = editorconfig.dirOf(p), .text = text }) catch continue;
    }
    return editorconfig.resolve(found.items, path);
}

/// Adopt a freshly loaded (or created) document's `.editorconfig`
/// properties and content-detected indentation.
pub fn onLoaded(view: *EditorView, tab: *ETab, props: editorconfig.Props) void {
    tab.language.loaded(&tab.doc, props);
    syncIndent(view, tab);
}

/// Push the tab's effective tab width into its layout and repaint.
pub fn syncIndent(view: *EditorView, tab: *ETab) void {
    const w = tab.language.indent.tab_width;
    if (tab.layout.tab_cols != w) {
        tab.layout.tab_cols = w;
        tab.layout.invalidateAll();
        // Wrapped-row estimates were made at the old width.
        tab.rows_lines = 0;
    }
    view.updateStatus();
    view.queueRender();
}

/// Language and indentation for the status line ("Python, Spaces: 4
/// (detected)"), empty while nothing is loaded.
pub fn statusFragment(tab: *const ETab, buf: []u8) []const u8 {
    var ibuf: [64]u8 = undefined;
    const name = if (tab.language.lang) |l| l.displayName() else "Plain Text";
    return std.fmt.bufPrint(buf, "  —  {s}, {s}", .{ name, tab.language.indent.describe(&ibuf) }) catch "";
}

/// Toggle-comment tokens for `tab`, or the status message explaining
/// why there are none.
pub fn commentTokens(tab: *ETab) union(enum) { tokens: ecmd.CommentTokens, none: [*:0]const u8 } {
    if (tab.language.commentTokens()) |t| return .{ .tokens = t };
    return .{ .none = if (tab.language.lang == null)
        "No known language for this file — no comment syntax."
    else
        "This language has no comment syntax." };
}

/// The per-tab indentation commands.
pub fn runIndentCommand(view: *EditorView, tab: *ETab, cmd: ecmd.Command) void {
    if (ecmd.indentOverrideOf(cmd)) |delta| {
        tab.language.applyOverride(delta);
    } else {
        tab.language.resetIndent(&tab.doc);
    }
    syncIndent(view, tab);
    var buf: [96]u8 = undefined;
    var ibuf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Indentation: {s}", .{tab.language.indent.describe(&ibuf)}) catch return;
    view.postStatus(msg);
}

/// Apply the save-time `.editorconfig` rules as one undo step before a
/// save snapshots the buffer.
pub fn beforeSave(view: *EditorView, tab: *ETab) void {
    const changed = tab.language.applySaveRules(&tab.doc, &tab.sels) catch false;
    if (changed) view.afterExternalEdit(tab);
}

// ======================================================================
// Control socket: `editor-lang`
// ======================================================================

pub const Info = struct {
    language: []const u8,
    lsp_id: []const u8,
    grammar: bool,
    /// A highlighter is attached and current.
    highlighted: bool,
    indent_style: []const u8,
    indent_size: u16,
    tab_width: u16,
    indent_source: []const u8,
    comment_open: []const u8,
    comment_close: []const u8,
    /// Kind at `offset` (the request's `data`), when one was asked for.
    kind_at: []const u8 = "",
    /// The bracket pair the caret machinery finds at `offset`.
    pair_open: ?usize = null,
    pair_close: ?usize = null,
    /// The status line as painted.
    status: []const u8 = "",
};

/// The active tab's language facts; `data` is an optional byte offset
/// to report the highlight kind and bracket pair at.
pub fn inspect(view: *EditorView, data: ?[]const u8) ?Info {
    const tab = view.activeTab() orelse return null;
    if (tab.loading) return null;
    const dl = &tab.language;
    const tokens = dl.commentTokens();
    var info = Info{
        .language = if (dl.lang) |l| l.displayName() else "",
        .lsp_id = dl.lspId(),
        .grammar = dl.grammarLang() != null,
        .highlighted = if (tab.hl) |hl| !hl.isStale(&tab.doc) else false,
        .indent_style = @tagName(dl.indent.style),
        .indent_size = dl.indent.size,
        .tab_width = dl.indent.tab_width,
        .indent_source = @tagName(dl.indent.source),
        .comment_open = if (tokens) |t| t.open else "",
        .comment_close = if (tokens) |t| t.close else "",
    };
    if (!view.widgets_dead) {
        if (c.gtk_label_get_text(view.status_label)) |txt| info.status = std.mem.span(txt);
    }
    const off_text = data orelse return info;
    const offset = std.fmt.parseInt(usize, std.mem.trim(u8, off_text, " "), 10) catch return info;
    if (offset >= tab.doc.rope.len()) return info;
    if (tab.hl) |hl| {
        if (hl.kindAt(&tab.doc, offset)) |k| {
            info.kind_at = kindName(k);
        } else |_| {}
    }
    if (view.bracketPairAt(tab, offset)) |p| {
        info.pair_open = p.open.start;
        info.pair_close = p.close.start;
    }
    return info;
}

fn kindName(k: syntax.Kind) []const u8 {
    const base = syntax.baseKind(k);
    inline for (@typeInfo(syntax.Kind).@"enum".fields) |f| {
        if (@intFromEnum(base) == f.value) return f.name;
    }
    return "none";
}
