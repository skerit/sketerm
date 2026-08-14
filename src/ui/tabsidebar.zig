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
//! ## Drag
//!
//! A row drags like a strip tab because it IS the strip's drag: a
//! window tab is published to `tabbar`'s shared state, so every
//! window's strip accepts it and a drop on nothing detaches it into a
//! new window. Within the sidebar the outer thirds of a row reorder
//! (before / after it), the middle nests, and the empty space below the
//! rows makes the tab a root again. A browser PAGE is the exception:
//! it belongs to one pane's group, so it never leaves this sidebar.
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
const input = @import("input.zig");
const winmod = @import("window.zig");
const Window = winmod.Window;
const tabbar = @import("tabbar.zig");
const tabchrome = @import("tabchrome.zig");
const classicmenu = @import("browser/classicmenu.zig");
const webgroup = @import("webgroup.zig");
const WebFace = @import("webface.zig").WebFace;

/// Row being dragged, module-level like tabbar's `dragged`: GTK's drop
/// payload types don't carry pointers safely, so the payload is a
/// dummy int and the item + source window live here for the drop
/// handler to validate against.
///
/// A dragged WINDOW TAB is published to `tabbar`'s shared drag state
/// INSTEAD, so the strip, the other windows' strips and the
/// drag-out-to-a-new-window path all see the one gesture they already
/// understand; `drag_item` then only ever carries a browser PAGE, which
/// belongs to one window's group and cannot leave it.
var drag_item: ?Item = null;
var drag_win: ?*Window = null;

/// Where a drop between rows would land, from the pointer's height
/// inside the hovered row.
const Zone = enum { above, into, below };

/// The row currently wearing a drop-indicator class. Cleared whenever
/// the row is torn down, so a rebuild under the pointer cannot leave a
/// stale pointer behind.
var drop_hint: ?*Sidebar.Row = null;

/// The row a drag started from, dimmed for the drag's duration so the
/// gesture reads as moving THE tab rather than a copy of it. Cleared
/// on row teardown like `drop_hint`.
var drag_src_row: ?*Sidebar.Row = null;

fn clearDragSrc() void {
    const r = drag_src_row orelse return;
    drag_src_row = null;
    c.gtk_widget_remove_css_class(r.row, "sketerm-tst-dragsrc");
}

/// TST's dwell-to-expand: hovering a collapsed row mid-drag expands
/// its subtree after a beat, so a drop INTO a hidden part of the tree
/// never requires aborting the drag.
var hover_expand_row: ?*Sidebar.Row = null;
var hover_expand_source: c.guint = 0;

const HOVER_EXPAND_MS: c.guint = 600;

fn cancelHoverExpand() void {
    if (hover_expand_source != 0) {
        _ = c.g_source_remove(hover_expand_source);
        hover_expand_source = 0;
    }
    hover_expand_row = null;
}

fn armHoverExpand(r: *Sidebar.Row) void {
    if (hover_expand_row == r) return;
    cancelHoverExpand();
    const collapsed = switch (r.item) {
        .tab => |page| blk: {
            const self = r.sidebar orelse return;
            const win = self.win orelse return;
            break :blk win.tab_forest.hasChildren(page) and win.tab_forest.isCollapsed(page);
        },
        .page => |face| blk: {
            const self = r.sidebar orelse return;
            const g = self.liveGroup() orelse return;
            break :blk g.forest.hasChildren(face) and g.forest.isCollapsed(face);
        },
    };
    if (!collapsed) return;
    hover_expand_row = r;
    hover_expand_source = c.g_timeout_add(HOVER_EXPAND_MS, @ptrCast(&onHoverExpand), @ptrCast(r));
}

fn onHoverExpand(user: ?*anyopaque) callconv(.c) c.gboolean {
    const r = cast.userData(Sidebar.Row, user);
    hover_expand_source = 0;
    if (hover_expand_row != r) return 0;
    hover_expand_row = null;
    if (!r.active) return 0;
    const self = r.sidebar orelse return 0;
    const win = self.win orelse return 0;
    switch (r.item) {
        .tab => |page| win.setTabCollapsed(page, false),
        .page => |face| {
            const g = self.liveGroup() orelse return 0;
            if (g.forest.find(face) == null) return 0;
            g.forest.setCollapsed(face, false);
            self.rebuild();
        },
    }
    return 0;
}

const DROP_CLASSES = [_][*:0]const u8{ "tst-drop-above", "tst-drop-into", "tst-drop-below" };

fn clearDropHint() void {
    const r = drop_hint orelse return;
    drop_hint = null;
    for (DROP_CLASSES) |cls| c.gtk_widget_remove_css_class(r.row, cls);
}

