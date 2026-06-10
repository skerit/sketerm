//! Command palette — Ctrl+Shift+P. Modal AdwDialog with a search
//! entry and a scrolling list of curated actions, each rendered as
//! an AdwActionRow (icon + bold title + dim subtitle + keybind hint).
//!
//! Filter: case-insensitive substring across title + description.
//! Keyboard: Up/Down move selection while focus stays in the entry,
//! Enter activates, Escape dismisses (handled by AdwDialog itself).
//!
//! Dispatch: every match dispatches the chosen action through
//! `Window.dispatchAction`, which mirrors the keybind dispatch path
//! (focused-pane input.Ctx first, falls through to onShortcut).

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const input = @import("input.zig");
const window_mod = @import("window.zig");
const Window = window_mod.Window;

const Entry = struct {
    icon: [:0]const u8,
    title: [:0]const u8,
    desc: [:0]const u8,
    action: input.Action,
};

/// Curated action set — every row that "makes sense" in a discoverable
/// list. Actions reachable only via context-menu / per-pane chords
/// are intentionally excluded; keybind-only actions where the chord
/// is the entire UX (Alt+digit goto-tab) are excluded too.
const ENTRIES = [_]Entry{
    // Clipboard
    .{ .icon = "edit-copy-symbolic", .title = "Copy",
       .desc = "Copy the selected text to the clipboard.", .action = .copy_selection },
    .{ .icon = "edit-paste-symbolic", .title = "Paste",
       .desc = "Paste clipboard contents at the cursor.", .action = .paste_clipboard },
    .{ .icon = "view-fullscreen-symbolic", .title = "Copy Screen",
       .desc = "Copy the entire visible terminal area.", .action = .copy_screen },
    .{ .icon = "document-save-symbolic", .title = "Copy Scrollback",
       .desc = "Copy the full scrollback buffer plus the visible screen.", .action = .copy_scrollback },
    .{ .icon = "find-location-symbolic", .title = "Keyboard Hints",
       .desc = "Label URLs, paths, and hashes on screen; type a label to open or copy.", .action = .hints_open },
    .{ .icon = "edit-select-all-symbolic", .title = "Copy Mode",
       .desc = "Keyboard-driven selection: move with h/j/k/l, select with v, copy with y.", .action = .copy_mode },

    // Tabs
    .{ .icon = "tab-new-symbolic", .title = "New Tab",
       .desc = "Open a new tab in the current window.", .action = .new_tab },
    .{ .icon = "edit-copy-symbolic", .title = "Duplicate Tab",
       .desc = "Open a new tab inheriting this tab's working directory and profile.", .action = .duplicate_tab },
    .{ .icon = "window-close-symbolic", .title = "Close Tab",
       .desc = "Close the active tab.", .action = .close_tab },
    .{ .icon = "view-pin-symbolic", .title = "Pin / Unpin Tab",
       .desc = "Toggle pinning. Pinned tabs sit at the start of the tab bar.", .action = .toggle_pin_tab },
    .{ .icon = "edit-undo-symbolic", .title = "Restore Closed Tab",
       .desc = "Reopen the most recently closed tab.", .action = .restore_closed_tab },
    .{ .icon = "view-grid-symbolic", .title = "Toggle Tab Bar",
       .desc = "Show or hide the tab bar at the top of the window.", .action = .toggle_tab_bar },
    .{ .icon = "go-next-symbolic", .title = "Next Tab",
       .desc = "Switch focus to the next tab.", .action = .next_tab },
    .{ .icon = "go-previous-symbolic", .title = "Previous Tab",
       .desc = "Switch focus to the previous tab.", .action = .prev_tab },

    // Panes
    .{ .icon = "view-dual-symbolic", .title = "Split Horizontal",
       .desc = "Split the active pane left and right.", .action = .split_h },
    .{ .icon = "view-paged-symbolic", .title = "Split Vertical",
       .desc = "Split the active pane top and bottom.", .action = .split_v },
    .{ .icon = "go-next-symbolic", .title = "Next Pane",
       .desc = "Move focus to the next pane within this tab.", .action = .pane_next },
    .{ .icon = "go-previous-symbolic", .title = "Previous Pane",
       .desc = "Move focus to the previous pane within this tab.", .action = .pane_prev },

    // Search & scrollback
    .{ .icon = "edit-find-symbolic", .title = "Search",
       .desc = "Search the scrollback for a string.", .action = .search_open },
    .{ .icon = "go-up-symbolic", .title = "Previous Prompt",
       .desc = "Jump to the previous shell prompt (uses OSC 133 marks).", .action = .prompt_prev },
    .{ .icon = "go-down-symbolic", .title = "Next Prompt",
       .desc = "Jump to the next shell prompt.", .action = .prompt_next },
    .{ .icon = "go-top-symbolic", .title = "Scroll to Top",
       .desc = "Jump to the oldest line in the scrollback.", .action = .scrollback_top },
    .{ .icon = "go-bottom-symbolic", .title = "Scroll to Bottom",
       .desc = "Return to the live screen position.", .action = .scrollback_bottom },
    .{ .icon = "go-up-symbolic", .title = "Page Up",
       .desc = "Scroll back one screenful.", .action = .scrollback_page_up },
    .{ .icon = "go-down-symbolic", .title = "Page Down",
       .desc = "Scroll forward one screenful.", .action = .scrollback_page_down },
    .{ .icon = "edit-clear-all-symbolic", .title = "Clear Scrollback",
       .desc = "Wipe the scrollback ring. The visible screen stays.", .action = .clear_scrollback },
    .{ .icon = "view-list-symbolic", .title = "Show Scrollback in Pager",
       .desc = "Open the scrollback buffer plus visible screen in a pager tab.", .action = .show_scrollback },

    // Font
    .{ .icon = "zoom-in-symbolic", .title = "Increase Font Size",
       .desc = "Bump the cell font up by one point.", .action = .font_inc },
    .{ .icon = "zoom-out-symbolic", .title = "Decrease Font Size",
       .desc = "Drop the cell font down by one point.", .action = .font_dec },
    .{ .icon = "zoom-original-symbolic", .title = "Reset Font Size",
       .desc = "Restore the configured default size.", .action = .font_reset },

    // Layout & config
    .{ .icon = "document-save-symbolic", .title = "Save Layout",
       .desc = "Write the current tabs and panes to last.json.", .action = .save_layout },
    .{ .icon = "document-save-as-symbolic", .title = "Save Layout As…",
       .desc = "Pick a path and save the current layout there.", .action = .save_layout_as },
    .{ .icon = "starred-symbolic", .title = "Save Default Layout",
       .desc = "Save current tabs and panes as the default for every new launch.", .action = .save_default_layout },
    .{ .icon = "view-refresh-symbolic", .title = "Reload Config",
       .desc = "Re-read config.conf from disk and apply live.", .action = .reload_config },

    // Misc
    .{ .icon = "input-keyboard-symbolic", .title = "Broadcast Mode",
       .desc = "Cycle broadcast typing across panes: off → group → all → off.", .action = .broadcast_cycle },
    .{ .icon = "preferences-system-symbolic", .title = "Preferences",
       .desc = "Open the preferences dialog.", .action = .prefs_open },
};

