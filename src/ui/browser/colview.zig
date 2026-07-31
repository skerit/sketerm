//! The GtkColumnView listing (details/compact/miller-right): ONE
//! widget owns the header AND the rows, so their columns cannot
//! disagree — resizing, the expand column, the horizontal scrollbar
//! and the rubber band are all GTK's own, exactly the machinery
//! GNOME Files runs on.
//!
//! The model is a flat GListStore of FbItem GObjects rebuilt by
//! renderList (grouping, tree expansion and filtering resolve into
//! the item list, same as the old row walk). Items borrow their
//! `*Entry`/`*Dir` from the tab's directories; mutation paths fence
//! them off before changing that storage, and anything that outlives
//! a render must copy `path`/`is_dir` out (they are owned copies).
//!
//! Cells are recycled: factories build the widget tree once (setup)
//! and re-point it per item (bind). Every cell root carries qdata
//! "sketerm-item" (*ItemData, bind-scoped) and "sketerm-cellobj"
//! (the GtkColumnViewCell, for positions), which is what the pick
//! based hit-testing (context menu, sticky click, drops) climbs to.

const std = @import("std");
const c = @import("../../c.zig").c;
const browser_model = @import("../../filebrowser/model.zig");
const colkeys = @import("../../filebrowser/colkeys.zig");
const fileicon = @import("../../filebrowser/fileicon.zig");
const grouping = @import("../../filebrowser/grouping.zig");
const iconload = @import("iconload.zig");
const profile = @import("../../util/profile.zig");
const render_mod = @import("render.zig");
const selection = @import("selection.zig");
const views = @import("views.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const Dir = @import("types.zig").Dir;
const Entry = @import("types.zig").Entry;
const ColumnRef = render_mod.ColumnRef;
const copyZ = @import("../../filebrowser/format.zig").copyZ;
const copyZN = @import("../../filebrowser/format.zig").copyZN;
const isPreviewMediaName = @import("../../filebrowser/paths.zig").isPreviewMediaName;
const tagColorHex = @import("../../filebrowser/format.zig").tagColorHex;

/// Width of the expander stand-in on rows that cannot expand.
pub const EXPANDER_PX = 16;

// ── the item GObject ─────────────────────────────────────────────

/// The Zig-side payload of one FbItem. Owned by the item; freed in
/// its GObject finalize.
pub const ItemData = struct {
    allocator: std.mem.Allocator,
    tab: *BTab,
    kind: enum { entry, group },
    /// Full path (owned). Empty for group headers.
    path: []u8 = &.{},
    /// Borrowed from the tab's Dir set; valid until the next splice.
    dir: ?*Dir = null,
    entry: ?*Entry = null,
    depth: u16 = 0,
    is_dir: bool = false,
    /// Zebra parity by ENTRY index (group headers reset it), so the
    /// stripes stay in phase across grouped listings.
    alt: bool = false,
    group_id: u64 = 0,
    group_label: [96:0]u8 = undefined,
    group_count: usize = 0,
};

const FbItem = extern struct {
    parent: c.GObject,
    data: ?*ItemData,
};

const FbItemClass = extern struct {
    parent_class: c.GObjectClass,
};

var fb_item_type: c.GType = 0;
var fb_parent_class: ?*c.GObjectClass = null;

fn itemClassInit(class: c.gpointer, _: c.gpointer) callconv(.c) void {
    fb_parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(class)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(class));
    oc.finalize = itemFinalize;
}

fn itemFinalize(obj: [*c]c.GObject) callconv(.c) void {
    const it: *FbItem = @ptrCast(@alignCast(obj));
    if (it.data) |d| {
        if (d.path.len > 0) d.allocator.free(d.path);
        d.allocator.destroy(d);
        it.data = null;
    }
    if (fb_parent_class.?.finalize) |f| f(obj);
}

fn itemType() c.GType {
    if (fb_item_type == 0) {
        fb_item_type = c.g_type_register_static_simple(
            c.G_TYPE_OBJECT,
            "SkFbItem",
            @sizeOf(FbItemClass),
            @ptrCast(&itemClassInit),
            @sizeOf(FbItem),
            null,
            0,
        );
    }
    return fb_item_type;
}

fn newItem(data: *ItemData) ?*c.GObject {
    const obj: ?*c.GObject = @ptrCast(@alignCast(c.g_object_new(itemType(), null)));
    if (obj) |o| {
        const it: *FbItem = @ptrCast(@alignCast(o));
        it.data = data;
    }
    return obj;
}

fn itemPayload(obj: ?*anyopaque) ?*ItemData {
    const o = obj orelse return null;
    const it: *FbItem = @ptrCast(@alignCast(o));
    return it.data;
}

// ── model access helpers ─────────────────────────────────────────

pub fn itemCount(tab: *BTab) c.guint {
    return c.g_list_model_get_n_items(@ptrCast(@alignCast(tab.store)));
}

/// Borrowed payload of the item at `pos` (the item ref is dropped
/// before returning; the store keeps it alive).
pub fn itemDataAt(tab: *BTab, pos: c.guint) ?*ItemData {
    const obj = c.g_list_model_get_item(@ptrCast(@alignCast(tab.store)), pos) orelse return null;
    defer c.g_object_unref(obj);
    return itemPayload(obj);
}

/// Fence recycled cells off before their borrowed Dir/Entry storage changes.
pub fn invalidateBackingRefs(tab: *BTab) void {
    if (tab.view.widgets_dead) {
        tab.name_cells.clearRetainingCapacity();
        return;
    }
    const n = itemCount(tab);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const d = itemDataAt(tab, i) orelse continue;
        d.dir = null;
        d.entry = null;
    }
    tab.name_cells.clearRetainingCapacity();
}

/// Position of the entry item whose path equals `path`.
pub fn positionForPath(tab: *BTab, path: []const u8) ?c.guint {
    const n = itemCount(tab);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const d = itemDataAt(tab, i) orelse continue;
        if (d.kind != .entry) continue;
        if (std.mem.eql(u8, d.path, path)) return i;
    }
    return null;
}

/// Rebind ONE live row after an in-place entry update (the async
/// child count): a fresh item is spliced over the old position, so
/// only that row's cells rebind — the rest of the view keeps its
/// hover, selection and scroll untouched, which a full renderList
/// cannot promise. No-op when the row is not in the model (filtered
/// out, icons view, or a render already pending).
pub fn refreshEntryRow(self: *BrowserView, tab: *BTab, dir: *Dir, e: *Entry) void {
    if (self.widgets_dead or tab.view_mode == .icons) return;
    if (self.listing_render_src != 0) return; // a full rebuild is coming anyway
    const n = itemCount(tab);
    var pos: c.guint = 0;
    const old: *ItemData = blk: while (pos < n) : (pos += 1) {
        const d = itemDataAt(tab, pos) orelse continue;
        if (d.kind == .entry and d.entry == e) break :blk d;
    } else return;
    const d = self.allocator.create(ItemData) catch return;
    d.* = .{
        .allocator = self.allocator,
        .tab = tab,
        .kind = .entry,
        .path = self.allocator.dupe(u8, old.path) catch {
            self.allocator.destroy(d);
            return;
        },
        .dir = dir,
        .entry = e,
        .depth = old.depth,
        .is_dir = e.tdir,
        .alt = old.alt,
    };
    const obj = newItem(d) orelse {
        self.allocator.free(d.path);
        self.allocator.destroy(d);
        return;
    };
    const was_selected = c.gtk_selection_model_is_selected(selModel(tab), pos) != 0;
    // `rendering` fences the selection-changed handler exactly like
    // renderList's splice: the swap must not rewrite tab.selected.
    tab.rendering = true;
    defer tab.rendering = false;
    var items = [_]?*anyopaque{@ptrCast(obj)};
    c.g_list_store_splice(tab.store, pos, 1, &items, 1);
    c.g_object_unref(@as(?*anyopaque, @ptrCast(obj)));
    if (was_selected) _ = c.gtk_selection_model_select_item(selModel(tab), pos, 0);
}

fn selModel(tab: *BTab) *c.GtkSelectionModel {
    return @ptrCast(@alignCast(tab.selmodel));
}

pub fn unselectAll(tab: *BTab) void {
    _ = c.gtk_selection_model_unselect_all(selModel(tab));
}

pub fn countSelected(tab: *BTab) usize {
    const bs = c.gtk_selection_model_get_selection(selModel(tab));
    defer c.gtk_bitset_unref(bs);
    return @intCast(c.gtk_bitset_get_size(bs));
}

/// Select exactly the positions in `want` (every other position is
/// deselected). Takes ownership of nothing; caller unrefs.
pub fn setExactSelection(tab: *BTab, want: *c.GtkBitset) void {
    setSelection(tab, want);
}

