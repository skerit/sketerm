//! The editor face's find / replace bar: a floating two-row bar over the
//! canvas (find always, replace in replace mode), per-tab match state,
//! stepping, and the two replace verbs.
//!
//! Replace All is `search.replaceAllIn`, the same definition the project
//! panel and the raw-file writer use (editor/search.zig documents the
//! semantics), so the three can no longer drift. The match state itself
//! (`ETab.matches`, `current_match`, `needle`) lives on the tab so that
//! switching tabs keeps each one's results.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const ev = @import("editorview.zig");
const EditorView = ev.EditorView;
const ETab = ev.ETab;
const findbar = @import("findbar.zig");
const input = @import("input.zig");
const search = @import("../editor/search.zig");
const vm = @import("../editor/view_model.zig");

/// Build the bar (hidden) and store its widgets on the view. The caller
/// adds `view.find_bar` to the canvas overlay.
pub fn build(view: *EditorView) void {
    const outer = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
    c.gtk_widget_add_css_class(outer, "toolbar");
    c.gtk_widget_add_css_class(outer, "osd");
    c.gtk_widget_set_halign(outer, c.GTK_ALIGN_END);
    c.gtk_widget_set_valign(outer, c.GTK_ALIGN_START);
    c.gtk_widget_set_margin_top(outer, 8);
    c.gtk_widget_set_margin_end(outer, 8);
    c.gtk_widget_set_visible(outer, 0);

    const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
    const parts = findbar.build(row, .{
        .placeholder = "Find",
        .width_chars = 22,
        .count_width_chars = 9,
        .regex_tooltip = "Regular expression. Replacements expand $1..$9 (and $0 for the whole match).",
    }, .{
        .ctx = @ptrCast(view),
        .on_changed = @ptrCast(&onFindChanged),
        .on_activate = @ptrCast(&onFindActivate),
        .on_stop = @ptrCast(&onFindStop),
        .on_toggle_changed = @ptrCast(&onFindOptionToggled),
    });
    view.find_entry = parts.entry;
    view.find_count = parts.count.?;
    view.find_case = parts.case_btn;
    view.find_word = parts.word_btn;
    view.find_regex = parts.regex_btn;
    _ = findbar.navButton(row, "go-up-symbolic", "Previous match (Shift+Enter)", @ptrCast(&onFindPrevClicked), @ptrCast(view));
    _ = findbar.navButton(row, "go-down-symbolic", "Next match (Enter)", @ptrCast(&onFindNextClicked), @ptrCast(view));
    _ = findbar.navButton(row, "window-close-symbolic", "Close (Escape)", @ptrCast(&onFindCloseClicked), @ptrCast(view));
    c.gtk_box_append(@ptrCast(outer), row);

    const rrow = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
    const rentry = c.gtk_entry_new();
    c.gtk_entry_set_placeholder_text(@ptrCast(rentry), "Replace with");
    c.gtk_editable_set_width_chars(@ptrCast(rentry), 22);
    _ = c.g_signal_connect_data(rentry, "activate", @ptrCast(&onReplaceActivate), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(rrow), rentry);
    view.replace_entry = rentry.?;
    const rbtn = c.gtk_button_new_with_label("Replace");
    _ = c.g_signal_connect_data(rbtn, "clicked", @ptrCast(&onReplaceClicked), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(rrow), rbtn);
    const abtn = c.gtk_button_new_with_label("All");
    c.gtk_widget_set_tooltip_text(abtn, "Replace every match (one undo step)");
    _ = c.g_signal_connect_data(abtn, "clicked", @ptrCast(&onReplaceAllClicked), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(rrow), abtn);
    c.gtk_widget_set_visible(rrow, 0);
    c.gtk_box_append(@ptrCast(outer), rrow);
    view.replace_row = rrow.?;

    // Escape anywhere in the bar closes it and returns focus.
    const keys = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(@ptrCast(keys), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onFindKey), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(outer, @ptrCast(keys));

    view.find_bar = outer.?;
}

fn options(view: *EditorView) search.Options {
    return .{
        .case_sensitive = c.gtk_toggle_button_get_active(@ptrCast(view.find_case)) != 0,
        .whole_word = c.gtk_toggle_button_get_active(@ptrCast(view.find_word)) != 0,
        .regex = c.gtk_toggle_button_get_active(@ptrCast(view.find_regex)) != 0,
    };
}

/// GtkEditable-based so it works for the GtkSearchEntry needle and the
/// plain GtkEntry replace field alike.
fn entryText(w: *c.GtkWidget) []const u8 {
    const buf = c.gtk_editable_get_text(@ptrCast(w));
    if (buf == null) return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(buf)));
}

