//! The browsing history and bookmarks windows — the human face of the
//! daemon-side web store (`src/mux/webstore.zig`, GUI client
//! `src/ui/webstore.zig`).
//!
//! Both are ordinary transient toplevels over the window that opened
//! them, like the app launcher and Preferences: non-modal, so the page
//! a row navigates to is visible behind them and the list can stay up
//! while the user works through it. Nothing here reads or writes a
//! file — every row comes from a `web_op` round trip, so a GUI attached
//! to a remote daemon lists THAT host's browsing state.
//!
//! Lifetime: one heap `List` per window, freed on the window's
//! "destroy" (mechanism 1 — the widget owns the data). The store's
//! async replies resolve through that same pointer, so "destroy" is
//! also the single `webstore.cancelFor` choke point required by
//! `ui/webstore.zig`'s contract.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const suggest = @import("../util/suggest.zig");
const webstore = @import("webstore.zig");
const classicmenu = @import("browser/classicmenu.zig");
const confirm = @import("confirm.zig");
const clipboard = @import("clipboard.zig");
const Window = @import("window.zig").Window;
const Pane = @import("pane.zig").Pane;
const WebFace = @import("webface.zig").WebFace;

const Kind = enum { history, bookmarks };

/// Row payloads live on the GtkListBoxRow as GLib-owned strings (the
/// app-launcher idiom), so a re-list is "drop the rows" and no Zig-side
/// parallel array can go stale against the widgets.
const KEY_URL = "wh-url";
const KEY_TITLE = "wh-title";
const KEY_FOLDER = "wh-folder";
/// Bookmark id, stashed as a pointer-sized integer (never dereferenced).
const KEY_ID = "wh-id";
/// The bookmark's position in the store's FLAT list — what a reorder
/// addresses, independent of how the folder grouping displays it.
const KEY_INDEX = "wh-index";

const List = struct {
    allocator: std.mem.Allocator,
    kind: Kind,
    win: *Window,
    /// The pane whose web face a plain activation navigates. Re-resolved
    /// through the window's pane list on every use, so a pane closing
    /// under this window cannot dangle.
    pane: ?*Pane,
    window: *c.GtkWidget,
    listbox: *c.GtkWidget,
    search: *c.GtkWidget,
    status: *c.GtkWidget,
    /// Wall-clock ms at the last refresh, so every row in one list ages
    /// against the same instant.
    now_ms: i64 = 0,

    fn liveFace(self: *List) ?*WebFace {
        const pane = self.pane orelse return null;
        for (self.win.panes.items) |p| {
            if (p == pane) return WebFace.fromPane(pane);
        }
        return null;
    }

    /// Navigate the pane that opened this window, or open a tab when
    /// that pane is gone (or a new tab was asked for explicitly).
    fn openUrl(self: *List, url: []const u8, new_tab: bool) void {
        if (url.len == 0) return;
        if (!new_tab) {
            if (self.liveFace()) |face| {
                face.navigate(url);
                return;
            }
        }
        self.win.newWebTabAt(url) catch {};
    }

    fn setStatus(self: *List, text: [*:0]const u8) void {
        c.gtk_label_set_text(@ptrCast(self.status), text);
    }
};

// ── relative time ───────────────────────────────────────────────

/// "3 minutes ago" for a wall-clock timestamp, written into `buf`.
///
/// Relative rather than absolute so no timezone has to be guessed at,
/// and buffer-based because it is called once per visible row. The
/// thresholds overshoot each unit (90 seconds is still "just now") so a
/// list never shows "1 minutes ago" rounding noise.
pub fn relativeTime(buf: []u8, now_ms: i64, then_ms: i64) []const u8 {
    if (then_ms <= 0) return "";
    if (then_ms > now_ms) return "just now";
    const secs = @divTrunc(now_ms - then_ms, 1000);
    if (secs < 90) return "just now";
    const mins = @divTrunc(secs, 60);
    if (mins < 90) return plural(buf, mins, "minute");
    const hours = @divTrunc(mins, 60);
    if (hours < 48) return plural(buf, hours, "hour");
    const days = @divTrunc(hours, 24);
    if (days < 14) return plural(buf, days, "day");
    const weeks = @divTrunc(days, 7);
    if (weeks < 9) return plural(buf, weeks, "week");
    const months = @divTrunc(days, 30);
    if (months < 24) return plural(buf, months, "month");
    return plural(buf, @divTrunc(days, 365), "year");
}

