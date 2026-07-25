//! Tab conveniences on top of nav.zig's tab lifecycle: the GTK-free
//! per-tab snapshot, duplicate-tab, the closed-tab ring behind
//! undo-close-tab, and the mouse gestures (middle-click a folder to
//! open it in a tab, middle-click a tab to close it, drop files onto
//! a tab to target its directory).
//!
//! nav.zig still owns newTab/closeTab; everything here goes through
//! them. The snapshot is the persisted `browser_model.TabState`, so
//! duplicate-tab, undo-close-tab and layout persistence all describe
//! a tab the same way.

const std = @import("std");
const c = @import("../../c.zig").c;
const browser_model = @import("../../filebrowser/model.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const RowCtx = @import("render.zig").RowCtx;
const dropSpecInto = @import("ops.zig").dropSpecInto;
const menuButton = @import("menu.zig").menuButton;
const connectPopoverAutoUnparent = @import("menu.zig").connectPopoverAutoUnparent;

/// Closed tabs remembered for undo-close-tab. Session state on
/// purpose: a reopened tab is a within-session correction, while
/// layout persistence already records the tabs that were OPEN.
pub const MAX_CLOSED_TABS = 10;

/// One closed tab, its whole snapshot owned by its own arena.
pub const ClosedTab = struct {
    arena: std.heap.ArenaAllocator,
    state: browser_model.TabState,

    pub fn destroy(self: *ClosedTab, allocator: std.mem.Allocator) void {
        self.arena.deinit();
        allocator.destroy(self);
    }
};

/// Tab-convenience state, so BrowserView keeps one field.
pub const State = struct {
    /// Newest last; bounded by MAX_CLOSED_TABS.
    closed: std.ArrayList(*ClosedTab) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.closed.items) |ct| ct.destroy(allocator);
        self.closed.deinit(allocator);
    }
};

fn refForTab(arena: std.mem.Allocator, tab: *BTab, path: []const u8) !browser_model.FileRef {
    return .{
        .host = if (tab.hc.host) |h| try arena.dupe(u8, h) else "",
        .path = try arena.dupe(u8, path),
    };
}

fn historyRefs(arena: std.mem.Allocator, current_host: []const u8, specs: []const []u8) ![]const browser_model.FileRef {
    const out = try arena.alloc(browser_model.FileRef, specs.len);
    for (specs, 0..) |spec, i| out[i] = try browser_model.dupeRef(arena, browser_model.parseSpec(spec, current_host).ref);
    return out;
}

fn columnsOf(arena: std.mem.Allocator, tab: *BTab) ![]const browser_model.Column {
    var out: std.ArrayList(browser_model.Column) = .empty;
    for (std.enums.values(browser_model.Column)) |col| {
        if (tab.columns.contains(col)) try out.append(arena, col);
    }
    return out.items;
}

fn attrColumnsOf(arena: std.mem.Allocator, tab: *BTab) ![]const []const u8 {
    const out = try arena.alloc([]const u8, tab.attr_columns.items.len);
    for (tab.attr_columns.items, 0..) |name, i| out[i] = try arena.dupe(u8, name);
    return out;
}

/// The full GTK-free snapshot of one tab, allocated in `arena`.
pub fn tabStateOf(arena: std.mem.Allocator, tab: *BTab) !browser_model.TabState {
    const host = tab.hc.host orelse "";
    const expanded = try arena.alloc(browser_model.FileRef, tab.subdirs.items.len);
    for (tab.subdirs.items, 0..) |d, j| expanded[j] = try refForTab(arena, tab, d.path);
    const selected = try arena.alloc(browser_model.FileRef, tab.selected.items.len);
    for (tab.selected.items, 0..) |p, j| selected[j] = try refForTab(arena, tab, p);
    return .{
        .kind = if (tab.root.collection) .collection else if (tab.root.flat) .search else .directory,
        .location = try refForTab(arena, tab, tab.root.path),
        .back = try historyRefs(arena, host, tab.back.items),
        .forward = try historyRefs(arena, host, tab.fwd.items),
        .expanded = expanded,
        .selected = selected,
        .view = tab.view_mode,
        .columns = try columnsOf(arena, tab),
        .attr_columns = try attrColumnsOf(arena, tab),
        .sort = tab.sort_key,
        .descending = tab.descending,
        .dirs_first = tab.dirs_first,
        .show_hidden = tab.show_hidden,
        .filter = try arena.dupe(u8, tab.filter),
        .virtual_spec = try arena.dupe(u8, tab.virtual_spec),
    };
}

