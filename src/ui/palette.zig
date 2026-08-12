//! Command palette — Ctrl+Shift+P. Modal AdwDialog with a search
//! entry and a scrolling list, each row an AdwActionRow (icon + bold
//! title + dim subtitle + keybind hint).
//!
//! This is one of the two views over the shared suggestion model
//! (`src/util/suggest.zig`); the omnibox is the other. The palette owns
//! no ranking, no matching and no dispatch of its own: it builds a row
//! per candidate slot, hands `suggest.Model` its sources, and renders
//! what comes back. Rows are activated by calling the candidate's own
//! `fire()`, so adding a source means adding it to `ctx.sources` — not
//! extending a dispatch switch here.
//!
//! Sources, in weight order:
//!   - the command catalogue (`commandcat.zig`) — curated actions,
//!     editor-face commands, one row per `[domain.<name>]`;
//!   - open tabs across every window, which activate by switching to
//!     the tab rather than doing anything.
//!
//! Why the palette hosts every source that can be ENUMERATED when it
//! opens, and no async ones: its rows are AdwActionRows carrying icon
//! theme lookups and keybind-label lookups, built once and thereafter
//! only re-sorted and shown/hidden. That is the right cost model for
//! ~80 rows and the wrong one for a set that changes per keystroke. The
//! omnibox rebuilds cheap GtkBox rows every keystroke and so can carry
//! daemon-backed history; the framework supports both and neither view
//! has to know about the other. See `suggest.Model`'s docblock.
//!
//! Keyboard: Up/Down move selection while focus stays in the entry,
//! Enter activates, Escape dismisses.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const suggest = @import("../util/suggest.zig");
const commandcat = @import("commandcat.zig");
const render_kick = @import("../util/render_kick.zig");
const input = @import("input.zig");
const ecmd = @import("../editor/commands.zig");
const EditorView = @import("editorview.zig").EditorView;
const remotectl = @import("remotectl.zig");
const window_mod = @import("window.zig");
const Window = window_mod.Window;

/// A "switch to this tab" row. Kept as a resolved page pointer rather
/// than an index because tabs can close while the dialog is up; the
/// activation re-checks the page is still in its view before selecting.
const TabRow = struct {
    title: [:0]const u8,
    detail: [:0]const u8,
    win: *Window,
    page: *c.AdwTabPage,
};

/// Per-widget-row state. Rows sit in ONE index space — catalogue rows
/// first, then tab rows — which both sources emit as `payload`; that is
/// what lets a single merged ranking address rows from either source.
/// `ctx.rows[cand.payload]` is the row a candidate stands for.
const RowCtx = struct {
    /// Build order — the sort tie-break that keeps catalogue order for
    /// rows the merger scored equally.
    orig_index: usize,
    /// Last merge score; 0 = filtered out (row hidden).
    score: f32 = 1.0,
    /// The candidate this row last stood for. Carries the framework's
    /// activation, so `fire()` is the whole of dispatch.
    cand: ?suggest.Candidate = null,
};

