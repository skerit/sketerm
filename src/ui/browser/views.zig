//! The views cluster: grouping with collapsible headers, zoom levels,
//! filter-as-you-type narrowing, the flat/branch view, and per-folder
//! view memory.
//!
//! State lives in exactly two structs: `State` (one field on
//! BrowserView) holds the view menu, the filter bar and the folder
//! memory store; `TabView` (one field on BTab) holds the per-tab
//! grouping flag, zoom step and collapsed-group set. Rendering itself
//! stays in render.zig, which asks this module what is visible, how
//! big it is, and which group a row belongs to.

const std = @import("std");
const c = @import("../../c.zig").c;
const browser_model = @import("../../filebrowser/model.zig");
const grouping = @import("../../filebrowser/grouping.zig");
const viewmem = @import("../../filebrowser/viewmem.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const Entry = @import("types.zig").Entry;
const connectPopoverAutoUnparent = @import("menu.zig").connectPopoverAutoUnparent;
const menuButton = @import("menu.zig").menuButton;
const showColumnPicker = @import("render.zig").showColumnPicker;

/// One zoom step. Icon sizes stop at 128 on purpose: that is the
/// freedesktop `normal` tier the thumbnail pipeline generates and
/// caches, so no step ever upscales a thumbnail -- and since the
/// thumbnail cache key is (path, mtime) and carries no size, zooming
/// never invalidates a single cached texture.
pub const Step = struct {
    /// Row icon AND row thumbnail size in the details/compact lists
    /// (one size so thumbnailed rows stay the same height as the
    /// rest; drives row height together with row_pad).
    icon_px: i32,
    /// Tile icon/thumbnail size in the grid.
    tile_icon_px: i32,
    /// Tile width in the grid.
    tile_px: i32,
    /// Vertical margin per list row.
    row_pad: i32,
};

/// Step DEFAULT_ZOOM is the treeview-dense default: a 23px row, the
/// density a GTK3 file manager (Nemo) has. These paddings ARE the
/// whole row height now -- the theme's own list-row padding and
/// min-height are zeroed for the browser listing by the stylesheet
/// render.installCss puts up, so nothing is added on top of them.
pub const ZOOM_STEPS = [_]Step{
    .{ .icon_px = 16, .tile_icon_px = 32, .tile_px = 72, .row_pad = 1 },
    .{ .icon_px = 24, .tile_icon_px = 48, .tile_px = 96, .row_pad = 2 },
    .{ .icon_px = 32, .tile_icon_px = 64, .tile_px = 120, .row_pad = 4 },
    .{ .icon_px = 48, .tile_icon_px = 96, .tile_px = 152, .row_pad = 7 },
    .{ .icon_px = 64, .tile_icon_px = 128, .tile_px = 184, .row_pad = 10 },
};

/// The step a tab starts at (and what a pre-zoom state file loads as):
/// exactly the sizes the browser used before zoom existed.
pub const DEFAULT_ZOOM: u8 = 1;

/// Per-tab view state.
pub const TabView = struct {
    grouped: bool = false,
    zoom: u8 = DEFAULT_ZOOM,
    /// Collapsed group ids (grouping.Group.id). Per group per tab.
    collapsed: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Last rendered counts, for the status line ("X of Y").
    shown: usize = 0,
    total: usize = 0,

    pub fn deinit(self: *TabView, allocator: std.mem.Allocator) void {
        self.collapsed.deinit(allocator);
    }

    pub fn step(self: *const TabView) Step {
        return ZOOM_STEPS[@min(self.zoom, ZOOM_STEPS.len - 1)];
    }
};

/// View-level state for the whole cluster.
pub const State = struct {
    /// Live only while the view menu is open.
    zoom_label: ?*c.GtkWidget = null,
    /// Filter bar (built on first use).
    filter_bar: ?*c.GtkWidget = null,
    filter_entry: ?*c.GtkEntry = null,
    /// Guard against the entry's own "changed" while syncing it.
    syncing_filter: bool = false,
    /// Per-folder view memory, loaded on first use.
    mem: ?viewmem.Store = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        _ = allocator;
        if (self.mem) |*m| m.deinit();
        self.mem = null;
    }
};

// -- filtering ---------------------------------------------------

