//! The selection cluster: sticky (toggle) selection, the vim-style
//! visual range mode, and the named persistent registers.
//!
//! State lives in exactly two structs: `State` (one field on
//! BrowserView) holds the register store and the name the mark
//! dialog offers next; `TabSel` (one field on BTab) holds the tab's
//! sticky flag and its visual-mode anchor. The selection ITSELF stays
//! where it always was -- `BTab.selected`, synced from the GTK
//! selection by render.zig -- so every existing verb keeps working
//! without knowing this module exists.
//!
//! Registers subsume the old collection shelf: the shelf is the
//! register named `registers.COLLECTION`, which is why there is one
//! store, one file and one set of verbs instead of two parallel
//! persistent cross-host sets. `migrateCollection` imports a shelf
//! written by a pre-register build exactly once.

const std = @import("std");
const c = @import("../../c.zig").c;
const places_mod = @import("../../filebrowser/places.zig");
const registers = @import("../../filebrowser/registers.zig");
const toolbtn = @import("../toolbtn.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const RowCtx = @import("render.zig").RowCtx;
const activateEntry = @import("render.zig").activateEntry;
const colview = @import("colview.zig");
const render_mod = @import("render.zig");
const dnd = @import("dnd.zig");
const connectPopoverAutoUnparent = @import("menu.zig").connectPopoverAutoUnparent;
const entryForPath = @import("nav.zig").entryForPath;
const formatSpec = @import("../../filebrowser/paths.zig").formatSpec;
const menuButton = @import("menu.zig").menuButton;
const menuDone = @import("menu.zig").menuDone;
const MenuCtx = @import("menu.zig").MenuCtx;
const cast = @import("../../util/cast.zig");

/// Per-tab selection state.
pub const TabSel = struct {
    /// Plain left click TOGGLES the clicked entry instead of
    /// replacing the selection (the xplorer2 / Explorer-checkbox
    /// model), so a misclick cannot destroy a curated set. Ctrl and
    /// Shift clicks keep their normal GTK meaning either way, which
    /// is what makes this cooperate with multi-select instead of
    /// fighting it.
    sticky: bool = false,
    /// Visual mode: the row index the range is anchored at (null =
    /// not in visual mode).
    anchor: ?c_int = null,
    /// The selection visual mode started from (owned full paths).
    /// The range is UNIONED with it, and cancelling restores it
    /// exactly -- so visual mode composes with sticky marks rather
    /// than throwing them away.
    saved: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *TabSel, allocator: std.mem.Allocator) void {
        for (self.saved.items) |p| allocator.free(p);
        self.saved.deinit(allocator);
    }
};

/// View-level state for the whole cluster.
pub const State = struct {
    /// Loaded on first use (marking, or a shelf migration).
    store: ?registers.Store = null,
    /// Name the mark dialog pre-fills next time (owned).
    last_name: ?[]u8 = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.store) |*s| s.deinit();
        self.store = null;
        if (self.last_name) |n| allocator.free(n);
        self.last_name = null;
    }
};

pub fn regStore(self: *BrowserView) *registers.Store {
    if (self.sel.store == null) self.sel.store = registers.Store.load(self.allocator);
    return &self.sel.store.?;
}

fn rememberName(self: *BrowserView, name: []const u8) void {
    const owned = self.allocator.dupe(u8, name) catch return;
    if (self.sel.last_name) |old| self.allocator.free(old);
    self.sel.last_name = owned;
}

fn defaultName(self: *BrowserView) []const u8 {
    return self.sel.last_name orelse registers.COLLECTION;
}

/// Import a collection shelf written by a pre-register build, once.
/// places.json is rewritten without it immediately, so the import
/// cannot run twice and a later unmark cannot be undone by a stale
/// copy still sitting in the old file.
pub fn migrateCollection(self: *BrowserView, items: []const places_mod.CollItem) void {
    if (items.len == 0) return;
    const store = regStore(self);
    if (store.sizeOf(registers.COLLECTION) == 0) {
        for (items) |ci| _ = store.add(registers.COLLECTION, registers.entryFromSpec(ci.spec, ci.dir));
        store.save();
    }
    self.savePlaces();
}

// -- sticky selection --------------------------------------------

/// Heap context for one register row/button.
pub const RegCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    name: []u8,
    action: enum { open, select_here, copy_here, delete, forget, mark_named, mark_results },
    popover: ?*c.GtkWidget = null,
    entry: ?*c.GtkWidget = null,

    fn free(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const ctx = cast.userData(RegCtx, user);
        ctx.allocator.free(ctx.name);
        ctx.allocator.destroy(ctx);
    }
};

fn regButton(self: *BrowserView, box: *c.GtkWidget, icon: [*:0]const u8, tip: [*:0]const u8, name: []const u8, action: @TypeOf(@as(RegCtx, undefined).action), destructive: bool) void {
    const btn = c.gtk_button_new_from_icon_name(icon);
    c.gtk_button_set_has_frame(@ptrCast(btn), 0);
    c.gtk_widget_set_tooltip_text(btn, tip);
    if (destructive) c.gtk_widget_add_css_class(btn, "destructive-action");
    const ctx = self.allocator.create(RegCtx) catch return;
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .name = self.allocator.dupe(u8, name) catch {
            self.allocator.destroy(ctx);
            return;
        },
        .action = action,
    };
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onRegAction), @ptrCast(ctx), @ptrCast(&RegCtx.free), c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(box), btn);
}