const Ctx = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    window: *Window,
    dialog: *c.AdwDialog,
    search_entry: *c.GtkWidget,
    listbox: *c.GtkWidget,
    rows: []*RowCtx,
    /// The two row stores the shared index space addresses, in order:
    /// a payload below `catalog.len` is a command, at or above it a tab.
    catalog: std.ArrayList(commandcat.Row) = .empty,
    tabs: std.ArrayList(TabRow) = .empty,
    feed: commandcat.Feed = undefined,
    /// Stable storage: `model` borrows this slice for its lifetime.
    sources: [2]suggest.Source = undefined,
    model: suggest.Model = undefined,
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
    c.gtk_search_entry_set_placeholder_text(@ptrCast(@alignCast(search)), "Search actions and tabs…");
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

    // Adwaita fallback theme for `iconImage`. A user's active icon theme
    // can ship a stale icon-theme.cache that advertises HiDPI (@2x)
    // variants it doesn't actually contain; the cache short-circuits the
    // usual inheritance, so a plain GtkImage.from_icon_name renders the
    // broken-image placeholder. Adwaita always resolves, so we route
    // around the broken theme per-icon. Built once, freed at the bottom.
    const fallback_theme: ?*c.GtkIconTheme = blk: {
        const display = c.gtk_widget_get_display(window.app_window);
        const ft = c.gtk_icon_theme_new() orelse break :blk null;
        const sp = c.gtk_icon_theme_get_search_path(c.gtk_icon_theme_get_for_display(display));
        if (sp != null) {
            c.gtk_icon_theme_set_search_path(ft, @ptrCast(sp));
            c.g_strfreev(sp);
        }
        c.gtk_icon_theme_set_theme_name(ft, "Adwaita");
        break :blk ft;
    };
    defer if (fallback_theme) |ft| c.g_object_unref(ft);

    try buildCatalog(ctx, arena, window);
    collectTabs(ctx, arena, window);

    const total = ctx.catalog.items.len + ctx.tabs.items.len;
    const rows = try arena.alloc(*RowCtx, total);
    var built: usize = 0;

    for (ctx.catalog.items) |entry| {
        const rctx = try arena.create(RowCtx);
        rctx.* = .{ .orig_index = built };
        rows[built] = rctx;
        built += 1;

        const row = c.adw_action_row_new();
        // AdwActionRow's template binds BOTH the title and the subtitle
        // label's `use-markup` to the row's, and it defaults to TRUE — so
        // a plain `&`, `<` or `>` anywhere in a row's text is parsed as
        // Pango markup, fails, and GTK renders the label EMPTY (with a
        // console warning nobody reads). Every string here is prose or
        // user data, never markup: one command description says
        // "zig build fetch-cef && zig build web" and lost its whole
        // subtitle to this. Turning markup off is the fix at the source
        // rather than escaping at each of the call sites.
        c.adw_preferences_row_set_use_markup(@ptrCast(@alignCast(row)), 0);
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), entry.title);
        c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), entry.desc);
        // Activatable is on the GtkListBoxRow base class.
        c.gtk_list_box_row_set_activatable(@ptrCast(@alignCast(row)), 1);
        c.adw_action_row_add_prefix(
            @ptrCast(@alignCast(row)),
            iconImage(window, fallback_theme, entry.icon, 20),
        );

        // Keybind hint suffix — the active binding for this row, if any.
        // No binding → no suffix (keeps the row clean).
        const label_z: ?[*:0]const u8 = switch (entry.kind) {
            .action => findBindingLabel(arena, window, entry.action),
            .editor => if (entry.editor_cmd) |cmd| findEdBindingLabel(arena, window, cmd) else null,
            .domain => null,
        };
        if (label_z) |lz| {
            const kbd = c.gtk_label_new(lz);
            c.gtk_widget_add_css_class(kbd, "dim-label");
            c.gtk_widget_add_css_class(kbd, "monospace");
            c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), kbd);
        }

        // Stash the rctx pointer on the row so the listbox-level
        // `row-activated` signal can recover it. AdwActionRow is a
        // GObject; the arena owns rctx for the dialog's lifetime.
        c.g_object_set_data(@ptrCast(@alignCast(row)), "palette-row", @ptrCast(rctx));
        c.gtk_list_box_append(@ptrCast(@alignCast(listbox)), row);
    }

    for (ctx.tabs.items) |tab| {
        const rctx = try arena.create(RowCtx);
        rctx.* = .{ .orig_index = built };
        rows[built] = rctx;
        built += 1;

        const row = c.adw_action_row_new();
        // Same markup trap as the catalogue rows above, and worse here:
        // a tab title is whatever the shell set it to, so an ordinary
        // `make && ./run` title would render as an EMPTY row.
        c.adw_preferences_row_set_use_markup(@ptrCast(@alignCast(row)), 0);
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), tab.title);
        c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), tab.detail);
        c.gtk_list_box_row_set_activatable(@ptrCast(@alignCast(row)), 1);
        c.adw_action_row_add_prefix(
            @ptrCast(@alignCast(row)),
            iconImage(window, fallback_theme, "go-jump-symbolic", 20),
        );
        c.g_object_set_data(@ptrCast(@alignCast(row)), "palette-row", @ptrCast(rctx));
        c.gtk_list_box_append(@ptrCast(@alignCast(listbox)), row);
    }
    ctx.rows = rows[0..built];

    // Single listbox-level activation handler — fires for click,
    // double-click on AdwActionRow, and our Enter forwarding.
    _ = c.g_signal_connect_data(
        listbox,
        "row-activated",
        @ptrCast(&onListBoxRowActivated),
        @ptrCast(ctx),
        null,
        c.G_CONNECT_DEFAULT,
    );

    // Ranked ordering: best match first, catalogue order on ties. The
    // RowCtx carries the scores; the qdata pointer outlives every sort
    // because the arena lives until the dialog's destroy-notify.
    c.gtk_list_box_set_sort_func(@ptrCast(@alignCast(listbox)), @ptrCast(&onSortRows), null, null);

    ctx.feed = .{ .rows = ctx.catalog.items, .mru = &commandcat.recent };
    ctx.sources = .{
        ctx.feed.source(&activateCommand, @ptrCast(ctx), 1.0),
        // Below the catalogue on purpose: a command you named exactly
        // must still win over a tab whose title happens to contain the
        // same word. 0.75 keeps even a perfect tab-title hit under a
        // command's word-boundary match (0.8).
        .{
            .ctx = @ptrCast(ctx),
            .weight = 0.75,
            .query = &tabsQuery,
            .activate = &activateTab,
        },
    };
    ctx.model = suggest.Model.init(allocator, &ctx.sources, ctx.rows.len);
    ctx.model.view_ctx = @ptrCast(ctx);
    ctx.model.on_changed = &onRanked;

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
    // CAPTURE phase: the search entry's inner GtkText emits "activate" and
    // swallows Return at the target phase, so a bubble-phase controller
    // never sees Enter (Up/Down survive because a single-line GtkText
    // ignores them). Capturing lets us intercept Return before GtkText.
    c.gtk_event_controller_set_propagation_phase(@ptrCast(key_ctrl), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(
        key_ctrl,
        "key-pressed",
        @ptrCast(&onKeyPressed),
        @ptrCast(ctx),
        null,
        c.G_CONNECT_DEFAULT,
    );
    c.gtk_widget_add_controller(search, @ptrCast(key_ctrl));

    // Seed the ranking (and every row's candidate) for the bare query,
    // then select the top row so Enter always has a target.
    ctx.model.setQuery("");

    c.adw_dialog_set_child(dialog, root);
    _ = c.g_signal_connect_data(dialog, "closed", @ptrCast(&render_kick.onDialogClosed), @ptrCast(window.app_window), null, c.G_CONNECT_DEFAULT);
    c.adw_dialog_present(dialog, @ptrCast(window.app_window));
    render_kick.dialogPresented(window.app_window);
    // Defer focus-grab to after the dialog is shown — grabbing during
    // construction races with AdwDialog's own focus handling.
    _ = c.gtk_widget_grab_focus(search);
}