fn setSelection(tab: *BTab, want: *c.GtkBitset) void {
    const mask = c.gtk_bitset_new_empty() orelse return;
    defer c.gtk_bitset_unref(mask);
    c.gtk_bitset_add_range(mask, 0, itemCount(tab));
    _ = c.gtk_selection_model_set_selection(selModel(tab), want, mask);
}

/// Focus (and optionally exclusively select) the row at `pos`.
pub fn focusRow(tab: *BTab, pos: c.guint, select: bool) void {
    if (select) _ = c.gtk_selection_model_select_item(selModel(tab), pos, 1);
    c.gtk_column_view_scroll_to(tab.colview, pos, null, c.GTK_LIST_SCROLL_FOCUS, null);
}

// ── pick-based hit testing ───────────────────────────────────────

/// Climb from a (deep) picked widget to the nearest cell root that
/// carries an item.
fn findItemWidget(w0: ?*c.GtkWidget) ?*c.GtkWidget {
    var w = w0;
    while (w) |x| : (w = c.gtk_widget_get_parent(x)) {
        if (c.g_object_get_data(@ptrCast(@alignCast(x)), "sketerm-item") != null) return x;
    }
    return null;
}

pub const Picked = struct { data: *ItemData, pos: c.guint };

/// The item under (x, y) in columnview coords, with its CURRENT
/// position (read live from the cell, so it survives model shifts).
pub fn pickItem(tab: *BTab, x: f64, y: f64) ?Picked {
    const hit = c.gtk_widget_pick(@ptrCast(@alignCast(tab.colview)), x, y, c.GTK_PICK_DEFAULT) orelse return null;
    const root = findItemWidget(hit) orelse return null;
    const data: *ItemData = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(@alignCast(root)), "sketerm-item") orelse return null));
    const cellobj = c.g_object_get_data(@ptrCast(@alignCast(root)), "sketerm-cellobj") orelse return null;
    const pos = c.gtk_column_view_cell_get_position(@ptrCast(@alignCast(cellobj)));
    if (pos == c.GTK_INVALID_LIST_POSITION) return null;
    return .{ .data = data, .pos = pos };
}

/// True when (x, y) lands on the column header strip (a
/// GtkColumnViewTitle or anything inside one).
pub fn pickIsHeader(tab: *BTab, x: f64, y: f64) bool {
    var w = c.gtk_widget_pick(@ptrCast(@alignCast(tab.colview)), x, y, c.GTK_PICK_DEFAULT);
    while (w) |x2| : (w = c.gtk_widget_get_parent(x2)) {
        const tn = std.mem.span(c.g_type_name_from_instance(@ptrCast(@alignCast(x2))));
        if (std.mem.eql(u8, tn, "GtkColumnViewTitle")) return true;
        if (x2 == @as(*c.GtkWidget, @ptrCast(@alignCast(tab.colview)))) break;
    }
    return false;
}

/// Payload + position of the row holding keyboard focus, resolved
/// through the focus chain (columnview → listview → row widget →
/// first cell).
pub fn focusedItem(tab: *BTab) ?Picked {
    var w = c.gtk_widget_get_focus_child(@ptrCast(@alignCast(tab.colview))) orelse return null;
    while (c.gtk_widget_get_focus_child(w)) |inner| w = inner;
    // `w` is (usually) the row widget; its children are the cell
    // wrappers whose child is our tagged root.
    if (findPickedIn(w, 3)) |p| return p;
    return null;
}

fn findPickedIn(w: *c.GtkWidget, depth: u32) ?Picked {
    if (c.g_object_get_data(@ptrCast(@alignCast(w)), "sketerm-item")) |d| {
        const cellobj = c.g_object_get_data(@ptrCast(@alignCast(w)), "sketerm-cellobj") orelse return null;
        const pos = c.gtk_column_view_cell_get_position(@ptrCast(@alignCast(cellobj)));
        if (pos == c.GTK_INVALID_LIST_POSITION) return null;
        return .{ .data = @ptrCast(@alignCast(d)), .pos = pos };
    }
    if (depth == 0) return null;
    var child = c.gtk_widget_get_first_child(w);
    while (child) |ch| : (child = c.gtk_widget_get_next_sibling(ch)) {
        if (findPickedIn(ch, depth - 1)) |p| return p;
    }
    return null;
}

// ── construction ─────────────────────────────────────────────────

/// Per-column signal context (factories, width persistence, header
/// clicks). Freed with the owning signal connection.
const ColCtx = struct {
    allocator: std.mem.Allocator,
    tab: *BTab,
    ref: ColumnRef,

    fn free(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const ctx: *ColCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.destroy(ctx);
    }
};