/// Install the per-tab selection controllers on a list or grid: the
/// sticky click interceptor and the selection keys. Both run in the
/// CAPTURE phase -- GtkListBox claims a plain click, the arrow keys
/// AND Ctrl+Space (as activate-cursor-row, which opens the file) in
/// its own bubble-phase bindings, so a bubble-phase interceptor would
/// only ever see what it has already lost.
pub fn installSelectionGestures(self: *BrowserView, tab: *BTab, widget: *c.GtkWidget, grid: bool) void {
    _ = self;
    const click = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(click), 1);
    c.gtk_event_controller_set_propagation_phase(@ptrCast(click), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(
        click,
        "pressed",
        @ptrCast(if (grid) &onGridStickyPressed else &onListStickyPressed),
        @ptrCast(tab),
        null,
        c.G_CONNECT_DEFAULT,
    );
    _ = c.g_signal_connect_data(click, "released", @ptrCast(&onSelectionReleased), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(widget, @ptrCast(click));
    const keys = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(@ptrCast(keys), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onSelectionKey), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(widget, @ptrCast(keys));
}

fn onSelectionReleased(_: *c.GtkGestureClick, _: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    const tab = cast.userData(BTab, user);
    dnd.clearDragSelection(tab);
}

/// True when the click carries a modifier the list widget itself
/// should interpret (Ctrl = add, Shift = range): sticky mode only
/// claims the PLAIN click.
fn plainClick(gesture: *c.GtkGestureClick) bool {
    const state = c.gtk_event_controller_get_current_event_state(@ptrCast(gesture));
    return (state & (c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK)) == 0;
}

pub fn onListStickyPressed(gesture: *c.GtkGestureClick, n_press: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const tab = cast.userData(BTab, user);
    // Group headers collapse on a plain click regardless of modes.
    if (colview.pickItem(tab, x, y)) |p| {
        if (p.data.kind == .entry) dnd.armSelection(tab, p.data.path);
        if (p.data.kind == .group) {
            _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_CLAIMED);
            @import("views.zig").toggleGroup(tab.view, tab, p.data.group_id);
            return;
        }
    }
    if (!tab.sel.sticky or tab.sel.anchor != null) return;
    if (!plainClick(gesture)) return;
    const p = colview.pickItem(tab, x, y) orelse return;
    if (p.data.kind != .entry) return;
    // Claiming denies the view's own click handling, which is what
    // stops the plain click from collapsing the selection to one row.
    _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_CLAIMED);
    if (n_press >= 2) {
        // Double click still opens: claiming press 1 means the view
        // never sees press 2 either, so activation is ours too.
        render_mod.activatePath(tab, p.data.path, p.data.is_dir);
        return;
    }
    const model: *c.GtkSelectionModel = @ptrCast(@alignCast(tab.selmodel));
    if (c.gtk_selection_model_is_selected(model, p.pos) != 0) {
        _ = c.gtk_selection_model_unselect_item(model, p.pos);
    } else {
        _ = c.gtk_selection_model_select_item(model, p.pos, 0);
    }
    colview.focusRow(tab, p.pos, false);
    tab.view.setStatusFmt("{d} selected (sticky)", .{tab.selected.items.len});
}

pub fn onGridStickyPressed(gesture: *c.GtkGestureClick, n_press: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const tab = cast.userData(BTab, user);
    const fb = tab.flowbox orelse return;
    const child = c.gtk_flow_box_get_child_at_pos(fb, @intFromFloat(x), @intFromFloat(y)) orelse return;
    const data = c.g_object_get_data(@ptrCast(child), "sketerm-row") orelse return;
    const row: *RowCtx = @ptrCast(@alignCast(data));
    dnd.armSelection(tab, row.path);
    if (!tab.sel.sticky) return;
    if (!plainClick(gesture)) return;
    _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_CLAIMED);
    if (n_press >= 2) {
        activateEntry(tab, @ptrCast(@alignCast(data)));
        return;
    }
    if (c.gtk_flow_box_child_is_selected(child) != 0) {
        c.gtk_flow_box_unselect_child(fb, child);
    } else {
        c.gtk_flow_box_select_child(fb, child);
    }
    _ = c.gtk_widget_grab_focus(@ptrCast(child));
    tab.view.setStatusFmt("{d} selected (sticky)", .{tab.selected.items.len});
}

pub fn toggleSticky(self: *BrowserView, tab: *BTab) void {
    tab.sel.sticky = !tab.sel.sticky;
    if (tab.sel.sticky) {
        self.setStatus("sticky selection on: a click toggles an item, Ctrl/Shift still work");
    } else {
        self.setStatus("sticky selection off");
    }
}

// -- keyboard marking --------------------------------------------

/// Toggle the mark on the focused entry and step to the next one
/// (Insert / Ctrl+Space): the keyboard half of sticky selection, and
/// it needs no mode of its own.
pub fn toggleMarkFocused(self: *BrowserView) bool {
    const tab = self.currentTab() orelse return false;
    if (tab.view_mode == .icons) {
        const fb = tab.flowbox orelse return false;
        const focus = c.gtk_widget_get_focus_child(@ptrCast(@alignCast(fb)));
        const fbc: *c.GtkFlowBoxChild = if (focus) |w|
            @ptrCast(@alignCast(w))
        else
            c.gtk_flow_box_get_child_at_index(fb, 0) orelse return false;
        if (c.gtk_flow_box_child_is_selected(fbc) != 0) {
            c.gtk_flow_box_unselect_child(fb, fbc);
        } else {
            c.gtk_flow_box_select_child(fb, fbc);
        }
        const next = c.gtk_flow_box_get_child_at_index(fb, c.gtk_flow_box_child_get_index(fbc) + 1) orelse fbc;
        _ = c.gtk_widget_grab_focus(@ptrCast(next));
        self.setStatusFmt("{d} selected", .{tab.selected.items.len});
        return true;
    }
    const pos: c.guint = if (colview.focusedItem(tab)) |p| p.pos else 0;
    const d = colview.itemDataAt(tab, pos) orelse return false;
    if (d.kind != .entry) return false;
    const model: *c.GtkSelectionModel = @ptrCast(@alignCast(tab.selmodel));
    if (c.gtk_selection_model_is_selected(model, pos) != 0) {
        _ = c.gtk_selection_model_unselect_item(model, pos);
    } else {
        _ = c.gtk_selection_model_select_item(model, pos, 0);
    }
    const next = if (pos + 1 < colview.itemCount(tab)) pos + 1 else pos;
    colview.focusRow(tab, next, false);
    self.setStatusFmt("{d} selected", .{tab.selected.items.len});
    return true;
}