// ── row construction ──────────────────────────────────────────────

/// The catalogue for this opening: curated actions, the editor-face
/// commands when the focused pane wears an editor, and one row per
/// configured `[domain.<name>]`.
fn buildCatalog(ctx: *Ctx, arena: std.mem.Allocator, window: *Window) !void {
    const editor_here: bool = blk: {
        const pane = window.focusedPane() orelse break :blk false;
        break :blk EditorView.fromPane(pane) != null;
    };

    var domains: std.ArrayList(commandcat.DomainRow) = .empty;
    for (window.config.domains.items) |dom| {
        if (dom.host.len == 0) continue;
        try domains.append(arena, .{
            .name = dom.name,
            .host_spec = try dom.hostSpec(arena),
            .title = try std.fmt.allocPrintSentinel(arena, "New Tab on {s}", .{dom.name}, 0),
            .desc = try std.fmt.allocPrintSentinel(
                arena,
                "Durable remote shell on {s} ({s}).",
                .{ dom.host, @tagName(dom.transport) },
                0,
            ),
        });
    }

    try commandcat.build(arena, .{ .editor = editor_here, .domains = domains.items }, &ctx.catalog);
}

/// Every tab of every window of this process. Failure to enumerate is
/// not fatal: the palette simply offers no tab rows.
fn collectTabs(ctx: *Ctx, arena: std.mem.Allocator, window: *Window) void {
    const app = c.gtk_window_get_application(@ptrCast(window.app_window));
    const wins = remotectl.liveWindows(arena, app) catch return;
    const many = wins.len > 1;
    for (wins) |win| {
        const n = c.adw_tab_view_get_n_pages(win.tab_view);
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const page = c.adw_tab_view_get_nth_page(win.tab_view, i) orelse continue;
            const title_c = c.adw_tab_page_get_title(page);
            const title = if (title_c != null) std.mem.span(title_c) else "";
            const title_z = arena.dupeZ(u8, if (title.len > 0) title else "Untitled tab") catch continue;
            const detail_z = if (many)
                std.fmt.allocPrintSentinel(arena, "Window {d} · tab {d}", .{ win.id, i + 1 }, 0) catch continue
            else
                std.fmt.allocPrintSentinel(arena, "Tab {d}", .{i + 1}, 0) catch continue;
            ctx.tabs.append(arena, .{
                .title = title_z,
                .detail = detail_z,
                .win = win,
                .page = page,
            }) catch return;
        }
    }
}

