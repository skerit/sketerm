//! The symbol outline panel.
//!
//! The model is `editor/outline.zig` (GTK-free, unit-tested); this file
//! is the panel, the two fill paths and the caret tracking.
//!
//! ## Which source answers
//!
//! A language server's `textDocument/documentSymbol` wins whenever one
//! is attached and advertises the capability, because it knows things
//! no grammar does. Otherwise the Tree-sitter tree the highlighter
//! already keeps answers. There is no third source and no synthetic
//! "outline parser": a file with neither a server nor a grammar simply
//! shows an empty panel that says so.
//!
//! The LSP reply is asynchronous, so the tree answer is filled in FIRST
//! and replaced when (if) the server answers. That is what stops the
//! panel from being blank for the first second of every file.
//!
//! ## Why it does not flicker
//!
//! Rows are rebuilt only when `Outline.signature()` — a hash of names,
//! kinds and depths, NOT of ranges — changes. Typing inside a function
//! body changes every range and no name, so the list stays put while
//! the ranges are carried through the edit by `Outline.mapThrough`
//! (ETab's shared document observer). Caret tracking then only moves
//! the SELECTION, which is why following the caret costs nothing.
//!
//! Ctrl+Shift+O opens it. That chord used to raise a transient
//! document-symbol popup; the panel is the same data in a form you can
//! keep open, so the popup path now only serves workspace symbols
//! (Ctrl+T).

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const ev = @import("editorview.zig");
const EditorView = ev.EditorView;
const ETab = ev.ETab;
const outline_mod = @import("../editor/outline.zig");
const syntax = @import("../editor/syntax.zig");
const lsp_pos = @import("../lsp/position.zig");
const lsp_symbols = @import("../lsp/symbols.zig");