// -- visual (range) mode -----------------------------------------

/// Select exactly (saved selection) UNION (anchor..cursor).
fn applyVisualRange(self: *BrowserView, tab: *BTab, cursor: c.guint) void {
    const anchor = tab.sel.anchor orelse return;
    const anchor_u: c.guint = @intCast(@max(anchor, 0));
    const lo = @min(anchor_u, cursor);
    const hi = @max(anchor_u, cursor);
    const want = c.gtk_bitset_new_empty() orelse return;
    defer c.gtk_bitset_unref(want);
    const n = colview.itemCount(tab);
    var idx: c.guint = 0;
    var marked: usize = 0;
    while (idx < n) : (idx += 1) {
        const d = colview.itemDataAt(tab, idx) orelse continue;
        if (d.kind != .entry) continue;
        var take = idx >= lo and idx <= hi;
        if (!take) {
            for (tab.sel.saved.items) |p| {
                if (std.mem.eql(u8, p, d.path)) {
                    take = true;
                    break;
                }
            }
        }
        if (take) {
            _ = c.gtk_bitset_add(want, idx);
            marked += 1;
        }
    }
    colview.setExactSelection(tab, want);
    colview.focusRow(tab, cursor, false);
    self.setStatusFmt("visual select: {d} item(s): arrows extend, Enter commits, Escape cancels", .{marked});
}

/// Enter or leave visual mode (Ctrl+Shift+X). Leaving this way
/// COMMITS, like pressing Enter.
pub fn toggleVisual(self: *BrowserView) bool {
    const tab = self.currentTab() orelse return false;
    if (tab.sel.anchor != null) {
        commitVisual(self, tab);
        return true;
    }
    if (tab.view_mode == .icons) {
        self.setStatus("visual select mode needs a list view");
        return true;
    }
    if (colview.itemCount(tab) == 0) {
        self.setStatus("nothing to select here");
        return true;
    }
    for (tab.sel.saved.items) |p| self.allocator.free(p);
    tab.sel.saved.clearRetainingCapacity();
    for (tab.selected.items) |p| {
        const owned = self.allocator.dupe(u8, p) catch continue;
        tab.sel.saved.append(self.allocator, owned) catch self.allocator.free(owned);
    }
    const idx: c.guint = if (colview.focusedItem(tab)) |p| p.pos else 0;
    tab.sel.anchor = @intCast(idx);
    applyVisualRange(self, tab, idx);
    return true;
}

pub fn commitVisual(self: *BrowserView, tab: *BTab) void {
    if (tab.sel.anchor == null) return;
    tab.sel.anchor = null;
    for (tab.sel.saved.items) |p| self.allocator.free(p);
    tab.sel.saved.clearRetainingCapacity();
    self.setStatusFmt("selected {d} item(s)", .{tab.selected.items.len});
}

pub fn cancelVisual(self: *BrowserView, tab: *BTab) void {
    if (tab.sel.anchor == null) return;
    tab.sel.anchor = null;
    const want = c.gtk_bitset_new_empty() orelse return;
    defer c.gtk_bitset_unref(want);
    const n = colview.itemCount(tab);
    var idx: c.guint = 0;
    while (idx < n) : (idx += 1) {
        const d = colview.itemDataAt(tab, idx) orelse continue;
        if (d.kind != .entry) continue;
        for (tab.sel.saved.items) |p| {
            if (std.mem.eql(u8, p, d.path)) {
                _ = c.gtk_bitset_add(want, idx);
                break;
            }
        }
    }
    colview.setExactSelection(tab, want);
    for (tab.sel.saved.items) |p| self.allocator.free(p);
    tab.sel.saved.clearRetainingCapacity();
    self.setStatus("visual select cancelled");
}