// ── sources ───────────────────────────────────────────────────────

/// Open tabs as suggestion rows. `payload` continues the catalogue's
/// index space so a merged candidate maps straight back to a widget.
fn tabsQuery(ctx_: ?*anyopaque, q: []const u8, gpa: std.mem.Allocator, out: *std.ArrayList(suggest.Candidate)) void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_.?));
    for (ctx.tabs.items, 0..) |tab, i| {
        const score = suggest.fieldsScore(q, tab.title, tab.detail);
        if (score <= 0) continue;
        out.append(gpa, .{
            .title = tab.title,
            .detail = tab.detail,
            .kind = .session,
            .score = score,
            .payload = ctx.catalog.items.len + i,
        }) catch {};
    }
}

/// Dispatch a catalogue row. Everything arena-owned that survives the
/// dialog has to be copied first: `force_close` runs the destroy-notify
/// that frees the arena.
fn activateCommand(ctx_: ?*anyopaque, cand: suggest.Candidate) void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_.?));
    const idx: usize = @intCast(cand.payload);
    if (idx >= ctx.catalog.items.len) return;
    const row = ctx.catalog.items[idx];
    const win = ctx.window;

    // Recency goes to the process-wide store, which outlives this
    // dialog by design — and is shared with the omnibox.
    commandcat.recent.note(commandcat.keyOf(row));

    var host_buf: [512]u8 = undefined;
    const host: ?[]const u8 = if (row.kind == .domain and row.host.len > 0 and row.host.len < host_buf.len) blk: {
        @memcpy(host_buf[0..row.host.len], row.host);
        break :blk host_buf[0..row.host.len];
    } else null;
    const kind = row.kind;
    const action = row.action;
    const editor_cmd = row.editor_cmd;

    // Dismiss BEFORE dispatching: actions like .prefs_open open another
    // dialog, and the palette would otherwise stack on top.
    c.adw_dialog_force_close(@ptrCast(@alignCast(ctx.dialog)));

    switch (kind) {
        .domain => {
            const h = host orelse return;
            win.newDurableTab(h) catch {
                std.debug.print("sketerm: durable tab on {s} failed (ssh/key auth?)\n", .{h});
            };
        },
        .editor => {
            const cmd = editor_cmd orelse return;
            const pane = win.focusedPane() orelse return;
            const view = EditorView.fromPane(pane) orelse return;
            const tab = view.activeTab() orelse return;
            view.runCommand(tab, cmd);
        },
        .action => window_mod.dispatchAction(win, action),
    }
}