fn plural(buf: []u8, n: i64, unit: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d} {s}{s} ago", .{
        n,
        unit,
        if (n == 1) "" else "s",
    }) catch "a while ago";
}

const wallMs = @import("../util/clock.zig").wallMs;

// ── window construction ─────────────────────────────────────────

/// Open the browsing-history window over `win`. `pane` (when it wears
/// a web face) is what a plain row activation navigates.
pub fn openHistory(win: *Window, pane: ?*Pane) void {
    open(win, pane, .history);
}

pub fn openBookmarks(win: *Window, pane: ?*Pane) void {
    open(win, pane, .bookmarks);
}

fn open(win: *Window, pane: ?*Pane, kind: Kind) void {
    const allocator = win.allocator;
    const self = allocator.create(List) catch return;
    const window = c.gtk_window_new();
    self.* = .{
        .allocator = allocator,
        .kind = kind,
        .win = win,
        .pane = pane,
        .window = window,
        .listbox = c.gtk_list_box_new(),
        .search = c.gtk_search_entry_new(),
        .status = c.gtk_label_new("Loading…"),
    };

    c.gtk_window_set_title(@ptrCast(window), switch (kind) {
        .history => "History",
        .bookmarks => "Bookmarks",
    });
    c.gtk_window_set_default_size(@ptrCast(window), 720, 640);
    c.gtk_window_set_transient_for(@ptrCast(window), @ptrCast(win.app_window));

    const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);

    // Search. History filters server-side through `history_query`'s
    // ranking (the store, not this window, decides what "best match"
    // means); bookmarks are few enough to filter in the listbox.
    c.gtk_search_entry_set_placeholder_text(
        @ptrCast(self.search),
        switch (kind) {
            .history => "Search history",
            .bookmarks => "Filter bookmarks",
        },
    );
    c.gtk_widget_set_margin_start(self.search, 8);
    c.gtk_widget_set_margin_end(self.search, 8);
    c.gtk_widget_set_margin_top(self.search, 8);
    c.gtk_widget_set_margin_bottom(self.search, 4);
    _ = c.g_signal_connect_data(self.search, "search-changed", @ptrCast(&onSearchChanged), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(self.search, "activate", @ptrCast(&onSearchActivate), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(self.search, "stop-search", @ptrCast(&onStopSearch), self, null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(root), self.search);

    const esc = c.gtk_shortcut_controller_new();
    c.gtk_shortcut_controller_add_shortcut(
        @ptrCast(esc),
        c.gtk_shortcut_new(
            c.gtk_keyval_trigger_new(c.GDK_KEY_Escape, 0),
            c.gtk_callback_action_new(@ptrCast(&onEscape), self, null),
        ),
    );
    c.gtk_widget_add_controller(window, esc);

    const scroller = c.gtk_scrolled_window_new();
    c.gtk_widget_set_vexpand(scroller, 1);
    c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), self.listbox);
    _ = c.g_signal_connect_data(self.listbox, "row-activated", @ptrCast(&onRowActivated), self, null, c.G_CONNECT_DEFAULT);
    if (kind == .bookmarks) {
        c.gtk_list_box_set_filter_func(@ptrCast(self.listbox), @ptrCast(&filterRow), self, null);
        // Folders are plain groups, not a hierarchy: a header widget
        // above the first row of each folder. Headers are not rows, so
        // nothing here can be activated or deleted by accident.
        c.gtk_list_box_set_header_func(@ptrCast(self.listbox), @ptrCast(&folderHeader), self, null);
    }
    c.gtk_box_append(@ptrCast(root), scroller);

    // Right-click a row for the verbs that do not deserve a button.
    const rclick = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(rclick), 3);
    _ = c.g_signal_connect_data(rclick, "pressed", @ptrCast(&onRowRightClick), self, null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(self.listbox, @ptrCast(rclick));

    const footer = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_widget_set_margin_start(footer, 10);
    c.gtk_widget_set_margin_end(footer, 10);
    c.gtk_widget_set_margin_top(footer, 4);
    c.gtk_widget_set_margin_bottom(footer, 8);
    c.gtk_label_set_xalign(@ptrCast(self.status), 0.0);
    c.gtk_widget_set_hexpand(self.status, 1);
    c.gtk_widget_add_css_class(self.status, "dim-label");
    c.gtk_box_append(@ptrCast(footer), self.status);
    if (kind == .history) {
        const clear = c.gtk_button_new_with_label("Clear History…");
        c.gtk_widget_add_css_class(clear, "destructive-action");
        _ = c.g_signal_connect_data(clear, "clicked", @ptrCast(&onClearHistory), self, null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(footer), clear);
    }
    c.gtk_box_append(@ptrCast(root), footer);

    c.gtk_window_set_child(@ptrCast(window), root);
    _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&onDestroy), self, null, c.G_CONNECT_DEFAULT);

    c.gtk_window_present(@ptrCast(window));
    _ = c.gtk_widget_grab_focus(self.search);
    refresh(self);
}

