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
const listdialog = @import("listdialog.zig");
const suggest = @import("../util/suggest.zig");
const commandcat = @import("commandcat.zig");
const render_kick = @import("../util/render_kick.zig");
const input = @import("input.zig");
const ecmd = @import("../editor/commands.zig");
const EditorView = @import("editorview.zig").EditorView;
const remotectl = @import("remotectl.zig");
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const Domain = @import("../config.zig").Domain;

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

    const ld = listdialog.build(.{
        .title = "Command Palette",
        .width = 640,
        .height = 480,
        .search_placeholder = "Search actions and tabs…",
    });
    const dialog = ld.dialog;
    const root = ld.root;
    const search = ld.search.?;
    const listbox = ld.listbox;
    ctx.dialog = dialog;
    ctx.search_entry = search;
    ctx.listbox = listbox;

    // The dialog owns the context: the "closed" handler's destroy-notify
    // is its single free (CLAUDE.md mechanism 1).
    _ = c.g_signal_connect_data(
        dialog,
        "closed",
        @ptrCast(&onClosed),
        @ptrCast(ctx),
        @ptrCast(&freeCtx),
        c.G_CONNECT_DEFAULT,
    );

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

    wireRanking(ctx, &commandcat.recent);
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
    try domainRows(arena, window.config.domains.items, &domains);
    try commandcat.build(arena, .{ .editor = editor_here, .domains = domains.items }, &ctx.catalog);
}

