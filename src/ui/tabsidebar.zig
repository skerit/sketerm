//! Vertical tree-style tab sidebar, TST-style.
//!
//! ## Two sources, one list
//!
//! The rows are a tree VIEW of whichever forest is relevant to what the
//! user is looking at:
//!
//! - `.window` — the window's tab forest (`src/ui/tabforest.zig`), one
//!   row per visible tab. The default.
//! - `.browser` — the PAGES of the browser the selected tab is focused
//!   on (`src/ui/webgroup.zig`). In a browser, the window tab IS the
//!   browser and the sidebar lists what is open inside it, the way the
//!   editor face owns its own document tabs. Opening a new tab there
//!   opens a page, not a window tab (`Window.newTabInBrowser`).
//!
//! `Window.sidebarGroup` resolves which one on every rebuild, so a tab
//! switch or a pane focus change flips the list without any state here.
//!
//! ## Rebuild cadence
//!
//! The Window owns it: forest mutations go through `Window.forestChanged`
//! and page-list mutations through `Window.webGroupChanged`, both of
//! which call `rebuild`. Only selection and per-item titles are tracked
//! with own signal handlers, and a title change patches ONE label
//! rather than rebuilding the list under the user's pointer.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const cssutil = @import("cssutil.zig");
const winmod = @import("window.zig");
const Window = winmod.Window;
const webgroup = @import("webgroup.zig");
const WebFace = @import("webface.zig").WebFace;

/// Row being dragged, module-level like tabbar's `dragged`: GTK's drop
/// payload types don't carry pointers safely, so the payload is a
/// dummy int and the item + source window live here for the drop
/// handler to validate against.
var drag_item: ?Item = null;
var drag_win: ?*Window = null;

/// Per-depth indent. TST-scale: enough that three levels are obvious
/// without eating the title on a narrow sidebar.
const INDENT_PX: c_int = 18;
/// Width reserved for the twisty on EVERY row, children or not — a
/// title that shifts sideways when a tab gains a child is the thing
/// that made the old rows unreadable.
const CHEVRON_PX: c_int = 16;
/// Deepest indent we apply; past this the rows would have no title left.
const MAX_DEPTH: usize = 12;

/// What one row stands for.
pub const Item = union(enum) {
    /// A window tab.
    tab: *c.AdwTabPage,
    /// A page inside one browser.
    page: *WebFace,

    fn eql(a: Item, b: Item) bool {
        return switch (a) {
            .tab => |p| switch (b) {
                .tab => |q| p == q,
                .page => false,
            },
            .page => |f| switch (b) {
                .page => |g| f == g,
                .tab => false,
            },
        };
    }
};