fn onDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(List, user);
    // The store's async replies resolve through `self`; this is the
    // single choke point its contract asks for.
    webstore.cancelFor(@ptrCast(self));
    self.allocator.destroy(self);
}

fn onEscape(_: ?*c.GtkWidget, _: ?*c.GVariant, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(List, user);
    c.gtk_window_destroy(@ptrCast(self.window));
    return 1;
}

fn onStopSearch(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(List, user);
    // Escape in a search entry clears it first; an empty box means the
    // user wants the window gone.
    if (std.mem.span(c.gtk_editable_get_text(@ptrCast(self.search))).len == 0)
        c.gtk_window_destroy(@ptrCast(self.window));
}

fn onSearchChanged(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(List, user);
    switch (self.kind) {
        // Server-side ranking: re-query rather than filter what is
        // already listed, or a match outside the first page never
        // shows up.
        .history => refresh(self),
        .bookmarks => c.gtk_list_box_invalidate_filter(@ptrCast(self.listbox)),
    }
}

/// Enter in the search box opens the first visible row.
fn onSearchActivate(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(List, user);
    var i: c_int = 0;
    while (c.gtk_list_box_get_row_at_index(@ptrCast(self.listbox), i)) |row| : (i += 1) {
        if (self.kind == .bookmarks and filterRow(@ptrCast(row), @ptrCast(self)) == 0) continue;
        activate(self, @ptrCast(row), false);
        return;
    }
}

fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    activate(cast.userData(List, user), row, false);
}

fn activate(self: *List, row: *c.GtkListBoxRow, new_tab: bool) void {
    self.openUrl(rowStr(row, KEY_URL), new_tab);
}

// ── refresh ─────────────────────────────────────────────────────

fn refresh(self: *List) void {
    self.now_ms = wallMs();
    const ok = switch (self.kind) {
        .history => blk: {
            const q = std.mem.span(c.gtk_editable_get_text(@ptrCast(self.search)));
            break :blk webstore.historyQuery(self.allocator, q, 200, @ptrCast(self), &onHits);
        },
        .bookmarks => webstore.bookmarkList(self.allocator, @ptrCast(self), &onBookmarks),
    };
    if (!ok) {
        clearList(self.listbox);
        self.setStatus("No web store on this daemon (it may be an older build).");
    }
}

fn onHits(ctx: ?*anyopaque, ok: bool, payload: []const u8) void {
    const self = cast.userData(List, ctx);
    if (!ok) {
        self.setStatus("The web store connection dropped.");
        return;
    }
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const hits = webstore.parseHits(arena.allocator(), payload);
    clearList(self.listbox);
    for (hits) |h| addHistoryRow(self, h);
    var buf: [96]u8 = undefined;
    const searching = std.mem.span(c.gtk_editable_get_text(@ptrCast(self.search))).len > 0;
    const msg = if (hits.len == 0)
        (if (searching)
            std.fmt.bufPrintZ(&buf, "No page in history matches that.", .{}) catch ""
        else
            std.fmt.bufPrintZ(&buf, "History is empty.", .{}) catch "")
    else
        std.fmt.bufPrintZ(&buf, "{d} page{s}{s}", .{
            hits.len,
            if (hits.len == 1) "" else "s",
            if (hits.len == 200) " (best matches)" else "",
        }) catch "";
    self.setStatus(msg.ptr);
}