const RowCtx = struct {
    palette: *Ctx,
    action: input.Action,
    title_lower: []u8,
    desc_lower: []u8,
};

const Ctx = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    window: *Window,
    dialog: *c.AdwDialog,
    search_entry: *c.GtkWidget,
    listbox: *c.GtkWidget,
    rows: []*RowCtx,
};

pub fn open(window: *Window) !void {
    const allocator = window.allocator;
    const ctx = try allocator.create(Ctx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .window = window,
        .dialog = undefined,
        .search_entry = undefined,
        .listbox = undefined,
        .rows = undefined,
    };
    errdefer ctx.arena.deinit();
    const arena = ctx.arena.allocator();

    // AdwDialog: handles modality, Escape, centring on the parent.
    const dialog = c.adw_dialog_new();
    c.adw_dialog_set_title(dialog, "Command Palette");
    c.adw_dialog_set_content_width(dialog, 640);
    c.adw_dialog_set_content_height(dialog, 480);
    ctx.dialog = @ptrCast(@alignCast(dialog));

    _ = c.g_signal_connect_data(
        dialog,
        "closed",
        @ptrCast(&onClosed),
        @ptrCast(ctx),
        @ptrCast(&freeCtx),
        c.G_CONNECT_DEFAULT,
    );

    const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_margin_start(root, 12);
    c.gtk_widget_set_margin_end(root, 12);
    c.gtk_widget_set_margin_top(root, 12);
    c.gtk_widget_set_margin_bottom(root, 12);

    // Search entry on top.
    const search = c.gtk_search_entry_new();
    c.gtk_widget_set_hexpand(search, 1);
    c.gtk_search_entry_set_placeholder_text(@ptrCast(@alignCast(search)), "Search actions…");
    c.gtk_widget_set_margin_bottom(search, 8);
    c.gtk_box_append(@ptrCast(root), search);
    ctx.search_entry = search;

    // Scrolling list.
    const scrolled = c.gtk_scrolled_window_new();
    c.gtk_widget_set_vexpand(scrolled, 1);
    c.gtk_scrolled_window_set_policy(@ptrCast(@alignCast(scrolled)), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);

    const listbox = c.gtk_list_box_new();
    c.gtk_list_box_set_selection_mode(@ptrCast(@alignCast(listbox)), c.GTK_SELECTION_BROWSE);
    c.gtk_widget_add_css_class(listbox, "boxed-list");
    c.gtk_scrolled_window_set_child(@ptrCast(@alignCast(scrolled)), listbox);
    c.gtk_box_append(@ptrCast(root), scrolled);
    ctx.listbox = listbox;

    // Build rows.
    const rows = try arena.alloc(*RowCtx, ENTRIES.len);
    for (ENTRIES, 0..) |entry, i| {
        const rctx = try arena.create(RowCtx);
        rctx.* = .{
            .palette = ctx,
            .action = entry.action,
            .title_lower = try toLowerOwned(arena, entry.title),
            .desc_lower = try toLowerOwned(arena, entry.desc),
        };
        rows[i] = rctx;

        const row = c.adw_action_row_new();
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), entry.title);
        c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), entry.desc);
        // Activatable is on the GtkListBoxRow base class.
        c.gtk_list_box_row_set_activatable(@ptrCast(@alignCast(row)), 1);

        const icon = c.gtk_image_new_from_icon_name(entry.icon);
        c.gtk_image_set_pixel_size(@ptrCast(@alignCast(icon)), 20);
        c.adw_action_row_add_prefix(@ptrCast(@alignCast(row)), icon);

        // Keybind hint suffix — looks up the active binding for this
        // action and renders the chord with `gtk_accelerator_get_label`.
        // No binding → no suffix (keeps the row clean).
        if (findBindingLabel(arena, window, entry.action)) |label_z| {
            const kbd = c.gtk_label_new(label_z);
            c.gtk_widget_add_css_class(kbd, "dim-label");
            c.gtk_widget_add_css_class(kbd, "monospace");
            c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), kbd);
        }

        // Stash the rctx pointer on the row so the listbox-level
        // `row-activated` signal can recover the action. AdwActionRow
        // is a GObject; the arena owns rctx for the dialog's lifetime.
        c.g_object_set_data(@ptrCast(@alignCast(row)), "palette-row", @ptrCast(rctx));

        c.gtk_list_box_append(@ptrCast(@alignCast(listbox)), row);
    }

    // Single listbox-level activation handler — fires for click,
    // double-click on AdwActionRow, and `gtk_list_box_row_activate`
    // (the path our Enter key forwarding takes).
    _ = c.g_signal_connect_data(
        listbox,
        "row-activated",
        @ptrCast(&onListBoxRowActivated),
        @ptrCast(ctx),
        null,
        c.G_CONNECT_DEFAULT,
    );
    ctx.rows = rows;

    // Search filter.
    _ = c.g_signal_connect_data(
        search,
        "search-changed",
        @ptrCast(&onSearchChanged),
        @ptrCast(ctx),
        null,
        c.G_CONNECT_DEFAULT,
    );

    // Up/Down/Enter on the search entry — keep typing-focus on the
    // entry but drive selection in the listbox below.
    const key_ctrl = c.gtk_event_controller_key_new();
    _ = c.g_signal_connect_data(
        key_ctrl,
        "key-pressed",
        @ptrCast(&onKeyPressed),
        @ptrCast(ctx),
        null,
        c.G_CONNECT_DEFAULT,
    );
    c.gtk_widget_add_controller(search, @ptrCast(key_ctrl));

    // Initial selection — first row.
    if (ENTRIES.len > 0) {
        const first = c.gtk_list_box_get_row_at_index(@ptrCast(@alignCast(listbox)), 0);
        if (first != null) c.gtk_list_box_select_row(@ptrCast(@alignCast(listbox)), first);
    }

    c.adw_dialog_set_child(dialog, root);
    c.adw_dialog_present(dialog, @ptrCast(window.app_window));
    // Defer focus-grab to after the dialog is shown — grabbing during
    // construction races with AdwDialog's own focus handling.
    _ = c.gtk_widget_grab_focus(search);
}