pub fn buildPanel(view: *EditorView) void {
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_visible(box, 0);
    c.gtk_widget_set_size_request(box, 220, -1);

    const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
    c.gtk_widget_add_css_class(row, "toolbar");
    const title = c.gtk_label_new("Outline");
    c.gtk_widget_add_css_class(title, "heading");
    c.gtk_widget_set_hexpand(title, 1);
    c.gtk_label_set_xalign(@ptrCast(title), 0);
    c.gtk_box_append(@ptrCast(row), title);
    const close = c.gtk_button_new_from_icon_name("window-close-symbolic");
    c.gtk_button_set_has_frame(@ptrCast(close), 0);
    _ = c.g_signal_connect_data(close, "clicked", @ptrCast(&onCloseClicked), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(row), close);
    c.gtk_box_append(@ptrCast(box), row);

    const status = c.gtk_label_new("");
    c.gtk_label_set_xalign(@ptrCast(status), 0);
    c.gtk_widget_add_css_class(status, "dim-label");
    c.gtk_widget_set_margin_start(status, 6);
    c.gtk_box_append(@ptrCast(box), status);
    view.outline_status = @ptrCast(@alignCast(status));

    const scroll = c.gtk_scrolled_window_new();
    c.gtk_widget_set_vexpand(scroll, 1);
    const list = c.gtk_list_box_new();
    c.gtk_list_box_set_selection_mode(@ptrCast(list), c.GTK_SELECTION_SINGLE);
    _ = c.g_signal_connect_data(list, "row-activated", @ptrCast(&onRowActivated), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_scrolled_window_set_child(@ptrCast(scroll), list);
    view.outline_list = list.?;
    c.gtk_box_append(@ptrCast(box), scroll);

    view.outline_panel = box.?;
}

pub fn setOpen(view: *EditorView, open: bool) void {
    view.outline_open = open;
    c.gtk_widget_set_visible(view.outline_panel, if (open) 1 else 0);
    if (open) {
        if (view.activeTab()) |tab| refresh(view, tab, true);
    } else view.focusFace();
}

pub fn toggle(view: *EditorView) void {
    setOpen(view, !view.outline_open);
}

/// Rebuild `tab`'s outline. Cheap and idempotent: with the panel closed
/// it does nothing at all, and with an unchanged revision it only
/// re-syncs the caret.
pub fn refresh(view: *EditorView, tab: *ETab, force: bool) void {
    if (!view.outline_open) return;
    if (!force and tab.outline_rev == tab.doc.revision and !tab.outline.isEmpty()) {
        syncCaret(view, tab);
        return;
    }
    fillFromTree(view, tab);
    requestLsp(view, tab);
    render(view, tab);
}

/// Fill from the Tree-sitter tree. Leaves an LSP-sourced outline alone
/// at the same revision: the server's answer is the better one.
fn fillFromTree(view: *EditorView, tab: *ETab) void {
    _ = view;
    const hl = tab.hl orelse {
        if (tab.outline.source != .lsp) tab.outline.clear();
        tab.outline_rev = tab.doc.revision;
        return;
    };
    const lang = tab.hl_lang orelse return;
    if (tab.outline.source == .lsp and tab.outline_rev == tab.doc.revision) return;
    outline_mod.fromTree(&tab.outline, hl, &tab.doc, lang) catch |err| {
        // Stale is normal (a debounced re-parse has not landed): keep
        // what we have rather than blanking the panel for one frame.
        if (err == syntax.Error.Stale) return;
        tab.outline.clear();
    };
    tab.outline_rev = tab.doc.revision;
}

fn requestLsp(view: *EditorView, tab: *ETab) void {
    if (tab.lsp == null) return;
    if (tab != view.activeTab()) return;
    const m = view.lsp orelse return;
    // Asked, never remembered: a "pending" flag has to be cleared on
    // every failure path there is (server death, tab detach, session
    // reset), and the one that was missed left the tab never asking a
    // language server again for the rest of its life.
    if (m.outlineRequestInFlight(tab)) return;
    _ = m.requestOutlineSymbols();
}

/// Fill from a `documentSymbol` reply, or ask again.
///
/// `reply_revision` is the revision the request was built against. A
/// reply for anything else describes lines that have moved, and filling
/// from it would stamp those wrong offsets as authoritative until the
/// next edit — so it is dropped and re-asked instead.
pub fn fillFromLsp(
    view: *EditorView,
    tab: *ETab,
    result: std.json.Value,
    enc: lsp_pos.Encoding,
    reply_revision: u64,
) void {
    lsp_symbols.fromLsp(&tab.outline, &tab.doc, result, enc, reply_revision) catch |err| {
        if (err == error.Stale) {
            // The tree answer already on screen stays; the fresh
            // request is the one that will replace it.
            requestLsp(view, tab);
            return;
        }
        lspFailed(view, tab);
        return;
    };
    tab.outline_rev = tab.doc.revision;
    render(view, tab);
}

/// The server answered, but with nothing usable: fall back to the tree
/// rather than showing an empty panel.
pub fn lspFailed(view: *EditorView, tab: *ETab) void {
    if (tab.outline.source == .lsp) tab.outline.clear();
    fillFromTree(view, tab);
    render(view, tab);
}

// ---- rendering --------------------------------------------------------

fn render(view: *EditorView, tab: *ETab) void {
    if (!view.outline_open) return;
    const sig = tab.outline.signature();
    if (sig != view.outline_sig) {
        view.outline_sig = sig;
        view.outline_row = null;
        rebuildRows(view, tab);
    }
    updateStatus(view, tab);
    syncCaret(view, tab);
}

/// Public entry for the view: the active document changed enough that
/// the panel should look again.
pub fn onDocumentChanged(view: *EditorView, tab: *ETab) void {
    if (!view.outline_open) return;
    refresh(view, tab, false);
}

/// Public entry for the view: only the caret moved.
pub fn onCaretMoved(view: *EditorView, tab: *ETab) void {
    if (!view.outline_open) return;
    syncCaret(view, tab);
}

fn rebuildRows(view: *EditorView, tab: *ETab) void {
    while (c.gtk_widget_get_first_child(view.outline_list)) |child| {
        c.gtk_list_box_remove(@ptrCast(view.outline_list), child);
    }
    for (tab.outline.nodes.items, 0..) |n, i| {
        var buf: [320:0]u8 = undefined;
        const detail = tab.outline.detail(i);
        const text = if (detail.len > 0)
            std.fmt.bufPrintZ(&buf, "{s}  {s}", .{ tab.outline.name(i), detail }) catch continue
        else
            std.fmt.bufPrintZ(&buf, "{s}", .{tab.outline.name(i)}) catch continue;
        const label = c.gtk_label_new(text.ptr);
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
        c.gtk_widget_set_margin_start(label, 4 + @as(c_int, @intCast(@min(n.depth, 8))) * 12);
        c.gtk_widget_set_tooltip_text(label, n.kind.tag().ptr);
        const row = c.gtk_list_box_row_new();
        c.gtk_list_box_row_set_child(@ptrCast(row), label);
        c.gtk_list_box_append(@ptrCast(view.outline_list), row);
    }
}

fn updateStatus(view: *EditorView, tab: *ETab) void {
    var buf: [160:0]u8 = undefined;
    const src = switch (tab.outline.source) {
        .lsp => "language server",
        .tree => "syntax tree",
        .none => "",
    };
    const z = if (tab.outline.isEmpty())
        std.fmt.bufPrintZ(&buf, "No symbols.", .{}) catch return
    else
        std.fmt.bufPrintZ(&buf, "{d} symbol(s) — {s}", .{ tab.outline.nodes.items.len, src }) catch return;
    c.gtk_label_set_text(view.outline_status, z.ptr);
}

/// Select the row for the deepest symbol containing the caret, without
/// rebuilding anything and without treating our own selection change as
/// a navigation request.
fn syncCaret(view: *EditorView, tab: *ETab) void {
    if (tab.outline.isEmpty()) return;
    const at = tab.sels.primary().head;
    const idx = tab.outline.indexAt(at);
    if (idx == null) {
        if (view.outline_row != null) {
            view.outline_row = null;
            view.outline_guard = true;
            c.gtk_list_box_unselect_all(@ptrCast(view.outline_list));
            view.outline_guard = false;
        }
        return;
    }
    if (view.outline_row != null and view.outline_row.? == idx.?) return;
    view.outline_row = idx;
    const row = c.gtk_list_box_get_row_at_index(@ptrCast(view.outline_list), @intCast(idx.?)) orelse return;
    view.outline_guard = true;
    c.gtk_list_box_select_row(@ptrCast(view.outline_list), row);
    view.outline_guard = false;
}

fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    const view = cast.userData(EditorView, user);
    if (view.outline_guard) return;
    const tab = view.activeTab() orelse return;
    const idx: usize = @intCast(c.gtk_list_box_row_get_index(row));
    if (idx >= tab.outline.nodes.items.len) return;
    const off = tab.outline.nodes.items[idx].sel;
    const lc = tab.doc.rope.offsetToLineCol(@min(off, tab.doc.rope.len()));
    view.gotoLineCol(tab, lc.line + 1, lc.col + 1);
    view.focusFace();
}

fn onCloseClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    setOpen(cast.userData(EditorView, user), false);
}