/// The marking keys, plus the movement keys while visual mode is
/// active. Capture phase, because the list widget's own bindings
/// would otherwise consume them first (arrows collapse the selection
/// to the cursor row on the way; Ctrl+Space OPENS the focused file).
pub fn onSelectionKey(_: *c.GtkEventControllerKey, keyval: c_uint, _: c_uint, state: c.GdkModifierType, user: ?*anyopaque) callconv(.c) c.gboolean {
    const tab = cast.userData(BTab, user);
    // This runs in the CAPTURE phase, i.e. before an inline-rename
    // editor inside a row sees its own keys; while one is up, every
    // key belongs to it.
    if (tab.view.inline_rename != null) return 0;
    const mods = state & (c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK | c.GDK_ALT_MASK);
    if (tab.view.currentTab() == tab) {
        // GtkColumnView binds plain Space to selection toggling before
        // the browser's bubble controller can open Quick Look.
        if (mods == 0 and (keyval == c.GDK_KEY_space or keyval == c.GDK_KEY_KP_Space))
            return @intFromBool(@import("nav.zig").quickLookKey(tab.view));
        const mark = (mods == 0 and keyval == c.GDK_KEY_Insert) or
            (mods == c.GDK_CONTROL_MASK and (keyval == c.GDK_KEY_space or keyval == c.GDK_KEY_KP_Space));
        if (mark) return @intFromBool(toggleMarkFocused(tab.view));
        // Dolphin-style tree keys: Right expands the focused
        // directory, Left collapses it (or jumps to its parent row).
        if (mods == 0 and (keyval == c.GDK_KEY_Right or keyval == c.GDK_KEY_Left))
            return @intFromBool(treeArrowKey(tab, keyval == c.GDK_KEY_Right));
    }
    const anchor = tab.sel.anchor orelse return 0;
    if (mods != 0) return 0;
    const self = tab.view;
    const count = colview.itemCount(tab);
    if (count == 0) return 0;
    const last: c_int = @intCast(count - 1);
    const cur: c_int = if (colview.focusedItem(tab)) |p| @intCast(p.pos) else anchor;
    const next: c_int = switch (keyval) {
        c.GDK_KEY_Up => cur - 1,
        c.GDK_KEY_Down => cur + 1,
        c.GDK_KEY_Home => 0,
        c.GDK_KEY_End => last,
        c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => {
            commitVisual(self, tab);
            return 1;
        },
        c.GDK_KEY_Escape => {
            cancelVisual(self, tab);
            return 1;
        },
        else => return 0,
    };
    applyVisualRange(self, tab, @intCast(std.math.clamp(next, 0, last)));
    return 1;
}

/// Right/Left tree navigation on the focused row (details view,
/// Dolphin-style): Right expands a collapsed directory, Left
/// collapses an expanded one or moves focus to the parent row.
/// @return true when the key was consumed.
fn treeArrowKey(tab: *BTab, expand: bool) bool {
    if (tab.view_mode != .details or tab.root.flat) return false;
    const focused = colview.focusedItem(tab) orelse return false;
    const d = focused.data;
    if (d.kind != .entry) return false;
    const self = tab.view;
    const expanded = tab.subdirByPath(d.path) != null;
    // toggleExpand's collapse path re-renders and frees every item;
    // the path must not be read from `d` past that call.
    var buf: [4096]u8 = undefined;
    if (d.path.len >= buf.len) return false;
    @memcpy(buf[0..d.path.len], d.path);
    const path = buf[0..d.path.len];
    if (expand) {
        if (!d.is_dir or expanded) return false;
        self.toggleExpand(tab, path);
        return true;
    }
    if (d.is_dir and expanded) {
        self.toggleExpand(tab, path);
        return true;
    }
    // Collapsed (or a file): Left walks to the parent row, if that
    // parent is itself a row (the root directory has none).
    const parent = std.fs.path.dirname(path) orelse return false;
    if (std.mem.eql(u8, parent, tab.root.path)) return false;
    const pos = colview.positionForPath(tab, parent) orelse return false;
    colview.focusRow(tab, pos, true);
    return true;
}

/// Drop visual mode when the rows under it are about to go away
/// (navigation, tab close).
pub fn visualForget(self: *BrowserView, tab: *BTab) void {
    if (tab.sel.anchor == null) return;
    tab.sel.anchor = null;
    for (tab.sel.saved.items) |p| self.allocator.free(p);
    tab.sel.saved.clearRetainingCapacity();
}

// -- registers ---------------------------------------------------

/// The paths a register verb acts on: the whole selection when the
/// clicked entry is part of it (same rule as Copy), otherwise just
/// the clicked entry. `one` is the caller's scratch, because a slice
/// of a temporary array would not outlive this function.
fn markTargets(ctx: *MenuCtx, one: *[1][]u8) []const []u8 {
    const tab = ctx.tab;
    const p = ctx.path orelse return tab.selected.items;
    for (tab.selected.items) |sp| {
        if (std.mem.eql(u8, sp, p)) return tab.selected.items;
    }
    one[0] = p;
    return one[0..1];
}

/// Mark `paths` (all on `tab`'s host) into the named register. The
/// directory flag comes from the tab's own listing, which is why this
/// takes paths rather than register entries.
pub fn markPaths(self: *BrowserView, tab: *BTab, name: []const u8, paths: []const []u8) void {
    var added: usize = 0;
    var full = false;
    const store = regStore(self);
    for (paths) |p| {
        switch (store.add(name, .{
            .host = tab.hc.host orelse "",
            .path = p,
            .dir = if (entryForPath(tab, p)) |e| e.tdir else false,
        })) {
            .added => added += 1,
            .full => full = true,
            else => {},
        }
    }
    reportMarks(self, name, added, full);
}

/// Mark explicit (host, path, dir) records. A query results tab knows
/// its own row kinds -- its rows are not entries of any listed
/// directory, so entryForPath cannot answer for them.
pub fn markEntries(self: *BrowserView, name: []const u8, items: []const registers.Entry) void {
    var added: usize = 0;
    var full = false;
    const store = regStore(self);
    for (items) |item| {
        switch (store.add(name, item)) {
            .added => added += 1,
            .full => full = true,
            else => {},
        }
    }
    reportMarks(self, name, added, full);
}

/// Persist and report the outcome of a marking run.
fn reportMarks(self: *BrowserView, name: []const u8, added: usize, full: bool) void {
    const store = regStore(self);
    store.save();
    rememberName(self, name);
    if (full) {
        self.setStatusFmt("register {s} is full ({d} marks max)", .{ name, registers.MAX_ENTRIES });
    } else {
        self.setStatusFmt("marked {d} item(s) in register {s} ({d} total)", .{ added, name, store.sizeOf(name) });
    }
    if (self.places_on) self.renderPlaces();
    refreshRegisterTab(self, name);
}