/// Whether an entry is rendered at all: the hidden-files toggle plus
/// the live filter. The single visibility predicate for every view
/// mode, so a filtered listing cannot disagree with its own count.
pub fn entryVisible(tab: *BTab, e: Entry) bool {
    if (!tab.show_hidden and e.name.len > 0 and e.name[0] == '.') return false;
    if (tab.filter.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(e.name, tab.filter) != null;
}

/// Toggle the filter bar (Ctrl+I). Hiding it clears the filter: a
/// narrowed listing with no visible filter box is a trap.
pub fn toggleFilter(self: *BrowserView) void {
    const bar = ensureFilterBar(self) orelse return;
    if (c.gtk_widget_get_visible(bar) != 0) {
        setFilterText(self, "");
        c.gtk_widget_set_visible(bar, 0);
        return;
    }
    c.gtk_widget_set_visible(bar, 1);
    if (self.views.filter_entry) |entry| _ = c.gtk_widget_grab_focus(@ptrCast(@alignCast(entry)));
}

pub fn ensureFilterBar(self: *BrowserView) ?*c.GtkWidget {
    if (self.views.filter_bar) |bar| return bar;
    const bar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
    c.gtk_widget_set_margin_start(bar, 4);
    c.gtk_widget_set_margin_end(bar, 4);
    c.gtk_widget_set_margin_bottom(bar, 4);
    const label = c.gtk_label_new("Filter");
    c.gtk_widget_add_css_class(label, "dim-label");
    c.gtk_box_append(@ptrCast(bar), label);
    const entry = c.gtk_entry_new();
    c.gtk_widget_set_hexpand(entry, 1);
    c.gtk_entry_set_placeholder_text(@ptrCast(entry), "narrow this listing (substring, case-insensitive)");
    _ = c.g_signal_connect_data(entry, "changed", @ptrCast(&onFilterChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    const keys = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(@ptrCast(keys), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onFilterKey), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(entry, @ptrCast(keys));
    c.gtk_box_append(@ptrCast(bar), entry);
    const close = c.gtk_button_new_from_icon_name("window-close-symbolic");
    c.gtk_button_set_has_frame(@ptrCast(close), 0);
    c.gtk_widget_set_tooltip_text(close, "Clear the filter and hide this bar");
    _ = c.g_signal_connect_data(close, "clicked", @ptrCast(&onFilterClose), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(bar), close);
    c.gtk_widget_set_visible(bar, 0);
    // Built here rather than in buildUi so the filter bar is free
    // until someone asks for it; it sits under the search bar.
    c.gtk_box_insert_child_after(@ptrCast(self.root_box), bar, self.search_bar);
    self.views.filter_bar = bar;
    self.views.filter_entry = @ptrCast(@alignCast(entry));
    return bar;
}

/// Replace the current tab's filter and re-render.
pub fn setFilter(self: *BrowserView, text: []const u8) void {
    const tab = self.currentTab() orelse return;
    if (std.mem.eql(u8, tab.filter, text)) return;
    if (tab.filter.len > 0) self.allocator.free(tab.filter);
    tab.filter = if (text.len == 0) &.{} else (self.allocator.dupe(u8, text) catch &.{});
    self.renderTab(tab);
}

fn setFilterText(self: *BrowserView, text: [*:0]const u8) void {
    const entry = self.views.filter_entry orelse return;
    self.views.syncing_filter = true;
    c.gtk_editable_set_text(@ptrCast(entry), text);
    self.views.syncing_filter = false;
    setFilter(self, std.mem.span(text));
}

/// Push the tab's filter into the entry when the visible tab changes.
/// The filter is TAB state, so switching tabs must not carry one
/// tab's narrowing into another.
pub fn syncFilterEntry(self: *BrowserView, tab: *BTab) void {
    const entry = self.views.filter_entry orelse return;
    // A background tab can be re-rendered (a delta, a search match);
    // only the visible one owns the shared entry.
    if (self.currentTab() != tab) return;
    const current = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(entry)))));
    if (std.mem.eql(u8, current, tab.filter)) return;
    var z: [512:0]u8 = undefined;
    const n = @min(tab.filter.len, z.len - 1);
    @memcpy(z[0..n], tab.filter[0..n]);
    z[n] = 0;
    self.views.syncing_filter = true;
    c.gtk_editable_set_text(@ptrCast(entry), &z);
    self.views.syncing_filter = false;
}