fn onSearchChanged(entry: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    const text_ptr = c.gtk_editable_get_text(@ptrCast(entry));
    const text: []const u8 = if (text_ptr == null) &.{}
        else std.mem.span(@as([*:0]const u8, @ptrCast(text_ptr)));

    var first_visible_idx: i32 = -1;
    var idx: i32 = 0;
    while (idx < @as(i32, @intCast(ctx.rows.len))) : (idx += 1) {
        const rctx = ctx.rows[@intCast(idx)];
        const visible = matches(text, rctx.title_lower, rctx.desc_lower);
        const row = c.gtk_list_box_get_row_at_index(@ptrCast(@alignCast(ctx.listbox)), idx);
        if (row != null) {
            c.gtk_widget_set_visible(@ptrCast(row), if (visible) 1 else 0);
            if (visible and first_visible_idx < 0) first_visible_idx = idx;
        }
    }

    // Always select the first visible row so Enter has a target.
    if (first_visible_idx >= 0) {
        const row = c.gtk_list_box_get_row_at_index(@ptrCast(@alignCast(ctx.listbox)), first_visible_idx);
        if (row != null) c.gtk_list_box_select_row(@ptrCast(@alignCast(ctx.listbox)), row);
    } else {
        c.gtk_list_box_unselect_all(@ptrCast(@alignCast(ctx.listbox)));
    }
}