pub fn onMenuRegisterAdd(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    var one: [1][]u8 = undefined;
    markPaths(ctx.view, ctx.tab, registers.COLLECTION, markTargets(ctx, &one));
    menuDone(ctx);
}

pub fn onMenuRegisterAddNamed(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    const self = ctx.view;
    menuDone(ctx);
    markDialog(self);
}

/// Unmark the clicked row from the register its tab is showing.
pub fn onMenuRegisterRemove(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    const self = ctx.view;
    const spec = ctx.path orelse return menuDone(ctx);
    const name = if (ctx.tab.virtual_spec.len > 0) ctx.tab.virtual_spec else registers.COLLECTION;
    var nbuf: [registers.MAX_NAME]u8 = undefined;
    if (name.len > nbuf.len) return menuDone(ctx);
    @memcpy(nbuf[0..name.len], name);
    const owned_name = nbuf[0..name.len];
    const entry = registers.entryFromSpec(spec, false);
    const store = regStore(self);
    if (store.remove(owned_name, entry.host, entry.path)) {
        store.save();
        self.setStatusFmt("unmarked: {s}", .{spec});
    }
    refreshRegisterTab(self, owned_name);
    if (self.places_on) self.renderPlaces();
    menuDone(ctx);
}

/// Open (or re-point) the one register tab at `name` and fill it with
/// the register's marks. Rows are host-qualified specs, exactly like
/// the collection shelf they replace, so every row verb behaves the
/// same.
pub fn registerTab(self: *BrowserView, name: []const u8) ?*BTab {
    const tab = self.register_tab orelse blk: {
        const cur = self.currentTab();
        const host = if (cur) |t| t.hc.host else null;
        var pbuf: [4096]u8 = undefined;
        var path: []const u8 = "/";
        if (cur) |t| {
            if (t.root.path.len < pbuf.len) {
                @memcpy(pbuf[0..t.root.path.len], t.root.path);
                path = pbuf[0..t.root.path.len];
            }
        }
        const t = self.newTab(host, path) orelse return null;
        // A register tab lists marks, not a directory: drop the
        // subscription newTab just opened.
        self.closeViewOf(t.hc, t.root);
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].tab == t) self.dropPending(i) else i += 1;
        }
        t.root.flat = true;
        t.root.collection = true;
        t.root.loaded = true;
        t.root.view_id = 0;
        self.register_tab = t;
        break :blk t;
    };
    if (tab.virtual_spec.len > 0) self.allocator.free(tab.virtual_spec);
    tab.virtual_spec = self.allocator.dupe(u8, name) catch &.{};
    fillRegisterTab(self, tab, name);
    const pn = c.gtk_notebook_page_num(self.notebook, tab.page);
    if (pn >= 0) c.gtk_notebook_set_current_page(self.notebook, pn);
    self.renderTab(tab);
    return tab;
}

fn fillRegisterTab(self: *BrowserView, tab: *BTab, name: []const u8) void {
    for (tab.root.entries.items) |*e| e.deinit(self.allocator);
    tab.root.entries.clearRetainingCapacity();
    var lbl: [96:0]u8 = undefined;
    const ltxt = std.fmt.bufPrintZ(&lbl, "reg: {s}", .{name}) catch "register";
    c.gtk_label_set_text(tab.tab_label, ltxt.ptr);
    const store = regStore(self);
    for (store.entriesOf(name)) |e| {
        var sbuf: [4400]u8 = undefined;
        const spec = formatSpec(&sbuf, if (e.host.len == 0) null else e.host, e.path);
        appendRegisterRow(self, tab, spec, e.dir);
    }
}

/// Re-fill the register tab when it happens to be showing `name`.
fn refreshRegisterTab(self: *BrowserView, name: []const u8) void {
    const tab = self.register_tab orelse return;
    if (!std.mem.eql(u8, tab.virtual_spec, name)) return;
    fillRegisterTab(self, tab, name);
    if (self.currentTab() == tab) self.renderTab(tab);
}

pub fn appendRegisterRow(self: *BrowserView, tab: *BTab, spec: []const u8, is_dir: bool) void {
    const a = self.allocator;
    if (tab.root.find(spec) != null) return;
    const name = a.dupe(u8, spec) catch return;
    const kind = a.dupe(u8, if (is_dir) "dir" else "file") catch {
        a.free(name);
        return;
    };
    const tgt = a.dupe(u8, spec) catch {
        a.free(name);
        a.free(kind);
        return;
    };
    tab.root.entries.append(a, .{
        .name = name,
        .kind = kind,
        .size = 0,
        .mode = 0,
        .mtime_ms = 0,
        .target = tgt,
        .tdir = false,
    }) catch {
        a.free(name);
        a.free(kind);
        a.free(tgt);
    };
}

