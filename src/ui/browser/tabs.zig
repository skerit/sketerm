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
const applyColumnWidths = @import("render.zig").applyColumnWidths;
const classicmenu = @import("classicmenu.zig");
const tabhost = @import("../tabhost.zig");
const paths = @import("../../filebrowser/paths.zig");
const dnd = @import("dnd.zig");
const dropValueIntoAction = @import("ops.zig").dropValueIntoAction;
const cast = @import("../../util/cast.zig");

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

/// Dragged widths in the same order as `columnsOf`, so the two lists
/// stay positional. 0 = this column was never dragged.
fn colWidthsOf(arena: std.mem.Allocator, tab: *BTab) ![]const i32 {
    var out: std.ArrayList(i32) = .empty;
    for (std.enums.values(browser_model.Column)) |col| {
        if (tab.columns.contains(col)) try out.append(arena, tab.col_widths.get(col));
    }
    return out.items;
}

/// Dragged widths of the extra columns, padded to the name list so a
/// restore can walk them together.
fn attrWidthsOf(arena: std.mem.Allocator, tab: *BTab) ![]const i32 {
    const out = try arena.alloc(i32, tab.attr_columns.items.len);
    for (out, 0..) |*w, i| w.* = if (i < tab.attr_col_widths.items.len) tab.attr_col_widths.items[i] else 0;
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
        .col_widths = try colWidthsOf(arena, tab),
        .attr_col_widths = try attrWidthsOf(arena, tab),
        .name_width = tab.name_width,
        .sort = tab.sort_key,
        .descending = tab.descending,
        .dirs_first = tab.dirs_first,
        .show_hidden = tab.show_hidden,
        .grouped = tab.vs.grouped,
        .zoom = tab.vs.zoom,
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
    // After restoreTabState: the width lists are positional against
    // the column lists it just filled.
    applyColumnWidths(tab, state);
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

/// Wire the browser-specific per-tab gesture on the tab-host label
/// box: the file-drop target. The label itself, close button,
/// middle-click close, scroll-to-switch AND the right-click tab menu
/// are the shared tabhost.zig recipe (see `tabMenuSpec`).
pub fn installTabConveniences(self: *BrowserView, tab: *BTab, label_box: *c.GtkWidget) void {
    _ = self;
    // Middle-click-a-row lives on the column view (colview.zig).

    // Dropping onto a tab targets THAT tab's directory, whichever
    // tab is currently shown.
    const dropt = dnd.newTarget(tab);
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
pub fn openInNewTab(tab: *BTab, path: []const u8) void {
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
    // The picker hides its tab strip; a second tab would be
    // unreachable chrome, so middle-click navigates in place.
    if (tab.view.picker != null) {
        tab.view.navigate(tab, host, pbuf[0..path.len]);
        return;
    }
    _ = tab.view.newTab(host, pbuf[0..path.len]);
}

pub fn onTileMiddleClick(_: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const tab = cast.userData(BTab, user);
    const fb = tab.flowbox orelse return;
    const child = c.gtk_flow_box_get_child_at_pos(fb, @intFromFloat(x), @intFromFloat(y)) orelse return;
    const data = c.g_object_get_data(@ptrCast(child), "sketerm-row") orelse return;
    const ctx: *RowCtx = @ptrCast(@alignCast(data));
    if (!ctx.is_dir) return;
    openInNewTab(tab, ctx.path);
}

pub fn onTabDrop(target: *c.GtkDropTarget, value: *c.GValue, _: f64, _: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
    const tab = cast.userData(BTab, user);
    // The destination is the tab's own root, even when another tab
    // is the visible one.
    var dbuf: [4096]u8 = undefined;
    if (tab.root.path.len >= dbuf.len) return 0;
    @memcpy(dbuf[0..tab.root.path.len], tab.root.path);
    return @intFromBool(dropValueIntoAction(tab.view, tab, value, dbuf[0..tab.root.path.len], dnd.dropAction(target, tab)));
}

// -- the per-tab menu (shared mechanism) ---------------------------
//
// Close / Close Others / Close to the Right / Duplicate come from
// tabhost.zig, which drives them through `on_close` and the
// predicates below. Only the browser-specific row (Reopen Closed
// Tab) is built here.

/// The browser's half of the shared per-tab menu contract.
pub fn tabMenuSpec() tabhost.TabMenu {
    return .{
        .extra = &menuExtra,
        .duplicate = &menuDuplicate,
        .can_duplicate = &menuCanDuplicate,
        .new_window = &menuNewWindow,
        .can_new_window = &menuCanNewWindow,
        // No `modified`: a listing has no unsaved state, so there is
        // no "Close Unmodified Tabs" row here.
    };
}

fn tabForPage(self: *BrowserView, page: *c.GtkWidget) ?*BTab {
    for (self.tabs.items) |t| {
        if (t.page == page) return t;
    }
    return null;
}

fn menuExtra(ctx: ?*anyopaque, _: *c.GtkWidget, _: *classicmenu.Root, m: classicmenu.Menu) void {
    const self = cast.userData(BrowserView, ctx);
    if (self.closed_tabs.closed.items.len == 0) return;
    var label: [96:0]u8 = undefined;
    const text = std.fmt.bufPrintZ(&label, "Reopen Closed Tab ({d})", .{
        self.closed_tabs.closed.items.len,
    }) catch "Reopen Closed Tab";
    m.itemIcon(text.ptr, .{ .name = "document-open-recent-symbolic" }, &onTabMenuReopen, ctx);
}

fn menuDuplicate(ctx: ?*anyopaque, page: *c.GtkWidget) void {
    const self = cast.userData(BrowserView, ctx);
    const tab = tabForPage(self, page) orelse return;
    self.duplicateTab(tab);
}

fn menuCanDuplicate(ctx: ?*anyopaque, page: *c.GtkWidget) bool {
    const self = cast.userData(BrowserView, ctx);
    const tab = tabForPage(self, page) orelse return false;
    return snapshotable(tab);
}

/// This tab's location in a fresh sketerm window — `openFilesWindow`,
/// the same call the menubar's File ▸ New Window makes, given this
/// tab's directory instead of the default one.
fn menuNewWindow(ctx: ?*anyopaque, page: *c.GtkWidget) void {
    const self = cast.userData(BrowserView, ctx);
    const tab = tabForPage(self, page) orelse return;
    const win = self.ownerWindow() orelse return;
    var spec_buf: [4096]u8 = undefined;
    const spec = paths.formatSpec(&spec_buf, tab.hc.host, tab.root.path);
    _ = win.openFilesWindow(spec, null) catch {};
}

fn menuCanNewWindow(ctx: ?*anyopaque, page: *c.GtkWidget) bool {
    const self = cast.userData(BrowserView, ctx);
    const tab = tabForPage(self, page) orelse return false;
    return self.ownerWindow() != null and snapshotable(tab);
}

fn onTabMenuReopen(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(BrowserView, user);
    self.reopenClosedTab();
}

// -- the tab STRIP (empty area) ------------------------------------
// The gestures themselves (right-click / double-click, with the
// empty-area hit test) live in tabhost.zig; the browser provides the
// menu content and the new-tab behaviour through these callbacks.

/// TabHost strip right-click: the browser's strip menu (New Tab +
/// Reopen Closed Tab).
pub fn showStripMenu(self: *BrowserView, x: f64, y: f64) void {
    const root = classicmenu.Root.create(self.allocator) orelse return;
    const m = root.top();
    m.itemIcon("New Tab", .{ .name = "tab-new-symbolic" }, &onStripNewTab, @ptrCast(self));
    if (self.closed_tabs.closed.items.len > 0) {
        var label: [96:0]u8 = undefined;
        const text = std.fmt.bufPrintZ(&label, "Reopen Closed Tab ({d})", .{
            self.closed_tabs.closed.items.len,
        }) catch "Reopen Closed Tab";
        m.item(text.ptr, &onStripReopen, @ptrCast(self));
    }
    _ = root.popupVia(@ptrCast(@alignCast(self.notebook)), self.root_box, x, y);
}

fn onStripNewTab(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    BrowserView.onNewTabClicked(undefined, user);
}

fn onStripReopen(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(BrowserView, user);
    self.reopenClosedTab();
}