fn onBookmarks(ctx: ?*anyopaque, ok: bool, payload: []const u8) void {
    const self = cast.userData(List, ctx);
    if (!ok) {
        self.setStatus("The web store connection dropped.");
        return;
    }
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const marks = webstore.parseBookmarks(arena.allocator(), payload);
    clearList(self.listbox);
    // Grouped for display, but each row remembers its FLAT index so a
    // reorder still addresses the store's own ordering.
    const order = arena.allocator().alloc(usize, marks.len) catch return;
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, marks, folderBefore);
    for (order) |i| addBookmarkRow(self, marks[i], i);
    var buf: [64]u8 = undefined;
    const msg = if (marks.len == 0)
        std.fmt.bufPrintZ(&buf, "No bookmarks yet — the toolbar star adds one.", .{}) catch ""
    else
        std.fmt.bufPrintZ(&buf, "{d} bookmark{s}", .{ marks.len, if (marks.len == 1) "" else "s" }) catch "";
    self.setStatus(msg.ptr);
}

/// Top level first, then folders alphabetically; inside a folder the
/// store's own order is kept (that is what reordering moves).
fn folderBefore(marks: []const webstore.BookmarkEntry, ia: usize, ib: usize) bool {
    const a = marks[ia].folder;
    const b = marks[ib].folder;
    if (a.len != b.len or !std.mem.eql(u8, a, b)) {
        if (a.len == 0) return true;
        if (b.len == 0) return false;
        return std.mem.lessThan(u8, a, b);
    }
    return ia < ib;
}

fn clearList(list: *c.GtkWidget) void {
    while (c.gtk_widget_get_first_child(list)) |child| {
        c.gtk_list_box_remove(@ptrCast(list), child);
    }
}

// ── rows ────────────────────────────────────────────────────────

fn setRowStr(row: *c.GtkWidget, key: [*:0]const u8, value: []const u8) void {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{value}) catch return;
    c.g_object_set_data_full(@ptrCast(@alignCast(row)), key, c.g_strdup(z.ptr), c.g_free);
}

fn rowStr(row: *c.GtkListBoxRow, key: [*:0]const u8) []const u8 {
    const p = c.g_object_get_data(@ptrCast(@alignCast(row)), key) orelse return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

fn rowUint(row: *c.GtkListBoxRow, key: [*:0]const u8) usize {
    return @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(row)), key));
}

/// Two stacked labels (title over url) plus whatever the caller packs
/// on the right — the shape both lists share.
fn rowShell(row: *c.GtkWidget, title: []const u8, url: []const u8) *c.GtkWidget {
    const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 10);
    c.gtk_widget_set_margin_start(box, 8);
    c.gtk_widget_set_margin_end(box, 8);
    c.gtk_widget_set_margin_top(box, 5);
    c.gtk_widget_set_margin_bottom(box, 5);

    const text = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_hexpand(text, 1);
    var buf: [1024]u8 = undefined;
    // A page with no title is listed by its address rather than blank.
    const shown_title = if (title.len > 0) title else url;
    if (std.fmt.bufPrintZ(&buf, "{s}", .{shown_title})) |z| {
        const lbl = c.gtk_label_new(z.ptr);
        c.gtk_label_set_xalign(@ptrCast(lbl), 0.0);
        c.gtk_label_set_ellipsize(@ptrCast(lbl), c.PANGO_ELLIPSIZE_END);
        c.gtk_box_append(@ptrCast(text), lbl);
    } else |_| {}
    if (std.fmt.bufPrintZ(&buf, "{s}", .{url})) |z| {
        const lbl = c.gtk_label_new(z.ptr);
        c.gtk_label_set_xalign(@ptrCast(lbl), 0.0);
        c.gtk_label_set_ellipsize(@ptrCast(lbl), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_widget_add_css_class(lbl, "dim-label");
        c.gtk_widget_add_css_class(lbl, "caption");
        c.gtk_box_append(@ptrCast(text), lbl);
    } else |_| {}
    c.gtk_box_append(@ptrCast(box), text);
    c.gtk_list_box_row_set_child(@ptrCast(row), box);
    return box;
}