pub const Sidebar = struct {
    allocator: std.mem.Allocator,
    win: *Window,
    /// Root widget: the paned's start child.
    root: *c.GtkWidget,
    list: *c.GtkWidget,
    rows: std.ArrayList(*Row) = .empty,
    /// Guards the listbox-selection <-> tab-view-selection feedback loop.
    syncing: bool = false,
    sel_handler: c.gulong = 0,
    /// The browser whose pages were listed at the last rebuild, null
    /// while the window's own tab tree was. It is a CHANGE MARKER, not
    /// a handle: a group is freed when its pane loses its web face, so
    /// this pointer may be stale and is only ever COMPARED, never
    /// dereferenced. Every use resolves the live group through
    /// `win.sidebarGroup()` instead.
    group: ?*webgroup.Group = null,

    /// The browser the sidebar is listing right now, re-resolved from
    /// the window. Null when the rows are window tabs.
    fn liveGroup(self: *Sidebar) ?*webgroup.Group {
        return self.win.sidebarGroup();
    }

    pub const Row = struct {
        sidebar: *Sidebar,
        /// Window-tab rows own this AdwTabPage reference for exactly as
        /// long as their notify::title handler can fire.
        item: Item,
        row: *c.GtkWidget,
        label: *c.GtkWidget,
        /// notify::title on an AdwTabPage; 0 for a browser page (whose
        /// title arrives through `Sidebar.noteWebTitle`).
        title_handler: c.gulong = 0,
    };

    fn freeRow(self: *Sidebar, r: *Row, remove_widget: bool) void {
        switch (r.item) {
            .tab => |page| {
                if (r.title_handler != 0)
                    c.g_signal_handler_disconnect(@ptrCast(page), r.title_handler);
                c.g_object_unref(@ptrCast(page));
            },
            .page => {},
        }
        if (remove_widget) c.gtk_list_box_remove(@ptrCast(self.list), r.row);
        self.allocator.destroy(r);
    }

    pub fn create(allocator: std.mem.Allocator, win: *Window) !*Sidebar {
        const self = try allocator.create(Sidebar);
        errdefer allocator.destroy(self);

        const list = c.gtk_list_box_new() orelse return error.GtkFail;
        c.gtk_list_box_set_selection_mode(@ptrCast(list), c.GTK_SELECTION_SINGLE);
        c.gtk_widget_add_css_class(list, "sketerm-tst-list");
        c.gtk_widget_set_vexpand(list, 1);
        installCss(list);

        const scroller = c.gtk_scrolled_window_new() orelse return error.GtkFail;
        c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_scrolled_window_set_child(@ptrCast(scroller), list);
        c.gtk_widget_add_css_class(scroller, "sketerm-tst");
        // The floor the divider can be dragged to; the width itself is
        // the paned position (config `tab_sidebar_width`).
        c.gtk_widget_set_size_request(scroller, 120, -1);

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

        // Drop on the list's empty space -> make the dragged item a root.
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
            // The list widgets are gone with the view. Window-tab rows
            // still own their page references, so release those without
            // touching the dead list box.
            for (self.rows.items) |r| self.freeRow(r, false);
            self.rows.deinit(self.allocator);
            self.allocator.destroy(self);
            return;
        }
        self.clearRows();
        self.rows.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn clearRows(self: *Sidebar) void {
        for (self.rows.items) |r| self.freeRow(r, true);
        self.rows.clearRetainingCapacity();
    }

    /// Rebuild every row from the relevant forest (visible refs, tree
    /// order). Cheap at tab-count scale; called on every mutation.
    pub fn rebuild(self: *Sidebar) void {
        self.clearRows();
        self.group = self.win.sidebarGroup();
        if (self.group) |g| {
            var flat: std.ArrayList(*WebFace) = .empty;
            defer flat.deinit(self.allocator);
            g.forest.flattenVisible(self.allocator, &flat) catch return;
            for (flat.items) |face| self.buildRow(.{ .page = face }, g.forest.depth(face), g.forest.hasChildren(face), g.forest.isCollapsed(face));
        } else {
            var flat: std.ArrayList(*c.AdwTabPage) = .empty;
            defer flat.deinit(self.allocator);
            const forest = &self.win.tab_forest;
            forest.flattenVisible(self.allocator, &flat) catch return;
            for (flat.items) |page| self.buildRow(.{ .tab = page }, forest.depth(page), forest.hasChildren(page), forest.isCollapsed(page));
        }
        self.refreshSelection();
    }

    fn buildRow(self: *Sidebar, item: Item, depth: usize, has_kids: bool, collapsed: bool) void {
        const r = self.allocator.create(Row) catch return;

        const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 2);
        c.gtk_widget_add_css_class(box, "sketerm-tst-body");

        // The twisty. Its space is reserved on EVERY row — a row
        // without children gets an invisible, untargetable one rather
        // than no widget, so titles line up down the whole tree.
        const expander = c.gtk_button_new_from_icon_name(if (collapsed) "pan-end-symbolic" else "pan-down-symbolic");
        c.gtk_button_set_has_frame(@ptrCast(expander), 0);
        c.gtk_widget_add_css_class(expander, "flat");
        c.gtk_widget_add_css_class(expander, "sketerm-tst-twisty");
        c.gtk_widget_set_valign(expander, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_size_request(expander, CHEVRON_PX, CHEVRON_PX);
        if (!has_kids) {
            c.gtk_widget_set_opacity(expander, 0);
            c.gtk_widget_set_can_target(expander, 0);
            c.gtk_widget_set_can_focus(expander, 0);
        }
        _ = c.g_signal_connect_data(expander, "clicked", @ptrCast(&onExpanderClicked), @ptrCast(r), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), expander);

        // Container dot. A page's identity has to be visible where the
        // pages are listed — the window tab's accent says nothing about
        // WHICH page in a browser pane is in a container. Markup rather
        // than a CSS class because the colour is an arbitrary palette
        // entry, so there is no fixed class to install.
        if (item == .page) {
            if (@import("webface.zig").containerColor(item.page.container)) |rgb| {
                const dot = c.gtk_label_new(null);
                var mk: [96]u8 = undefined;
                const m = std.fmt.bufPrintZ(
                    &mk,
                    "<span foreground=\"#{x:0>2}{x:0>2}{x:0>2}\">\u{25CF}</span>",
                    .{ rgb[0], rgb[1], rgb[2] },
                ) catch "";
                c.gtk_label_set_markup(@ptrCast(dot), m.ptr);
                c.gtk_widget_set_valign(dot, c.GTK_ALIGN_CENTER);
                c.gtk_widget_set_tooltip_text(dot, "In a container");
                c.gtk_box_append(@ptrCast(box), dot);
            }
        }

        const label = c.gtk_label_new(null);
        c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
        c.gtk_label_set_xalign(@ptrCast(label), 0.0);
        c.gtk_widget_set_hexpand(label, 1);
        c.gtk_widget_add_css_class(label, "sketerm-tst-title");
        c.gtk_box_append(@ptrCast(box), label);

        const close = c.gtk_button_new_from_icon_name("window-close-symbolic");
        c.gtk_button_set_has_frame(@ptrCast(close), 0);
        c.gtk_widget_add_css_class(close, "flat");
        c.gtk_widget_add_css_class(close, "sketerm-tst-close");
        c.gtk_widget_set_valign(close, c.GTK_ALIGN_CENTER);
        _ = c.g_signal_connect_data(close, "clicked", @ptrCast(&onCloseClicked), @ptrCast(r), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), close);

        const row = c.gtk_list_box_row_new();
        c.gtk_widget_add_css_class(row, "sketerm-tst-row");
        // The indent moves the whole ROW, so a child's chip visibly
        // steps in — indenting only the row's CONTENT left every chip
        // the same width and the nesting read as ragged text.
        const d: c_int = @intCast(@min(depth, MAX_DEPTH));
        c.gtk_widget_set_margin_start(row, d * INDENT_PX);
        c.gtk_list_box_row_set_child(@ptrCast(row), box);
        c.gtk_list_box_append(@ptrCast(self.list), row);

        r.* = .{
            .sidebar = self,
            .item = item,
            .row = row,
            .label = label,
        };
        switch (item) {
            .tab => |page| _ = c.g_object_ref(@ptrCast(page)),
            .page => {},
        }
        setLabel(r);
        switch (item) {
            .tab => |page| r.title_handler = c.g_signal_connect_data(@ptrCast(page), "notify::title", @ptrCast(&onTitle), @ptrCast(r), null, c.G_CONNECT_DEFAULT),
            // A page's title arrives through the group, which knows
            // which row to patch (`noteWebTitle`).
            .page => {},
        }

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
            self.freeRow(r, true);
        };
    }

    fn setLabel(r: *Row) void {
        switch (r.item) {
            .tab => |page| c.gtk_label_set_text(@ptrCast(r.label), c.adw_tab_page_get_title(page)),
            .page => |face| {
                const title = webgroup.Group.pageTitle(face);
                const z = r.sidebar.allocator.dupeZ(u8, title) catch return;
                defer r.sidebar.allocator.free(z);
                c.gtk_label_set_text(@ptrCast(r.label), z.ptr);
            },
        }
    }

    /// One browser page's title changed. Patches its row only.
    pub fn noteWebTitle(self: *Sidebar, face: *WebFace) void {
        for (self.rows.items) |r| {
            switch (r.item) {
                .page => |f| if (f == face) {
                    setLabel(r);
                    return;
                },
                .tab => {},
            }
        }
    }

    /// Move the listbox highlight to whatever the source calls current.
    pub fn refreshSelection(self: *Sidebar) void {
        const sel: ?Item = blk: {
            if (self.liveGroup()) |g| {
                const face = g.active() orelse break :blk null;
                break :blk Item{ .page = face };
            }
            const page = c.adw_tab_view_get_selected_page(self.win.tab_view) orelse break :blk null;
            break :blk Item{ .tab = page };
        };
        self.syncing = true;
        defer self.syncing = false;
        if (sel) |want| {
            for (self.rows.items) |r| {
                if (r.item.eql(want)) {
                    c.gtk_list_box_select_row(@ptrCast(self.list), @ptrCast(r.row));
                    return;
                }
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
                switch (r.item) {
                    .tab => |page| c.adw_tab_view_set_selected_page(self.win.tab_view, page),
                    .page => |face| if (self.liveGroup()) |g| g.setActive(face),
                }
                return;
            }
        }
    }

    fn onSelectedPage(_: *c.AdwTabView, _: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Sidebar, user);
        // A different tab may well be a different SOURCE (a browser tab
        // lists its pages, anything else the window tree), so the whole
        // list is re-resolved rather than just the highlight.
        if (self.win.sidebarGroup() != self.group) {
            self.rebuild();
            return;
        }
        if (self.liveGroup() != null) {
            self.refreshSelection();
            return;
        }
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
        const self = r.sidebar;
        switch (r.item) {
            .tab => |page| {
                const win = self.win;
                win.setTabCollapsed(page, !win.tab_forest.isCollapsed(page));
            },
            .page => |face| {
                const g = self.liveGroup() orelse return;
                if (g.forest.find(face) == null) return;
                g.forest.setCollapsed(face, !g.forest.isCollapsed(face));
                self.rebuild();
            },
        }
    }

    fn onCloseClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        closeItem(cast.userData(Row, user));
    }

    fn onMiddlePressed(gesture: *c.GtkGestureClick, _: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
        const r = cast.userData(Row, user);
        _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_CLAIMED);
        closeItem(r);
    }

    fn closeItem(r: *Row) void {
        const self = r.sidebar;
        switch (r.item) {
            .tab => |page| _ = c.adw_tab_view_close_page(self.win.tab_view, page),
            .page => |face| {
                const g = self.liveGroup() orelse return;
                if (!g.has(face)) return;
                g.closePage(face, switch (self.win.config.tab_close_parent) {
                    .promote => .promote,
                    .close_subtree => .close_subtree,
                });
            },
        }
    }

    fn onDragPrepare(_: *c.GtkDragSource, _: f64, _: f64, user: ?*anyopaque) callconv(.c) ?*c.GdkContentProvider {
        const r = cast.userData(Row, user);
        drag_item = r.item;
        drag_win = r.sidebar.win;
        var v: c.GValue = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, c.G_TYPE_INT);
        c.g_value_set_int(&v, 1);
        const provider = c.gdk_content_provider_new_for_value(&v);
        c.g_value_unset(&v);
        return provider;
    }

    fn onDragEnd(_: *c.GtkDragSource, _: *c.GdkDrag, _: c.gboolean, _: ?*anyopaque) callconv(.c) void {
        drag_item = null;
        drag_win = null;
    }

    fn onRowDrop(_: *c.GtkDropTarget, _: *const c.GValue, _: f64, _: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const r = cast.userData(Row, user);
        const item = drag_item orelse return 0;
        // Same-window only: the forest holds per-window state, and a
        // cross-window page move must go through AdwTabView transfer.
        if (drag_win != r.sidebar.win) return 0;
        if (item.eql(r.item)) return 0;
        return r.sidebar.reparent(item, r.item);
    }

    fn onListDrop(_: *c.GtkDropTarget, _: *const c.GValue, _: f64, _: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Sidebar, user);
        const item = drag_item orelse return 0;
        if (drag_win != self.win) return 0;
        // Only the empty space below the rows means "make it a root";
        // drops on a row are claimed by the row's own target first.
        return self.reparent(item, null);
    }

    /// Reparent within whichever forest both items belong to. A drop
    /// that crosses the two sources is refused rather than guessed at.
    fn reparent(self: *Sidebar, item: Item, onto: ?Item) c.gboolean {
        switch (item) {
            .tab => |page| {
                const parent: ?*c.AdwTabPage = if (onto) |o| switch (o) {
                    .tab => |p| p,
                    .page => return 0,
                } else null;
                self.win.tabForestReparent(page, parent);
                return 1;
            },
            .page => |face| {
                const g = self.liveGroup() orelse return 0;
                const parent: ?*WebFace = if (onto) |o| switch (o) {
                    .page => |f| f,
                    .tab => return 0,
                } else null;
                g.forest.reparent(face, parent, g.childInsertPos()) catch |err| {
                    if (err == error.WouldCycle)
                        winmod.showToast(self.win, "Cannot drop a tab into its own subtree.");
                    return 0;
                };
                self.rebuild();
                return 1;
            },
        }
    }
};