/// Open (or focus) the bar; `replace` also reveals the second row. A
/// selection on one line seeds the needle.
pub fn open(view: *EditorView, replace: bool) void {
    const tab = view.active orelse return;
    if (!view.find_open) {
        const sel = tab.sels.primary();
        if (!sel.isCaret() and sel.end() - sel.start() < 120) {
            if (tab.doc.rope.sliceAlloc(view.allocator, sel.start(), sel.end())) |t| {
                defer view.allocator.free(t);
                if (std.mem.indexOfScalar(u8, t, '\n') == null) {
                    if (view.allocator.dupeZ(u8, t)) |zz| {
                        defer view.allocator.free(zz);
                        c.gtk_editable_set_text(@ptrCast(view.find_entry), zz.ptr);
                    } else |_| {}
                }
            } else |_| {}
        }
    }
    view.find_open = true;
    c.gtk_widget_set_visible(view.find_bar, 1);
    c.gtk_widget_set_visible(view.replace_row, if (replace) 1 else 0);
    // With a needle already typed, Ctrl+H should land in the
    // replacement field; otherwise the needle comes first.
    if (replace and entryText(view.find_entry).len > 0) {
        _ = c.gtk_widget_grab_focus(view.replace_entry);
    } else {
        _ = c.gtk_widget_grab_focus(view.find_entry);
        c.gtk_editable_select_region(@ptrCast(view.find_entry), 0, -1);
    }
    recompute(view, tab, true);
}

pub fn close(view: *EditorView) void {
    if (!view.find_open) return;
    view.find_open = false;
    c.gtk_widget_set_visible(view.find_bar, 0);
    if (view.active) |tab| tab.clearMatches();
    _ = c.gtk_widget_grab_focus(@ptrCast(view.area));
    view.queueRender();
}

/// Re-run the search for the active needle. `select` moves the current
/// match to the one nearest the caret.
pub fn recompute(view: *EditorView, tab: *ETab, select: bool) void {
    const needle = entryText(view.find_entry);
    if (tab.needle.len > 0) view.allocator.free(tab.needle);
    tab.needle = view.allocator.dupe(u8, needle) catch &.{};
    tab.clearMatches();
    view.find_bad_pattern = false;
    if (needle.len > 0) {
        tab.matches = search.findAll(view.allocator, &tab.doc, needle, options(view)) catch |e| blk: {
            // A pattern the user is still typing is invalid most of the
            // time; that is a label, not an error dialog.
            view.find_bad_pattern = e != error.OutOfMemory;
            break :blk &.{};
        };
    }
    if (select and tab.matches.len > 0) {
        tab.current_match = search.pick(tab.matches, tab.sels.primary().start(), true);
    }
    updateCount(view, tab);
    view.queueRender();
}

/// Label text for the match counter; `buf` backs the formatted cases.
fn countText(buf: *[40:0]u8, bad_pattern: bool, needle_len: usize, total: usize, current: ?usize) [:0]const u8 {
    if (bad_pattern) return "Bad pattern";
    if (total == 0) return if (needle_len == 0) "" else "No results";
    if (current) |i| return std.fmt.bufPrintZ(buf, "{d} of {d}", .{ i + 1, total }) catch "";
    return std.fmt.bufPrintZ(buf, "{d} matches", .{total}) catch "";
}

fn updateCount(view: *EditorView, tab: *ETab) void {
    var buf: [40:0]u8 = undefined;
    const txt = countText(&buf, view.find_bad_pattern, entryText(view.find_entry).len, tab.matches.len, tab.current_match);
    c.gtk_label_set_text(view.find_count, txt.ptr);
}

/// Step to the next/previous match (wrapping) and select it.
pub fn step(view: *EditorView, forward: bool) void {
    const tab = view.active orelse return;
    if (!std.mem.eql(u8, tab.needle, entryText(view.find_entry))) recompute(view, tab, false);
    if (tab.matches.len == 0) {
        updateCount(view, tab);
        return;
    }
    const caret = tab.sels.primary();
    const from = if (forward) caret.end() else caret.start();
    // Stepping off the match we are sitting on, not onto it again.
    var idx = search.pick(tab.matches, from, forward) orelse return;
    if (search.indexOfRange(tab.matches, caret.start(), caret.end())) |cur| {
        if (idx == cur) {
            idx = if (forward)
                (cur + 1) % tab.matches.len
            else
                (cur + tab.matches.len - 1) % tab.matches.len;
        }
    }
    tab.current_match = idx;
    const m = tab.matches[idx];
    tab.sels.keepPrimaryOnly();
    tab.sels.sels.items[0] = .{ .anchor = m.start, .head = m.end };
    tab.goal_x = null;
    // A match inside a folded region unfolds it, for the same reason
    // goto does.
    view.revealCaretLines(tab);
    updateCount(view, tab);
    view.ensureCaretVisible(tab);
    view.updateStatus();
    view.queueRender();
}

/// Replace the current match (or step onto the first one).
pub fn replaceCurrent(view: *EditorView) void {
    const tab = view.active orelse return;
    const idx = tab.current_match orelse {
        step(view, true);
        return;
    };
    if (idx >= tab.matches.len) return;
    const m = tab.matches[idx];
    const with = search.replacementAt(
        view.allocator,
        &tab.doc,
        tab.needle,
        entryText(view.replace_entry),
        options(view),
        m,
    ) catch return orelse {
        // The document moved under a stale match list.
        recompute(view, tab, true);
        return;
    };
    defer view.allocator.free(with);
    tab.sels.keepPrimaryOnly();
    tab.sels.sels.items[0] = .{ .anchor = m.start, .head = m.end };
    vm.insertText(view.allocator, &tab.doc, &tab.sels, with) catch return;
    view.afterDocEdit(tab);
    step(view, true);
}