fn iconButton(box: *c.GtkWidget, icon: [*:0]const u8, tip: [*:0]const u8, cb: anytype, user: ?*anyopaque) *c.GtkWidget {
    const btn = c.gtk_button_new_from_icon_name(icon).?;
    c.gtk_widget_set_tooltip_text(btn, tip);
    c.gtk_widget_add_css_class(btn, "flat");
    c.gtk_widget_set_valign(btn, c.GTK_ALIGN_CENTER);
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(cb), user, null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(box), btn);
    return btn;
}

fn addHistoryRow(self: *List, hit: webstore.HistoryHit) void {
    if (hit.url.len == 0) return;
    const row = c.gtk_list_box_row_new().?;
    const box = rowShell(row, hit.title, hit.url);
    setRowStr(row, KEY_URL, hit.url);
    setRowStr(row, KEY_TITLE, hit.title);

    var meta: [64]u8 = undefined;
    var age: [48]u8 = undefined;
    const when = relativeTime(&age, self.now_ms, hit.last_ms);
    const text = if (hit.visits > 1)
        std.fmt.bufPrintZ(&meta, "{s} · {d} visits", .{ when, hit.visits }) catch ""
    else
        std.fmt.bufPrintZ(&meta, "{s}", .{when}) catch "";
    const lbl = c.gtk_label_new(text.ptr);
    c.gtk_widget_add_css_class(lbl, "dim-label");
    c.gtk_widget_add_css_class(lbl, "caption");
    c.gtk_widget_set_valign(lbl, c.GTK_ALIGN_CENTER);
    c.gtk_box_append(@ptrCast(box), lbl);

    // The row OWNS its per-row context (mechanism 1): the button's
    // closure dies with the row, so a re-list can never leave a handler
    // pointing at a row that is gone. A row that could not get one is
    // still listed, just without the verbs that would resolve through
    // a null pointer.
    if (rowCtx(self, row)) |ctx|
        _ = iconButton(box, "user-trash-symbolic", "Forget this page", &onDeleteRow, ctx);
    c.gtk_list_box_append(@ptrCast(self.listbox), row);
}

fn addBookmarkRow(self: *List, mark: webstore.BookmarkEntry, flat_index: usize) void {
    if (mark.url.len == 0) return;
    const row = c.gtk_list_box_row_new().?;
    const box = rowShell(row, mark.title, mark.url);
    setRowStr(row, KEY_URL, mark.url);
    setRowStr(row, KEY_TITLE, mark.title);
    setRowStr(row, KEY_FOLDER, mark.folder);
    c.g_object_set_data(@ptrCast(@alignCast(row)), KEY_ID, @ptrFromInt(@as(usize, @intCast(mark.id))));
    c.g_object_set_data(@ptrCast(@alignCast(row)), KEY_INDEX, @ptrFromInt(flat_index));

    if (rowCtx(self, row)) |ctx| {
        _ = iconButton(box, "tab-new-symbolic", "Open in a new tab", &onOpenNewTabRow, ctx);
        _ = iconButton(box, "user-trash-symbolic", "Delete this bookmark", &onDeleteRow, ctx);
    }
    c.gtk_list_box_append(@ptrCast(self.listbox), row);
}

/// Header above the first row of each folder group.
fn folderHeader(row: *c.GtkListBoxRow, before: ?*c.GtkListBoxRow, _: ?*anyopaque) callconv(.c) void {
    const folder = rowStr(row, KEY_FOLDER);
    if (before) |b| {
        const prev = rowStr(b, KEY_FOLDER);
        if (std.mem.eql(u8, prev, folder)) {
            c.gtk_list_box_row_set_header(row, null);
            return;
        }
    } else if (folder.len == 0) {
        // Top-level bookmarks at the top of the list need no "no
        // folder" caption.
        c.gtk_list_box_row_set_header(row, null);
        return;
    }
    var buf: [256]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{if (folder.len > 0) folder else "Other bookmarks"}) catch return;
    const lbl = c.gtk_label_new(z.ptr);
    c.gtk_label_set_xalign(@ptrCast(lbl), 0.0);
    c.gtk_widget_add_css_class(lbl, "dim-label");
    c.gtk_widget_add_css_class(lbl, "heading");
    c.gtk_widget_set_margin_start(lbl, 8);
    c.gtk_widget_set_margin_top(lbl, 8);
    c.gtk_widget_set_margin_bottom(lbl, 2);
    c.gtk_list_box_row_set_header(row, lbl);
}