/// True for the tabs a snapshot can reopen: a search/collection/
/// archive tab's rows come from a job, not from its own directory.
fn snapshotable(tab: *BTab) bool {
    return !tab.root.flat and !tab.root.collection and tab.root.archive.len == 0;
}

/// Open a tab from a snapshot (same host, same history, same view
/// state) and make it current.
fn openFromState(self: *BrowserView, state: browser_model.TabState) ?*BTab {
    const host: ?[]const u8 = if (state.location.host.len == 0) null else state.location.host;
    const tab = self.newTab(host, state.location.path) orelse return null;
    self.restoreTabState(tab, state);
    if (tab.attr_columns.items.len > 0) {
        // The listing newTab already asked for carries no attribute
        // values; re-subscribing is what fills the restored columns.
        self.reopenTabListing(tab);
    } else {
        self.updateSortHeader(tab);
    }
    self.syncPathEntry(tab);
    return tab;
}

/// Clone a tab: location, history, and view state.
pub fn duplicateTab(self: *BrowserView, tab: *BTab) void {
    if (!snapshotable(tab)) {
        self.setStatus("only a directory tab can be duplicated");
        return;
    }
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const state = tabStateOf(arena.allocator(), tab) catch return;
    _ = openFromState(self, state);
}

/// Remember a tab about to be closed. Called by closeTab before the
/// tab's own state is freed.
pub fn stashClosedTab(self: *BrowserView, tab: *BTab) void {
    if (!snapshotable(tab)) return;
    const entry = self.allocator.create(ClosedTab) catch return;
    entry.* = .{ .arena = std.heap.ArenaAllocator.init(self.allocator), .state = .{} };
    entry.state = tabStateOf(entry.arena.allocator(), tab) catch {
        entry.destroy(self.allocator);
        return;
    };
    self.closed_tabs.closed.append(self.allocator, entry) catch {
        entry.destroy(self.allocator);
        return;
    };
    while (self.closed_tabs.closed.items.len > MAX_CLOSED_TABS) {
        const oldest = self.closed_tabs.closed.orderedRemove(0);
        oldest.destroy(self.allocator);
    }
}

/// Reopen the most recently closed tab with its history intact.
pub fn reopenClosedTab(self: *BrowserView) void {
    const entry = self.closed_tabs.closed.pop() orelse {
        self.setStatus("no recently closed tab");
        return;
    };
    defer entry.destroy(self.allocator);
    if (openFromState(self, entry.state) == null) return;
    self.setStatusFmt("reopened {s}", .{entry.state.location.path});
}

// -- mouse conveniences ------------------------------------------