/// Select every mark of `name` that lives in this listing. The
/// register is the source of truth; entries on other hosts or in
/// other directories are simply not here.
pub fn selectRegisterHere(self: *BrowserView, tab: *BTab, name: []const u8) void {
    const store = regStore(self);
    const host = tab.hc.host orelse "";
    var hit: usize = 0;
    if (tab.view_mode == .icons) {
        const fb = tab.flowbox orelse return;
        c.gtk_flow_box_unselect_all(fb);
        var i: c_int = 0;
        while (c.gtk_flow_box_get_child_at_index(fb, i)) |child| : (i += 1) {
            const data = c.g_object_get_data(@ptrCast(child), "sketerm-row") orelse continue;
            const ctx: *RowCtx = @ptrCast(@alignCast(data));
            if (!store.contains(name, host, ctx.path)) continue;
            c.gtk_flow_box_select_child(fb, child);
            hit += 1;
        }
    } else {
        const want = c.gtk_bitset_new_empty() orelse return;
        defer c.gtk_bitset_unref(want);
        const n = colview.itemCount(tab);
        var i: c.guint = 0;
        while (i < n) : (i += 1) {
            const d = colview.itemDataAt(tab, i) orelse continue;
            if (d.kind != .entry) continue;
            if (!store.contains(name, host, d.path)) continue;
            _ = c.gtk_bitset_add(want, i);
            hit += 1;
        }
        colview.setExactSelection(tab, want);
    }
    self.setStatusFmt("selected {d} of {d} mark(s) from register {s} here", .{
        hit, store.sizeOf(name), name,
    });
}