/// Build the tab's column view, model and controllers. Returns the
/// widget to parent into the tab's scroller.
pub fn installColumnView(self: *BrowserView, tab: *BTab) *c.GtkWidget {
    const store = c.g_list_store_new(itemType());
    const sel = c.gtk_multi_selection_new(@ptrCast(@alignCast(store)));
    const cv = c.gtk_column_view_new(@ptrCast(@alignCast(sel)));
    tab.store = @ptrCast(@alignCast(store));
    tab.selmodel = @ptrCast(@alignCast(sel));
    tab.colview = @ptrCast(@alignCast(cv));

    c.gtk_widget_add_css_class(cv, "sketerm-fb-cv");
    // Nemo's flat look: GTK's data-table density, no separators.
    c.gtk_widget_add_css_class(cv, "data-table");
    c.gtk_column_view_set_show_row_separators(tab.colview, 0);
    c.gtk_column_view_set_show_column_separators(tab.colview, 0);
    c.gtk_column_view_set_single_click_activate(tab.colview, 0);
    c.gtk_column_view_set_reorderable(tab.colview, 0);
    // GTK's own drag-to-select on empty space (and Nemo's click-on-
    // empty-space-deselects falls out of it).
    c.gtk_column_view_set_enable_rubberband(tab.colview, 1);

    // Group headers must not act like rows.
    const rowf = c.gtk_signal_list_item_factory_new();
    _ = c.g_signal_connect_data(rowf, "bind", @ptrCast(&onRowBind), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    c.gtk_column_view_set_row_factory(tab.colview, @ptrCast(@alignCast(rowf)));
    c.g_object_unref(rowf);

    _ = c.g_signal_connect_data(cv, "activate", @ptrCast(&onActivate), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(sel, "selection-changed", @ptrCast(&onSelectionChanged), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);

    // Header clicks change OUR sort state (the model is spliced
    // pre-sorted; GTK only tracks the clicked column and draws the
    // arrows).
    const sorter = c.gtk_column_view_get_sorter(tab.colview);
    _ = c.g_signal_connect_data(sorter, "changed", @ptrCast(&onSorterChanged), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);

    // Capture phase: the context menu must claim the press before
    // the view's own gestures, or a right-click inside a
    // multi-selection collapses the selection the menu acts on.
    const rclick = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(rclick), 3);
    c.gtk_event_controller_set_propagation_phase(@ptrCast(rclick), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(rclick, "pressed", @ptrCast(&@import("menu.zig").onRightClick), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(cv, @ptrCast(rclick));

    // Sticky-click toggling, group-header collapse, and the
    // selection keys — capture phase for the same reason.
    self.installSelectionGestures(tab, cv.?, false);

    // A plain CLICK on empty listing space clears the selection,
    // like every file manager. GTK's rubberband only replaces the
    // selection once it becomes a drag; the zero-travel case is ours.
    const empty_click = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(empty_click), 1);
    _ = c.g_signal_connect_data(empty_click, "pressed", @ptrCast(&onEmptyPressed), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(empty_click, "released", @ptrCast(&onEmptyReleased), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(cv, @ptrCast(empty_click));

    // Middle-click a folder row: open in a new tab.
    const mid = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(mid), c.GDK_BUTTON_MIDDLE);
    _ = c.g_signal_connect_data(mid, "pressed", @ptrCast(&onMiddleClick), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(cv, @ptrCast(mid));

    // Internal DnD target: dropping an entry spec moves/copies into
    // the row's directory (or the tab's).
    const dropt = c.gtk_drop_target_new(c.G_TYPE_STRING, c.GDK_ACTION_COPY | c.GDK_ACTION_MOVE);
    _ = c.g_signal_connect_data(dropt, "drop", @ptrCast(&@import("ops.zig").onListDrop), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(cv, @ptrCast(dropt));

    return cv.?;
}

fn onRowBind(_: *c.GtkSignalListItemFactory, obj: *c.GObject, user: ?*anyopaque) callconv(.c) void {
    _ = user;
    const row: *c.GtkColumnViewRow = @ptrCast(@alignCast(obj));
    const data = itemPayload(c.gtk_column_view_row_get_item(row)) orelse return;
    const is_entry = data.kind == .entry;
    c.gtk_column_view_row_set_selectable(row, @intFromBool(is_entry));
    c.gtk_column_view_row_set_activatable(row, @intFromBool(is_entry));
}

fn onEmptyPressed(_: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    tab.empty_press = .{ .x = x, .y = y };
}

fn onEmptyReleased(_: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    const press = tab.empty_press orelse return;
    tab.empty_press = null;
    // A release that travelled is a rubber band (GTK's), not a click.
    if (@abs(x - press.x) > 2 or @abs(y - press.y) > 2) return;
    if (pickItem(tab, x, y) != null) return;
    if (pickIsHeader(tab, x, y)) return;
    unselectAll(tab);
}

fn onMiddleClick(_: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    const p = pickItem(tab, x, y) orelse return;
    if (p.data.kind != .entry or !p.data.is_dir) return;
    @import("tabs.zig").openInNewTab(tab, p.data.path);
}

fn onActivate(_: *c.GtkColumnView, pos: c.guint, user: ?*anyopaque) callconv(.c) void {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    const d = itemDataAt(tab, pos) orelse return;
    if (d.kind != .entry) return;
    render_mod.activatePath(tab, d.path, d.is_dir);
}

fn onSelectionChanged(_: *c.GtkSelectionModel, _: c.guint, _: c.guint, user: ?*anyopaque) callconv(.c) void {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    if (tab.rendering) return;
    syncSelectedMirror(tab);
    tab.view.updatePreview();
}

/// Rebuild `tab.selected` (the path mirror every verb reads) from
/// the GTK selection.
pub fn syncSelectedMirror(tab: *BTab) void {
    const a = tab.view.allocator;
    for (tab.selected.items) |p| a.free(p);
    tab.selected.clearRetainingCapacity();
    const bs = c.gtk_selection_model_get_selection(selModel(tab));
    defer c.gtk_bitset_unref(bs);
    var iter: c.GtkBitsetIter = undefined;
    var pos: c.guint = 0;
    if (c.gtk_bitset_iter_init_first(&iter, bs, &pos) == 0) return;
    while (true) {
        if (itemDataAt(tab, pos)) |d| {
            if (d.kind == .entry) {
                const owned = a.dupe(u8, d.path) catch break;
                tab.selected.append(a, owned) catch a.free(owned);
            }
        }
        if (c.gtk_bitset_iter_next(&iter, &pos) == 0) break;
    }
}

// ── columns ──────────────────────────────────────────────────────

/// Encoding of a ColumnRef as qdata on its GtkColumnViewColumn.
fn colRefCode(ref: ColumnRef) usize {
    return switch (ref) {
        .name => 1,
        .fixed => |col| 2 + @as(usize, @intFromEnum(col)),
        .attr => |i| 1000 + i,
    };
}

fn colRefFromCode(code: usize) ?ColumnRef {
    if (code == 1) return .name;
    if (code >= 1000) return .{ .attr = code - 1000 };
    if (code >= 2) {
        const v = code - 2;
        if (v <= @intFromEnum(browser_model.Column.target))
            return .{ .fixed = @enumFromInt(v) };
    }
    return null;
}

/// The desired column set, as a comparable signature.
fn columnSignature(tab: *BTab) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(if (tab.view_mode == .details) "d" else "c");
    for (std.enums.values(browser_model.Column)) |col| {
        if (tab.columns.contains(col)) h.update(col.title()[0..std.mem.len(col.title())]);
    }
    for (tab.attr_columns.items) |name| {
        h.update(name);
        h.update("|");
    }
    return h.final();
}

/// A sorter that never sorts: the model is spliced pre-sorted; the
/// sorter exists so GTK makes the header clickable and draws the
/// direction arrow.
fn dummyCompare(_: c.gconstpointer, _: c.gconstpointer, _: c.gpointer) callconv(.c) c_int {
    return 0;
}

fn appendColumn(self: *BrowserView, tab: *BTab, title: [*:0]const u8, ref: ColumnRef) void {
    const setup_ctx = self.allocator.create(ColCtx) catch return;
    setup_ctx.* = .{ .allocator = self.allocator, .tab = tab, .ref = ref };
    const factory = c.gtk_signal_list_item_factory_new();
    if (ref == .name) {
        _ = c.g_signal_connect_data(factory, "setup", @ptrCast(&onNameSetup), @ptrCast(setup_ctx), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(factory, "bind", @ptrCast(&onNameBind), @ptrCast(setup_ctx), @ptrCast(&ColCtx.free), c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(factory, "unbind", @ptrCast(&onNameUnbind), @ptrCast(setup_ctx), null, c.G_CONNECT_DEFAULT);
    } else {
        _ = c.g_signal_connect_data(factory, "setup", @ptrCast(&onCellSetup), @ptrCast(setup_ctx), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(factory, "bind", @ptrCast(&onCellBind), @ptrCast(setup_ctx), @ptrCast(&ColCtx.free), c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(factory, "unbind", @ptrCast(&onCellUnbind), @ptrCast(setup_ctx), null, c.G_CONNECT_DEFAULT);
    }

    const col = c.gtk_column_view_column_new(title, @ptrCast(@alignCast(factory)));
    c.g_object_set_data(@ptrCast(@alignCast(col)), "sketerm-colref", @ptrFromInt(colRefCode(ref)));
    c.gtk_column_view_column_set_resizable(col, 1);
    const sorter = c.gtk_custom_sorter_new(@ptrCast(&dummyCompare), null, null);
    c.gtk_column_view_column_set_sorter(col, @ptrCast(@alignCast(sorter)));
    c.g_object_unref(sorter);

    // Width persistence: GTK writes the dragged width into
    // fixed-width; it joins the folder's remembered view.
    const wctx = self.allocator.create(ColCtx) catch {
        c.gtk_column_view_append_column(tab.colview, col);
        c.g_object_unref(col);
        return;
    };
    wctx.* = .{ .allocator = self.allocator, .tab = tab, .ref = ref };
    _ = c.g_signal_connect_data(col, "notify::fixed-width", @ptrCast(&onColumnWidthChanged), @ptrCast(wctx), @ptrCast(&ColCtx.free), c.G_CONNECT_DEFAULT);

    c.gtk_column_view_append_column(tab.colview, col);
    c.g_object_unref(col);
}

/// GtkColumnViewTitle owns a horizontal box containing its label and
/// native sort indicator. GTK leaves the label at its natural width
/// (which reads as centered once it expands); expanding it puts the
/// indicator against the column's right edge, and xalign 0 keeps the
/// title itself left-aligned like every other file manager.
fn alignHeaderIndicators(w: *c.GtkWidget) void {
    const tn = std.mem.span(c.g_type_name_from_instance(@ptrCast(@alignCast(w))));
    if (std.mem.eql(u8, tn, "GtkColumnViewTitle")) {
        const box = c.gtk_widget_get_first_child(w) orelse return;
        const label = c.gtk_widget_get_first_child(box) orelse return;
        c.gtk_widget_set_hexpand(label, 1);
        if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(label)), c.gtk_label_get_type()) != 0)
            c.gtk_label_set_xalign(@ptrCast(@alignCast(label)), 0);
        return;
    }
    var child = c.gtk_widget_get_first_child(w);
    while (child) |ch| : (child = c.gtk_widget_get_next_sibling(ch))
        alignHeaderIndicators(ch);
}

fn onColumnWidthChanged(obj: *c.GObject, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const ctx: *ColCtx = @ptrCast(@alignCast(user.?));
    const tab = ctx.tab;
    if (tab.col_syncing or tab.rendering) return;
    const width = c.gtk_column_view_column_get_fixed_width(@ptrCast(@alignCast(obj)));
    if (width <= 0) {
        render_mod.resetColumnWidth(tab, ctx.ref);
    } else {
        render_mod.setColumnWidth(tab, ctx.ref, width);
    }
    if (ctx.ref == .name) applyExpandPolicy(tab);
    // Debounced: a drag emits one notify per frame.
    if (tab.width_save_src != 0) _ = c.g_source_remove(tab.width_save_src);
    tab.width_save_src = c.g_timeout_add(400, @ptrCast(&onWidthSaveTick), @ptrCast(tab));
}

fn onWidthSaveTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    tab.width_save_src = 0;
    views.rememberFolder(tab.view, tab);
    return 0;
}

/// Make the view's columns match the tab (set, titles, widths, sort
/// indicator). Cheap when only widths/sort changed; a changed SET
/// rebuilds the GtkColumnViewColumn list.
pub fn syncColumns(self: *BrowserView, tab: *BTab) void {
    installCss(@ptrCast(@alignCast(tab.colview)));
    const sig = columnSignature(tab);
    tab.col_syncing = true;
    defer tab.col_syncing = false;
    if (sig != tab.col_sig) {
        tab.col_sig = sig;
        const cols = c.gtk_column_view_get_columns(tab.colview);
        while (c.g_list_model_get_n_items(cols) > 0) {
            const col = c.g_list_model_get_item(cols, 0) orelse break;
            c.gtk_column_view_remove_column(tab.colview, @ptrCast(@alignCast(col)));
            c.g_object_unref(col);
        }
        appendColumn(self, tab, "Name", .name);
        if (tab.view_mode == .details) {
            for (std.enums.values(browser_model.Column)) |col| {
                if (!tab.columns.contains(col)) continue;
                appendColumn(self, tab, col.title(), .{ .fixed = col });
            }
            for (tab.attr_columns.items, 0..) |name, i| {
                var cb: [64:0]u8 = undefined;
                const txt: [*:0]const u8 = if (std.fmt.bufPrintZ(&cb, "{s}", .{colkeys.label(name)})) |v| v.ptr else |_| "column";
                appendColumn(self, tab, txt, .{ .attr = i });
            }
        }
    }
    applyWidths(tab);
    applyExpandPolicy(tab);
    alignHeaderIndicators(@ptrCast(@alignCast(tab.colview)));
    applySortIndicator(tab);
}

/// Auto-width Name consumes spare room. Once the user gives Name an
/// explicit width, NO column expands: surplus room stays blank at the
/// right, like Nemo. Handing the surplus to the last visible column
/// grew Modified/Created to absurd widths whenever a split closed, and
/// handing it back to Name would snap a just-narrowed Name straight
/// back. A Name width the viewport cannot honour counts as auto here
/// too, so a shrunken pane never hides every other column behind a
/// horizontal scrollbar.
fn applyExpandPolicy(tab: *BTab) void {
    const cols = c.gtk_column_view_get_columns(tab.colview);
    const n = c.g_list_model_get_n_items(cols);
    if (n == 0) return;
    const name_expands = fittedNameWidth(tab) <= 0;
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const obj = c.g_list_model_get_item(cols, i) orelse continue;
        defer c.g_object_unref(obj);
        c.gtk_column_view_column_set_expand(@ptrCast(@alignCast(obj)), @intFromBool(i == 0 and name_expands));
    }
}

/// Room the OTHER columns claim, in pixels. Their widths are all
/// explicit (a dragged one or the type's default), so this is exact
/// rather than a measurement.
fn otherColumnsWidth(tab: *BTab) c_int {
    const cols = c.gtk_column_view_get_columns(tab.colview);
    const n = c.g_list_model_get_n_items(cols);
    var total: c_int = 0;
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const obj = c.g_list_model_get_item(cols, i) orelse continue;
        defer c.g_object_unref(obj);
        const code = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(obj)), "sketerm-colref"));
        const ref = colRefFromCode(code) orelse continue;
        if (ref == .name) continue;
        total += render_mod.columnWidthOf(tab, ref);
    }
    return total;
}