/// One "New Tab on <name>" row per configured domain; a domain with
/// no host is an ignored section and gets none.
fn domainRows(arena: std.mem.Allocator, domains: []const Domain, out: *std.ArrayList(commandcat.DomainRow)) !void {
    for (domains) |dom| {
        if (dom.host.len == 0) continue;
        try out.append(arena, .{
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
            const labels = tabLabels(arena, title, many, win.id, @intCast(i)) catch continue;
            ctx.tabs.append(arena, .{
                .title = labels.title,
                .detail = labels.detail,
                .win = win,
                .page = page,
            }) catch return;
        }
    }
}

const TabLabels = struct { title: [:0]const u8, detail: [:0]const u8 };

/// A tab row's text: an untitled tab still gets a title, and the
/// detail names the window only when there is more than one.
fn tabLabels(arena: std.mem.Allocator, title: []const u8, many: bool, win_id: u32, index: usize) !TabLabels {
    return .{
        .title = try arena.dupeZ(u8, if (title.len > 0) title else "Untitled tab"),
        .detail = if (many)
            try std.fmt.allocPrintSentinel(arena, "Window {d} \u{b7} tab {d}", .{ win_id, index + 1 }, 0)
        else
            try std.fmt.allocPrintSentinel(arena, "Tab {d}", .{index + 1}, 0),
    };
}

// ── sources ───────────────────────────────────────────────────────

/// Point `ctx.model` at this opening's catalogue and tabs, ranking the
/// catalogue with the recency in `mru`. `ctx` must not move afterwards:
/// the model borrows `ctx.sources`, which borrow `ctx.feed`.
fn wireRanking(ctx: *Ctx, mru: *commandcat.Mru) void {
    ctx.feed = .{ .rows = ctx.catalog.items, .mru = mru };
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
    ctx.model = suggest.Model.init(ctx.allocator, &ctx.sources, ctx.catalog.items.len + ctx.tabs.items.len);
}

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
    stampRanking(ctx.rows, ctx.model.items.items);

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

/// Stamp a merge result onto the rows its payloads address; a row the
/// merge left out scores 0, which is what hides it.
fn stampRanking(rows: []const *RowCtx, items: []const suggest.Candidate) void {
    for (rows) |rctx| {
        rctx.score = 0;
        rctx.cand = null;
    }
    for (items) |cand| {
        const at: usize = @intCast(cand.payload);
        if (at >= rows.len) continue;
        rows[at].score = cand.score;
        rows[at].cand = cand;
    }
}

fn onSortRows(row1: ?*c.GtkListBoxRow, row2: ?*c.GtkListBoxRow, _: ?*anyopaque) callconv(.c) c_int {
    const a = rowCtxOf(row1) orelse return 0;
    const b = rowCtxOf(row2) orelse return 0;
    return rowOrder(a, b);
}

/// GtkListBox sort: score descending, catalogue build order on ties.
fn rowOrder(a: *const RowCtx, b: *const RowCtx) c_int {
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

// -- tests --------------------------------------------------------------

const t = std.testing;

/// A palette with every widget left out: the real catalogue, the real
/// ranking wiring and the list's own sort, with plain tab rows
/// standing in for open tabs. Initialised in place, because the model
/// borrows the context.
const TestPalette = struct {
    ctx: Ctx,
    mru: commandcat.Mru,

    fn init(self: *TestPalette, cat: commandcat.Context, tab_titles: []const []const u8) !void {
        self.mru = .{};
        self.ctx = .{
            .allocator = t.allocator,
            .arena = std.heap.ArenaAllocator.init(t.allocator),
            .window = undefined,
            .dialog = undefined,
            .search_entry = undefined,
            .listbox = undefined,
            .rows = &.{},
        };
        errdefer self.ctx.arena.deinit();
        const arena = self.ctx.arena.allocator();
        try commandcat.build(arena, cat, &self.ctx.catalog);
        for (tab_titles, 0..) |title, i| {
            const labels = try tabLabels(arena, title, false, 1, i);
            try self.ctx.tabs.append(arena, .{
                .title = labels.title,
                .detail = labels.detail,
                .win = undefined,
                .page = undefined,
            });
        }
        const rows = try arena.alloc(*RowCtx, self.ctx.catalog.items.len + self.ctx.tabs.items.len);
        for (rows, 0..) |*slot, i| {
            slot.* = try arena.create(RowCtx);
            slot.*.* = .{ .orig_index = i };
        }
        self.ctx.rows = rows;
        wireRanking(&self.ctx, &self.mru);
    }

    fn deinit(self: *TestPalette) void {
        self.ctx.model.deinit();
        self.ctx.arena.deinit();
    }

    /// The rows the list shows for `q`, in the order it shows them.
    fn shown(self: *TestPalette, q: []const u8) ![]const suggest.Candidate {
        self.ctx.model.setQuery(q);
        stampRanking(self.ctx.rows, self.ctx.model.items.items);
        const arena = self.ctx.arena.allocator();
        const order = try arena.dupe(*RowCtx, self.ctx.rows);
        std.sort.insertion(*RowCtx, order, {}, sortsBefore);
        var out: std.ArrayList(suggest.Candidate) = .empty;
        for (order) |r| {
            if (r.score <= 0) continue;
            try out.append(arena, r.cand.?);
        }
        return out.items;
    }

    fn sortsBefore(_: void, a: *RowCtx, b: *RowCtx) bool {
        return rowOrder(a, b) < 0;
    }

    fn catalogRow(self: *TestPalette, title: []const u8) commandcat.Row {
        for (self.ctx.catalog.items) |row| {
            if (std.mem.eql(u8, row.title, title)) return row;
        }
        @panic("no such catalogue row");
    }
};

fn position(rows: []const suggest.Candidate, title: []const u8, kind: suggest.Kind) ?usize {
    for (rows, 0..) |r, i| {
        if (r.kind == kind and std.mem.eql(u8, r.title, title)) return i;
    }
    return null;
}

test "an empty query lists every command in catalogue order, then every tab" {
    var p: TestPalette = undefined;
    try p.init(.{}, &.{ "vim notes", "htop" });
    defer p.deinit();
    const rows = try p.shown("");
    try t.expectEqual(commandcat.curated.len + 2, rows.len);
    for (commandcat.curated, 0..) |row, i| try t.expectEqualStrings(row.title, rows[i].title);
    try t.expectEqualStrings("vim notes", rows[rows.len - 2].title);
    try t.expectEqualStrings("htop", rows[rows.len - 1].title);
}

test "title prefix beats word boundary beats description, ties keep catalogue order" {
    var p: TestPalette = undefined;
    try p.init(.{}, &.{});
    defer p.deinit();
    const rows = try p.shown("scroll");
    const top = position(rows, "Scroll to Top", .command).?;
    const bottom = position(rows, "Scroll to Bottom", .command).?;
    const copy = position(rows, "Copy Scrollback", .command).?;
    const clear = position(rows, "Clear Scrollback", .command).?;
    // "Scroll back one screenful." is a description prefix; "...whole
    // buffer: scrollback ring..." a description word boundary.
    const page_up = position(rows, "Page Up", .command).?;
    const select_all = position(rows, "Select All", .command).?;
    try t.expectEqual(@as(usize, 0), top);
    try t.expect(top < bottom);
    try t.expect(bottom < copy);
    try t.expect(copy < clear);
    try t.expect(clear < page_up);
    try t.expect(page_up < select_all);
    // Nothing that does not contain the query is shown at all.
    try t.expect(position(rows, "New Tab", .command) == null);

    // A title substring (0.6) still beats a description word boundary
    // (0.8 of 0.7).
    const back = try p.shown("back");
    try t.expect(position(back, "Copy Scrollback", .command).? < position(back, "Page Up", .command).?);
}

test "a tab never outranks a command, and sits above description-only hits" {
    var p: TestPalette = undefined;
    try p.init(.{}, &.{ "New Tab", "pane logs" });
    defer p.deinit();

    const named = try p.shown("new tab");
    try t.expectEqual(suggest.Kind.command, named[0].kind);
    try t.expectEqualStrings("New Tab", named[0].title);
    try t.expect(position(named, "New Tab", .session) != null);

    const pane = try p.shown("pane");
    const tab = position(pane, "pane logs", .session).?;
    // Below a command's word-boundary title hit...
    try t.expect(position(pane, "Zoom Pane", .command).? < tab);
    // ...above a command that only mentions it in its description.
    try t.expect(tab < position(pane, "Split Horizontal", .command).?);
}

test "every catalogue row comes first when its own title is typed" {
    const domains = [_]commandcat.DomainRow{.{
        .name = "box",
        .host_spec = "ssh:box",
        .title = "New Tab on box",
        .desc = "Durable remote shell on box (ssh).",
    }};
    // Editor rows and a domain row too, plus tabs whose titles collide
    // with commands on purpose.
    var p: TestPalette = undefined;
    try p.init(.{ .editor = true, .domains = &domains }, &.{ "Copy", "Preferences" });
    defer p.deinit();
    try t.expect(p.ctx.catalog.items.len > commandcat.curated.len);

    var lower: [128]u8 = undefined;
    for (p.ctx.catalog.items) |row| {
        const exact = try p.shown(row.title);
        try t.expectEqual(suggest.Kind.command, exact[0].kind);
        try t.expectEqualStrings(row.title, exact[0].title);
        // Matching folds ASCII case, so typing it in lower case works too.
        const folded = try p.shown(std.ascii.lowerString(&lower, row.title));
        try t.expectEqualStrings(row.title, folded[0].title);
    }
}

test "a recently run command floats above its equals, as the palette wires recency" {
    var p: TestPalette = undefined;
    try p.init(.{}, &.{});
    defer p.deinit();
    const before = try p.shown("pane");
    try t.expect(position(before, "Zoom Pane", .command).? < position(before, "Close Pane", .command).?);
    p.mru.note(commandcat.keyOf(p.catalogRow("Close Pane")));
    const after = try p.shown("pane");
    try t.expect(position(after, "Close Pane", .command).? < position(after, "Zoom Pane", .command).?);
}

test "tab rows continue the catalogue's index space and dispatch as tabs" {
    var p: TestPalette = undefined;
    try p.init(.{}, &.{ "alpha", "zeta-7" });
    defer p.deinit();
    _ = try p.shown("zeta-7");
    const n = p.ctx.catalog.items.len;
    const hit = p.ctx.rows[n + 1];
    try t.expectEqualStrings("zeta-7", hit.cand.?.title);
    try t.expect(hit.cand.?.activate.? == &activateTab);
    // The other tab did not match, so its row is hidden.
    try t.expectEqual(@as(f32, 0), p.ctx.rows[n].score);
    try t.expect(p.ctx.rows[n].cand == null);

    // Commands dispatch through the catalogue, not the tab switcher.
    _ = try p.shown("preferences");
    var commands: usize = 0;
    for (p.ctx.rows[0..n]) |r| {
        const cand = r.cand orelse continue;
        commands += 1;
        try t.expect(cand.activate.? == &activateCommand);
    }
    try t.expect(commands > 0);
}

test "a query nothing matches hides every row and clears stale candidates" {
    var p: TestPalette = undefined;
    try p.init(.{}, &.{"htop"});
    defer p.deinit();
    try t.expect((try p.shown("tab")).len > 0);
    try t.expectEqual(@as(usize, 0), (try p.shown("qqqqzz")).len);
    for (p.ctx.rows) |r| {
        try t.expectEqual(@as(f32, 0), r.score);
        try t.expect(r.cand == null);
    }
}

test "the list sorts by score, then by build order" {
    var a = RowCtx{ .orig_index = 4, .score = 0.8 };
    var b = RowCtx{ .orig_index = 1, .score = 0.8 };
    var hi = RowCtx{ .orig_index = 9, .score = 1.0 };
    try t.expectEqual(@as(c_int, 1), rowOrder(&a, &b));
    try t.expectEqual(@as(c_int, -1), rowOrder(&b, &a));
    try t.expectEqual(@as(c_int, -1), rowOrder(&hi, &b));
    try t.expectEqual(@as(c_int, 0), rowOrder(&a, &a));
}

test "tab rows name the window only when there are several" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const one = try tabLabels(arena.allocator(), "vim", false, 3, 0);
    try t.expectEqualStrings("vim", one.title);
    try t.expectEqualStrings("Tab 1", one.detail);
    const many = try tabLabels(arena.allocator(), "", true, 3, 4);
    try t.expectEqualStrings("Untitled tab", many.title);
    try t.expectEqualStrings("Window 3 \u{b7} tab 5", many.detail);
}

test "configured domains become New Tab rows, a hostless one does not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const doms = [_]Domain{
        .{ .name = "box", .host = "user@box.example", .transport = .ssh },
        .{ .name = "empty" },
        .{ .name = "lab", .host = "lab.local" },
    };
    var out: std.ArrayList(commandcat.DomainRow) = .empty;
    try domainRows(arena.allocator(), &doms, &out);
    try t.expectEqual(@as(usize, 2), out.items.len);
    try t.expectEqualStrings("New Tab on box", out.items[0].title);
    try t.expectEqualStrings("Durable remote shell on user@box.example (ssh).", out.items[0].desc);
    try t.expectEqualStrings("ssh:user@box.example", out.items[0].host_spec);
    // The automatic transport keeps the host bare.
    try t.expectEqualStrings("lab.local", out.items[1].host_spec);
    try t.expectEqualStrings("Durable remote shell on lab.local (auto).", out.items[1].desc);
}