pub fn onFilterChanged(_: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    if (self.views.syncing_filter) return;
    const entry = self.views.filter_entry orelse return;
    const txt = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(entry)))));
    setFilter(self, txt);
}

pub fn onFilterKey(_: *c.GtkEventControllerKey, keyval: c_uint, _: c_uint, _: c.GdkModifierType, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    if (keyval != c.GDK_KEY_Escape) return 0;
    toggleFilter(self);
    return 1;
}

pub fn onFilterClose(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    toggleFilter(self);
}

// -- zoom --------------------------------------------------------

/// Move the current tab `delta` zoom steps (clamped, remembered).
pub fn zoomBy(self: *BrowserView, delta: i32) void {
    const tab = self.currentTab() orelse return;
    const at: i32 = @intCast(@min(tab.vs.zoom, ZOOM_STEPS.len - 1));
    const next = std.math.clamp(at + delta, 0, @as(i32, ZOOM_STEPS.len - 1));
    if (next == at) return;
    tab.vs.zoom = @intCast(next);
    updateZoomLabel(self, tab);
    rememberFolder(self, tab);
    self.renderTab(tab);
}

/// Ctrl+wheel zoom. Installed in the CAPTURE phase so the scrolled
/// window never sees the event first; a plain wheel still scrolls.
pub fn onZoomScroll(ctrl: *c.GtkEventControllerScroll, _: f64, dy: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    const state = c.gtk_event_controller_get_current_event_state(@ptrCast(ctrl));
    if (state & c.GDK_CONTROL_MASK == 0) return 0;
    if (dy == 0) return 1;
    const self = tab.view;
    if (self.currentTab() != tab) return 1;
    zoomBy(self, if (dy < 0) 1 else -1);
    return 1;
}

/// Per-tab gestures owned by this module (Ctrl+wheel zoom).
pub fn installViewGestures(self: *BrowserView, tab: *BTab, page: *c.GtkWidget) void {
    _ = self;
    const scroll = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_VERTICAL);
    c.gtk_event_controller_set_propagation_phase(@ptrCast(scroll), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(scroll, "scroll", @ptrCast(&onZoomScroll), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(page, @ptrCast(scroll));
}

// -- grouping ----------------------------------------------------

/// The group an entry belongs to under the tab's active sort key.
/// With dirs-first on, directories form their own leading group so a
/// bucket never appears twice in one listing.
pub fn groupFor(tab: *BTab, e: Entry, now_ms: i64) grouping.Group {
    if (tab.dirs_first and e.tdir) return grouping.folders();
    return grouping.groupOf(tab.sort_key, .{
        .name = e.name,
        .kind = e.kind,
        .size = e.size,
        .mtime_ms = e.mtime_ms,
        .ctime_ms = e.ctime_ms,
        .atime_ms = e.atime_ms,
        .btime_ms = e.btime_ms,
        .uid = e.uid,
        .gid = e.gid,
        .owner = e.owner,
        .group = e.group,
        .mode = e.mode,
        .nlink = e.nlink,
        .blocks = e.blocks,
        .is_dir = e.tdir,
    }, now_ms);
}

pub fn groupCollapsed(tab: *BTab, id: u64) bool {
    return tab.vs.collapsed.contains(id);
}

pub fn toggleGroup(self: *BrowserView, tab: *BTab, id: u64) void {
    if (tab.vs.collapsed.remove(id)) {
        self.renderTab(tab);
        return;
    }
    tab.vs.collapsed.put(self.allocator, id, {}) catch return;
    self.renderTab(tab);
}

pub fn setGrouping(self: *BrowserView, tab: *BTab, on: bool) void {
    if (tab.vs.grouped == on) return;
    tab.vs.grouped = on;
    if (!on) tab.vs.collapsed.clearRetainingCapacity();
    rememberFolder(self, tab);
    self.renderTab(tab);
}

// -- flat / branch view ------------------------------------------

/// Flatten the tab's whole subtree into one operable list, or go back
/// to the plain directory listing. The rows are the same flat rows a
/// search produces (full path in `target`, path relative to the root
/// as the display name), so every entry verb keeps working.
pub fn toggleFlat(self: *BrowserView, tab: *BTab) void {
    if (flatOn(tab)) {
        stopFlat(self, tab);
        return;
    }
    startFlat(self, tab);
}

/// Whether this tab is showing its own subtree flattened (as opposed
/// to a query results tab, which is flat but is not a directory).
pub fn flatOn(tab: *BTab) bool {
    const q = tab.query orelse return false;
    return q.mode == .flat;
}

pub fn startFlat(self: *BrowserView, tab: *BTab) void {
    if (tab.root.collection or tab.root.archive.len > 0) {
        self.setStatus("flat view needs a real directory");
        return;
    }
    if (tab.root.flat) {
        self.setStatus("this tab already shows a flat result list");
        return;
    }
    if (tab.hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{tab.hc.label()});
        return;
    }
    // The subtree stream replaces the directory subscription.
    @import("colview.zig").invalidateBackingRefs(tab);
    self.cancelPendingDir(tab.root);
    self.closeViewOf(tab.hc, tab.root);
    tab.root.view_id = 0;
    for (tab.root.entries.items) |*e| e.deinit(self.allocator);
    tab.root.entries.clearRetainingCapacity();
    tab.dropSubdirsUnder(tab.root.path);
    tab.root.flat = true;
    tab.root.loaded = true;
    // A flat view IS a live query over the tab's own directory: the
    // same live_find job, so a rename or delete in the subtree updates
    // the list by itself, and the same per-tab ownership, so several
    // flattened tabs coexist.
    var root_buf: [4096]u8 = undefined;
    if (tab.root.path.len >= root_buf.len) return;
    @memcpy(root_buf[0..tab.root.path.len], tab.root.path);
    const root = root_buf[0..tab.root.path.len];
    if (!self.queryStart(tab, root, "*", .{ .kind = .live_name, .pattern = "*" }, .flat)) return;
    self.setStatusFmt("flattening {s}…", .{root});
    self.renderTab(tab);
}