fn onKeyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c_uint,
    _: c_uint,
    _: c.GdkModifierType,
    user: ?*anyopaque,
) callconv(.c) c.gboolean {
    const ctx = cast.userData(Ctx, user);
    switch (keyval) {
        c.GDK_KEY_Up => {
            moveSelection(ctx, -1);
            return 1;
        },
        c.GDK_KEY_Down => {
            moveSelection(ctx, 1);
            return 1;
        },
        c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => {
            activateSelected(ctx);
            return 1;
        },
        // GtkSearchEntry swallows Escape via its built-in "stop-search"
        // handler before AdwDialog's default close-on-Escape sees it,
        // so dismiss explicitly here.
        c.GDK_KEY_Escape => {
            c.adw_dialog_force_close(@ptrCast(@alignCast(ctx.dialog)));
            return 1;
        },
        else => return 0,
    }
}

fn moveSelection(ctx: *Ctx, delta: i32) void {
    const lb: *c.GtkListBox = @ptrCast(@alignCast(ctx.listbox));
    const cur = c.gtk_list_box_get_selected_row(lb);
    const cur_idx: i32 = if (cur == null) -1 else c.gtk_list_box_row_get_index(cur);

    // Step in `delta` direction, skipping invisible (filtered) rows.
    const total: i32 = @intCast(ctx.rows.len);
    var i: i32 = cur_idx + delta;
    while (i >= 0 and i < total) : (i += delta) {
        const row = c.gtk_list_box_get_row_at_index(lb, i);
        if (row == null) break;
        if (c.gtk_widget_get_visible(@ptrCast(row)) != 0) {
            c.gtk_list_box_select_row(lb, row);
            // gtk_widget_grab_focus returns gboolean; we don't need it.
            _ = c.gtk_widget_grab_focus(@ptrCast(row));
            // Re-focus the entry so typing keeps working.
            _ = c.gtk_widget_grab_focus(ctx.search_entry);
            return;
        }
    }
}