/// Bookmark visibility. The MATCHER is the shared one
/// (`suggest.containsFold`), but the ranking framework's `merge` is
/// deliberately not used here: this is a GTK filter func, so the result
/// has to be a boolean, and the display order is folder grouping plus
/// the user's own manual ordering (`folderBefore`) — a score sort would
/// destroy both, along with the section headers that depend on adjacent
/// rows sharing a folder. History needs none of this: it is re-queried
/// and ranked daemon-side on every keystroke.
fn filterRow(row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(List, user);
    const query = std.mem.span(c.gtk_editable_get_text(@ptrCast(self.search)));
    if (query.len == 0) return 1;
    return if (suggest.containsFold(rowStr(row, KEY_TITLE), query) or
        suggest.containsFold(rowStr(row, KEY_URL), query) or
        suggest.containsFold(rowStr(row, KEY_FOLDER), query)) 1 else 0;
}

// ── per-row context ─────────────────────────────────────────────

/// A row and the list it belongs to, as one pointer for the row's own
/// buttons and menu. Owned by the row (`g_object_set_data_full`), so it
/// is freed exactly when the row is — including by a re-list.
const RowCtx = struct {
    allocator: std.mem.Allocator,
    list: *List,
    row: *c.GtkListBoxRow,
};

fn freeRowCtx(user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RowCtx, user);
    ctx.allocator.destroy(ctx);
}

fn rowCtx(self: *List, row: *c.GtkWidget) ?*anyopaque {
    // One context per row, made on first use and kept as row qdata.
    if (c.g_object_get_data(@ptrCast(@alignCast(row)), "wh-ctx")) |p| return p;
    const ctx = self.allocator.create(RowCtx) catch return null;
    ctx.* = .{ .allocator = self.allocator, .list = self, .row = @ptrCast(row) };
    c.g_object_set_data_full(@ptrCast(@alignCast(row)), "wh-ctx", @ptrCast(ctx), freeRowCtx);
    return @ptrCast(ctx);
}

fn onDeleteRow(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    deleteRow(cast.userData(RowCtx, user));
}

fn deleteRow(ctx: *RowCtx) void {
    const self = ctx.list;
    switch (self.kind) {
        .history => webstore.historyDelete(self.allocator, rowStr(ctx.row, KEY_URL)),
        .bookmarks => webstore.bookmarkRemove(self.allocator, @intCast(rowUint(ctx.row, KEY_ID))),
    }
    // The write is ordered ahead of the re-list on the same connection,
    // so the refreshed list already reflects it.
    refresh(self);
}

fn onOpenNewTabRow(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RowCtx, user);
    ctx.list.openUrl(rowStr(ctx.row, KEY_URL), true);
}

// ── row context menu ────────────────────────────────────────────

fn onRowRightClick(_: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(List, user);
    const row = c.gtk_list_box_get_row_at_y(@ptrCast(self.listbox), @intFromFloat(y)) orelse return;
    c.gtk_list_box_select_row(@ptrCast(self.listbox), row);
    const ctx = rowCtx(self, @ptrCast(row)) orelse return;

    const root = classicmenu.Root.create(self.allocator) orelse return;
    const m = root.top();
    m.item("Open", &onMenuOpen, ctx);
    m.item("Open in New Tab", &onMenuOpenNewTab, ctx);
    m.item("Copy Address", &onMenuCopy, ctx);
    if (self.kind == .bookmarks) {
        const edit = m.section();
        edit.item("Rename…", &onMenuRename, ctx);
        edit.item("Move to Folder…", &onMenuFolder, ctx);
        const order = m.section();
        order.itemIconEnabled("Move Up", .{ .name = "go-up-symbolic" }, rowUint(row, KEY_INDEX) > 0, &onMenuUp, ctx);
        order.itemIcon("Move Down", .{ .name = "go-down-symbolic" }, &onMenuDown, ctx);
    }
    const del = m.section();
    del.itemIcon(
        if (self.kind == .history) "Forget This Page" else "Delete Bookmark",
        .{ .name = "user-trash-symbolic" },
        &onMenuDelete,
        ctx,
    );
    _ = root.popup(self.listbox, x, y);
}

