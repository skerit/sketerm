//! Filter-list subscription manager — the human face of the
//! `filter_list = <url>` config lines (capability "filter-subscribe").
//!
//! The helper does the fetching, caching and updating
//! (`src/web/filtersub.zig`, cefhost's `FilterFetch`); this window only
//! edits the url list. Every change goes the way a Preferences edit
//! does: the live config is cloned, the list replaced, the clone applied
//! (`applyConfigChange` pushes the new set to every helper through
//! `webface.setFilterSubscriptions`) and the file written back
//! (`persistConfig`). Reached from the window menu's Browser submenu,
//! the pane menu and the palette, all as the `web_filter_lists` verb.
//!
//! A transient toplevel over its window, the `webuserscripts.zig`
//! shape: one heap context, owned by the window's "destroy".

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const filtersub = @import("../web/filtersub.zig");
const Window = @import("window.zig").Window;

const Manager = struct {
    allocator: std.mem.Allocator,
    win: *Window,
    window: *c.GtkWidget,
    listbox: *c.GtkWidget,
    entry: *c.GtkWidget,
    status: *c.GtkWidget,
};

/// Per-row remove button context (owned by its closure).
const RowCtx = struct {
    allocator: std.mem.Allocator,
    mgr: *Manager,
    /// Index into the config's list at build time; the rows are rebuilt
    /// after every edit, so it never goes stale.
    index: usize,
};

pub fn openManager(win: *Window) void {
    const allocator = win.allocator;
    const self = allocator.create(Manager) catch return;
    const window = c.gtk_window_new();
    self.* = .{
        .allocator = allocator,
        .win = win,
        .window = window,
        .listbox = c.gtk_list_box_new(),
        .entry = c.gtk_entry_new(),
        .status = c.gtk_label_new(""),
    };
    c.gtk_window_set_title(@ptrCast(window), "Filter Lists");
    c.gtk_window_set_default_size(@ptrCast(window), 620, 420);
    c.gtk_window_set_transient_for(@ptrCast(window), @ptrCast(win.app_window));

    const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
    const intro = c.gtk_label_new("Subscribed ad-block lists (EasyList syntax). The browser fetches each one, " ++
        "keeps a cached copy, and refreshes it on the filter_update_hours schedule.");
    c.gtk_label_set_wrap(@ptrCast(intro), 1);
    c.gtk_label_set_xalign(@ptrCast(intro), 0.0);
    c.gtk_widget_set_margin_start(intro, 10);
    c.gtk_widget_set_margin_end(intro, 10);
    c.gtk_widget_set_margin_top(intro, 8);
    c.gtk_box_append(@ptrCast(root), intro);

    const scroller = c.gtk_scrolled_window_new();
    c.gtk_widget_set_vexpand(scroller, 1);
    c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_list_box_set_selection_mode(@ptrCast(self.listbox), c.GTK_SELECTION_NONE);
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), self.listbox);
    c.gtk_box_append(@ptrCast(root), scroller);

    const add_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_widget_set_margin_start(add_row, 10);
    c.gtk_widget_set_margin_end(add_row, 10);
    c.gtk_entry_set_placeholder_text(@ptrCast(self.entry), "https://easylist.to/easylist/easylist.txt");
    c.gtk_widget_set_hexpand(self.entry, 1);
    _ = c.g_signal_connect_data(self.entry, "activate", @ptrCast(&onEntryActivate), self, null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(add_row), self.entry);
    const add = c.gtk_button_new_with_label("Subscribe");
    _ = c.g_signal_connect_data(add, "clicked", @ptrCast(&onAddClicked), self, null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(add_row), add);
    c.gtk_box_append(@ptrCast(root), add_row);

    c.gtk_label_set_xalign(@ptrCast(self.status), 0.0);
    c.gtk_widget_add_css_class(self.status, "dim-label");
    c.gtk_widget_set_margin_start(self.status, 10);
    c.gtk_widget_set_margin_bottom(self.status, 8);
    c.gtk_box_append(@ptrCast(root), self.status);

    c.gtk_window_set_child(@ptrCast(window), root);
    _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&onDestroy), self, null, c.G_CONNECT_DEFAULT);
    c.gtk_window_present(@ptrCast(window));
    _ = c.gtk_widget_grab_focus(self.entry);
    rebuild(self);
}

fn onDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Manager, user);
    self.allocator.destroy(self);
}

