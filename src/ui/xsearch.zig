//! Cross-session search — palette action `cross_search`. AdwDialog
//! with a query entry; Enter searches EVERY session on the local mux
//! daemon server-side (scrollback + live grid, case-insensitive
//! substring) and lists the hits. Activating a hit focuses the pane
//! already showing that session or attaches it as a new tab.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const listdialog = @import("listdialog.zig");
const mux_cli = @import("../ipc/mux_cli.zig");
const window_mod = @import("window.zig");
const Window = window_mod.Window;

const MAX_PER_SESSION = 20;

const Ctx = struct {
    allocator: std.mem.Allocator,
    /// Row contexts + hit strings; reset on every new query.
    arena: std.heap.ArenaAllocator,
    window: *Window,
    dialog: *c.AdwDialog,
    search_entry: *c.GtkWidget,
    listbox: *c.GtkWidget,
};

const RowCtx = struct {
    ctx: *Ctx,
    session: []const u8,
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
    };

    const ld = listdialog.build(.{
        .title = "Search All Sessions",
        .width = 700,
        .height = 480,
        .search_placeholder = "Search scrollback of every session (Enter)…",
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

    // Enter in the entry runs the search (deliberately NOT
    // search-changed: a server-side sweep per keystroke is too heavy).
    _ = c.g_signal_connect_data(search, "activate", @ptrCast(&onActivate), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(listbox, "row-activated", @ptrCast(&onRowActivated), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);

    c.adw_dialog_set_child(dialog, root);
    c.adw_dialog_present(dialog, window.app_window);
    _ = c.gtk_widget_grab_focus(search);
}

fn clearList(ctx: *Ctx) void {
    while (c.gtk_widget_get_first_child(ctx.listbox)) |child| {
        c.gtk_list_box_remove(@ptrCast(@alignCast(ctx.listbox)), child);
    }
}

fn addInfoRow(ctx: *Ctx, text: [*:0]const u8) void {
    const row = c.adw_action_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), text);
    c.gtk_list_box_row_set_activatable(@ptrCast(@alignCast(row)), 0);
    c.gtk_list_box_append(@ptrCast(@alignCast(ctx.listbox)), row);
}

fn onActivate(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    const text_c = c.gtk_editable_get_text(@ptrCast(@alignCast(ctx.search_entry)));
    if (text_c == null) return;
    const pattern = std.mem.span(@as([*:0]const u8, @ptrCast(text_c)));
    clearList(ctx);
    if (pattern.len == 0) return;

    // Fresh arena per query: rows referencing the old strings are
    // gone (clearList above).
    _ = ctx.arena.reset(.free_all);
    const arena = ctx.arena.allocator();

    var sessions = mux_cli.fetchSessions(ctx.allocator, null) orelse {
        addInfoRow(ctx, "mux daemon not reachable");
        return;
    };
    defer sessions.deinit();

    var any = false;
    for (sessions.value.sessions) |s| {
        if (s.exited) continue;
        const reply = mux_cli.searchSession(ctx.allocator, null, s.name, pattern, MAX_PER_SESSION) orelse continue;
        defer reply.deinit();
        for (reply.value.hits) |h| {
            any = true;
            const rctx = arena.create(RowCtx) catch return;
            rctx.* = .{ .ctx = ctx, .session = arena.dupe(u8, s.name) catch return };

            const row = c.adw_action_row_new();
            // Titles are pango markup by default — show hit text verbatim.
            c.adw_preferences_row_set_use_markup(@ptrCast(@alignCast(row)), 0);
            const title_z = arena.dupeZ(u8, h.text) catch return;
            const sub_z = std.fmt.allocPrintSentinel(arena, "{s}  (line -{d})", .{ s.name, h.back }, 0) catch return;
            c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title_z.ptr);
            c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), sub_z.ptr);
            c.gtk_list_box_row_set_activatable(@ptrCast(@alignCast(row)), 1);
            c.g_object_set_data(@ptrCast(@alignCast(row)), "xsearch-row", @ptrCast(rctx));
            c.gtk_list_box_append(@ptrCast(@alignCast(ctx.listbox)), row);
        }
    }
    if (!any) addInfoRow(ctx, "no matches");
}

fn onRowActivated(_: *c.GtkListBox, row: ?*c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    if (row == null) return;
    const raw = c.g_object_get_data(@ptrCast(@alignCast(row)), "xsearch-row") orelse return;
    const rctx: *RowCtx = @ptrCast(@alignCast(raw));
    const win = ctx.window;
    // Copy the name out of the dialog arena BEFORE closing frees it.
    var name_buf: [256]u8 = undefined;
    if (rctx.session.len > name_buf.len) return;
    @memcpy(name_buf[0..rctx.session.len], rctx.session);
    const name = name_buf[0..rctx.session.len];
    c.adw_dialog_force_close(ctx.dialog);
    win.focusOrAttachSession(name);
}

fn onClosed(_: *c.AdwDialog, user: ?*anyopaque) callconv(.c) void {
    _ = user;
    // Cleanup runs via the GDestroyNotify (`freeCtx`).
}

fn freeCtx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const ctx: *Ctx = @ptrCast(@alignCast(u));
        ctx.arena.deinit();
        ctx.allocator.destroy(ctx);
    }
}