/// Switch to an open tab. The page is re-checked against its view
/// because a tab can close while the dialog is up.
fn activateTab(ctx_: ?*anyopaque, cand: suggest.Candidate) void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_.?));
    const idx: usize = @intCast(cand.payload);
    if (idx < ctx.catalog.items.len) return;
    const at = idx - ctx.catalog.items.len;
    if (at >= ctx.tabs.items.len) return;
    const tab = ctx.tabs.items[at];
    const win = tab.win;
    const page = tab.page;
    c.adw_dialog_force_close(@ptrCast(@alignCast(ctx.dialog)));
    if (!pageStillThere(win, page)) return;
    c.adw_tab_view_set_selected_page(win.tab_view, page);
    c.gtk_window_present(@ptrCast(win.app_window));
}

fn pageStillThere(win: *Window, page: *c.AdwTabPage) bool {
    const n = c.adw_tab_view_get_n_pages(win.tab_view);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        if (c.adw_tab_view_get_nth_page(win.tab_view, i) == page) return true;
    }
    return false;
}

// ── ranking → widgets ─────────────────────────────────────────────

fn onSearchChanged(entry: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    ctx.model.setQuery(cast.editableText(entry));
}

/// The model's single "results changed" hook: stamp the merge result
/// onto the rows, hide what did not match, re-sort, and keep a
/// selection under Enter.
fn onRanked(user: ?*anyopaque) void {
    const ctx = cast.userData(Ctx, user);
    const lb: *c.GtkListBox = @ptrCast(@alignCast(ctx.listbox));

    for (ctx.rows) |rctx| {
        rctx.score = 0;
        rctx.cand = null;
    }
    for (ctx.model.items.items) |cand| {
        const at: usize = @intCast(cand.payload);
        if (at >= ctx.rows.len) continue;
        ctx.rows[at].score = cand.score;
        ctx.rows[at].cand = cand;
    }

    var idx: i32 = 0;
    while (idx < @as(i32, @intCast(ctx.rows.len))) : (idx += 1) {
        const row = c.gtk_list_box_get_row_at_index(lb, idx) orelse break;
        const rctx = rowCtxOf(row) orelse continue;
        c.gtk_widget_set_visible(@ptrCast(row), if (rctx.score > 0) 1 else 0);
    }
    c.gtk_list_box_invalidate_sort(lb);

    // Always select the first visible row (post-sort: the best match)
    // so Enter has a target.
    idx = 0;
    while (idx < @as(i32, @intCast(ctx.rows.len))) : (idx += 1) {
        const row = c.gtk_list_box_get_row_at_index(lb, idx) orelse break;
        if (c.gtk_widget_get_visible(@ptrCast(row)) != 0) {
            c.gtk_list_box_select_row(lb, row);
            return;
        }
    }
    c.gtk_list_box_unselect_all(lb);
}

/// GtkListBox sort: score descending, catalogue build order on ties.
fn onSortRows(row1: ?*c.GtkListBoxRow, row2: ?*c.GtkListBoxRow, _: ?*anyopaque) callconv(.c) c_int {
    const a = rowCtxOf(row1) orelse return 0;
    const b = rowCtxOf(row2) orelse return 0;
    if (a.score > b.score) return -1;
    if (a.score < b.score) return 1;
    if (a.orig_index < b.orig_index) return -1;
    if (a.orig_index > b.orig_index) return 1;
    return 0;
}

fn rowCtxOf(row: ?*c.GtkListBoxRow) ?*RowCtx {
    const data = c.g_object_get_data(@ptrCast(@alignCast(row orelse return null)), "palette-row") orelse return null;
    return @ptrCast(@alignCast(data));
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
    // `gtk_list_box_row_activate`; calling the handler is the modern
    // equivalent.)
    onListBoxRowActivated(lb, row, @ptrCast(ctx));
}