/// Every match replaced in ONE transaction, so it is one undo step.
pub fn replaceAll(view: *EditorView) void {
    const tab = view.active orelse return;
    recompute(view, tab, false);
    if (tab.matches.len == 0) return;
    const n = search.replaceAllIn(
        view.allocator,
        &tab.doc,
        &tab.sels,
        tab.needle,
        entryText(view.replace_entry),
        options(view),
    ) catch return;
    var msg_buf: [64:0]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&msg_buf, "Replaced {d} occurrence(s).", .{n}) catch "Replaced.";
    view.afterDocEdit(tab);
    view.setStatusText(msg.ptr);
}

fn onFindChanged(_: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
    const view = cast.userData(EditorView, user);
    const tab = view.active orelse return;
    recompute(view, tab, true);
}

fn onFindActivate(_: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    step(cast.userData(EditorView, user), true);
}

fn onReplaceActivate(_: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    replaceCurrent(cast.userData(EditorView, user));
}

fn onFindOptionToggled(_: *c.GtkToggleButton, user: ?*anyopaque) callconv(.c) void {
    const view = cast.userData(EditorView, user);
    const tab = view.active orelse return;
    recompute(view, tab, true);
}

fn onFindNextClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    step(cast.userData(EditorView, user), true);
}

fn onFindPrevClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    step(cast.userData(EditorView, user), false);
}

fn onFindCloseClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    close(cast.userData(EditorView, user));
}

/// GtkSearchEntry "stop-search" (Esc in the entry). The bar's own
/// capture-phase Esc handler normally wins; this is the backstop.
fn onFindStop(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    close(cast.userData(EditorView, user));
}

fn onReplaceClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    replaceCurrent(cast.userData(EditorView, user));
}

fn onReplaceAllClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    replaceAll(cast.userData(EditorView, user));
}

/// The keyboard focus is `w` or inside it (a search entry focuses its
/// inner text widget).
fn focusWithin(w: *c.GtkWidget) bool {
    const root = c.gtk_widget_get_root(w) orelse return false;
    const f = c.gtk_root_get_focus(root) orelse return false;
    return f == w or c.gtk_widget_is_ancestor(f, w) != 0;
}

fn onFindKey(
    _: *c.GtkEventControllerKey,
    keyval: c_uint,
    _: c_uint,
    state: c.GdkModifierType,
    user: ?*anyopaque,
) callconv(.c) c.gboolean {
    const view = cast.userData(EditorView, user);
    const mods = state & input.SIGNIFICANT_MODS;
    // The find/replace chords must also work from INSIDE the bar (the
    // canvas controller never sees them while an entry has focus), and
    // they are whatever the binding table says, not a second copy.
    if (view.matchEdBinding(keyval, c.gdk_keyval_to_lower(keyval), mods)) |cmd| {
        switch (cmd) {
            .find, .replace => {
                open(view, cmd == .replace);
                return 1;
            },
            else => {},
        }
    }
    switch (keyval) {
        c.GDK_KEY_Escape => {
            close(view);
            return 1;
        },
        c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => {
            // Ctrl+Alt+Enter replaces every match (VS Code's chord);
            // Shift+Enter steps backwards from either entry; plain Enter
            // in the replace entry replaces one (its "activate").
            if ((mods & (c.GDK_CONTROL_MASK | c.GDK_ALT_MASK)) == (c.GDK_CONTROL_MASK | c.GDK_ALT_MASK)) {
                replaceAll(view);
                return 1;
            }
            if ((mods & c.GDK_SHIFT_MASK) != 0) {
                step(view, false);
                return 1;
            }
            return 0;
        },
        c.GDK_KEY_Tab, c.GDK_KEY_ISO_Left_Tab => {
            // Tab hops between the two entries while the replace row is
            // up, instead of walking every toggle button in between.
            if (c.gtk_widget_get_visible(view.replace_row) == 0 or mods & ~@as(c_uint, c.GDK_SHIFT_MASK) != 0) return 0;
            const in_replace = focusWithin(view.replace_entry);
            const target = if (in_replace) view.find_entry else view.replace_entry;
            _ = c.gtk_widget_grab_focus(target);
            return 1;
        },
        else => return 0,
    }
}

// ======================================================================
// Tests
// ======================================================================

test "editorfind: the counter says what the search found" {
    var buf: [40:0]u8 = undefined;
    try std.testing.expectEqualStrings("Bad pattern", countText(&buf, true, 3, 0, null));
    try std.testing.expectEqualStrings("", countText(&buf, false, 0, 0, null));
    try std.testing.expectEqualStrings("No results", countText(&buf, false, 2, 0, null));
    try std.testing.expectEqualStrings("2 of 5", countText(&buf, false, 2, 5, 1));
    try std.testing.expectEqualStrings("5 matches", countText(&buf, false, 2, 5, null));
}