fn onMenuOpen(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RowCtx, user);
    ctx.list.openUrl(rowStr(ctx.row, KEY_URL), false);
}

fn onMenuOpenNewTab(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RowCtx, user);
    ctx.list.openUrl(rowStr(ctx.row, KEY_URL), true);
}

fn onMenuCopy(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RowCtx, user);
    const url = rowStr(ctx.row, KEY_URL);
    const z = ctx.allocator.dupeZ(u8, url) catch return;
    defer ctx.allocator.free(z);
    clipboard.copyToClipboard(ctx.list.listbox, z);
}

fn onMenuDelete(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    deleteRow(cast.userData(RowCtx, user));
}

fn onMenuUp(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    move(cast.userData(RowCtx, user), -1);
}

fn onMenuDown(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    move(cast.userData(RowCtx, user), 1);
}

fn move(ctx: *RowCtx, delta: i32) void {
    const at: i64 = @intCast(rowUint(ctx.row, KEY_INDEX));
    const want = at + delta;
    if (want < 0) return;
    webstore.bookmarkUpdate(
        ctx.list.allocator,
        @intCast(rowUint(ctx.row, KEY_ID)),
        "",
        "",
        null,
        @intCast(want),
    );
    refresh(ctx.list);
}

// ── rename / re-folder ──────────────────────────────────────────

/// The entry a rename/re-folder prompt is reading, kept alive for the
/// dialog's async answer. Owned by the dialog (mechanism 1).
const EditCtx = struct {
    allocator: std.mem.Allocator,
    list: *List,
    id: u64,
    field: enum { title, folder },
    entry: *c.GtkWidget,
};

fn freeEditCtx(user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(EditCtx, user);
    ctx.allocator.destroy(ctx);
}

fn onMenuRename(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    promptEdit(cast.userData(RowCtx, user), .title);
}

fn onMenuFolder(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    promptEdit(cast.userData(RowCtx, user), .folder);
}

fn promptEdit(ctx: *RowCtx, field: @FieldType(EditCtx, "field")) void {
    const self = ctx.list;
    const entry = c.gtk_entry_new().?;
    const current = rowStr(ctx.row, if (field == .title) KEY_TITLE else KEY_FOLDER);
    var buf: [1024]u8 = undefined;
    if (std.fmt.bufPrintZ(&buf, "{s}", .{current})) |z|
        c.gtk_editable_set_text(@ptrCast(entry), z.ptr)
    else |_| {}
    c.gtk_entry_set_placeholder_text(
        @ptrCast(entry),
        if (field == .title) "Bookmark name" else "Folder (empty = top level)",
    );

    const edit = self.allocator.create(EditCtx) catch return;
    edit.* = .{
        .allocator = self.allocator,
        .list = self,
        .id = @intCast(rowUint(ctx.row, KEY_ID)),
        .field = field,
        .entry = entry,
    };
    const dialog = confirm.present(
        self.window,
        .{
            .heading = if (field == .title) "Rename Bookmark" else "Move Bookmark to Folder",
            .responses = &.{
                .{ .id = "cancel", .label = "Cancel", .is_close = true },
                .{ .id = "save", .label = "Save", .appearance = .suggested, .is_default = true },
            },
            .extra_child = entry,
            .focus = entry,
        },
        .{ .allocator = self.allocator, .cb = &onEditAnswer, .ctx = @ptrCast(edit) },
    );
    if (dialog) |d| {
        // Qdata-at-finalize, so the entry text is still readable when
        // the response callback runs (the free is the dialog's, not the
        // callback's).
        c.g_object_set_data_full(@ptrCast(@alignCast(d)), "wh-edit", @ptrCast(edit), freeEditCtx);
    } else {
        self.allocator.destroy(edit);
    }
}