/// The Name width to actually apply: -1 means "auto, take what is
/// left".
///
/// A dragged width is a PREFERENCE, never a floor. Splitting a pane
/// halves the listing, and honouring a width measured in the old,
/// wider pane left Name alone on screen with every other column behind
/// a horizontal scrollbar. So the stored width is clamped to the room
/// this viewport actually has; widening the pane again restores it,
/// because the stored value is never rewritten from here.
fn fittedNameWidth(tab: *BTab) c_int {
    if (tab.name_width <= 0) return -1;
    const avail = c.gtk_widget_get_width(tab.scroller);
    // Before the first allocation there is nothing to fit against.
    if (avail <= 0) return tab.name_width;
    const room = avail - otherColumnsWidth(tab);
    if (room < render_mod.MIN_NAME_WIDTH) return -1;
    return @min(tab.name_width, room);
}

fn applyWidths(tab: *BTab) void {
    const cols = c.gtk_column_view_get_columns(tab.colview);
    const n = c.g_list_model_get_n_items(cols);
    const name_want = fittedNameWidth(tab);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const obj = c.g_list_model_get_item(cols, i) orelse continue;
        defer c.g_object_unref(obj);
        const col: *c.GtkColumnViewColumn = @ptrCast(@alignCast(obj));
        const code = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(col)), "sketerm-colref"));
        const ref = colRefFromCode(code) orelse continue;
        const want: c_int = switch (ref) {
            // Auto: the expand column takes the leftover.
            .name => name_want,
            else => render_mod.columnWidthOf(tab, ref),
        };
        if (c.gtk_column_view_column_get_fixed_width(col) != want)
            c.gtk_column_view_column_set_fixed_width(col, want);
    }
}

/// Re-fit after the listing viewport changed size. The scrolled
/// window's horizontal adjustment is the resize signal GtkWidget does
/// not offer: its page size IS the viewport width.
pub fn installWidthFit(tab: *BTab) void {
    const adj = c.gtk_scrolled_window_get_hadjustment(@ptrCast(@alignCast(tab.scroller))) orelse return;
    _ = c.g_signal_connect_data(adj, "notify::page-size", @ptrCast(&onViewportWidthChanged), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
}

fn onViewportWidthChanged(_: *c.GObject, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    // Only an explicit Name width can ever need re-fitting; an auto
    // one is GTK's own leftover and already correct.
    if (tab.name_width <= 0 or tab.width_fit_src != 0) return;
    tab.width_fit_src = c.g_idle_add(@ptrCast(&onWidthFitTick), @ptrCast(tab));
}

/// Deferred so the widths are read AFTER allocation settled. Applying
/// a width feeds back into the adjustment, so the idle is one-shot and
/// re-arms only when the target actually moved.
fn onWidthFitTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    tab.width_fit_src = 0;
    if (tab.view.widgets_dead) return 0;
    tab.col_syncing = true;
    defer tab.col_syncing = false;
    applyWidths(tab);
    applyExpandPolicy(tab);
    return 0;
}

/// Point GTK's header arrows at the tab's current sort.
fn applySortIndicator(tab: *BTab) void {
    const cols = c.gtk_column_view_get_columns(tab.colview);
    const n = c.g_list_model_get_n_items(cols);
    var active: ?*c.GtkColumnViewColumn = null;
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const obj = c.g_list_model_get_item(cols, i) orelse continue;
        defer c.g_object_unref(obj);
        const col: *c.GtkColumnViewColumn = @ptrCast(@alignCast(obj));
        const code = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(col)), "sketerm-colref"));
        const ref = colRefFromCode(code) orelse continue;
        const marked = switch (ref) {
            .name => tab.sort_key == .name and tab.attr_sort == null,
            .fixed => |fc| tab.attr_sort == null and fc != .target and tab.sort_key == fc.sortKey(),
            .attr => |ai| tab.attr_sort != null and tab.attr_sort.? == ai,
        };
        if (marked and active == null) active = col;
    }
    c.gtk_column_view_sort_by_column(
        tab.colview,
        active,
        if (tab.descending) c.GTK_SORT_DESCENDING else c.GTK_SORT_ASCENDING,
    );
}

/// A header click cycled GTK's column sorter; mirror it into the
/// tab's sort state and re-render.
fn onSorterChanged(sorter: *c.GtkSorter, _: c_int, user: ?*anyopaque) callconv(.c) void {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    if (tab.col_syncing) return;
    const cvs: *c.GtkColumnViewSorter = @ptrCast(@alignCast(sorter));
    const col = c.gtk_column_view_sorter_get_primary_sort_column(cvs);
    const order = c.gtk_column_view_sorter_get_primary_sort_order(cvs);
    var ref: ColumnRef = .name;
    if (col) |cc| {
        const code = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(cc)), "sketerm-colref"));
        ref = colRefFromCode(code) orelse .name;
    }
    // GTK's third click means "unsorted"; a listing is always sorted
    // by SOMETHING, so that state maps back to the name default.
    switch (ref) {
        .name => {
            tab.sort_key = .name;
            tab.attr_sort = null;
        },
        .fixed => |fc| {
            tab.sort_key = fc.sortKey();
            tab.attr_sort = null;
        },
        .attr => |ai| {
            if (ai < tab.attr_columns.items.len) {
                tab.attr_sort = ai;
                tab.sort_key = .name;
                if (colkeys.sourceOf(tab.attr_columns.items[ai]) == .media)
                    @import("mediacols.zig").beginSortFill(tab.view);
            }
        },
    }
    tab.descending = col != null and order == c.GTK_SORT_DESCENDING;
    views.rememberFolder(tab.view, tab);
    tab.view.renderTab(tab);
}