/// Copy every mark of `name` into this tab's directory. Entries are
/// grouped by host and each group goes through the normal paste path,
/// so a same-host group is a daemon copy job and a cross-host group
/// is a verified transfer -- a register spanning hosts is copied in
/// one gesture. Each group asks about its OWN name conflicts.
pub fn copyRegisterHere(self: *BrowserView, tab: *BTab, name: []const u8) void {
    const entries = regStore(self).entriesOf(name);
    if (entries.len == 0) {
        self.setStatusFmt("register {s} is empty", .{name});
        return;
    }
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var total: usize = 0;
    var waiting: usize = 0;
    for (entries, 0..) |group, gi| {
        var seen = false;
        for (entries[0..gi]) |earlier| {
            if (std.mem.eql(u8, earlier.host, group.host)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        const host: ?[]const u8 = if (group.host.len == 0) null else group.host;
        var srcs: std.ArrayList([]u8) = .empty;
        for (entries) |e| {
            if (!std.mem.eql(u8, e.host, group.host)) continue;
            const owned = a.dupe(u8, e.path) catch continue;
            srcs.append(a, owned) catch {};
        }
        if (srcs.items.len == 0) continue;
        // A register outlives its connections: the first copy after a
        // restart may name a host this view has not dialled yet, and
        // the transfer path refuses a source that is still connecting.
        // Skipping the group by NAME beats a silent no-op.
        const hc = self.hostConnFor(host);
        if (hc == null or hc.?.state != .ready) {
            waiting += srcs.items.len;
            continue;
        }
        total += srcs.items.len;
        self.beginPaste(tab, host, srcs.items, false, false);
    }
    if (waiting > 0) {
        self.setStatusFmt("copying {d} item(s); {d} skipped: their host is still connecting, run it again", .{ total, waiting });
    } else {
        self.setStatusFmt("copying {d} marked item(s) from register {s} here", .{ total, name });
    }
}

/// Permanently delete every mark of `name`, on whichever host it
/// lives, then forget the register (its entries no longer exist).
pub fn deleteRegister(self: *BrowserView, name: []const u8) void {
    const store = regStore(self);
    const entries = store.entriesOf(name);
    var sent: usize = 0;
    var waiting: usize = 0;
    for (entries) |e| {
        const hc = self.hostConnFor(if (e.host.len == 0) null else e.host) orelse {
            waiting += 1;
            continue;
        };
        if (hc.state != .ready) {
            waiting += 1;
            continue;
        }
        if (e.dir) {
            var lbl: [128]u8 = undefined;
            const label = std.fmt.bufPrint(&lbl, "delete {s}", .{std.fs.path.basename(e.path)}) catch "delete";
            self.startDaemonJob(hc, "delete_tree", e.path, "", label);
        } else {
            self.sendOp(hc, .{ .req = self.nextReq(), .op = "delete", .path = e.path });
        }
        sent += 1;
    }
    // The register is only forgotten once every mark was actually
    // dispatched; a host that was still connecting keeps its marks so
    // a second run finishes the job.
    if (waiting == 0) _ = store.drop(name);
    store.save();
    refreshRegisterTab(self, name);
    if (self.places_on) self.renderPlaces();
    if (waiting > 0) {
        self.setStatusFmt("deleting {d} item(s); {d} kept: their host is still connecting, run it again", .{ sent, waiting });
    } else {
        self.setStatusFmt("deleting {d} marked item(s); register {s} forgotten", .{ sent, name });
    }
}

// -- the selection menu ------------------------------------------

/// Add the selection button to the toolbar. Called once from attach,
/// so buildUi stays a plain widget tree.
pub fn installSelectionMenu(self: *BrowserView) void {
    // Into the collapsible cluster, right after the Places toggle
    // (the old hidden-files anchor moved into the hamburger menu).
    const bar = c.gtk_widget_get_parent(@ptrCast(@alignCast(self.places_toggle))) orelse return;
    const btn = c.gtk_button_new_from_icon_name("edit-select-all-symbolic");
    // Same treatment `toolbtn.flatten` gives every other toolbar
    // button; without it this one framed itself on hover while its
    // neighbours did not.
    toolbtn.flatten(btn.?);
    c.gtk_widget_set_tooltip_text(btn, "Selection: sticky clicks, visual range mode, persistent registers");
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onSelectionMenuClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_insert_child_after(@ptrCast(bar), btn, @ptrCast(@alignCast(self.places_toggle)));
}

pub fn onSelectionMenuClicked(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(BrowserView, user);
    const tab = self.currentTab() orelse return;
    const popover = c.gtk_popover_new();
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
    c.gtk_widget_set_margin_start(box, 10);
    c.gtk_widget_set_margin_end(box, 10);
    c.gtk_widget_set_margin_top(box, 10);
    c.gtk_widget_set_margin_bottom(box, 10);

    const sticky = c.gtk_check_button_new_with_label("Sticky selection (a click toggles)");
    c.gtk_widget_set_tooltip_text(sticky, "Build a set without holding Ctrl; a stray click cannot destroy it. Insert / Ctrl+Space do the same from the keyboard.");
    c.gtk_check_button_set_active(@ptrCast(sticky), @intFromBool(tab.sel.sticky));
    _ = c.g_signal_connect_data(sticky, "toggled", @ptrCast(&onStickyToggled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(box), sticky);

    menuButton(box, "Visual select mode  (Ctrl+Shift+X)", &onVisualMenu, @ptrCast(self), false);
    menuButton(box, "Mark selection in a register...  (Ctrl+M)", &onMarkMenu, @ptrCast(self), false);

    c.gtk_box_append(@ptrCast(box), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL));
    const store = regStore(self);
    var head_buf: [96:0]u8 = undefined;
    const head_txt: [*:0]const u8 = if (std.fmt.bufPrintZ(&head_buf, "Registers ({d} marks kept across restarts)", .{
        store.totalEntries(),
    })) |v| v.ptr else |_| "Registers";
    const head = c.gtk_label_new(head_txt);
    c.gtk_label_set_xalign(@ptrCast(head), 0);
    c.gtk_widget_add_css_class(head, "dim-label");
    c.gtk_box_append(@ptrCast(box), head);

    if (store.count() == 0) {
        const none = c.gtk_label_new("no marks yet");
        c.gtk_label_set_xalign(@ptrCast(none), 0);
        c.gtk_widget_add_css_class(none, "dim-label");
        c.gtk_box_append(@ptrCast(box), none);
    }
    var i: usize = 0;
    while (i < store.count()) : (i += 1) {
        const name = store.nameAt(i);
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        var rz: [128:0]u8 = undefined;
        const rtxt: [*:0]const u8 = if (std.fmt.bufPrintZ(&rz, "{s}  ({d})", .{ name, store.sizeOf(name) })) |v| v.ptr else |_| "register";
        const lab = c.gtk_label_new(rtxt);
        c.gtk_label_set_xalign(@ptrCast(lab), 0);
        c.gtk_widget_set_hexpand(lab, 1);
        c.gtk_box_append(@ptrCast(row), lab);
        regButton(self, row, "folder-open-symbolic", "Open this register as a tab", name, .open, false);
        regButton(self, row, "edit-select-all-symbolic", "Select this register's marks in the current listing", name, .select_here, false);
        regButton(self, row, "edit-copy-symbolic", "Copy every mark into the current folder", name, .copy_here, false);
        regButton(self, row, "list-remove-symbolic", "Forget this register (files untouched)", name, .forget, false);
        regButton(self, row, "user-trash-symbolic", "Delete every marked file permanently", name, .delete, true);
        c.gtk_box_append(@ptrCast(box), row);
    }

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
    c.gtk_popover_popup(@ptrCast(popover));
}

pub fn onStickyToggled(check: *c.GtkCheckButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(BrowserView, user);
    const tab = self.currentTab() orelse return;
    const want = c.gtk_check_button_get_active(check) != 0;
    if (want != tab.sel.sticky) toggleSticky(self, tab);
}

pub fn onVisualMenu(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    _ = toggleVisual(@ptrCast(@alignCast(user.?)));
}

pub fn onMarkMenu(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    markDialog(@ptrCast(@alignCast(user.?)));
}

/// Ask for a register name and mark the current selection into it.
pub fn markDialog(self: *BrowserView) void {
    const tab = self.currentTab() orelse return;
    if (tab.selected.items.len == 0) {
        self.setStatus("select something first, then mark it into a register");
        return;
    }
    openMarkDialog(self, .mark_named);
}

/// The same dialog, marking every ROW of a query results tab rather
/// than the selection: a search or panel result becomes a keepable
/// named set that outlives the tab and the GUI process.
pub fn markResultsDialog(self: *BrowserView) void {
    const tab = self.currentTab() orelse return;
    if (!tab.root.flat or tab.root.entries.items.len == 0) {
        self.setStatus("run a query first: this keeps its whole result set in a register");
        return;
    }
    openMarkDialog(self, .mark_results);
}

fn openMarkDialog(self: *BrowserView, action: @TypeOf(@as(RegCtx, undefined).action)) void {
    const popover = c.gtk_popover_new();
    const entry = c.gtk_entry_new();
    c.gtk_entry_set_placeholder_text(@ptrCast(entry), if (action == .mark_results)
        "register name (Enter keeps every result row)"
    else
        "register name (Enter marks the selection)");
    var z: [registers.MAX_NAME + 1:0]u8 = undefined;
    const def = defaultName(self);
    const n = @min(def.len, z.len - 1);
    @memcpy(z[0..n], def[0..n]);
    z[n] = 0;
    c.gtk_editable_set_text(@ptrCast(entry), &z);
    c.gtk_editable_select_region(@ptrCast(entry), 0, -1);
    const ctx = self.allocator.create(RegCtx) catch return;
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .name = self.allocator.dupe(u8, "") catch {
            self.allocator.destroy(ctx);
            return;
        },
        .action = action,
        .popover = popover,
        .entry = entry,
    };
    _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onMarkActivate), @ptrCast(ctx), @ptrCast(&RegCtx.free), c.G_CONNECT_DEFAULT);
    c.gtk_popover_set_child(@ptrCast(popover), entry);
    c.gtk_widget_set_parent(popover, @ptrCast(@alignCast(self.path_entry)));
    connectPopoverAutoUnparent(popover);
    c.gtk_popover_popup(@ptrCast(popover));
    _ = c.gtk_widget_grab_focus(entry);
}