fn onEditAnswer(user: ?*anyopaque, response: []const u8) void {
    const ctx = cast.userData(EditCtx, user);
    if (!std.mem.eql(u8, response, "save")) return;
    const text = std.mem.span(c.gtk_editable_get_text(@ptrCast(ctx.entry)));
    switch (ctx.field) {
        // An empty rename is ignored: the daemon reads "" as "leave it
        // alone", and a nameless bookmark is not a thing to want.
        .title => if (text.len > 0)
            webstore.bookmarkUpdate(ctx.allocator, ctx.id, "", text, null, null),
        // An empty folder IS meaningful here — it moves the bookmark
        // back to the top level.
        .folder => webstore.bookmarkUpdate(ctx.allocator, ctx.id, "", "", text, null),
    }
    refresh(ctx.list);
}

// ── clear history ───────────────────────────────────────────────

fn onClearHistory(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(List, user);
    _ = confirm.present(
        self.window,
        .{
            .heading = "Clear browsing history?",
            .body = "Every page this daemon remembers visiting is forgotten. Bookmarks and site settings are kept.",
            .responses = &.{
                .{ .id = "cancel", .label = "Cancel", .is_close = true, .is_default = true },
                .{ .id = "clear", .label = "Clear History", .appearance = .destructive },
            },
        },
        .{ .allocator = self.allocator, .cb = &onClearAnswer, .ctx = @ptrCast(self) },
    );
}

fn onClearAnswer(user: ?*anyopaque, response: []const u8) void {
    const self = cast.userData(List, user);
    if (!std.mem.eql(u8, response, "clear")) return;
    webstore.historyClear(self.allocator);
    refresh(self);
}

// ── tests ───────────────────────────────────────────────────────

test "webhistory: relative time reads naturally at every scale" {
    const t = std.testing;
    var buf: [48]u8 = undefined;
    const now: i64 = 1_000_000_000_000;
    const sec = 1000;
    const min = 60 * sec;
    const hour = 60 * min;
    const day = 24 * hour;

    try t.expectEqualStrings("just now", relativeTime(&buf, now, now));
    try t.expectEqualStrings("just now", relativeTime(&buf, now, now - 89 * sec));
    try t.expectEqualStrings("1 minute ago", relativeTime(&buf, now, now - 90 * sec));
    try t.expectEqualStrings("5 minutes ago", relativeTime(&buf, now, now - 5 * min));
    try t.expectEqualStrings("89 minutes ago", relativeTime(&buf, now, now - 89 * min));
    try t.expectEqualStrings("1 hour ago", relativeTime(&buf, now, now - 90 * min));
    try t.expectEqualStrings("47 hours ago", relativeTime(&buf, now, now - 47 * hour));
    try t.expectEqualStrings("2 days ago", relativeTime(&buf, now, now - 48 * hour));
    try t.expectEqualStrings("13 days ago", relativeTime(&buf, now, now - 13 * day));
    try t.expectEqualStrings("2 weeks ago", relativeTime(&buf, now, now - 14 * day));
    try t.expectEqualStrings("8 weeks ago", relativeTime(&buf, now, now - 60 * day));
    try t.expectEqualStrings("2 months ago", relativeTime(&buf, now, now - 63 * day));
    try t.expectEqualStrings("23 months ago", relativeTime(&buf, now, now - 700 * day));
    try t.expectEqualStrings("2 years ago", relativeTime(&buf, now, now - 730 * day));

    // A never-visited entry says nothing rather than "56 years ago",
    // and a clock that stepped backwards must not print a negative age.
    try t.expectEqualStrings("", relativeTime(&buf, now, 0));
    try t.expectEqualStrings("just now", relativeTime(&buf, now, now + 5 * min));
}

test "webhistory: bookmark grouping puts top level first, then folders" {
    const t = std.testing;
    const marks = [_]webstore.BookmarkEntry{
        .{ .id = 1, .url = "https://w/", .title = "W", .folder = "work" },
        .{ .id = 2, .url = "https://t/", .title = "T", .folder = "" },
        .{ .id = 3, .url = "https://a/", .title = "A", .folder = "admin" },
        .{ .id = 4, .url = "https://w2/", .title = "W2", .folder = "work" },
    };
    var order = [_]usize{ 0, 1, 2, 3 };
    const all: []const webstore.BookmarkEntry = &marks;
    std.mem.sort(usize, &order, all, folderBefore);
    // Top level, then "admin", then "work" — and inside "work" the
    // store's own order survives, because that is what a reorder moves.
    try t.expectEqualSlices(usize, &.{ 1, 2, 0, 3 }, &order);
}