/// Wire the per-tab gestures: middle-click a folder row to open it
/// in a new tab, and the tab label's close/menu/drop behaviors.
pub fn installTabConveniences(self: *BrowserView, tab: *BTab, label_box: *c.GtkWidget) void {
    _ = self;
    const rows = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(rows), c.GDK_BUTTON_MIDDLE);
    _ = c.g_signal_connect_data(rows, "pressed", @ptrCast(&onRowMiddleClick), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(@ptrCast(@alignCast(tab.listbox)), @ptrCast(rows));

    const close = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(close), c.GDK_BUTTON_MIDDLE);
    _ = c.g_signal_connect_data(close, "pressed", @ptrCast(&onTabMiddleClick), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(label_box, @ptrCast(close));

    const menu = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(menu), 3);
    _ = c.g_signal_connect_data(menu, "pressed", @ptrCast(&onTabRightClick), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(label_box, @ptrCast(menu));

    // Dropping onto a tab targets THAT tab's directory, whichever
    // tab is currently shown.
    const dropt = c.gtk_drop_target_new(c.G_TYPE_STRING, c.GDK_ACTION_COPY | c.GDK_ACTION_MOVE);
    _ = c.g_signal_connect_data(dropt, "drop", @ptrCast(&onTabDrop), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(label_box, @ptrCast(dropt));
}

/// The icon grid's half of installTabConveniences (the flow box is
/// built lazily, on the first switch to grid view).
pub fn installGridMiddleClick(self: *BrowserView, tab: *BTab, fb: *c.GtkFlowBox) void {
    _ = self;
    const gesture = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(gesture), c.GDK_BUTTON_MIDDLE);
    _ = c.g_signal_connect_data(gesture, "pressed", @ptrCast(&onTileMiddleClick), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(@ptrCast(@alignCast(fb)), @ptrCast(gesture));
}

/// Open `path` in a new tab on the tab's host, copying both strings
/// out of storage the new tab may re-render away.
fn openInNewTab(tab: *BTab, path: []const u8) void {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return;
    @memcpy(pbuf[0..path.len], path);
    var hbuf: [256]u8 = undefined;
    var host: ?[]const u8 = null;
    if (tab.hc.host) |h| {
        if (h.len >= hbuf.len) return;
        @memcpy(hbuf[0..h.len], h);
        host = hbuf[0..h.len];
    }
    _ = tab.view.newTab(host, pbuf[0..path.len]);
}

pub fn onRowMiddleClick(_: *c.GtkGestureClick, _: c_int, _: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    const row = c.gtk_list_box_get_row_at_y(tab.listbox, @intFromFloat(y)) orelse return;
    const data = c.g_object_get_data(@ptrCast(row), "sketerm-row") orelse return;
    const ctx: *RowCtx = @ptrCast(@alignCast(data));
    if (!ctx.is_dir) return;
    openInNewTab(tab, ctx.path);
}

pub fn onTileMiddleClick(_: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    const fb = tab.flowbox orelse return;
    const child = c.gtk_flow_box_get_child_at_pos(fb, @intFromFloat(x), @intFromFloat(y)) orelse return;
    const data = c.g_object_get_data(@ptrCast(child), "sketerm-row") orelse return;
    const ctx: *RowCtx = @ptrCast(@alignCast(data));
    if (!ctx.is_dir) return;
    openInNewTab(tab, ctx.path);
}

pub fn onTabMiddleClick(_: *c.GtkGestureClick, _: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    tab.view.closeTab(tab);
}

pub fn onTabDrop(_: *c.GtkDropTarget, value: *c.GValue, _: f64, _: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    const cstr = c.g_value_get_string(value) orelse return 0;
    const spec = std.mem.span(@as([*:0]const u8, @ptrCast(cstr)));
    // The destination is the tab's own root, even when another tab
    // is the visible one.
    var dbuf: [4096]u8 = undefined;
    if (tab.root.path.len >= dbuf.len) return 0;
    @memcpy(dbuf[0..tab.root.path.len], tab.root.path);
    return @intFromBool(dropSpecInto(tab.view, tab, spec, dbuf[0..tab.root.path.len]));
}

/// Heap context for the tab menu; owned by its popover.
pub const TabMenuCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    tab: *BTab,
    popover: *c.GtkWidget,

    pub fn free(user: ?*anyopaque) callconv(.c) void {
        const ctx: *TabMenuCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.destroy(ctx);
    }
};

pub fn onTabRightClick(_: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    tab.view.showTabMenu(tab, x, y);
}

pub fn showTabMenu(self: *BrowserView, tab: *BTab, x: f64, y: f64) void {
    const label_box = c.gtk_notebook_get_tab_label(self.notebook, tab.page) orelse return;
    const popover = c.gtk_popover_new();
    const ctx = self.allocator.create(TabMenuCtx) catch return;
    ctx.* = .{ .allocator = self.allocator, .view = self, .tab = tab, .popover = popover };
    c.g_object_set_data_full(@ptrCast(popover), "sketerm-tabmenu", @ptrCast(ctx), @ptrCast(&TabMenuCtx.free));

    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    menuButton(box, "Duplicate Tab", &onTabMenuDuplicate, @ptrCast(ctx), false);
    if (self.closed_tabs.closed.items.len > 0) {
        var label: [96:0]u8 = undefined;
        const text = std.fmt.bufPrintZ(&label, "Reopen Closed Tab ({d})", .{
            self.closed_tabs.closed.items.len,
        }) catch "Reopen Closed Tab";
        menuButton(box, text.ptr, &onTabMenuReopen, @ptrCast(ctx), false);
    }
    menuButton(box, "Close Tab", &onTabMenuClose, @ptrCast(ctx), true);
    c.gtk_popover_set_child(@ptrCast(popover), box);
    c.gtk_widget_set_parent(popover, label_box);
    connectPopoverAutoUnparent(popover);
    const rect = c.GdkRectangle{ .x = @intFromFloat(x), .y = @intFromFloat(y), .width = 1, .height = 1 };
    c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
    c.gtk_popover_popup(@ptrCast(popover));
}

pub fn onTabMenuDuplicate(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *TabMenuCtx = @ptrCast(@alignCast(user.?));
    const view = ctx.view;
    const tab = ctx.tab;
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
    view.duplicateTab(tab);
}

pub fn onTabMenuReopen(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *TabMenuCtx = @ptrCast(@alignCast(user.?));
    const view = ctx.view;
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
    view.reopenClosedTab();
}

pub fn onTabMenuClose(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *TabMenuCtx = @ptrCast(@alignCast(user.?));
    const view = ctx.view;
    const tab = ctx.tab;
    // The popover is parented to the tab label this is about to
    // destroy; pop it down first.
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
    view.closeTab(tab);
}