fn activateSelected(ctx: *Ctx) void {
    const lb: *c.GtkListBox = @ptrCast(@alignCast(ctx.listbox));
    const row = c.gtk_list_box_get_selected_row(lb);
    if (row == null) return;
    // Call our handler directly — equivalent to what the listbox's
    // "row-activated" signal would do on a click. (GTK4 dropped
    // `gtk_list_box_row_activate`; emitting the signal manually is
    // the modern equivalent.)
    onListBoxRowActivated(lb, row, @ptrCast(ctx));
}

// GtkListBox::row-activated — fires for click, AdwActionRow
// double-click, and `gtk_list_box_row_activate` (the path our Enter
// key forwarding takes). Recover the RowCtx via the row's stashed
// g_object_data, dispatch, dismiss.
fn onListBoxRowActivated(
    _: *c.GtkListBox,
    row: *c.GtkListBoxRow,
    user: ?*anyopaque,
) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    const data = c.g_object_get_data(@ptrCast(@alignCast(row)), "palette-row") orelse return;
    const rctx: *RowCtx = @ptrCast(@alignCast(data));
    const win = ctx.window;
    const action = rctx.action;
    // Dismiss BEFORE dispatching: actions like .prefs_open open
    // another dialog, and the palette would otherwise stack on top.
    c.adw_dialog_force_close(@ptrCast(@alignCast(ctx.dialog)));
    window_mod.dispatchAction(win, action);
}

fn onClosed(_: *c.AdwDialog, user: ?*anyopaque) callconv(.c) void {
    _ = user;
    // Cleanup runs via the GDestroyNotify (`freeCtx`) the
    // `g_signal_connect_data` call attached.
}

fn freeCtx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const ctx: *Ctx = @ptrCast(@alignCast(u));
        ctx.arena.deinit();
        ctx.allocator.destroy(ctx);
    }
}

// ── Helpers ───────────────────────────────────────────────────────

fn toLowerOwned(arena: std.mem.Allocator, s: [:0]const u8) ![]u8 {
    const out = try arena.alloc(u8, s.len);
    for (s, 0..) |ch, i| {
        out[i] = std.ascii.toLower(ch);
    }
    return out;
}

fn matches(query: []const u8, title_lower: []const u8, desc_lower: []const u8) bool {
    if (query.len == 0) return true;
    var lower_buf: [256]u8 = undefined;
    const n = @min(query.len, lower_buf.len);
    for (query[0..n], 0..) |ch, i| lower_buf[i] = std.ascii.toLower(ch);
    const q = lower_buf[0..n];
    if (std.mem.indexOf(u8, title_lower, q) != null) return true;
    if (std.mem.indexOf(u8, desc_lower, q) != null) return true;
    return false;
}

fn findBindingLabel(arena: std.mem.Allocator, window: *Window, action: input.Action) ?[*:0]const u8 {
    for (window.bindings.items) |b| {
        if (b.action != action) continue;
        const label_ptr = c.gtk_accelerator_get_label(b.keyval, b.mods);
        if (label_ptr == null) return null;
        defer c.g_free(label_ptr);
        const label = std.mem.span(@as([*:0]const u8, @ptrCast(label_ptr)));
        const z = arena.allocSentinel(u8, label.len, 0) catch return null;
        @memcpy(z, label);
        return z.ptr;
    }
    return null;
}