/// Stop `tab`'s flat view and re-subscribe the directory it was
/// flattening.
pub fn stopFlat(self: *BrowserView, tab: *BTab) void {
    if (!flatOn(tab)) return;
    self.queryForget(tab);
    for (tab.root.entries.items) |*e| e.deinit(self.allocator);
    tab.root.entries.clearRetainingCapacity();
    tab.root.flat = false;
    tab.root.loaded = false;
    // A closed view id is spent; the fresh subscription needs its own.
    tab.root.view_id = self.next_view;
    self.next_view += 1;
    self.openDir(tab, tab.root);
    self.setStatusFmt("flat view off: {s}", .{tab.root.path});
    self.renderTab(tab);
}

// -- per-folder view memory --------------------------------------

fn memStore(self: *BrowserView) *viewmem.Store {
    if (self.views.mem == null) self.views.mem = viewmem.Store.load(self.allocator);
    return &self.views.mem.?;
}

/// True for the tabs whose location is a real remembered folder
/// (search results, collections and archives are not folders).
fn memorable(tab: *BTab) bool {
    return !tab.root.flat and !tab.root.collection and tab.root.archive.len == 0;
}

/// Apply the folder's remembered view settings, if any. Called when a
/// tab lands on a directory; an explicit TabState restore runs after
/// this and therefore wins.
pub fn applyFolderMemory(self: *BrowserView, tab: *BTab) void {
    if (!memorable(tab)) return;
    const rec = memStore(self).use(tab.hc.host orelse "", tab.root.path) orelse return;
    tab.view_mode = rec.view;
    tab.sort_key = rec.sort;
    tab.attr_sort = null;
    tab.descending = rec.descending;
    tab.dirs_first = rec.dirs_first;
    tab.vs.grouped = rec.grouped;
    tab.vs.zoom = @min(rec.zoom, ZOOM_STEPS.len - 1);
    tab.name_width = rec.name_width;
    if (rec.columns.len > 0) {
        tab.columns = .initEmpty();
        for (rec.columns) |col| tab.columns.insert(col);
        // Widths are positional against rec.columns; a navigation
        // reuses the tab, so widths from the previous folder must not
        // bleed into this one.
        tab.col_widths = .initFill(0);
        for (rec.columns, 0..) |col, i| {
            if (i >= rec.col_widths.len) break;
            if (rec.col_widths[i] > 0) tab.col_widths.set(col, rec.col_widths[i]);
        }
    }
}