// ── the name cell ────────────────────────────────────────────────

/// Widget refs of one recycled name cell, qdata'd on its root box.
const NameCell = struct {
    allocator: std.mem.Allocator,
    expander: *c.GtkWidget,
    spacer: *c.GtkWidget,
    icon: *c.GtkWidget,
    emblem: *c.GtkWidget,
    label: *c.GtkWidget,
    git: *c.GtkWidget,
    tag: *c.GtkWidget,

    fn free(user: ?*anyopaque) callconv(.c) void {
        const nc: *NameCell = @ptrCast(@alignCast(user.?));
        nc.allocator.destroy(nc);
    }
};

fn onNameSetup(_: *c.GtkSignalListItemFactory, obj: *c.GObject, user: ?*anyopaque) callconv(.c) void {
    const ctx: *ColCtx = @ptrCast(@alignCast(user.?));
    const cell: *c.GtkColumnViewCell = @ptrCast(@alignCast(obj));
    const root = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, render_mod.CELL_SPACING);

    const exp = c.gtk_button_new_from_icon_name("pan-end-symbolic");
    c.gtk_button_set_has_frame(@ptrCast(exp), 0);
    c.gtk_widget_add_css_class(exp, "sketerm-fb-expander");
    c.gtk_widget_set_valign(exp, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_visible(exp, 0);
    _ = c.g_signal_connect_data(exp, "clicked", @ptrCast(&onCellExpandClicked), @ptrCast(root), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(root), exp);

    const spacer = c.gtk_label_new("");
    c.gtk_widget_set_size_request(spacer, EXPANDER_PX, -1);
    c.gtk_box_append(@ptrCast(root), spacer);

    const icon = c.gtk_image_new();
    c.gtk_box_append(@ptrCast(root), icon);

    const emblem = c.gtk_image_new();
    c.gtk_image_set_pixel_size(@ptrCast(emblem), 12);
    c.gtk_widget_set_valign(emblem, c.GTK_ALIGN_END);
    c.gtk_widget_set_visible(emblem, 0);
    c.gtk_box_append(@ptrCast(root), emblem);

    const label = c.gtk_label_new("");
    c.gtk_label_set_xalign(@ptrCast(label), 0);
    c.gtk_widget_set_hexpand(label, 1);
    c.gtk_widget_set_margin_start(label, 4);
    c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
    c.gtk_label_set_width_chars(@ptrCast(label), 3);
    // Natural stays tiny: the column, not the longest filename,
    // decides the width (GtkColumnView measures cell naturals).
    c.gtk_label_set_max_width_chars(@ptrCast(label), 1);
    c.gtk_box_append(@ptrCast(root), label);

    const git = c.gtk_label_new("");
    c.gtk_widget_set_visible(git, 0);
    c.gtk_box_append(@ptrCast(root), git);

    const tag = c.gtk_label_new("");
    c.gtk_widget_set_visible(tag, 0);
    c.gtk_box_append(@ptrCast(root), tag);

    const nc = ctx.allocator.create(NameCell) catch return;
    nc.* = .{
        .allocator = ctx.allocator,
        .expander = exp.?,
        .spacer = spacer.?,
        .icon = icon.?,
        .emblem = emblem.?,
        .label = label.?,
        .git = git.?,
        .tag = tag.?,
    };
    c.g_object_set_data_full(@ptrCast(@alignCast(root)), "sketerm-namecell", @ptrCast(nc), @ptrCast(&NameCell.free));
    c.g_object_set_data(@ptrCast(@alignCast(root)), "sketerm-cellobj", @ptrCast(cell));

    // Any part of the row drags the file (spec string; terminals
    // paste it, browser tabs move/copy).
    const dsrc = c.gtk_drag_source_new();
    _ = c.g_signal_connect_data(dsrc, "prepare", @ptrCast(&onDragPrepare), @ptrCast(root), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(root, @ptrCast(dsrc));

    c.gtk_column_view_cell_set_child(cell, root);
}

/// The bound name-cell root widget currently showing `path`, if any
/// (inline rename edits inside it).
pub fn nameCellForPath(tab: *BTab, path: []const u8) ?*c.GtkWidget {
    return tab.name_cells.get(path);
}

/// The name label inside a name-cell root (inline rename hides it
/// and inserts its editor after it).
pub fn labelOfNameCellRoot(root: *c.GtkWidget) ?*c.GtkWidget {
    const nc = nameCellOf(root) orelse return null;
    return nc.label;
}

/// The icon image of a bound name cell, from its qdata payload
/// (render.zig's thumbnail landing path uses this).
pub fn iconOfNameCell(nc_data: *anyopaque) ?*c.GtkWidget {
    const nc: *NameCell = @ptrCast(@alignCast(nc_data));
    return nc.icon;
}

fn nameCellOf(root: *c.GtkWidget) ?*NameCell {
    const d = c.g_object_get_data(@ptrCast(@alignCast(root)), "sketerm-namecell") orelse return null;
    return @ptrCast(@alignCast(d));
}

fn onCellExpandClicked(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    _ = btn;
    const root: *c.GtkWidget = @ptrCast(@alignCast(user.?));
    const d: *ItemData = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(@alignCast(root)), "sketerm-item") orelse return));
    const tab = d.tab;
    if (d.kind == .group) {
        views.toggleGroup(tab.view, tab, d.group_id);
        return;
    }
    // toggleExpand re-renders (frees d); copy the path out first.
    var buf: [4096]u8 = undefined;
    if (d.path.len >= buf.len) return;
    @memcpy(buf[0..d.path.len], d.path);
    tab.view.toggleExpand(tab, buf[0..d.path.len]);
}

fn onDragPrepare(_: *c.GtkDragSource, _: f64, _: f64, user: ?*anyopaque) callconv(.c) ?*c.GdkContentProvider {
    const root: *c.GtkWidget = @ptrCast(@alignCast(user.?));
    const d: *ItemData = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(@alignCast(root)), "sketerm-item") orelse return null));
    if (d.kind != .entry) return null;
    var pz: [4500:0]u8 = undefined;
    const spec_res = if (d.tab.hc.host) |h|
        std.fmt.bufPrintZ(&pz, "{s}:{s}", .{ h, d.path })
    else
        std.fmt.bufPrintZ(&pz, "{s}", .{d.path});
    const pzs = spec_res catch return null;
    return c.gdk_content_provider_new_typed(c.G_TYPE_STRING, pzs.ptr);
}