/// GtkListBox::row-activated. Recover the RowCtx from the row's qdata
/// and fire the candidate it stands for — the framework decides what
/// that means, so there is no per-kind switch here.
fn onListBoxRowActivated(
    _: *c.GtkListBox,
    row: *c.GtkListBoxRow,
    user: ?*anyopaque,
) callconv(.c) void {
    _ = user;
    const rctx = rowCtxOf(row) orelse return;
    const cand = rctx.cand orelse return;
    _ = cand.fire();
}

fn onClosed(_: *c.AdwDialog, user: ?*anyopaque) callconv(.c) void {
    _ = user;
    // Cleanup runs via the GDestroyNotify (`freeCtx`) the
    // `g_signal_connect_data` call attached.
}

fn freeCtx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const ctx: *Ctx = @ptrCast(@alignCast(u));
        ctx.model.deinit();
        ctx.arena.deinit();
        ctx.allocator.destroy(ctx);
    }
}

// ── Helpers ───────────────────────────────────────────────────────

/// Resolve a symbolic icon into a prefix image that survives a broken
/// active icon theme. We look the paintable up ourselves at the display
/// scale; if the active theme resolves to a file that isn't on disk (a
/// stale @2x cache entry), we re-resolve through Adwaita so the row never
/// shows the broken-image placeholder. The returned GtkIconPaintable is
/// a GtkSymbolicPaintable, so recolouring to the row's foreground still
/// works, and SVG sources stay crisp at the requested size.
fn iconImage(window: *Window, fallback: ?*c.GtkIconTheme, name: [*c]const u8, size: c_int) *c.GtkWidget {
    const display = c.gtk_widget_get_display(window.app_window);
    const scale = c.gtk_widget_get_scale_factor(window.app_window);
    const theme = c.gtk_icon_theme_get_for_display(display);

    var paintable = c.gtk_icon_theme_lookup_icon(theme, name, null, size, scale, c.GTK_TEXT_DIR_LTR, 0);
    if (!iconFileExists(paintable)) {
        if (fallback) |ft| {
            const alt = c.gtk_icon_theme_lookup_icon(ft, name, null, size, scale, c.GTK_TEXT_DIR_LTR, 0);
            if (iconFileExists(alt)) {
                if (paintable != null) c.g_object_unref(paintable);
                paintable = alt;
            } else if (alt != null) {
                c.g_object_unref(alt);
            }
        }
    }

    const img = c.gtk_image_new_from_paintable(@ptrCast(paintable));
    c.gtk_image_set_pixel_size(@ptrCast(@alignCast(img)), size);
    if (paintable != null) c.g_object_unref(paintable);
    return img;
}

/// Whether a looked-up icon points at a real file. A null GFile means a
/// resource/builtin icon (no on-disk path to check) — treat it as valid.
fn iconFileExists(paintable: ?*c.GtkIconPaintable) bool {
    if (paintable == null) return false;
    const file = c.gtk_icon_paintable_get_file(paintable) orelse return true;
    defer c.g_object_unref(file);
    return c.g_file_query_exists(file, null) != 0;
}

/// Keybind hint for an editor-command row: the `editor_keybind.*`
/// override when one exists, else the command's default accelerator.
fn findEdBindingLabel(arena: std.mem.Allocator, window: *Window, cmd: ecmd.Command) ?[*:0]const u8 {
    var accel: []const u8 = ecmd.defaultAccel(cmd);
    for (window.config.editor_keybinds.items) |kb| {
        if (std.mem.eql(u8, kb.name, ecmd.name(cmd))) accel = kb.accel;
    }
    if (accel.len == 0) return null;
    const parsed = input.parseAccel(accel) orelse return null;
    const label_ptr = c.gtk_accelerator_get_label(parsed.keyval, parsed.mods);
    if (label_ptr == null) return null;
    defer c.g_free(label_ptr);
    const label = std.mem.span(@as([*:0]const u8, @ptrCast(label_ptr)));
    const z = arena.allocSentinel(u8, label.len, 0) catch return null;
    @memcpy(z, label);
    return z.ptr;
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
