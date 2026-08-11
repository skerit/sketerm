//! Vertical tree-style tab sidebar — the tree VIEW of the window's
//! tab forest (src/ui/tabforest.zig), TST-style.
//!
//! The sidebar renders one row per VISIBLE tab in tree order:
//! indentation by depth, an expander arrow on tabs with children, the
//! page title, a close button. Clicking a row selects its page in the
//! AdwTabView; dragging a row onto another reparents its whole subtree
//! (drop on empty space below the rows = make it a root tab).
//!
//! The Window owns the rebuild cadence: every forest mutation goes
//! through `Window.forestChanged`, which calls `rebuild` here. Only
//! selection and per-page titles are tracked with own signal handlers.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const winmod = @import("window.zig");
const Window = winmod.Window;

/// Row being dragged, module-level like tabbar's `dragged`: GTK's drop
/// payload types don't carry pointers safely, so the payload is a
/// dummy int and the page + source window live here for the drop
/// handler to validate against.
var drag_page: ?*c.AdwTabPage = null;
var drag_win: ?*Window = null;

const INDENT_PX: c_int = 14;

pub const Sidebar = struct {
    allocator: std.mem.Allocator,
    win: *Window,
    /// Root widget packed into the window's content box.
    root: *c.GtkWidget,
    list: *c.GtkWidget,
    rows: std.ArrayList(*Row) = .empty,
    /// Guards the listbox-selection <-> tab-view-selection feedback loop.
    syncing: bool = false,
    sel_handler: c.gulong = 0,

    pub const Row = struct {
        sidebar: *Sidebar,
        page: *c.AdwTabPage,
        row: *c.GtkWidget,
        label: *c.GtkWidget,
        title_handler: c.gulong = 0,
    };

    pub fn create(allocator: std.mem.Allocator, win: *Window) !*Sidebar {
        const self = try allocator.create(Sidebar);
        errdefer allocator.destroy(self);

        const list = c.gtk_list_box_new() orelse return error.GtkFail;
        c.gtk_list_box_set_selection_mode(@ptrCast(list), c.GTK_SELECTION_SINGLE);
        c.gtk_widget_add_css_class(list, "navigation-sidebar");
        c.gtk_widget_set_vexpand(list, 1);

        const scroller = c.gtk_scrolled_window_new() orelse return error.GtkFail;
        c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_scrolled_window_set_child(@ptrCast(scroller), list);
        c.gtk_widget_set_size_request(scroller, 220, -1);

        self.* = .{
            .allocator = allocator,
            .win = win,
            .root = scroller,
            .list = list,
        };

        _ = c.g_signal_connect_data(list, "row-activated", @ptrCast(&onRowActivated), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        // Selection tracking (highlight follows the tab view; selecting
        // a hidden page auto-expands its collapsed ancestors).
        self.sel_handler = c.g_signal_connect_data(
            @ptrCast(win.tab_view),
            "notify::selected-page",
            @ptrCast(&onSelectedPage),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );

        // Drop on the list's empty space -> make the dragged tab a root.
        const drop = c.gtk_drop_target_new(c.G_TYPE_INT, c.GDK_ACTION_MOVE);
        _ = c.g_signal_connect_data(drop, "drop", @ptrCast(&onListDrop), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(list, @ptrCast(@alignCast(drop)));

        self.rebuild();
        return self;
    }

    /// Disconnect-at-teardown (mechanism 2): deinit is the single
    /// choke point; the sidebar lives exactly as long as its Window.
    pub fn deinit(self: *Sidebar) void {
        // Window.deinit can run after the toplevel's destroy chain has
        // finalized the tab view (deferred secondary free) — check the
        // instance is still an AdwTabView before touching it, like
        // onPageDetachedIdle does.
        // `destroying` also covers rows holding pages that died after
        // forestChanged stopped rebuilding (it no-ops once teardown
        // starts) — those title handlers must not be touched either.
        const view_alive = !self.win.destroying and c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(self.win.tab_view)),
            c.adw_tab_view_get_type(),
        ) != 0;
        if (self.sel_handler != 0) {
            if (view_alive) c.g_signal_handler_disconnect(@ptrCast(self.win.tab_view), self.sel_handler);
            self.sel_handler = 0;
        }
        if (!view_alive) {
            // Widgets (and the per-page title handlers' pages) are
            // gone with the view; free only our own bookkeeping.
            for (self.rows.items) |r| self.allocator.destroy(r);
            self.rows.deinit(self.allocator);
            self.allocator.destroy(self);
            return;
        }
        self.clearRows();
        self.rows.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn clearRows(self: *Sidebar) void {
        for (self.rows.items) |r| {
            if (r.title_handler != 0) c.g_signal_handler_disconnect(@ptrCast(r.page), r.title_handler);
            c.gtk_list_box_remove(@ptrCast(self.list), r.row);
            self.allocator.destroy(r);
        }
        self.rows.clearRetainingCapacity();
    }

    /// Rebuild every row from the forest (visible refs, tree order).
    /// Cheap at tab-count scale; called on every forest mutation.
    pub fn rebuild(self: *Sidebar) void {
        self.clearRows();
        var flat: std.ArrayList(*c.AdwTabPage) = .empty;
        defer flat.deinit(self.allocator);
        self.win.tab_forest.flattenVisible(self.allocator, &flat) catch return;
        for (flat.items) |page| self.buildRow(page);
        self.refreshSelection();
    }

    fn buildRow(self: *Sidebar, page: *c.AdwTabPage) void {
        const r = self.allocator.create(Row) catch return;

        const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        const forest = &self.win.tab_forest;
        const d: c_int = @intCast(@min(forest.depth(page), 12));
        c.gtk_widget_set_margin_start(box, d * INDENT_PX);

        // Expander arrow — only on tabs that have children.
        const has_kids = forest.hasChildren(page);
        const collapsed = forest.isCollapsed(page);
        const expander = c.gtk_button_new_from_icon_name(if (collapsed) "pan-end-symbolic" else "pan-down-symbolic");
        c.gtk_button_set_has_frame(@ptrCast(expander), 0);
        c.gtk_widget_add_css_class(expander, "flat");
        c.gtk_widget_set_valign(expander, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_visible(expander, @intFromBool(has_kids));
        _ = c.g_signal_connect_data(expander, "clicked", @ptrCast(&onExpanderClicked), @ptrCast(r), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), expander);

        const title = c.adw_tab_page_get_title(page);
        const label = c.gtk_label_new(title);
        c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
        c.gtk_label_set_xalign(@ptrCast(label), 0.0);
        c.gtk_widget_set_hexpand(label, 1);
        c.gtk_box_append(@ptrCast(box), label);

        const close = c.gtk_button_new_from_icon_name("window-close-symbolic");
        c.gtk_button_set_has_frame(@ptrCast(close), 0);
        c.gtk_widget_add_css_class(close, "flat");
        c.gtk_widget_set_valign(close, c.GTK_ALIGN_CENTER);
        _ = c.g_signal_connect_data(close, "clicked", @ptrCast(&onCloseClicked), @ptrCast(r), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), close);

        const row = c.gtk_list_box_row_new();
        c.gtk_list_box_row_set_child(@ptrCast(row), box);
        c.gtk_list_box_append(@ptrCast(self.list), row);

        r.* = .{
            .sidebar = self,
            .page = page,
            .row = row,
            .label = label,
        };
        r.title_handler = c.g_signal_connect_data(@ptrCast(page), "notify::title", @ptrCast(&onTitle), @ptrCast(r), null, c.G_CONNECT_DEFAULT);

        // Middle-click closes (strip convention).
        const mclick = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(mclick), 2);
        _ = c.g_signal_connect_data(mclick, "pressed", @ptrCast(&onMiddlePressed), @ptrCast(r), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(row, @ptrCast(@alignCast(mclick)));

        // Drag this row -> reparent its subtree wherever it drops.
        const src = c.gtk_drag_source_new();
        c.gtk_drag_source_set_actions(src, c.GDK_ACTION_MOVE);
        _ = c.g_signal_connect_data(src, "prepare", @ptrCast(&onDragPrepare), @ptrCast(r), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(src, "drag-end", @ptrCast(&onDragEnd), @ptrCast(r), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(row, @ptrCast(@alignCast(src)));

        // Drop ON this row -> become a child of it.
        const drop = c.gtk_drop_target_new(c.G_TYPE_INT, c.GDK_ACTION_MOVE);
        _ = c.g_signal_connect_data(drop, "drop", @ptrCast(&onRowDrop), @ptrCast(r), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(row, @ptrCast(@alignCast(drop)));

        self.rows.append(self.allocator, r) catch {
            if (r.title_handler != 0) c.g_signal_handler_disconnect(@ptrCast(r.page), r.title_handler);
            c.gtk_list_box_remove(@ptrCast(self.list), row);
            self.allocator.destroy(r);
        };
    }

    /// Move the listbox highlight to the tab view's selected page.
    pub fn refreshSelection(self: *Sidebar) void {
        const sel = c.adw_tab_view_get_selected_page(self.win.tab_view);
        self.syncing = true;
        defer self.syncing = false;
        for (self.rows.items) |r| {
            if (@as(?*c.AdwTabPage, r.page) == sel) {
                c.gtk_list_box_select_row(@ptrCast(self.list), @ptrCast(r.row));
                return;
            }
        }
        c.gtk_list_box_unselect_all(@ptrCast(self.list));
    }

    fn onRowActivated(_: *c.GtkListBox, row: ?*c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Sidebar, user);
        if (self.syncing) return;
        const rw = row orelse return;
        for (self.rows.items) |r| {
            if (@as(*c.GtkListBoxRow, @ptrCast(r.row)) == rw) {
                c.adw_tab_view_set_selected_page(self.win.tab_view, r.page);
                return;
            }
        }
    }

    fn onSelectedPage(_: *c.AdwTabView, _: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Sidebar, user);
        const sel = c.adw_tab_view_get_selected_page(self.win.tab_view) orelse return;
        // Selecting a page inside a collapsed subtree (Ctrl+Tab, goto_tab_N,
        // overview…) expands its ancestors so the selection is never invisible.
        if (self.win.tab_forest.isHidden(sel)) {
            var p = self.win.tab_forest.parentOf(sel);
            while (p) |parent| : (p = self.win.tab_forest.parentOf(parent)) {
                self.win.tab_forest.setCollapsed(parent, false);
            }
            self.win.forestChanged();
            return;
        }
        self.refreshSelection();
    }

    fn onTitle(page: *c.AdwTabPage, _: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const r = cast.userData(Row, user);
        c.gtk_label_set_text(@ptrCast(r.label), c.adw_tab_page_get_title(page));
    }

    fn onExpanderClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const r = cast.userData(Row, user);
        const win = r.sidebar.win;
        win.setTabCollapsed(r.page, !win.tab_forest.isCollapsed(r.page));
    }

    fn onCloseClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const r = cast.userData(Row, user);
        _ = c.adw_tab_view_close_page(r.sidebar.win.tab_view, r.page);
    }

    fn onMiddlePressed(gesture: *c.GtkGestureClick, _: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
        const r = cast.userData(Row, user);
        _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_CLAIMED);
        _ = c.adw_tab_view_close_page(r.sidebar.win.tab_view, r.page);
    }

    fn onDragPrepare(_: *c.GtkDragSource, _: f64, _: f64, user: ?*anyopaque) callconv(.c) ?*c.GdkContentProvider {
        const r = cast.userData(Row, user);
        drag_page = r.page;
        drag_win = r.sidebar.win;
        var v: c.GValue = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, c.G_TYPE_INT);
        c.g_value_set_int(&v, 1);
        const provider = c.gdk_content_provider_new_for_value(&v);
        c.g_value_unset(&v);
        return provider;
    }

    fn onDragEnd(_: *c.GtkDragSource, _: *c.GdkDrag, _: c.gboolean, _: ?*anyopaque) callconv(.c) void {
        drag_page = null;
        drag_win = null;
    }

    fn onRowDrop(_: *c.GtkDropTarget, _: *const c.GValue, _: f64, _: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const r = cast.userData(Row, user);
        const page = drag_page orelse return 0;
        // Same-window only: the forest holds per-window state, and a
        // cross-window page move must go through AdwTabView transfer.
        if (drag_win != r.sidebar.win) return 0;
        if (page == r.page) return 0;
        r.sidebar.win.tabForestReparent(page, r.page);
        return 1;
    }

    fn onListDrop(target: *c.GtkDropTarget, _: *const c.GValue, _: f64, y: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        _ = target;
        const self = cast.userData(Sidebar, user);
        const page = drag_page orelse return 0;
        if (drag_win != self.win) return 0;
        // Only the empty space below the rows means "make it a root";
        // drops on a row are claimed by the row's own target first, but
        // be defensive about coordinates anyway.
        _ = y;
        self.win.tabForestReparent(page, null);
        return 1;
    }
};