fn onNameBind(_: *c.GtkSignalListItemFactory, obj: *c.GObject, user: ?*anyopaque) callconv(.c) void {
    const ctx: *ColCtx = @ptrCast(@alignCast(user.?));
    const cell: *c.GtkColumnViewCell = @ptrCast(@alignCast(obj));
    const root = c.gtk_column_view_cell_get_child(cell) orelse return;
    const nc = nameCellOf(root) orelse return;
    const d = itemPayload(c.gtk_column_view_cell_get_item(cell)) orelse return;
    const tab = ctx.tab;
    const self = tab.view;
    c.g_object_set_data(@ptrCast(@alignCast(root)), "sketerm-item", @ptrCast(d));
    zebraClass(root, d);

    if (d.kind == .group) {
        const collapsed = views.groupCollapsed(tab, d.group_id);
        c.gtk_widget_set_visible(nc.expander, 1);
        c.gtk_button_set_icon_name(@ptrCast(nc.expander), if (collapsed) "pan-end-symbolic" else "pan-down-symbolic");
        c.gtk_widget_set_visible(nc.spacer, 0);
        c.gtk_widget_set_visible(nc.icon, 0);
        c.gtk_widget_set_visible(nc.emblem, 0);
        c.gtk_widget_set_visible(nc.git, 0);
        c.gtk_widget_set_visible(nc.tag, 0);
        var text: [128:0]u8 = undefined;
        const label: [*:0]const u8 = if (std.fmt.bufPrintZ(&text, "{s}  ({d})", .{
            d.group_label[0..std.mem.len(@as([*:0]const u8, &d.group_label))],
            d.group_count,
        })) |v| v.ptr else |_| "group";
        c.gtk_label_set_text(@ptrCast(nc.label), label);
        c.gtk_widget_add_css_class(nc.label, "heading");
        c.gtk_widget_set_margin_start(root, 0);
        c.gtk_widget_set_margin_top(root, 4);
        c.gtk_widget_set_margin_bottom(root, 2);
        return;
    }
    c.gtk_widget_remove_css_class(nc.label, "heading");

    const e = d.entry orelse return;
    const dir = d.dir orelse return;
    const step = tab.vs.step();
    c.gtk_widget_set_margin_start(root, @intCast(@as(u32, d.depth) * 18));
    c.gtk_widget_set_margin_top(root, step.row_pad);
    c.gtk_widget_set_margin_bottom(root, step.row_pad);

    // Expander vs stand-in spacer.
    const can_expand = e.tdir and !dir.flat;
    c.gtk_widget_set_visible(nc.expander, @intFromBool(can_expand));
    c.gtk_widget_set_visible(nc.spacer, @intFromBool(!can_expand));
    if (can_expand) {
        const expanded = tab.subdirByPath(d.path) != null;
        c.gtk_button_set_icon_name(@ptrCast(nc.expander), if (expanded) "pan-down-symbolic" else "pan-end-symbolic");
    }

    // Icon or thumbnail (async thumbs land via applyThumbTexture).
    c.gtk_widget_set_visible(nc.icon, 1);
    var thumb_pending = false;
    if (self.thumbLookup(tab.hc, d.path, e.*)) |tex| {
        c.gtk_image_set_from_paintable(@ptrCast(nc.icon), @ptrCast(tex));
        c.gtk_image_set_pixel_size(@ptrCast(nc.icon), step.icon_px);
    } else {
        thumb_pending = std.mem.eql(u8, e.kind, "file") and isPreviewMediaName(e.name);
        setEntryIcon(nc.icon, @ptrCast(@alignCast(tab.colview)), e.*, step.icon_px);
    }
    c.g_object_set_data(@ptrCast(@alignCast(root)), "sketerm-thumb-pending", if (thumb_pending) @as(?*anyopaque, @ptrFromInt(1)) else null);

    if (render_mod.emblemFor(self, tab, e.*)) |emblem| {
        var iz: [128:0]u8 = undefined;
        iconload.setImageIcon(nc.emblem, @ptrCast(@alignCast(tab.colview)), copyZ(@ptrCast(&iz), emblem), 12);
        c.gtk_widget_set_visible(nc.emblem, 1);
    } else {
        c.gtk_widget_set_visible(nc.emblem, 0);
    }

    var name_buf: [512:0]u8 = undefined;
    const nn = @min(e.name.len, name_buf.len - 1);
    @memcpy(name_buf[0..nn], e.name[0..nn]);
    name_buf[nn] = 0;
    if (self.fileColorFor(e.name)) |color| {
        const esc = c.g_markup_escape_text(&name_buf, -1);
        var mk: [640:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&mk, "<span foreground=\"{s}\">{s}</span>", .{
            color, std.mem.span(@as([*:0]const u8, @ptrCast(esc))),
        })) |m| {
            c.gtk_label_set_markup(@ptrCast(nc.label), m.ptr);
        } else |_| {
            c.gtk_label_set_text(@ptrCast(nc.label), &name_buf);
        }
        c.g_free(esc);
    } else {
        c.gtk_label_set_text(@ptrCast(nc.label), &name_buf);
    }

    // Git status badge (local current dir only).
    var git_shown = false;
    if (tab.hc.host == null and dir == tab.root) {
        if (self.git_map.get(e.name)) |st| {
            var gz: [8:0]u8 = undefined;
            const gtxt = std.fmt.bufPrintZ(&gz, "[{c}]", .{st}) catch "";
            c.gtk_label_set_text(@ptrCast(nc.git), gtxt.ptr);
            c.gtk_widget_remove_css_class(nc.git, "dim-label");
            c.gtk_widget_remove_css_class(nc.git, "warning");
            c.gtk_widget_add_css_class(nc.git, if (st == '?') "dim-label" else "warning");
            c.gtk_widget_set_visible(nc.git, 1);
            git_shown = true;
        }
    }
    if (!git_shown) c.gtk_widget_set_visible(nc.git, 0);

    if (e.tags.len > 0) {
        var tag_z: [128:0]u8 = undefined;
        const ttxt = std.fmt.bufPrintZ(&tag_z, "[{s}]", .{e.tags}) catch "";
        c.gtk_widget_remove_css_class(nc.tag, "dim-label");
        if (std.mem.indexOfAny(u8, e.tags, "<>&\"") == null) {
            var mk: [192:0]u8 = undefined;
            if (std.fmt.bufPrintZ(&mk, "<span foreground=\"{s}\">[{s}]</span>", .{
                tagColorHex(e.tags), e.tags,
            })) |m| {
                c.gtk_label_set_markup(@ptrCast(nc.tag), m.ptr);
            } else |_| {
                c.gtk_label_set_text(@ptrCast(nc.tag), ttxt.ptr);
            }
        } else {
            c.gtk_label_set_text(@ptrCast(nc.tag), ttxt.ptr);
            c.gtk_widget_add_css_class(nc.tag, "dim-label");
        }
        c.gtk_widget_set_visible(nc.tag, 1);
    } else {
        c.gtk_widget_set_visible(nc.tag, 0);
    }

    // Live lookup for thumbnails and inline rename.
    tab.name_cells.put(self.allocator, d.path, root) catch {};
}

fn onNameUnbind(_: *c.GtkSignalListItemFactory, obj: *c.GObject, user: ?*anyopaque) callconv(.c) void {
    const ctx: *ColCtx = @ptrCast(@alignCast(user.?));
    const cell: *c.GtkColumnViewCell = @ptrCast(@alignCast(obj));
    const root = c.gtk_column_view_cell_get_child(cell) orelse return;
    if (c.g_object_get_data(@ptrCast(@alignCast(root)), "sketerm-item")) |dp| {
        const d: *ItemData = @ptrCast(@alignCast(dp));
        if (d.kind == .entry) {
            if (ctx.tab.name_cells.get(d.path)) |w| {
                if (w == root) _ = ctx.tab.name_cells.remove(d.path);
            }
        }
    }
    c.g_object_set_data(@ptrCast(@alignCast(root)), "sketerm-item", null);
}

/// Themed icon for an entry, set onto an existing image (cells are
/// recycled). Same resolution rules as the grid tiles: kind first,
/// then the content type guessed FROM THE NAME.
fn setEntryIcon(img: *c.GtkWidget, anchor: *c.GtkWidget, e: Entry, px: i32) void {
    if (fileicon.folderIconName(e.kind, e.tdir)) |name| {
        var fz: [32:0]u8 = undefined;
        iconload.setImageIcon(img, anchor, copyZN(&fz, name), px);
        return;
    }
    var nz: [512:0]u8 = undefined;
    _ = copyZN(&nz, e.name);
    var uncertain: c.gboolean = 0;
    const ctype = c.g_content_type_guess(&nz, null, 0, &uncertain);
    if (ctype != null) {
        defer c.g_free(ctype);
        if (c.g_content_type_get_icon(ctype)) |gicon| {
            defer c.g_object_unref(gicon);
            iconload.setImageGicon(img, anchor, @ptrCast(gicon), px);
            return;
        }
    }
    var gz: [32:0]u8 = undefined;
    iconload.setImageIcon(img, anchor, copyZN(&gz, fileicon.GENERIC_ICON), px);
}

// ── data cells ───────────────────────────────────────────────────

fn onCellSetup(_: *c.GtkSignalListItemFactory, obj: *c.GObject, user: ?*anyopaque) callconv(.c) void {
    const ctx: *ColCtx = @ptrCast(@alignCast(user.?));
    const cell: *c.GtkColumnViewCell = @ptrCast(@alignCast(obj));
    const label = c.gtk_label_new("");
    c.gtk_widget_add_css_class(label, "sketerm-fb-cell");
    c.gtk_widget_add_css_class(label, "dim-label");
    const xalign: f32 = switch (ctx.ref) {
        .fixed => |col| col.xalign(),
        else => 0,
    };
    c.gtk_label_set_xalign(@ptrCast(label), xalign);
    c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_MIDDLE);
    c.gtk_label_set_max_width_chars(@ptrCast(label), 1);
    switch (ctx.ref) {
        .fixed => |col| if (col == .permissions or col == .octal)
            c.gtk_widget_add_css_class(label, "monospace"),
        else => {},
    }
    // The drag source rides every cell, so a row drags from any
    // column, not just the name.
    const dsrc = c.gtk_drag_source_new();
    _ = c.g_signal_connect_data(dsrc, "prepare", @ptrCast(&onDragPrepare), @ptrCast(label), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(label, @ptrCast(dsrc));
    c.g_object_set_data(@ptrCast(@alignCast(label)), "sketerm-cellobj", @ptrCast(cell));
    c.gtk_column_view_cell_set_child(cell, label);
}