pub fn onMarkActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RegCtx, user);
    const self = ctx.view;
    const raw = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(entry)))));
    const name = std.mem.trim(u8, raw, " ");
    const valid = registers.validName(name);
    var nbuf: [registers.MAX_NAME]u8 = undefined;
    if (valid) @memcpy(nbuf[0..name.len], name);
    if (ctx.popover) |pop| {
        if (c.gtk_widget_get_parent(pop) != null) c.gtk_widget_unparent(pop);
    }
    if (!valid) {
        self.setStatus("register names are 1-48 printable characters, no spaces");
        return;
    }
    const tab = self.currentTab() orelse return;
    if (ctx.action == .mark_results) markResults(self, tab, nbuf[0..name.len]) else markPaths(self, tab, nbuf[0..name.len], tab.selected.items);
}

/// Mark every row of a flat results tab. The rows carry their full
/// path in `target` and their kind in `tdir`, which is everything a
/// register entry needs -- no listing lookup is possible for them.
fn markResults(self: *BrowserView, tab: *BTab, name: []const u8) void {
    var items: std.ArrayList(registers.Entry) = .empty;
    defer items.deinit(self.allocator);
    const host = tab.hc.host orelse "";
    for (tab.root.entries.items) |e| {
        const target = e.target orelse continue;
        // A collection row's target is already a host-qualified spec;
        // a query row's is a plain path on the tab's own host.
        const item = if (tab.root.collection)
            registers.entryFromSpec(target, e.tdir)
        else
            registers.Entry{ .host = host, .path = target, .dir = e.tdir };
        items.append(self.allocator, item) catch break;
    }
    markEntries(self, name, items.items);
}

pub fn onRegAction(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RegCtx, user);
    const self = ctx.view;
    // The register menu popover dies with the button that owns this
    // ctx, so copy the name out BEFORE popping the menu down. And it
    // must be popped down first: its grab keeps any popover an action
    // opens (the delete confirmation) from ever mapping.
    var nbuf: [registers.MAX_NAME]u8 = undefined;
    if (ctx.name.len > nbuf.len) return;
    @memcpy(nbuf[0..ctx.name.len], ctx.name);
    const name = nbuf[0..ctx.name.len];
    const action = ctx.action;
    if (c.gtk_widget_get_ancestor(@ptrCast(btn), c.gtk_popover_get_type())) |menu|
        c.gtk_popover_popdown(@ptrCast(@alignCast(menu)));
    const tab = self.currentTab();
    switch (action) {
        .open => _ = registerTab(self, name),
        .select_here => if (tab) |t| selectRegisterHere(self, t, name),
        .copy_here => if (tab) |t| copyRegisterHere(self, t, name),
        .forget => {
            const store = regStore(self);
            if (store.drop(name)) {
                store.save();
                self.setStatusFmt("forgot register {s} (files untouched)", .{name});
            }
            refreshRegisterTab(self, name);
            if (self.places_on) self.renderPlaces();
        },
        .delete => {
            confirmDelete(self, name);
            return;
        },
        else => {},
    }
}

/// Confirm popover for the destructive register verb. Built on the
/// tab page, not inside the menu that triggered it: a popover
/// parented to a widget the menu is about to destroy dies with it.
fn confirmDelete(self: *BrowserView, name: []const u8) void {
    const tab = self.currentTab() orelse return;
    const store = regStore(self);
    const n = store.sizeOf(name);
    if (n == 0) return;
    const popover = c.gtk_popover_new();
    const ctx = self.allocator.create(RegCtx) catch return;
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .name = self.allocator.dupe(u8, name) catch {
            self.allocator.destroy(ctx);
            return;
        },
        .action = .delete,
        .popover = popover,
    };
    var lbl: [160:0]u8 = undefined;
    const txt: [*:0]const u8 = if (std.fmt.bufPrintZ(&lbl, "Permanently delete {d} marked item(s) of register {s}", .{ n, name })) |v| v.ptr else |_| "Delete marked items";
    const btn = c.gtk_button_new_with_label(txt);
    c.gtk_widget_add_css_class(btn, "destructive-action");
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onDeleteRegisterConfirmed), @ptrCast(ctx), @ptrCast(&RegCtx.free), c.G_CONNECT_DEFAULT);
    c.gtk_popover_set_child(@ptrCast(popover), btn);
    // Without an explicit rect the confirmation lands below the
    // window's bottom edge (the page has no natural anchor).
    const rect = c.GdkRectangle{
        .x = @divTrunc(c.gtk_widget_get_width(tab.page), 2),
        .y = @divTrunc(c.gtk_widget_get_height(tab.page), 3),
        .width = 1,
        .height = 1,
    };
    c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
    c.gtk_widget_set_parent(popover, tab.page);
    connectPopoverAutoUnparent(popover);
    c.gtk_popover_popup(@ptrCast(popover));
}

pub fn onDeleteRegisterConfirmed(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RegCtx, user);
    const self = ctx.view;
    var nbuf: [registers.MAX_NAME]u8 = undefined;
    if (ctx.name.len > nbuf.len) return;
    @memcpy(nbuf[0..ctx.name.len], ctx.name);
    const name = nbuf[0..ctx.name.len];
    if (ctx.popover) |pop| c.gtk_popover_popdown(@ptrCast(pop));
    deleteRegister(self, name);
}

// -- chord entry points (nav.zig's browser_chords table) ---------

pub fn chordVisual(self: *BrowserView) bool {
    return toggleVisual(self);
}

pub fn chordMark(self: *BrowserView) bool {
    markDialog(self);
    return true;
}