fn setDropHint(r: *Sidebar.Row, zone: Zone) void {
    if (drop_hint != r) clearDropHint();
    drop_hint = r;
    for (DROP_CLASSES, 0..) |cls, i| {
        if (i == @intFromEnum(zone)) {
            c.gtk_widget_add_css_class(r.row, cls);
        } else {
            c.gtk_widget_remove_css_class(r.row, cls);
        }
    }
}

/// The outer thirds of a row mean "between rows", the middle "into".
/// A generous middle band on purpose: nesting is the gesture users
/// reach for most, and a thin one is a lottery on a 26px row.
fn zoneAt(r: *Sidebar.Row, y: f64) Zone {
    const h: f64 = @floatFromInt(c.gtk_widget_get_height(r.row));
    if (h <= 0) return .into;
    if (y < h * 0.3) return .above;
    if (y > h * 0.7) return .below;
    return .into;
}

/// Painted like a selected row would be, but owned by us: the sidebar
/// answers "which tab is current", not "which row has the cursor".
const ACTIVE_CLASS = "sketerm-tst-active";

const SIDEBAR_LIST_QDATA = "sketerm-tab-sidebar-list";
const SIDEBAR_VIEW_QDATA = "sketerm-tab-sidebar-view";
const ROW_QDATA = "sketerm-tab-sidebar-row";

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
    refs: usize = 1,
    win: ?*Window,
    /// Root widget: the paned's start child.
    root: *c.GtkWidget,
    list: ?*c.GtkWidget,
    rows: std.ArrayList(*Row) = .empty,
    title_contexts: std.ArrayList(*TitleCtx) = .empty,
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
        const win = self.win orelse return null;
        return win.sidebarGroup();
    }

    pub const Row = struct {
        allocator: std.mem.Allocator,
        sidebar: ?*Sidebar,
        active: bool = true,
        item: Item,
        row: *c.GtkWidget,
        label: *c.GtkWidget,
    };

    const TitleCtx = struct {
        allocator: std.mem.Allocator,
        sidebar: *Sidebar,
        page: *c.AdwTabPage,
    };

    pub fn create(allocator: std.mem.Allocator, win: *Window) !*Sidebar {
        const self = try allocator.create(Sidebar);
        errdefer allocator.destroy(self);

        const list = c.gtk_list_box_new() orelse return error.GtkFail;
        // NOT a selectable list. GtkListBox's own selection follows the
        // keyboard cursor, so in SINGLE mode an arrow key inside the
        // sidebar moved the highlight to a tab that was NOT current and
        // nothing ever reconciled it — the flaky "active" row. The
        // active tab is painted by an explicit class instead, which also
        // keeps it marked while focus sits in a pane.
        c.gtk_list_box_set_selection_mode(@ptrCast(list), c.GTK_SELECTION_NONE);
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

        // Window owns the base reference. The list and tab view each
        // retain one because their signal closures can outlive either
        // sibling during GtkWindow disposal.
        self.retain();
        c.g_object_set_data_full(@ptrCast(list), SIDEBAR_LIST_QDATA, @ptrCast(self), @ptrCast(&releaseList));
        self.retain();
        c.g_object_set_data_full(@ptrCast(@alignCast(win.tab_view)), SIDEBAR_VIEW_QDATA, @ptrCast(self), @ptrCast(&releaseView));

        _ = c.g_signal_connect_data(list, "row-activated", @ptrCast(&onRowActivated), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        // The pane faces normally forward global bindings after their
        // own key handling. Focused sidebar rows are outside every pane,
        // so a bubble-phase controller provides the same final fallback
        // without pre-empting GtkListBox navigation or row activation.
        const keys = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onKeyPressed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(list, @ptrCast(keys));

        // Selection tracking (highlight follows the tab view; selecting
        // a hidden page auto-expands its collapsed ancestors).
        _ = c.g_signal_connect_data(
            @ptrCast(win.tab_view),
            "notify::selected-page",
            @ptrCast(&onSelectedPage),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );

        // Drop on the sidebar's empty space -> make the dragged item a
        // root. On the SCROLLER, not the list: the list is only as tall
        // as its rows, so the space below them belongs to the scroller —
        // and a drop the sidebar does not accept is a drop on nothing,
        // which now detaches the tab into a new window.
        const drop = c.gtk_drop_target_new(c.G_TYPE_INT, c.GDK_ACTION_MOVE);
        _ = c.g_signal_connect_data(drop, "motion", @ptrCast(&onListMotion), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(drop, "drop", @ptrCast(&onListDrop), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(scroller, @ptrCast(@alignCast(drop)));

        // Right-click on the empty space below the rows (bubble phase,
        // so a row's own claimed menu press never reaches it).
        const rclick = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(rclick), 3);
        _ = c.g_signal_connect_data(rclick, "pressed", @ptrCast(&onEmptyRightClick), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(scroller, @ptrCast(@alignCast(rclick)));

        self.rebuild();
        return self;
    }

    /// Fence callbacks before the owning Window is freed.
    pub fn sever(self: *Sidebar) void {
        const win = self.win orelse return;
        if (drag_win == win) {
            drag_item = null;
            drag_win = null;
        }
        // A shared drag started here carries this Window as its detach
        // context; nothing may hand a dead one back.
        if (tabbar.currentDrag()) |d| {
            if (d.view == win.tab_view) tabbar.clearDrag();
        }
        clearDropHint();
        clearDragSrc();
        cancelHoverExpand();
        self.win = null;
        self.release();
    }

    fn clearRows(self: *Sidebar) void {
        const list = self.list orelse return;
        while (self.rows.pop()) |r| {
            r.active = false;
            if (drop_hint == r) drop_hint = null;
            if (drag_win == self.win and drag_item != null and drag_item.?.eql(r.item)) {
                drag_item = null;
                drag_win = null;
            }
            c.gtk_list_box_remove(@ptrCast(list), r.row);
        }
    }

    /// Rebuild every row from the relevant forest (visible refs, tree
    /// order). Cheap at tab-count scale; called on every mutation.
    pub fn rebuild(self: *Sidebar) void {
        self.clearRows();
        const win = self.win orelse return;
        self.group = win.sidebarGroup();
        if (self.group) |g| {
            var flat: std.ArrayList(*WebFace) = .empty;
            defer flat.deinit(self.allocator);
            g.forest.flattenVisible(self.allocator, &flat) catch return;
            for (flat.items) |face| self.buildRow(.{ .page = face }, g.forest.depth(face), g.forest.hasChildren(face), g.forest.isCollapsed(face));
        } else {
            var flat: std.ArrayList(*c.AdwTabPage) = .empty;
            defer flat.deinit(self.allocator);
            const forest = &win.tab_forest;
            forest.flattenVisible(self.allocator, &flat) catch return;
            for (flat.items) |page| self.buildRow(.{ .tab = page }, forest.depth(page), forest.hasChildren(page), forest.isCollapsed(page));
        }
        self.refreshSelection();
        self.pruneTitleWatches();
    }

    /// Drop title watches for pages no longer rowed here, so a tab
    /// dragged to another window cannot pin this Sidebar (and its
    /// arrays) alive until the page finalizes there.
    fn pruneTitleWatches(self: *Sidebar) void {
        var i: usize = 0;
        outer: while (i < self.title_contexts.items.len) {
            const ctx = self.title_contexts.items[i];
            for (self.rows.items) |r| {
                switch (r.item) {
                    .tab => |page| if (page == ctx.page) {
                        i += 1;
                        continue :outer;
                    },
                    .page => {},
                }
            }
            // The disconnect destroys the closure, whose GDestroyNotify
            // (freeTitleCtx) swap-removes this entry and frees it — the
            // list shrinks in place of advancing.
            _ = c.g_signal_handlers_disconnect_matched(@ptrCast(ctx.page), c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, @ptrCast(ctx));
        }
    }

    fn buildRow(self: *Sidebar, item: Item, depth: usize, has_kids: bool, collapsed: bool) void {
        // Bail before building anything: constructing the row first and
        // then unreffing it on a null list would finalize a FLOATING
        // widget (a GLib critical per row).
        const list = self.list orelse return;
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

        r.* = .{
            .allocator = self.allocator,
            .sidebar = self,
            .item = item,
            .row = row,
            .label = label,
        };
        self.retain();
        c.g_object_set_data_full(@ptrCast(row), ROW_QDATA, @ptrCast(r), @ptrCast(&freeRow));
        c.gtk_list_box_append(@ptrCast(list), row);
        setLabel(r);
        switch (item) {
            .tab => |page| self.ensureTitleWatch(page),
            // A page's title arrives through the group, which knows
            // which row to patch (`noteWebTitle`).
            .page => {},
        }

        // Middle-click closes (strip convention).
        const mclick = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(mclick), 2);
        _ = c.g_signal_connect_data(mclick, "pressed", @ptrCast(&onMiddlePressed), @ptrCast(r), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(row, @ptrCast(@alignCast(mclick)));

        // Right-click: the same context menu the row's tab wears
        // elsewhere (the strip's window-tab menu, the notebook's
        // page menu) — the sidebar adds no second implementation.
        const rclick = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(rclick), 3);
        _ = c.g_signal_connect_data(rclick, "pressed", @ptrCast(&onRowRightClick), @ptrCast(r), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(row, @ptrCast(@alignCast(rclick)));

        // Drag this row: same gesture as a strip tab, so it can reorder,
        // nest, cross windows or drop out into a new window.
        const src = c.gtk_drag_source_new();
        c.gtk_drag_source_set_actions(src, c.GDK_ACTION_MOVE);
        _ = c.g_signal_connect_data(src, "prepare", @ptrCast(&onDragPrepare), @ptrCast(r), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(src, "drag-begin", @ptrCast(&onDragBegin), @ptrCast(r), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(src, "drag-cancel", @ptrCast(&onDragCancel), null, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(src, "drag-end", @ptrCast(&onDragEnd), null, null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(row, @ptrCast(@alignCast(src)));

        // Drop on this row -> above it, into it, or below it.
        const drop = c.gtk_drop_target_new(c.G_TYPE_INT, c.GDK_ACTION_MOVE);
        _ = c.g_signal_connect_data(drop, "motion", @ptrCast(&onRowMotion), @ptrCast(r), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(drop, "leave", @ptrCast(&onRowLeave), @ptrCast(r), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(drop, "drop", @ptrCast(&onRowDrop), @ptrCast(r), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(row, @ptrCast(@alignCast(drop)));

        self.rows.append(self.allocator, r) catch {
            r.active = false;
            c.gtk_list_box_remove(@ptrCast(list), row);
        };
    }

    fn ensureTitleWatch(self: *Sidebar, page: *c.AdwTabPage) void {
        for (self.title_contexts.items) |ctx| if (ctx.page == page) return;
        const ctx = self.allocator.create(TitleCtx) catch return;
        ctx.* = .{ .allocator = self.allocator, .sidebar = self, .page = page };
        self.title_contexts.append(self.allocator, ctx) catch {
            self.allocator.destroy(ctx);
            return;
        };
        self.retain();
        _ = c.g_signal_connect_data(@ptrCast(page), "notify::title", @ptrCast(&onTitle), @ptrCast(ctx), @ptrCast(&freeTitleCtx), c.G_CONNECT_DEFAULT);
    }

    fn setLabel(r: *Row) void {
        switch (r.item) {
            .tab => |page| c.gtk_label_set_text(@ptrCast(r.label), c.adw_tab_page_get_title(page)),
            .page => |face| {
                const title = webgroup.Group.pageTitle(face);
                const sidebar = r.sidebar orelse return;
                const z = sidebar.allocator.dupeZ(u8, title) catch return;
                defer sidebar.allocator.free(z);
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

    /// Mark the row of whatever the source calls current, and unmark
    /// every other one.
    pub fn refreshSelection(self: *Sidebar) void {
        const sel: ?Item = blk: {
            if (self.liveGroup()) |g| {
                const face = g.active() orelse break :blk null;
                break :blk Item{ .page = face };
            }
            const win = self.win orelse break :blk null;
            const page = c.adw_tab_view_get_selected_page(win.tab_view) orelse break :blk null;
            break :blk Item{ .tab = page };
        };
        for (self.rows.items) |r| {
            const active = if (sel) |want| r.item.eql(want) else false;
            if (active) {
                c.gtk_widget_add_css_class(r.row, ACTIVE_CLASS);
            } else {
                c.gtk_widget_remove_css_class(r.row, ACTIVE_CLASS);
            }
        }
    }

    fn retain(self: *Sidebar) void {
        self.refs += 1;
    }

    fn release(self: *Sidebar) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        self.rows.deinit(self.allocator);
        self.title_contexts.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn releaseList(user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Sidebar, user);
        self.list = null;
        self.release();
    }

    fn releaseView(user: ?*anyopaque) callconv(.c) void {
        cast.userData(Sidebar, user).release();
    }

    fn freeRow(user: ?*anyopaque) callconv(.c) void {
        const r = cast.userData(Row, user);
        if (drop_hint == r) drop_hint = null;
        if (drag_src_row == r) drag_src_row = null;
        if (hover_expand_row == r) cancelHoverExpand();
        const sidebar = r.sidebar;
        r.sidebar = null;
        if (sidebar) |self| {
            for (self.rows.items, 0..) |candidate, i| {
                if (candidate == r) {
                    _ = self.rows.swapRemove(i);
                    break;
                }
            }
        }
        r.allocator.destroy(r);
        if (sidebar) |s| s.release();
    }

    fn freeTitleCtx(user: ?*anyopaque) callconv(.c) void {
        const ctx = cast.userData(TitleCtx, user);
        const self = ctx.sidebar;
        for (self.title_contexts.items, 0..) |candidate, i| {
            if (candidate == ctx) {
                _ = self.title_contexts.swapRemove(i);
                break;
            }
        }
        ctx.allocator.destroy(ctx);
        self.release();
    }

    fn onRowActivated(_: *c.GtkListBox, row: ?*c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Sidebar, user);
        const win = self.win orelse return;
        const rw = row orelse return;
        for (self.rows.items) |r| {
            if (@as(*c.GtkListBoxRow, @ptrCast(r.row)) == rw) {
                switch (r.item) {
                    .tab => |page| c.adw_tab_view_set_selected_page(win.tab_view, page),
                    .page => |face| if (self.liveGroup()) |g| g.setActive(face),
                }
                return;
            }
        }
    }

    fn onKeyPressed(
        _: *c.GtkEventControllerKey,
        keyval: c_uint,
        _: c_uint,
        state: c.GdkModifierType,
        user: ?*anyopaque,
    ) callconv(.c) c.gboolean {
        const self = cast.userData(Sidebar, user);
        const win = self.win orelse return 0;
        const action = input.matchWithDefaults(win.bindings.items, keyval, state) orelse return 0;
        winmod.dispatchAction(win, action);
        return 1;
    }

    fn onSelectedPage(_: *c.AdwTabView, _: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Sidebar, user);
        const win = self.win orelse return;
        // A different tab may well be a different SOURCE (a browser tab
        // lists its pages, anything else the window tree), so the whole
        // list is re-resolved rather than just the highlight.
        if (win.sidebarGroup() != self.group) {
            self.rebuild();
            return;
        }
        if (self.liveGroup() != null) {
            self.refreshSelection();
            return;
        }
        const sel = c.adw_tab_view_get_selected_page(win.tab_view) orelse return;
        // Selecting a page inside a collapsed subtree (Ctrl+Tab, goto_tab_N,
        // overview…) expands its ancestors so the selection is never invisible.
        if (win.tab_forest.isHidden(sel)) {
            var p = win.tab_forest.parentOf(sel);
            while (p) |parent| : (p = win.tab_forest.parentOf(parent)) {
                win.tab_forest.setCollapsed(parent, false);
            }
            win.forestChanged();
            return;
        }
        self.refreshSelection();
    }

    fn onTitle(page: *c.AdwTabPage, _: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const ctx = cast.userData(TitleCtx, user);
        const self = ctx.sidebar;
        if (self.win == null) return;
        for (self.rows.items) |r| switch (r.item) {
            .tab => |candidate| if (candidate == page and r.active) {
                c.gtk_label_set_text(@ptrCast(r.label), c.adw_tab_page_get_title(page));
                return;
            },
            .page => {},
        };
    }

    fn onExpanderClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const r = cast.userData(Row, user);
        if (!r.active) return;
        const self = r.sidebar orelse return;
        const win = self.win orelse return;
        switch (r.item) {
            .tab => |page| {
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
        const r = cast.userData(Row, user);
        if (r.active) closeItem(r);
    }

    fn onMiddlePressed(gesture: *c.GtkGestureClick, _: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
        const r = cast.userData(Row, user);
        if (!r.active) return;
        _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_CLAIMED);
        closeItem(r);
    }

    fn onRowRightClick(gesture: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const r = cast.userData(Row, user);
        if (!r.active) return;
        const self = r.sidebar orelse return;
        const win = self.win orelse return;
        // Claim before popping up: an unclaimed release dismisses the
        // popover the frame it maps (ui/menu.zig documents the race).
        _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_CLAIMED);
        switch (r.item) {
            .tab => |page| {
                // Anchor on the SCROLLER, not the row, and translate the
                // coordinates FIRST: selecting the tab below can rebuild
                // the row list (a browser tab swaps the sidebar to its
                // pages), and a popover parented to the destroyed row
                // crashes in gdk_surface_new_popup.
                var src = c.graphene_point_t{ .x = @floatCast(x), .y = @floatCast(y) };
                var dst = c.graphene_point_t{ .x = 0, .y = 0 };
                if (c.gtk_widget_compute_point(r.row, self.root, &src, &dst) == 0)
                    dst = src;
                const anchor = self.root;
                // Strip convention: the right-click selects the tab so
                // the menu's selection-scoped verbs act on it.
                c.adw_tab_view_set_selected_page(win.tab_view, page);
                tabchrome.onTabContextMenu(@ptrCast(win), page, anchor, @floatCast(dst.x), @floatCast(dst.y));
            },
            .page => |face| {
                const g = self.liveGroup() orelse return;
                if (!g.has(face)) return;
                _ = g.host.showTabMenu(face.root_box, r.row, x, y);
            },
        }
    }

    /// Right-click on the sidebar's empty space: list-level verbs.
    fn onEmptyRightClick(gesture: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Sidebar, user);
        const win = self.win orelse return;
        _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_CLAIMED);

        const cx = self.allocator.create(EmptyMenuCtx) catch return;
        cx.* = .{ .allocator = self.allocator, .sidebar = self };
        const root = classicmenu.Root.create(self.allocator) orelse {
            self.allocator.destroy(cx);
            return;
        };
        root.own(cast.destroyCtx(EmptyMenuCtx), @ptrCast(cx));

        const m = root.top();
        m.itemIcon("New Tab", .{ .name = "tab-new-symbolic" }, &onEmptyMenuNewTab, @ptrCast(cx));
        const tree = m.section();
        var any_children = false;
        for (self.rows.items) |r| {
            const has = switch (r.item) {
                .tab => |page| win.tab_forest.hasChildren(page),
                .page => |face| if (self.liveGroup()) |g| g.forest.hasChildren(face) else false,
            };
            if (has) {
                any_children = true;
                break;
            }
        }
        tree.itemIconEnabled("Collapse All", .{ .name = "view-list-symbolic" }, any_children, &onEmptyMenuCollapseAll, @ptrCast(cx));
        tree.itemIconEnabled("Expand All", .{ .name = "view-list-symbolic" }, true, &onEmptyMenuExpandAll, @ptrCast(cx));
        _ = root.popup(self.root, x, y);
    }

    const EmptyMenuCtx = struct {
        allocator: std.mem.Allocator,
        sidebar: *Sidebar,
    };

    fn onEmptyMenuNewTab(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const cx = cast.userData(EmptyMenuCtx, user);
        const win = cx.sidebar.win orelse return;
        if (!win.newTabInBrowser())
            win.newShellTab(null) catch {};
    }

    fn onEmptyMenuCollapseAll(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        cast.userData(EmptyMenuCtx, user).sidebar.setAllCollapsed(true);
    }

    fn onEmptyMenuExpandAll(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        cast.userData(EmptyMenuCtx, user).sidebar.setAllCollapsed(false);
    }

    /// Collapse or expand every subtree in whichever forest the rows
    /// show. A selection hidden by "collapse all" is pulled up to its
    /// nearest visible ancestor first, or the selected-page watcher
    /// would immediately re-expand its branch.
    fn setAllCollapsed(self: *Sidebar, collapse: bool) void {
        const win = self.win orelse return;
        if (self.liveGroup()) |g| {
            var all: std.ArrayList(*WebFace) = .empty;
            defer all.deinit(self.allocator);
            g.forest.flattenAll(self.allocator, &all) catch return;
            for (all.items) |f| {
                if (g.forest.hasChildren(f)) g.forest.setCollapsed(f, collapse);
            }
            if (collapse) {
                if (g.active()) |cur| {
                    if (g.forest.isHidden(cur)) {
                        var p: *WebFace = cur;
                        while (g.forest.isHidden(p)) p = g.forest.parentOf(p) orelse break;
                        g.setActive(p);
                    }
                }
            }
            win.webGroupChanged(g);
            return;
        }
        var all: std.ArrayList(*c.AdwTabPage) = .empty;
        defer all.deinit(self.allocator);
        win.tab_forest.flattenAll(self.allocator, &all) catch return;
        for (all.items) |page| {
            if (win.tab_forest.hasChildren(page)) win.tab_forest.setCollapsed(page, collapse);
        }
        if (collapse) {
            if (c.adw_tab_view_get_selected_page(win.tab_view)) |sel| {
                if (win.tab_forest.isHidden(sel)) {
                    var p: *c.AdwTabPage = sel;
                    while (win.tab_forest.isHidden(p)) p = win.tab_forest.parentOf(p) orelse break;
                    c.adw_tab_view_set_selected_page(win.tab_view, p);
                }
            }
        }
        win.forestChanged();
    }

    fn closeItem(r: *Row) void {
        const self = r.sidebar orelse return;
        const win = self.win orelse return;
        switch (r.item) {
            .tab => |page| _ = c.adw_tab_view_close_page(win.tab_view, page),
            .page => |face| {
                const g = self.liveGroup() orelse return;
                if (!g.has(face)) return;
                g.closePage(face, g.closePolicy());
            },
        }
    }

    // ── drag and drop ────────────────────────────────────────────
    //
    // A window tab travels as `tabbar`'s shared drag (the strip's own
    // payload), so the sidebar reaches parity for free: the strips of
    // every window already accept it, and a drag that finds no target
    // detaches into a new window through the same callback. Only the
    // browser-PAGE case stays sidebar-private, because a page belongs
    // to one pane's group and has nowhere to land outside it.

    fn onDragPrepare(_: *c.GtkDragSource, _: f64, _: f64, user: ?*anyopaque) callconv(.c) ?*c.GdkContentProvider {
        const r = cast.userData(Row, user);
        if (!r.active) return null;
        const self = r.sidebar orelse return null;
        const win = self.win orelse return null;
        tabbar.clearDrag();
        drag_item = null;
        drag_win = null;
        switch (r.item) {
            .tab => |page| tabbar.publishDrag(win.tab_view, page, win.tabbar.detach_ctx, win.tabbar.on_detach),
            .page => {
                drag_item = r.item;
                drag_win = win;
            },
        }
        return c.gdk_content_provider_new_typed(c.G_TYPE_INT, @as(c_int, 1));
    }

    /// Carry a live picture of the row, like the strip carries a
    /// picture of the tab.
    fn onDragBegin(src: *c.GtkDragSource, _: *c.GdkDrag, user: ?*anyopaque) callconv(.c) void {
        const r = cast.userData(Row, user);
        if (!r.active) return;
        const paintable = c.gtk_widget_paintable_new(r.row) orelse return;
        defer c.g_object_unref(paintable);
        c.gtk_drag_source_set_icon(src, @ptrCast(paintable), 0, 0);
        // The source row all but vacates for the duration: the user is
        // moving THE tab, not minting a copy of it.
        clearDragSrc();
        drag_src_row = r;
        c.gtk_widget_add_css_class(r.row, "sketerm-tst-dragsrc");
    }

    /// Dropped on nothing: the strip's drag-out behaviour, which spawns
    /// a window for the page.
    fn onDragCancel(_: *c.GtkDragSource, _: *c.GdkDrag, reason: c_int, _: ?*anyopaque) callconv(.c) c.gboolean {
        clearDropHint();
        clearDragSrc();
        cancelHoverExpand();
        drag_item = null;
        drag_win = null;
        // Same refusals the strip makes before it detaches: a window's
        // only tab has nowhere to go, and a pinned tab stays put.
        if (tabbar.currentDrag()) |d| {
            if (c.adw_tab_view_get_n_pages(d.view) <= 1 or c.adw_tab_page_get_pinned(d.page) != 0) {
                tabbar.clearDrag();
                return 0;
            }
        }
        return @intFromBool(tabbar.dragCancelled(reason));
    }

    fn onDragEnd(_: *c.GtkDragSource, _: *c.GdkDrag, _: c.gboolean, _: ?*anyopaque) callconv(.c) void {
        clearDropHint();
        clearDragSrc();
        cancelHoverExpand();
        drag_item = null;
        drag_win = null;
        tabbar.clearDrag();
    }

    /// Can this row take what is in flight, and where would it land?
    fn dropTargetFor(r: *Row) ?Item {
        if (!r.active) return null;
        const self = r.sidebar orelse return null;
        const win = self.win orelse return null;
        if (tabbar.currentDrag() != null) {
            // A window tab only nests among window tabs, never into a
            // list of browser pages.
            return if (r.item == .tab) r.item else null;
        }
        const item = drag_item orelse return null;
        if (drag_win != win) return null;
        if (item.eql(r.item)) return null;
        return if (r.item == .page) r.item else null;
    }

    fn onRowMotion(_: *c.GtkDropTarget, _: f64, y: f64, user: ?*anyopaque) callconv(.c) c.GdkDragAction {
        const r = cast.userData(Row, user);
        if (dropTargetFor(r) == null) {
            clearDropHint();
            return 0;
        }
        setDropHint(r, zoneAt(r, y));
        armHoverExpand(r);
        return c.GDK_ACTION_MOVE;
    }

    fn onRowLeave(_: *c.GtkDropTarget, user: ?*anyopaque) callconv(.c) void {
        const r = cast.userData(Row, user);
        if (drop_hint == r) clearDropHint();
        if (hover_expand_row == r) cancelHoverExpand();
    }

    fn onRowDrop(_: *c.GtkDropTarget, _: *const c.GValue, _: f64, y: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const r = cast.userData(Row, user);
        clearDropHint();
        const anchor = dropTargetFor(r) orelse return 0;
        const self = r.sidebar orelse return 0;
        const win = self.win orelse return 0;
        const zone = zoneAt(r, y);
        if (tabbar.takeDrag()) |d| {
            defer tabbar.releaseDrag(d);
            const page = switch (anchor) {
                .tab => |p| p,
                .page => return 0,
            };
            if (d.view != win.tab_view) {
                // Another window's tab: hand it over the way the strip
                // does, then place it in THIS window's forest. The
                // PaneTree travels with the page as qdata.
                var pos = c.adw_tab_view_get_page_position(win.tab_view, page);
                if (zone == .below or zone == .into) pos += 1;
                if (!win.transferPageFrom(d.view, d.page, pos)) return 0;
            } else if (d.page == page) {
                return 0;
            }
            switch (zone) {
                .into => win.tabForestReparent(d.page, page),
                .above => win.tabForestMoveNextTo(d.page, page, false),
                .below => win.tabForestMoveNextTo(d.page, page, true),
            }
            c.adw_tab_view_set_selected_page(win.tab_view, d.page);
            return 1;
        }
        const face = switch (drag_item orelse return 0) {
            .page => |f| f,
            .tab => return 0,
        };
        const onto = switch (anchor) {
            .page => |f| f,
            .tab => return 0,
        };
        const g = self.liveGroup() orelse return 0;
        const moved = switch (zone) {
            .into => g.forest.reparent(face, onto, g.childInsertPos()),
            .above => g.forest.moveNextTo(face, onto, false),
            .below => g.forest.moveNextTo(face, onto, true),
        };
        moved catch |err| {
            if (err == error.WouldCycle)
                winmod.showToast(win, "Cannot drop a tab into its own subtree.");
            return 0;
        };
        self.rebuild();
        return 1;
    }

    fn onListMotion(_: *c.GtkDropTarget, _: f64, _: f64, user: ?*anyopaque) callconv(.c) c.GdkDragAction {
        const self = cast.userData(Sidebar, user);
        clearDropHint();
        if (self.win == null) return 0;
        if (tabbar.currentDrag() != null) return if (self.liveGroup() == null) c.GDK_ACTION_MOVE else 0;
        if (drag_item != null and drag_win == self.win) return c.GDK_ACTION_MOVE;
        return 0;
    }

    /// The empty space below the rows: make the dragged item a root.
    fn onListDrop(_: *c.GtkDropTarget, _: *const c.GValue, _: f64, _: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Sidebar, user);
        clearDropHint();
        const win = self.win orelse return 0;
        if (tabbar.takeDrag()) |d| {
            defer tabbar.releaseDrag(d);
            if (self.liveGroup() != null) return 0;
            if (d.view != win.tab_view and
                !win.transferPageFrom(d.view, d.page, c.adw_tab_view_get_n_pages(win.tab_view)))
                return 0;
            win.tabForestReparent(d.page, null);
            c.adw_tab_view_set_selected_page(win.tab_view, d.page);
            return 1;
        }
        const face = switch (drag_item orelse return 0) {
            .page => |f| f,
            .tab => return 0,
        };
        if (drag_win != win) return 0;
        const g = self.liveGroup() orelse return 0;
        g.forest.reparent(face, null, g.childInsertPos()) catch return 0;
        self.rebuild();
        return 1;
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
        \\/* Firefox-TST (proton) row: inactive rows are flat text on
        \\   the sidebar background; hover gets a faint surface; the
        \\   ACTIVE tab a stronger neutral surface — the same treatment
        \\   the window's tab strip gives its current tab, NOT the blue
        \\   selection colour. `alpha(currentColor, …)` so it works out
        \\   in both light and dark without asking. */
        \\list.sketerm-tst-list > row.sketerm-tst-row {
        \\  min-height: 0;
        \\  padding: 0;
        \\  margin: 0;
        \\  border-radius: 4px;
        \\  background-color: transparent;
        \\  transition: background-color 120ms ease-out;
        \\}
        \\list.sketerm-tst-list > row.sketerm-tst-row:hover {
        \\  background-color: alpha(currentColor, 0.08);
        \\}
        \\/* The ACTIVE tab's row. Our own class, not `:selected`: the
        \\   list has no selection, so this stays put while focus is in a
        \\   pane and cannot drift with the keyboard cursor. */
        \\list.sketerm-tst-list > row.sketerm-tst-row.sketerm-tst-active,
        \\list.sketerm-tst-list > row.sketerm-tst-row.sketerm-tst-active:hover {
        \\  background-color: alpha(currentColor, 0.16);
        \\}
        \\/* The row a drag is moving: it has all but left, only a faint
        \\   placeholder remains until the drop lands. */
        \\list.sketerm-tst-list > row.sketerm-tst-row.sketerm-tst-dragsrc,
        \\list.sketerm-tst-list > row.sketerm-tst-row.sketerm-tst-dragsrc:hover {
        \\  opacity: 0.35;
        \\  background-color: transparent;
        \\}
        \\/* Where a drop would land: a line between rows, a frame for a
        \\   drop INTO the row (making the dragged tab its child). */
        \\list.sketerm-tst-list > row.sketerm-tst-row.tst-drop-above {
        \\  box-shadow: inset 0 3px 0 0 @theme_selected_bg_color;
        \\}
        \\list.sketerm-tst-list > row.sketerm-tst-row.tst-drop-below {
        \\  box-shadow: inset 0 -3px 0 0 @theme_selected_bg_color;
        \\}
        \\list.sketerm-tst-list > row.sketerm-tst-row.tst-drop-into {
        \\  outline: 2px solid @theme_selected_bg_color;
        \\  outline-offset: -2px;
        \\}
        \\.sketerm-tst-body { min-height: 28px; padding: 0 2px 0 2px; }
        \\.sketerm-tst-title { font-size: 1em; }
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
        \\row.sketerm-tst-row.sketerm-tst-active button.sketerm-tst-close { opacity: 1; }
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