fn onCellBind(_: *c.GtkSignalListItemFactory, obj: *c.GObject, user: ?*anyopaque) callconv(.c) void {
    const ctx: *ColCtx = @ptrCast(@alignCast(user.?));
    const cell: *c.GtkColumnViewCell = @ptrCast(@alignCast(obj));
    const label = c.gtk_column_view_cell_get_child(cell) orelse return;
    const d = itemPayload(c.gtk_column_view_cell_get_item(cell)) orelse return;
    c.g_object_set_data(@ptrCast(@alignCast(label)), "sketerm-item", @ptrCast(d));
    zebraClass(label, d);
    if (d.kind == .group) {
        c.gtk_label_set_text(@ptrCast(label), "");
        return;
    }
    const e = d.entry orelse return;
    const dir = d.dir orelse return;
    var buf: [256:0]u8 = undefined;
    switch (ctx.ref) {
        .fixed => |col| {
            var mode_buf: [16:0]u8 = undefined;
            var size_buf: [48:0]u8 = undefined;
            var items_buf: [32]u8 = undefined;
            var time_buf: [40:0]u8 = undefined;
            c.gtk_label_set_text(@ptrCast(label), render_mod.fixedCellText(dir, e.*, col, &buf, &mode_buf, &size_buf, &items_buf, &time_buf));
        },
        .attr => |i| {
            if (i >= ctx.tab.attr_columns.items.len) {
                c.gtk_label_set_text(@ptrCast(label), "");
                return;
            }
            var disp_buf: [256]u8 = undefined;
            const text = render_mod.columnCellText(ctx.tab, dir, e.*, ctx.tab.attr_columns.items[i], i, &disp_buf);
            c.gtk_label_set_text(@ptrCast(label), copyZ(@ptrCast(&buf), text));
        },
        .name => unreachable,
    }
}

fn onCellUnbind(_: *c.GtkSignalListItemFactory, obj: *c.GObject, user: ?*anyopaque) callconv(.c) void {
    _ = user;
    const cell: *c.GtkColumnViewCell = @ptrCast(@alignCast(obj));
    const label = c.gtk_column_view_cell_get_child(cell) orelse return;
    c.g_object_set_data(@ptrCast(@alignCast(label)), "sketerm-item", null);
}

/// Zebra parity class, stamped on the internal ROW widget (two
/// parents above the cell child: cell node, then row node) so the
/// stripe spans the full row. The class is always maintained;
/// whether it PAINTS is the `sketerm-fb-zebra` class on the view
/// (toggled without a re-render). Every cell of a row stamps the
/// same verdict, which is idempotent.
fn zebraClass(w: *c.GtkWidget, d: *ItemData) void {
    const cell = c.gtk_widget_get_parent(w) orelse return;
    const row = c.gtk_widget_get_parent(cell) orelse return;
    if (d.kind == .entry and d.alt) {
        c.gtk_widget_add_css_class(row, "sketerm-fb-alt");
    } else {
        c.gtk_widget_remove_css_class(row, "sketerm-fb-alt");
    }
}

// ── CSS ──────────────────────────────────────────────────────────

var css_installed = false;