/// Record the tab's view settings for its folder. Called from every
/// place that changes one of them.
pub fn rememberFolder(self: *BrowserView, tab: *BTab) void {
    if (!memorable(tab)) return;
    var cols: [std.enums.values(browser_model.Column).len]browser_model.Column = undefined;
    var widths: [std.enums.values(browser_model.Column).len]i32 = undefined;
    var n: usize = 0;
    for (std.enums.values(browser_model.Column)) |col| {
        if (!tab.columns.contains(col)) continue;
        cols[n] = col;
        widths[n] = tab.col_widths.get(col);
        n += 1;
    }
    const store = memStore(self);
    store.remember(.{
        .host = tab.hc.host orelse "",
        .path = tab.root.path,
        .view = tab.view_mode,
        .sort = tab.sort_key,
        .descending = tab.descending,
        .dirs_first = tab.dirs_first,
        .grouped = tab.vs.grouped,
        .zoom = tab.vs.zoom,
        .columns = cols[0..n],
        .col_widths = widths[0..n],
        .name_width = tab.name_width,
    });
    store.save();
}

pub fn forgetFolder(self: *BrowserView, tab: *BTab) void {
    const store = memStore(self);
    if (store.forget(tab.hc.host orelse "", tab.root.path)) {
        store.save();
        self.setStatusFmt("forgot the view settings for {s}", .{tab.root.path});
    } else {
        self.setStatus("this folder has no remembered view settings");
    }
}

pub fn forgetAllFolders(self: *BrowserView) void {
    const store = memStore(self);
    const n = store.count();
    store.forgetAll();
    store.save();
    self.setStatusFmt("forgot the view settings of {d} folder(s)", .{n});
}

// -- the view menu -----------------------------------------------

/// Add the view-options button to the toolbar. Called once, from
/// attach, so buildUi stays a plain widget tree.
pub fn installViewMenu(self: *BrowserView) void {
    // First slot of the collapsible cluster (whose parent is read off
    // the Places toggle; the old anchor, the hidden-files toggle, now
    // lives in the hamburger menu).
    const bar = c.gtk_widget_get_parent(@ptrCast(@alignCast(self.places_toggle))) orelse return;
    const btn = c.gtk_button_new_from_icon_name("view-list-symbolic");
    // Same treatment view.zig's `flatten` gives every other toolbar
    // button: flat, out of the focus chain, so the right cluster
    // reads as one row of icons.
    BrowserView.flatten(btn.?);
    c.gtk_widget_set_tooltip_text(btn, "View options: view mode, columns, grouping, zoom, filter, flat view, folder memory");
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onViewMenuClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_insert_child_after(@ptrCast(bar), btn, null);
}

/// Heap context for one view-mode radio in the View options menu.
const ModeCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    mode: browser_model.ViewMode,

    fn free(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const ctx: *ModeCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.destroy(ctx);
    }
};

pub fn onViewModeChosen(check: *c.GtkCheckButton, user: ?*anyopaque) callconv(.c) void {
    if (c.gtk_check_button_get_active(check) == 0) return;
    const ctx: *ModeCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const tab = self.currentTab() orelse return;
    if (tab.view_mode == ctx.mode) return;
    tab.view_mode = ctx.mode;
    self.setStatusFmt("view: {s}", .{@tagName(ctx.mode)});
    rememberFolder(self, tab);
    self.renderTab(tab);
}

fn updateZoomLabel(self: *BrowserView, tab: *BTab) void {
    const label = self.views.zoom_label orelse return;
    var buf: [64:0]u8 = undefined;
    const txt = std.fmt.bufPrintZ(&buf, "{d} px icons", .{tab.vs.step().tile_icon_px}) catch return;
    c.gtk_label_set_text(@ptrCast(@alignCast(label)), txt.ptr);
}