/// Rows are our own chips rather than libadwaita's `navigation-sidebar`
/// list rows, for two reasons the stock styling could not give:
/// an inactive row has to be visible AGAINST the sidebar background
/// (`navigation-sidebar` paints inactive rows in the background colour,
/// so the list read as a flat wall of text), and the rows have to be
/// dense enough that a real tab tree fits on screen.
fn installCss(any_widget: *c.GtkWidget) void {
    const css =
        \\.sketerm-tst { background-color: transparent; }
        \\list.sketerm-tst-list { background-color: transparent; padding: 3px 4px; }
        \\/* The chip. `alpha(currentColor, …)` rather than a named colour
        \\   so it works out in both light and dark without asking. */
        \\list.sketerm-tst-list > row.sketerm-tst-row {
        \\  min-height: 0;
        \\  padding: 0;
        \\  margin: 1px 0;
        \\  border-radius: 6px;
        \\  background-color: alpha(currentColor, 0.09);
        \\  transition: background-color 120ms ease-out;
        \\}
        \\list.sketerm-tst-list > row.sketerm-tst-row:hover {
        \\  background-color: alpha(currentColor, 0.17);
        \\}
        \\list.sketerm-tst-list > row.sketerm-tst-row:selected {
        \\  background-color: @theme_selected_bg_color;
        \\  color: @theme_selected_fg_color;
        \\}
        \\.sketerm-tst-body { min-height: 26px; padding: 0 2px 0 0; }
        \\.sketerm-tst-title { font-size: 0.92em; }
        \\/* A twisty the size of the glyph, not of a toolbar button. */
        \\button.sketerm-tst-twisty {
        \\  padding: 0; margin: 0; border: none; min-width: 16px; min-height: 16px;
        \\}
        \\button.sketerm-tst-twisty:hover { background: alpha(currentColor, 0.15); }
        \\button.sketerm-tst-close {
        \\  padding: 0; margin: 0; border: none; min-width: 18px; min-height: 18px;
        \\  opacity: 0;
        \\  transition: opacity 120ms ease-out;
        \\}
        \\row.sketerm-tst-row:hover button.sketerm-tst-close,
        \\row.sketerm-tst-row:selected button.sketerm-tst-close { opacity: 1; }
        \\button.sketerm-tst-close:hover { background: alpha(currentColor, 0.2); }
        \\/* The window paints every `paned > separator` as a solid
        \\   pane-gap bar (winconfig `refreshTitlebarCss`). This divider
        \\   is a control the user drags, so it gets the stock look back
        \\   with a wide enough grab area. */
        \\paned.sketerm-tst-paned.horizontal > separator {
        \\  background-color: alpha(currentColor, 0.15);
        \\  background-image: none;
        \\  min-width: 1px;
        \\  margin: 0 2px;
        \\  box-shadow: none;
        \\}
        \\paned.sketerm-tst-paned.horizontal > separator:hover {
        \\  background-color: @theme_selected_bg_color;
        \\}
    ;
    cssutil.install("tabsidebar", any_widget, css);
}