/// Density + zebra + rename-editor styling for the column view.
/// Installed once per process at APPLICATION priority, scoped to
/// the sketerm-fb-cv class.
pub fn installCss(any_widget: *c.GtkWidget) void {
    if (css_installed) return;
    css_installed = true;
    const css =
        \\columnview.sketerm-fb-cv > listview > row {
        \\  padding: 0;
        \\  min-height: 0;
        \\}
        \\columnview.sketerm-fb-cv > listview > row > cell {
        \\  padding: 0 6px;
        \\}
        \\columnview.sketerm-fb-cv > header > button {
        \\  padding: 4px 6px;
        \\}
        \\button.sketerm-fb-expander {
        \\  padding: 0;
        \\  margin: 0;
        \\  border: none;
        \\  min-width: 16px;
        \\  min-height: 16px;
        \\}
        \\columnview.sketerm-fb-cv.sketerm-fb-zebra > listview > row.sketerm-fb-alt:not(:selected):not(:hover) {
        \\  background: alpha(currentColor, 0.035);
        \\}
        \\columnview.sketerm-fb-cv > listview > row:hover:not(:selected) {
        \\  background: alpha(currentColor, 0.1);
        \\}
        \\columnview.sketerm-fb-cv > listview > row:selected,
        \\flowbox.sketerm-fb-flow > flowboxchild:selected {
        \\  background-color: @theme_selected_bg_color;
        \\  color: @theme_selected_fg_color;
        \\}
        \\text.sketerm-fb-rename {
        \\  padding: 0 2px;
        \\  min-height: 0;
        \\  border-radius: 3px;
        \\  background-color: @theme_base_color;
        \\  color: @theme_text_color;
        \\  caret-color: @theme_text_color;
        \\}
    ;
    const provider = c.gtk_css_provider_new();
    c.gtk_css_provider_load_from_string(provider, css);
    const display = c.gtk_widget_get_display(any_widget);
    c.gtk_style_context_add_provider_for_display(display, @ptrCast(@alignCast(provider)), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

// ── rendering (model splice) ─────────────────────────────────────

/// Rebuild the item list for the tab's current listing state and
/// splice it into the store. Widgets are recycled by GTK; scroll
/// position is pinned across the splice for a same-listing render.
pub fn renderList(self: *BrowserView, tab: *BTab) void {
    // A live inline-rename editor cannot survive rebinding; cancel
    // it explicitly rather than trust focus-out to fire.
    if (self.inline_rename) |ir| {
        if (ir.tab == tab) @import("ops.zig").finishInlineRenameDeferred(ir, false);
    }
    const keep_scroll = scrollToKeep(tab);
    tab.rendering = true;
    defer tab.rendering = false;

    const cvw: *c.GtkWidget = @ptrCast(@alignCast(tab.colview));
    if (self.zebra) {
        c.gtk_widget_add_css_class(cvw, "sketerm-fb-zebra");
    } else {
        c.gtk_widget_remove_css_class(cvw, "sketerm-fb-zebra");
    }

    var items: std.ArrayList(?*anyopaque) = .empty;
    defer items.deinit(self.allocator);
    var alt = false;
    if (tab.vs.grouped) {
        buildGroupedItems(self, tab, &items);
    } else {
        buildDirItems(self, tab, tab.root, 0, &items, &alt);
    }

    const old_n = itemCount(tab);
    const new_n: c.guint = @intCast(items.items.len);

    // Windowed splice: rows whose identity AND content are unchanged
    // keep their exact GObjects, so GTK never rebinds them — a
    // watch-delta storm on a busy directory repaints only the rows
    // that changed instead of flickering the whole listing and eating
    // the click under the cursor. Rows named by `changed_paths`
    // (structural deltas, fresh media values) are forced into the
    // window; `changed_all` widens it to everything.
    var prefix: c.guint = 0;
    var suffix: c.guint = 0;
    if (!tab.changed_all) {
        const lim = @min(old_n, new_n);
        while (prefix < lim) : (prefix += 1) {
            const od = itemDataAt(tab, prefix) orelse break;
            const nd = itemPayload(items.items[prefix]) orelse break;
            if (!reusableItem(self, tab, od, nd)) break;
        }
        while (suffix < lim - prefix) : (suffix += 1) {
            const od = itemDataAt(tab, old_n - 1 - suffix) orelse break;
            const nd = itemPayload(items.items[new_n - 1 - suffix]) orelse break;
            if (!reusableItem(self, tab, od, nd)) break;
        }
    }
    // Reused rows keep their item, but the item's borrowed pointers
    // must be re-aimed at the fresh (possibly reallocated) entry
    // storage — delta application nulled them via
    // invalidateBackingRefs, and leaving them null breaks every later
    // interaction with those rows.
    rebindReused(tab, items.items, prefix, suffix, old_n, new_n);

    if (prefix == 0 and suffix == 0) {
        // Full replacement: rebinding drops stale path→cell entries as
        // it goes, but cells that stay unbound would keep pointers to
        // freed items. Partial splices keep out-of-window cells bound
        // and valid, so their map entries must survive.
        tab.name_cells.clearRetainingCapacity();
    }
    c.g_list_store_splice(
        tab.store,
        prefix,
        old_n - prefix - suffix,
        items.items.ptr + prefix,
        new_n - prefix - suffix,
    );
    for (items.items) |it| {
        if (it) |o| c.g_object_unref(@as(?*anyopaque, o));
    }
    tab.clearChanged();

    // Restore the path selection onto the new items.
    const want = c.gtk_bitset_new_empty() orelse return;
    defer c.gtk_bitset_unref(want);
    const n = itemCount(tab);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const d = itemDataAt(tab, i) orelse continue;
        if (d.kind != .entry) continue;
        for (tab.selected.items) |path| {
            if (std.mem.eql(u8, path, d.path)) {
                _ = c.gtk_bitset_add(want, i);
                break;
            }
        }
    }
    setSelection(tab, want);

    if (keep_scroll) |value| restoreScroll(tab, value);
}

/// May the row at this store position keep its GObject for this new
/// item? Identity must match (path, depth, zebra parity when it
/// shows, header fields) and the row must not be named as changed.
fn reusableItem(self: *BrowserView, tab: *BTab, od: *ItemData, nd: *ItemData) bool {
    if (od.kind != nd.kind) return false;
    if (od.kind == .group) {
        return od.group_id == nd.group_id and od.group_count == nd.group_count and
            std.mem.eql(
                u8,
                std.mem.sliceTo(&od.group_label, 0),
                std.mem.sliceTo(&nd.group_label, 0),
            );
    }
    if (od.depth != nd.depth or od.is_dir != nd.is_dir) return false;
    if (self.zebra and od.alt != nd.alt) return false;
    if (!std.mem.eql(u8, od.path, nd.path)) return false;
    for (tab.changed_paths.items) |chp| {
        if (std.mem.eql(u8, chp, od.path)) return false;
    }
    return true;
}

/// Re-aim reused rows' borrowed Dir/Entry pointers at the fresh
/// storage the matching new items carry.
fn rebindReused(tab: *BTab, new_items: []?*anyopaque, prefix: c.guint, suffix: c.guint, old_n: c.guint, new_n: c.guint) void {
    var i: c.guint = 0;
    while (i < prefix) : (i += 1) {
        const od = itemDataAt(tab, i) orelse continue;
        const nd = itemPayload(new_items[i]) orelse continue;
        od.dir = nd.dir;
        od.entry = nd.entry;
    }
    var s: c.guint = 0;
    while (s < suffix) : (s += 1) {
        const od = itemDataAt(tab, old_n - 1 - s) orelse continue;
        const nd = itemPayload(new_items[new_n - 1 - s]) orelse continue;
        od.dir = nd.dir;
        od.entry = nd.entry;
    }
}

fn appendEntryItem(
    self: *BrowserView,
    tab: *BTab,
    dir: *Dir,
    e: *Entry,
    depth: u32,
    alt: *bool,
    items: *std.ArrayList(?*anyopaque),
) void {
    var full_buf: [4096]u8 = undefined;
    const full = dir.fullPath(e.*, &full_buf) orelse return;
    const d = self.allocator.create(ItemData) catch return;
    d.* = .{
        .allocator = self.allocator,
        .tab = tab,
        .kind = .entry,
        .path = self.allocator.dupe(u8, full) catch {
            self.allocator.destroy(d);
            return;
        },
        .dir = dir,
        .entry = e,
        .depth = @intCast(@min(depth, 64)),
        .is_dir = e.tdir,
        .alt = alt.*,
    };
    alt.* = !alt.*;
    const obj = newItem(d) orelse {
        self.allocator.free(d.path);
        self.allocator.destroy(d);
        return;
    };
    items.append(self.allocator, @ptrCast(obj)) catch c.g_object_unref(@as(?*anyopaque, @ptrCast(obj)));
}

fn buildDirItems(
    self: *BrowserView,
    tab: *BTab,
    dir: *Dir,
    depth: u32,
    items: *std.ArrayList(?*anyopaque),
    alt: *bool,
) void {
    for (dir.entries.items) |*e| {
        if (!views.entryVisible(tab, e.*)) continue;
        appendEntryItem(self, tab, dir, e, depth, alt, items);
        if (!e.tdir) continue;
        var buf: [4096]u8 = undefined;
        const child = dir.fullPath(e.*, &buf) orelse continue;
        const sub = tab.subdirByPath(child) orelse continue;
        if (sub.loaded) buildDirItems(self, tab, sub, depth + 1, items, alt);
    }
}

fn appendGroupItem(self: *BrowserView, tab: *BTab, g: grouping.Group, count: usize, items: *std.ArrayList(?*anyopaque)) void {
    const d = self.allocator.create(ItemData) catch return;
    d.* = .{
        .allocator = self.allocator,
        .tab = tab,
        .kind = .group,
        .group_id = g.id,
        .group_count = count,
    };
    _ = std.fmt.bufPrintZ(&d.group_label, "{s}", .{g.label()}) catch {
        d.group_label[0] = 0;
    };
    const obj = newItem(d) orelse {
        self.allocator.destroy(d);
        return;
    };
    items.append(self.allocator, @ptrCast(obj)) catch c.g_object_unref(@as(?*anyopaque, @ptrCast(obj)));
}

/// One group run of the root listing, for the header's count.
const GroupRun = struct { id: u64, count: usize };

/// Grouped rendering: one collapsible header item per bucket of the
/// ROOT listing. Entries are already sorted by the bucket key, so a
/// run ends exactly when the bucket id changes. Zebra parity resets
/// at every header so the stripes stay in phase per group.
fn buildGroupedItems(self: *BrowserView, tab: *BTab, items: *std.ArrayList(?*anyopaque)) void {
    const now_ms = profile.milliTimestamp();
    var runs: std.ArrayList(GroupRun) = .empty;
    defer runs.deinit(self.allocator);
    for (tab.root.entries.items) |e| {
        if (!views.entryVisible(tab, e)) continue;
        const g = views.groupFor(tab, e, now_ms);
        if (runs.items.len > 0 and runs.items[runs.items.len - 1].id == g.id) {
            runs.items[runs.items.len - 1].count += 1;
            continue;
        }
        runs.append(self.allocator, .{ .id = g.id, .count = 1 }) catch return;
    }
    var run: usize = 0;
    var last_id: ?u64 = null;
    var alt = false;
    for (tab.root.entries.items) |*e| {
        if (!views.entryVisible(tab, e.*)) continue;
        const g = views.groupFor(tab, e.*, now_ms);
        if (last_id == null or last_id.? != g.id) {
            last_id = g.id;
            const count = if (run < runs.items.len) runs.items[run].count else 0;
            run += 1;
            appendGroupItem(self, tab, g, count, items);
            alt = false;
        }
        if (views.groupCollapsed(tab, g.id)) continue;
        appendEntryItem(self, tab, tab.root, e, 0, &alt, items);
        if (e.tdir) {
            var buf: [4096]u8 = undefined;
            if (dirChildLoaded(tab, tab.root, e.*, &buf)) |sub|
                buildDirItems(self, tab, sub, 1, items, &alt);
        }
    }
}

fn dirChildLoaded(tab: *BTab, dir: *Dir, e: Entry, buf: *[4096]u8) ?*Dir {
    const child = dir.fullPath(e, buf) orelse return null;
    const sub = tab.subdirByPath(child) orelse return null;
    return if (sub.loaded) sub else null;
}

// ── scroll preservation ──────────────────────────────────────────

/// The scroll position to pin across the rebuild, or null when this
/// render is a navigation (different listing → start at the top).
fn scrollToKeep(tab: *BTab) ?f64 {
    var hasher = std.hash.Wyhash.init(0);
    if (tab.hc.host) |h| hasher.update(h);
    hasher.update(":");
    hasher.update(tab.root.path);
    const hash = hasher.final();
    if (hash != tab.scroll_path_hash) {
        tab.scroll_path_hash = hash;
        return null;
    }
    const vadj = c.gtk_scrolled_window_get_vadjustment(@ptrCast(@alignCast(tab.scroller))) orelse return null;
    const value = c.gtk_adjustment_get_value(vadj);
    return if (value > 0) value else null;
}

const ScrollKeep = struct {
    allocator: std.mem.Allocator,
    adj: *c.GtkAdjustment,
    value: f64,
};

/// Re-assert the captured value from an idle: the splice's clamp
/// happens during the next layout, which runs before idles.
fn restoreScroll(tab: *BTab, value: f64) void {
    const vadj = c.gtk_scrolled_window_get_vadjustment(@ptrCast(@alignCast(tab.scroller))) orelse return;
    const ctx = tab.view.allocator.create(ScrollKeep) catch return;
    ctx.* = .{ .allocator = tab.view.allocator, .adj = vadj, .value = value };
    _ = c.g_object_ref(@as(?*anyopaque, @ptrCast(vadj)));
    _ = c.g_idle_add(@ptrCast(&scrollKeepIdle), @ptrCast(ctx));
}

fn scrollKeepIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const ctx: *ScrollKeep = @ptrCast(@alignCast(user.?));
    c.gtk_adjustment_set_value(ctx.adj, ctx.value);
    c.g_object_unref(@as(?*anyopaque, @ptrCast(ctx.adj)));
    ctx.allocator.destroy(ctx);
    return 0;
}