pub fn onViewMenuClicked(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const tab = self.currentTab() orelse return;
    const popover = c.gtk_popover_new();
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
    c.gtk_widget_set_margin_start(box, 10);
    c.gtk_widget_set_margin_end(box, 10);
    c.gtk_widget_set_margin_top(box, 10);
    c.gtk_widget_set_margin_bottom(box, 10);

    // View-mode radios first, like Dolphin's view_settings dropdown.
    const mode_rows = [_]struct { label: [*:0]const u8, mode: browser_model.ViewMode }{
        .{ .label = "Details list", .mode = .details },
        .{ .label = "Compact list", .mode = .compact },
        .{ .label = "Icon grid", .mode = .icons },
        .{ .label = "Miller columns", .mode = .miller },
    };
    var mode_group: ?*c.GtkCheckButton = null;
    for (mode_rows) |m| {
        const rb = c.gtk_check_button_new_with_label(m.label);
        if (mode_group == null) {
            mode_group = @ptrCast(@alignCast(rb));
        } else {
            c.gtk_check_button_set_group(@ptrCast(rb), mode_group);
        }
        c.gtk_check_button_set_active(@ptrCast(rb), @intFromBool(tab.view_mode == m.mode));
        const mctx = self.allocator.create(ModeCtx) catch continue;
        mctx.* = .{ .allocator = self.allocator, .view = self, .mode = m.mode };
        _ = c.g_signal_connect_data(rb, "toggled", @ptrCast(&onViewModeChosen), @ptrCast(mctx), @ptrCast(&ModeCtx.free), c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), rb);
    }
    c.gtk_box_append(@ptrCast(box), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL));

    var gbuf: [96:0]u8 = undefined;
    const gtxt: [*:0]const u8 = if (std.fmt.bufPrintZ(&gbuf, "Group by {s}", .{@tagName(tab.sort_key)})) |v| v.ptr else |_| "Group";
    const group = c.gtk_check_button_new_with_label(gtxt);
    c.gtk_widget_set_tooltip_text(group, "Collapsible headers over the active sort key (list views)");
    c.gtk_check_button_set_active(@ptrCast(group), @intFromBool(tab.vs.grouped));
    _ = c.g_signal_connect_data(group, "toggled", @ptrCast(&onGroupToggled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(box), group);

    const flat = c.gtk_check_button_new_with_label("Flat view (whole subtree)");
    c.gtk_widget_set_tooltip_text(flat, "Flatten every file under this folder into one operable list");
    c.gtk_check_button_set_active(@ptrCast(flat), @intFromBool(flatOn(tab)));
    _ = c.g_signal_connect_data(flat, "toggled", @ptrCast(&onFlatToggled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(box), flat);

    const zebra = c.gtk_check_button_new_with_label("Zebra stripes");
    c.gtk_widget_set_tooltip_text(zebra, "Slight alternating row background (all browser panes)");
    c.gtk_check_button_set_active(@ptrCast(zebra), @intFromBool(self.zebra));
    _ = c.g_signal_connect_data(zebra, "toggled", @ptrCast(&onZebraToggled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(box), zebra);

    const side_info = c.gtk_check_button_new_with_label("Sidebar info card");
    c.gtk_widget_set_tooltip_text(side_info, "Compact selection summary at the bottom of the places sidebar");
    c.gtk_check_button_set_active(@ptrCast(side_info), @intFromBool(self.side_info));
    _ = c.g_signal_connect_data(side_info, "toggled", @ptrCast(&@import("preview.zig").onSideInfoToggled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(box), side_info);

    const zoom_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
    const zoom_out = c.gtk_button_new_from_icon_name("zoom-out-symbolic");
    c.gtk_widget_set_tooltip_text(zoom_out, "Smaller icons and rows (Ctrl+wheel down)");
    _ = c.g_signal_connect_data(zoom_out, "clicked", @ptrCast(&onZoomOut), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(zoom_row), zoom_out);
    const zoom_label = c.gtk_label_new("");
    c.gtk_widget_set_hexpand(zoom_label, 1);
    c.gtk_box_append(@ptrCast(zoom_row), zoom_label);
    const zoom_in = c.gtk_button_new_from_icon_name("zoom-in-symbolic");
    c.gtk_widget_set_tooltip_text(zoom_in, "Bigger icons and rows (Ctrl+wheel up)");
    _ = c.g_signal_connect_data(zoom_in, "clicked", @ptrCast(&onZoomIn), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(zoom_row), zoom_in);
    c.gtk_box_append(@ptrCast(box), zoom_row);
    self.views.zoom_label = zoom_label;
    updateZoomLabel(self, tab);

    menuButton(box, "Filter this listing (Ctrl+I)", &onFilterMenu, @ptrCast(self), false);
    // The visible way to the column picker, now that the header
    // carries no picker button of its own (right-clicking the header
    // still opens the same popover).
    menuButton(box, "Columns...", &onColumnsMenu, @ptrCast(self), false);
    c.gtk_box_append(@ptrCast(box), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL));
    const mem_head = c.gtk_label_new("This folder's view is remembered per folder");
    c.gtk_label_set_xalign(@ptrCast(mem_head), 0);
    c.gtk_widget_add_css_class(mem_head, "dim-label");
    c.gtk_box_append(@ptrCast(box), mem_head);
    menuButton(box, "Forget this folder's view", &onForgetFolder, @ptrCast(self), false);
    var abuf: [96:0]u8 = undefined;
    const atxt: [*:0]const u8 = if (std.fmt.bufPrintZ(&abuf, "Forget all {d} remembered folders", .{
        memStore(self).count(),
    })) |v| v.ptr else |_| "Forget all remembered folders";
    menuButton(box, atxt, &onForgetAllFolders, @ptrCast(self), true);

    c.gtk_popover_set_child(@ptrCast(popover), box);
    var bounds: c.graphene_rect_t = undefined;
    if (c.gtk_widget_compute_bounds(@ptrCast(btn), @ptrCast(btn), &bounds) != 0) {
        const rect = c.GdkRectangle{
            .x = @intFromFloat(bounds.origin.x),
            .y = @intFromFloat(bounds.origin.y),
            .width = @intFromFloat(bounds.size.width),
            .height = @intFromFloat(bounds.size.height),
        };
        c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
    }
    c.gtk_widget_set_parent(popover, @ptrCast(btn));
    connectPopoverAutoUnparent(popover);
    _ = c.g_signal_connect_data(popover, "closed", @ptrCast(&onViewMenuClosed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_popover_popup(@ptrCast(popover));
}

pub fn onViewMenuClosed(_: *c.GtkPopover, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    // The label dies with the popover.
    self.views.zoom_label = null;
}

pub fn onGroupToggled(check: *c.GtkCheckButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const tab = self.currentTab() orelse return;
    setGrouping(self, tab, c.gtk_check_button_get_active(check) != 0);
}

pub fn onFlatToggled(check: *c.GtkCheckButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const tab = self.currentTab() orelse return;
    const want = c.gtk_check_button_get_active(check) != 0;
    if (want == flatOn(tab)) return;
    toggleFlat(self, tab);
}

pub fn onZebraToggled(check: *c.GtkCheckButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const want = c.gtk_check_button_get_active(check) != 0;
    if (want == self.zebra) return;
    self.zebra = want;
    // Pure CSS class flip on every tab's column view — the cells
    // carry their parity class permanently, this decides whether it
    // paints. No re-render.
    for (self.tabs.items) |tab| {
        const cv: *c.GtkWidget = @ptrCast(@alignCast(tab.colview));
        if (want) {
            c.gtk_widget_add_css_class(cv, "sketerm-fb-zebra");
        } else {
            c.gtk_widget_remove_css_class(cv, "sketerm-fb-zebra");
        }
    }
    self.savePlaces();
}

pub fn onZoomIn(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    zoomBy(@ptrCast(@alignCast(user.?)), 1);
}

pub fn onZoomOut(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    zoomBy(@ptrCast(@alignCast(user.?)), -1);
}

pub fn onFilterMenu(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const bar = ensureFilterBar(self) orelse return;
    if (c.gtk_widget_get_visible(bar) == 0) toggleFilter(self);
}

/// "Columns..." in the view menu: close this popover, then open the
/// column picker over the tab's header strip.
pub fn onColumnsMenu(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const tab = self.currentTab() orelse return;
    if (c.gtk_widget_get_ancestor(@ptrCast(@alignCast(btn)), c.gtk_popover_get_type())) |pop|
        c.gtk_popover_popdown(@ptrCast(pop));
    showColumnPicker(tab, @ptrCast(@alignCast(tab.colview)));
}

pub fn onForgetFolder(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const tab = self.currentTab() orelse return;
    forgetFolder(self, tab);
}

pub fn onForgetAllFolders(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    forgetAllFolders(@ptrCast(@alignCast(user.?)));
}