fn setStatus(self: *Manager, text: []const u8) void {
    var buf: [512]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{text[0..@min(text.len, 500)]}) catch return;
    c.gtk_label_set_text(@ptrCast(self.status), z.ptr);
}

fn rebuild(self: *Manager) void {
    while (c.gtk_list_box_get_row_at_index(@ptrCast(self.listbox), 0)) |row|
        c.gtk_list_box_remove(@ptrCast(self.listbox), @ptrCast(row));
    const lists = self.win.config.filter_lists.items;
    for (lists, 0..) |url, i| {
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
        c.gtk_widget_set_margin_start(row, 10);
        c.gtk_widget_set_margin_end(row, 10);
        c.gtk_widget_set_margin_top(row, 4);
        c.gtk_widget_set_margin_bottom(row, 4);
        var zbuf: [2048]u8 = undefined;
        const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{url[0..@min(url.len, 2000)]}) catch continue;
        const label = c.gtk_label_new(z.ptr);
        c.gtk_label_set_xalign(@ptrCast(label), 0.0);
        c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_label_set_selectable(@ptrCast(label), 1);
        c.gtk_widget_set_hexpand(label, 1);
        c.gtk_box_append(@ptrCast(row), label);
        const rm = c.gtk_button_new_from_icon_name("user-trash-symbolic");
        c.gtk_widget_set_tooltip_text(rm, "Unsubscribe");
        const ctx = self.allocator.create(RowCtx) catch continue;
        ctx.* = .{ .allocator = self.allocator, .mgr = self, .index = i };
        _ = c.g_signal_connect_data(rm, "clicked", @ptrCast(&onRemoveClicked), ctx, @ptrCast(cast.destroyCtx(RowCtx)), c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row), rm);
        c.gtk_list_box_append(@ptrCast(self.listbox), row);
    }
    var sbuf: [128]u8 = undefined;
    const s = if (lists.len == 0)
        "No filter lists subscribed: only the built-in rules block."
    else
        std.fmt.bufPrint(&sbuf, "{d} list{s} subscribed; updated every {d} h.", .{
            lists.len, if (lists.len == 1) "" else "s", self.win.config.filter_update_hours,
        }) catch "";
    setStatus(self, s);
}

/// Apply a new url list the way a Preferences edit is applied, then
/// write config.conf.
fn commit(self: *Manager, urls: []const []const u8) void {
    var cfg = self.win.config.clone(self.allocator) catch return;
    defer cfg.deinit();
    const arena = (&cfg.arena.?).allocator();
    var list: std.ArrayList([]const u8) = .empty;
    for (urls) |u| {
        const owned = arena.dupe(u8, u) catch return;
        list.append(arena, owned) catch return;
    }
    cfg.filter_lists = list;
    self.win.applyConfigChange(&cfg);
    @import("winconfig.zig").persistConfig(self.win);
    rebuild(self);
}

fn addFromEntry(self: *Manager) void {
    const text = std.mem.span(c.gtk_editable_get_text(@ptrCast(self.entry)));
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const next = filtersub.withAdded(arena_state.allocator(), self.win.config.filter_lists.items, text) catch |err| {
        setStatus(self, switch (err) {
            error.InvalidUrl => "Not a list url: it must be http:// or https:// with a host.",
            error.AlreadySubscribed => "Already subscribed to that list.",
            error.OutOfMemory => "Out of memory.",
        });
        return;
    };
    commit(self, next);
    c.gtk_editable_set_text(@ptrCast(self.entry), "");
}

fn onEntryActivate(_: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    addFromEntry(cast.userData(Manager, user));
}

fn onAddClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    addFromEntry(cast.userData(Manager, user));
}

fn onRemoveClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RowCtx, user);
    const self = ctx.mgr;
    const lists = self.win.config.filter_lists.items;
    if (ctx.index >= lists.len) return;
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    // Copy first: `commit` replaces the config arena these slices live in.
    const url = arena_state.allocator().dupe(u8, lists[ctx.index]) catch return;
    const next = filtersub.withRemoved(arena_state.allocator(), lists, url) catch return;
    var copies: std.ArrayList([]const u8) = .empty;
    for (next) |u| copies.append(arena_state.allocator(), arena_state.allocator().dupe(u8, u) catch return) catch return;
    // Rebuilding the rows destroys this button (and ctx) — `commit` is
    // the last thing that touches either.
    commit(self, copies.items);
}
