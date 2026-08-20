//! The terminal window's headerbar hamburger.
//!
//! Every row here is a row of `menu.zig`'s declarative spec, taken by
//! `menu.labelFor`/`menu.iconFor` and dispatched through the focused
//! pane's `runMenuAction` — i.e. the same `Sink` a right-click row
//! uses, with the same pane-local-then-Window handling behind it.
//! Nothing is re-implemented here: this file decides WHICH verbs make
//! sense window-level and nothing else, so a relabelled or rewired
//! verb moves in both menus at once.
//!
//! The rows are built fresh per open (sensitivity depends on the
//! focused pane's session), the classicmenu way.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const classicmenu = @import("browser/classicmenu.zig");
const appmenu = @import("appmenu.zig");
const menu = @import("menu.zig");
const Window = @import("window.zig").Window;

/// One row: the verb, and the window to run it on. Owned by the menu
/// Root (mechanism 1 — the popover frees it), never by the row.
const RowCtx = struct {
    allocator: std.mem.Allocator,
    win: *Window,
    action: menu.Action,
};

fn onRow(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RowCtx, user);
    const pane = ctx.win.focusedPane() orelse return;
    pane.runMenuAction(ctx.action);
}

/// Append one spec row. `enabled = false` greys it out rather than
/// hiding it, so the menu still shows what this window CAN do.
fn row(m: classicmenu.Menu, win: *Window, action: menu.Action, enabled: bool) void {
    const ctx = win.allocator.create(RowCtx) catch return;
    ctx.* = .{ .allocator = win.allocator, .win = win, .action = action };
    m.root.own(cast.destroyCtx(RowCtx), @ptrCast(ctx));
    m.itemIconEnabled(
        menu.labelFor(action),
        .{ .name = menu.iconFor(action) },
        enabled,
        &onRow,
        @ptrCast(ctx),
    );
}

/// Build and pop the window menu under `anchor`.
pub fn show(win: *Window, anchor: *c.GtkWidget) void {
    const root = classicmenu.Root.create(win.allocator) orelse return;
    const m = root.top();

    const pane = win.focusedPane();
    // A durable session survives its pane closing; a plain local shell
    // tab is GUI-owned and ephemeral, so detach/rename/kill would be
    // meaningless on it. Same rule the pane menu's pre-popup applies.
    const durable = if (pane) |p|
        (if (p.terminal.remote) |r| !r.ephemeral else false)
    else
        false;
    const has_pane = pane != null;

    const tabs = m;
    row(tabs, win, .new_tab, true);
    row(tabs, win, .new_tab_as_profile, true);
    row(tabs, win, .duplicate_tab, has_pane);
    row(tabs, win, .rename_tab, has_pane);
    row(tabs, win, .close_tab, has_pane);
    // Tree-style tabs. The sidebar toggle works with no pane at all;
    // collapse/expand act on the selected tab, so they follow it.
    const tree = m.section();
    row(tree, win, .toggle_tab_sidebar, true);
    row(tree, win, .tab_collapse, has_pane);
    row(tree, win, .tab_expand, has_pane);
    row(tree, win, .tab_tree_next, has_pane);
    row(tree, win, .tab_tree_prev, has_pane);

    const panes = m.section();
    row(panes, win, .split_h, has_pane);
    row(panes, win, .split_v, has_pane);
    row(panes, win, .zoom_pane, has_pane);
    row(panes, win, .apply_profile, has_pane);
    row(panes, win, .close_pane, has_pane);

    const session = m.section().submenu("Session");
    row(session, win, .mux_detach, durable);
    row(session, win, .mux_rename, durable);
    row(session, win, .mux_kill, durable);

    const tail = m.section();
    row(tail, win, .prefs_open, true);
    // Sits with the shared Help section appended right below it: the
    // tour is discoverability, not a terminal verb.
    row(tail, win, .welcome_open, true);

    appmenu.appendHelp(m, win.allocator, @ptrCast(@alignCast(win.app_window)), .terminal);

    _ = root.popup(
        anchor,
        @floatFromInt(@divTrunc(c.gtk_widget_get_width(anchor), 2)),
        @floatFromInt(c.gtk_widget_get_height(anchor)),
    );
}

/// The button itself is the anchor, so nothing has to remember it.
fn onBurgerClicked(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    show(cast.userData(Window, user), @ptrCast(@alignCast(btn)));
}

/// The headerbar button itself. Packed by the caller so it lands
/// end-most, next to the tab-overview button.
pub fn button(win: *Window) *c.GtkWidget {
    const btn = c.gtk_button_new_from_icon_name("open-menu-symbolic").?;
    c.gtk_widget_set_tooltip_text(btn, "Main Menu");
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onBurgerClicked), @ptrCast(win), null, c.G_CONNECT_DEFAULT);
    return btn;
}
