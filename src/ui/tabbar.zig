//! Custom tab strip.
//!
//! Replaces AdwTabBar so we can draw a per-tab activity glow, while
//! keeping AdwTabView as the source of truth for the page list, content
//! switching, and the reorder/transfer APIs.
//!
//! Each tab is a REAL widget tree (GtkLabel + flat GtkButton) styled by
//! CSS with libadwaita's named colours, so it inherits the theme's font,
//! centring, hover and selected states natively. The rainbow activity
//! glow rides on top as a non-interactive GtkDrawingArea overlay.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const profile = @import("../util/profile.zig");
const Config = @import("../config.zig").Config;
const tab_effects = @import("tab_effects.zig");
const cssutil = @import("cssutil.zig");

const TAB_W: c_int = 170;

/// Whether a tab shows its close button: never on a pinned tab (the
/// pinned section is for tabs that should not close by accident), else
/// as `close_button_on_tab` says. Middle-click and the menus still close.
pub fn closeButtonShown(close_button_on_tab: bool, pinned: bool) bool {
    return close_button_on_tab and !pinned;
}

test "close buttons follow close_button_on_tab and never show on pinned tabs" {
    try std.testing.expect(closeButtonShown(true, false));
    try std.testing.expect(!closeButtonShown(true, true));
    try std.testing.expect(!closeButtonShown(false, false));
    try std.testing.expect(!closeButtonShown(false, true));
}

/// Fallback config so `TabBar.config` is always valid before the owning
/// Window points it at the real one (and in tests).
var default_config: Config = .{};

/// One page in flight. Public because the tree-style sidebar publishes
/// and consumes the SAME state: a tab dragged out of a sidebar row and
/// one dragged out of the strip are the same gesture to every drop
/// target, which is what gives the sidebar strip parity (cross-window
/// transfer, drag-out-to-new-window) instead of a second half-drag.
pub const Dragged = struct {
    view: *c.AdwTabView,
    page: *c.AdwTabPage,
    detach_ctx: ?*anyopaque,
    on_detach: ?*const fn (ctx: ?*anyopaque, view: *c.AdwTabView, page: *c.AdwTabPage) void,
};

/// Owns GObject refs rather than a heap `Tab`: structure notifications can
/// rebuild the strip while a GDK drag is still alive.
var dragged: ?Dragged = null;

fn releaseDragged(d: Dragged) void {
    c.g_object_unref(d.page);
    c.g_object_unref(d.view);
}

fn clearDragged() void {
    if (dragged) |d| releaseDragged(d);
    dragged = null;
}

/// Start carrying `page`; refs both objects for the drag's lifetime.
pub fn publishDrag(
    view: *c.AdwTabView,
    page: *c.AdwTabPage,
    detach_ctx: ?*anyopaque,
    on_detach: ?*const fn (ctx: ?*anyopaque, view: *c.AdwTabView, page: *c.AdwTabPage) void,
) void {
    clearDragged();
    _ = c.g_object_ref(view);
    _ = c.g_object_ref(page);
    dragged = .{ .view = view, .page = page, .detach_ctx = detach_ctx, .on_detach = on_detach };
}

pub fn currentDrag() ?Dragged {
    return dragged;
}

/// Take the drag over: the caller becomes responsible for `releaseDrag`.
pub fn takeDrag() ?Dragged {
    const d = dragged orelse return null;
    dragged = null;
    return d;
}

pub fn releaseDrag(d: Dragged) void {
    releaseDragged(d);
}

pub fn clearDrag() void {
    clearDragged();
}

/// Our own ref on the in-flight `gdk_drag_begin` result (GDK keeps a
/// separate one for the duration of the operation). Released by whichever
/// of ::cancel / ::dnd-finished runs; both can fire for a single drag, so
/// the release matches on identity and nulls the slot, making any later
/// callback a no-op instead of a second unref.
var gdk_drag: ?*c.GdkDrag = null;

fn clearGdkDrag() void {
    if (gdk_drag) |d| {
        gdk_drag = null;
        c.g_object_unref(d);
    }
}

fn releaseGdkDrag(drag: ?*anyopaque) void {
    const held = gdk_drag orelse return;
    if (@as(?*anyopaque, @ptrCast(held)) != drag) return;
    clearGdkDrag();
}

/// A GDK drag carrying a page ended without a drop target: hand the page
/// to the detach callback (drag-out spawns a window for it). Answers
/// whether the cancel was consumed.
pub fn dragCancelled(reason: c_int) bool {
    const d = dragged orelse return false;
    defer clearDragged();
    if (reason != c.GDK_DRAG_CANCEL_NO_TARGET) return false;
    if (d.on_detach) |f| f(d.detach_ctx, d.view, d.page);
    return true;
}

// ── custom widget types ──────────────────────────────────────────────
//
// libadwaita (and the user's GTK theme) style tabs by CSS NODE NAME
// (`tabbar tab`, `tab:checked`), not by style class — and a node name is
// fixed by the widget *type*, not settable with add_css_class. So we
// register trivial GtkBox subclasses whose css names are exactly
// "tabbar" and "tab". The Adwaita base stylesheet and any user theme
// then style our strip as real native tabs.
var tab_gtype: c.GType = 0;
var tabbar_gtype: c.GType = 0;
var tabbox_gtype: c.GType = 0;
var tabboxchild_gtype: c.GType = 0;
/// Saved GObject dispose for the tab widget, chained after unparenting.
var orig_tab_dispose: ?*const fn (object: [*c]c.GObject) callconv(.c) void = null;

fn tabClassInit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const wc: *c.GtkWidgetClass = @ptrCast(@alignCast(klass));
    c.gtk_widget_class_set_css_name(wc, "tab");
    // Draw children + activity glow ourselves (plain GtkWidget draws no
    // children by default).
    wc.snapshot = tabSnapshot;
    // Port AdwTab's custom layout: fixed natural width + icon/title centred
    // as a group with the close button overlapping the end.
    wc.measure = tabMeasure;
    wc.size_allocate = tabSizeAllocate;
    // A manually-parented GtkWidget must unparent its children on dispose.
    const oc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    orig_tab_dispose = oc.dispose;
    oc.dispose = tabDispose;
}

fn tabDispose(object: [*c]c.GObject) callconv(.c) void {
    var child = c.gtk_widget_get_first_child(@ptrCast(@alignCast(object)));
    while (child != null) {
        const next = c.gtk_widget_get_next_sibling(child);
        c.gtk_widget_unparent(child);
        child = next;
    }
    if (orig_tab_dispose) |f| f(object);
}

// ── AdwTab layout port (src/adw-tab.c measure/size_allocate) ──────────
const BASE_WIDTH: c_int = 118;
const BASE_WIDTH_PINNED: c_int = 26;

fn tabOf(widget: [*c]c.GtkWidget) ?*TabBar.Tab {
    const d = c.g_object_get_data(@ptrCast(@alignCast(widget)), "sketerm-tab") orelse return null;
    return @ptrCast(@alignCast(d));
}

fn measureChildV(child: *c.GtkWidget, for_size: c_int, min: *c_int, nat: *c_int) void {
    var cmin: c_int = 0;
    var cnat: c_int = 0;
    c.gtk_widget_measure(@ptrCast(child), c.GTK_ORIENTATION_VERTICAL, for_size, &cmin, &cnat, null, null);
    if (cmin > min.*) min.* = cmin;
    if (cnat > nat.*) nat.* = cnat;
}

fn measureChildWidth(child: *c.GtkWidget, height: c_int) c_int {
    var nat: c_int = 0;
    c.gtk_widget_measure(@ptrCast(child), c.GTK_ORIENTATION_HORIZONTAL, height, null, &nat, null, null);
    return nat;
}

fn allocateChild(child: *c.GtkWidget, x: c_int, w: c_int, height: c_int, baseline: c_int) void {
    var alloc: c.GtkAllocation = .{ .x = x, .y = 0, .width = w, .height = height };
    c.gtk_widget_size_allocate(@ptrCast(child), &alloc, baseline);
}

fn tabMeasure(widget: [*c]c.GtkWidget, orientation: c.GtkOrientation, for_size: c_int, minimum: [*c]c_int, natural: [*c]c_int, min_base: [*c]c_int, nat_base: [*c]c_int) callconv(.c) void {
    var min: c_int = 0;
    var nat: c_int = 0;
    const t = tabOf(widget);
    if (orientation == c.GTK_ORIENTATION_HORIZONTAL) {
        const pinned = if (t) |tt| c.adw_tab_page_get_pinned(tt.page) != 0 else false;
        nat = if (pinned) BASE_WIDTH_PINNED else BASE_WIDTH;
    } else if (t) |tt| {
        // Vertical: the max of every child (close button included, so the
        // tab keeps a consistent height even when it's hidden/pinned).
        measureChildV(tt.icon, for_size, &min, &nat);
        measureChildV(tt.label, for_size, &min, &nat);
        if (tt.close_btn) |cb| measureChildV(cb, for_size, &min, &nat);
    }
    if (minimum != null) minimum.* = min;
    if (natural != null) natural.* = nat;
    if (min_base != null) min_base.* = -1;
    if (nat_base != null) nat_base.* = -1;
}

fn tabSizeAllocate(widget: [*c]c.GtkWidget, width: c_int, height: c_int, baseline: c_int) callconv(.c) void {
    const t = tabOf(widget) orelse return;
    const icon_w = measureChildWidth(t.icon, height);
    const title_w = measureChildWidth(t.label, height);

    // No indicator button and title_inverted is false, so neither the
    // close button nor anything else reserves space: the close button is
    // placed at the end and the title may extend under it.
    if (t.close_btn) |cb| {
        if (c.gtk_widget_get_visible(@ptrCast(cb)) != 0) {
            const close_w = measureChildWidth(cb, height);
            allocateChild(cb, width - close_w, close_w, height, baseline);
        }
    }

    const group = centerGroup(width, icon_w + title_w);
    var center_x = group.x;
    var center_width = group.width;

    if (c.gtk_widget_get_visible(@ptrCast(t.icon)) != 0) {
        allocateChild(t.icon, center_x, icon_w, height, baseline);
        center_x += icon_w;
        center_width -= icon_w;
    }
    if (c.gtk_widget_get_visible(@ptrCast(t.label)) != 0) {
        if (center_width < 0) center_width = 0;
        allocateChild(t.label, center_x, center_width, height, baseline);
    }
}

const Span = struct { x: c_int, width: c_int };

/// Where the icon+title group of `content` px sits in a tab `width` px
/// wide: centred across the full width, never wider than it and never
/// spilling past the reserved edges (both zero-width here).
fn centerGroup(width: c_int, content: c_int) Span {
    const start_width: c_int = 0;
    const end_width: c_int = 0;
    var center_width = @min(width - start_width - end_width, content);
    if (center_width < 0) center_width = 0;
    const hi = width - center_width - end_width;
    var center_x = @divTrunc(width - center_width, 2);
    if (center_x < start_width) center_x = start_width;
    if (center_x > hi) center_x = hi;
    return .{ .x = center_x, .width = center_width };
}

/// Tab `snapshot`: draw the active effects BEHIND, then the tab's children
/// (icon, title, close) on top so the text/button stay legible.
fn tabSnapshot(widget: [*c]c.GtkWidget, snapshot: ?*c.GtkSnapshot) callconv(.c) void {
    drawEffects(widget, snapshot);
    var child = c.gtk_widget_get_first_child(widget);
    while (child != null) : (child = c.gtk_widget_get_next_sibling(child)) {
        c.gtk_widget_snapshot_child(widget, child, snapshot);
    }
}

/// Iterate the effect registry and draw each enabled, active effect for this
/// background tab (back-to-front). The selected tab is what you're looking
/// at, so it carries no effects.
fn drawEffects(widget: [*c]c.GtkWidget, snapshot: ?*c.GtkSnapshot) void {
    const tab = tabOf(widget) orelse return;
    if (c.adw_tab_view_get_selected_page(tab.bar.view) == @as(?*c.AdwTabPage, tab.page)) return;
    const cfg = tab.bar.config;
    const s = tab_effects.tabSettings(tab.page);
    for (tab_effects.registry) |effect| {
        if (!effect.enabled(s)) continue;
        const act = effect.eval(tab.page, cfg, s);
        if (act.intensity <= 0.01) continue;
        effect.draw(tab.page, @ptrCast(widget), snapshot, act);
    }
}

/// True if any enabled effect on this page is still animating, so the tick
/// loop should keep running.
fn tabAnimating(cfg: *const Config, page: *c.AdwTabPage) bool {
    const s = tab_effects.tabSettings(page);
    for (tab_effects.registry) |effect| {
        if (!effect.enabled(s)) continue;
        if (effect.eval(page, cfg, s).animating) return true;
    }
    return false;
}
fn tabbarClassInit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    c.gtk_widget_class_set_css_name(@ptrCast(@alignCast(klass)), "tabbar");
}
fn tabboxClassInit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const wc: *c.GtkWidgetClass = @ptrCast(@alignCast(klass));
    c.gtk_widget_class_set_css_name(wc, "tabbox");
    // Snapshot children ourselves so a reordered tab can carry a
    // horizontal offset *including* its CSS background/border — those are
    // drawn by the widget machinery around each child, not inside the
    // child's own snapshot vfunc, so only the parent can shift the whole
    // tab decoration.
    wc.snapshot = tabboxSnapshot;
}

/// Draw one tabbox child, optionally shifted by `dx` (px).
fn snapshotChildShifted(box: [*c]c.GtkWidget, child: [*c]c.GtkWidget, snapshot: ?*c.GtkSnapshot, dx: f64) void {
    if (@abs(dx) > 0.01) {
        c.gtk_snapshot_save(snapshot);
        var pt: c.graphene_point_t = undefined;
        _ = c.graphene_point_init(&pt, @floatCast(dx), 0);
        c.gtk_snapshot_translate(snapshot, &pt);
        c.gtk_widget_snapshot_child(box, child, snapshot);
        c.gtk_snapshot_restore(snapshot);
    } else {
        c.gtk_widget_snapshot_child(box, child, snapshot);
    }
}

fn tabboxSnapshot(widget: [*c]c.GtkWidget, snapshot: ?*c.GtkSnapshot) callconv(.c) void {
    // Each child carries the offset of its owning tab: a tab node via
    // "sketerm-tab", its leading separator via "sketerm-sep-tab" (so the
    // separator travels with the tab). Pass 1 draws everything at rest /
    // slid; the dragged tab and its separator are deferred to pass 2 so
    // they float above their neighbours.
    var deferred: [2]struct { ch: [*c]c.GtkWidget, dx: f64 } = undefined;
    var ndef: usize = 0;
    var child = c.gtk_widget_get_first_child(widget);
    while (child != null) : (child = c.gtk_widget_get_next_sibling(child)) {
        var dx: f64 = 0;
        var is_drag = false;
        if (c.g_object_get_data(@ptrCast(@alignCast(child)), "sketerm-tab")) |d| {
            const t: *TabBar.Tab = @ptrCast(@alignCast(d));
            dx = t.drag_dx + t.slide;
            is_drag = t.dragging;
        } else if (c.g_object_get_data(@ptrCast(@alignCast(child)), "sketerm-sep-tab")) |d| {
            const t: *TabBar.Tab = @ptrCast(@alignCast(d));
            dx = t.drag_dx + t.slide;
            is_drag = t.dragging;
        }
        if (is_drag and ndef < deferred.len) {
            deferred[ndef] = .{ .ch = child, .dx = dx };
            ndef += 1;
            continue;
        }
        snapshotChildShifted(widget, child, snapshot, dx);
    }
    for (deferred[0..ndef]) |d| snapshotChildShifted(widget, d.ch, snapshot, d.dx);
}
fn tabboxchildClassInit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    c.gtk_widget_class_set_css_name(@ptrCast(@alignCast(klass)), "tabboxchild");
}
fn registerTypes() void {
    if (tab_gtype != 0) return;
    // The tab is a plain GtkWidget (NOT a GtkBox) so it has no layout
    // manager — that lets our measure/size_allocate vfuncs run, which is
    // how we port AdwTab's custom layout. A GtkBox would route layout
    // through GtkBoxLayout and ignore the vfuncs.
    tab_gtype = c.g_type_register_static_simple(c.gtk_widget_get_type(), "SketermTab", @sizeOf(c.GtkWidgetClass), tabClassInit, @sizeOf(c.GtkWidget), null, c.G_TYPE_FLAG_NONE);
    tabbar_gtype = c.g_type_register_static_simple(c.gtk_box_get_type(), "SketermTabbar", @sizeOf(c.GtkBoxClass), tabbarClassInit, @sizeOf(c.GtkBox), null, c.G_TYPE_FLAG_NONE);
    tabbox_gtype = c.g_type_register_static_simple(c.gtk_box_get_type(), "SketermTabbox", @sizeOf(c.GtkBoxClass), tabboxClassInit, @sizeOf(c.GtkBox), null, c.G_TYPE_FLAG_NONE);
    tabboxchild_gtype = c.g_type_register_static_simple(c.gtk_box_get_type(), "SketermTabboxchild", @sizeOf(c.GtkBoxClass), tabboxchildClassInit, @sizeOf(c.GtkBox), null, c.G_TYPE_FLAG_NONE);
}

/// A new horizontal box with the given custom css node name. (GtkBox
/// defaults to horizontal orientation.)
fn newNode(gtype: c.GType) *c.GtkWidget {
    return @ptrCast(@alignCast(c.g_object_new(gtype, @as([*c]const u8, null))));
}

pub const TabBar = struct {
    allocator: std.mem.Allocator,
    view: *c.AdwTabView,
    /// Root widget added to the toolbar (a horizontal scroller).
    root: *c.GtkWidget,
    /// The hbox holding one tab per page.
    box: *c.GtkWidget,
    tabs: std.ArrayList(*Tab) = .empty,
    tick_id: c.guint = 0,
    reorder_gesture: ?*c.GtkGesture = null,
    drop_target: ?*c.GtkDropTarget = null,
    /// Set by `sever` before any source or widget callback can outlive the
    /// owning Window. Public entry points become no-ops once set.
    callbacks_severed: bool = false,
    /// Smoke-only assertions that both raw-pointer timeout classes and all
    /// signal closures were live, then removed, at the teardown choke point.
    verify_teardown: bool = false,
    /// Signals carrying this controller as user-data, counted where they
    /// are connected. `sever` checks its disconnect count against this
    /// instead of a literal, so an added OR removed signal is detected.
    signals: c.guint = 0,
    detach_ctx: ?*anyopaque = null,
    on_detach: ?*const fn (ctx: ?*anyopaque, view: *c.AdwTabView, page: *c.AdwTabPage) void = null,
    transfer_ctx: ?*anyopaque = null,
    on_transfer: ?*const fn (
        ctx: ?*anyopaque,
        source: *c.AdwTabView,
        page: *c.AdwTabPage,
        position: c_int,
    ) bool = null,
    reorder: ?Reorder = null,
    /// Config read by the tab effects (which gates fire, thresholds). Points
    /// at the owning Window's `config` once wired; a static default keeps it
    /// valid before that and in tests.
    config: *const Config = &default_config,
    /// One-shot timer that re-wakes the tick when a silent tab crosses the
    /// inactive-warning threshold (see `armWarn`).
    warn_arm_id: c.guint = 0,
    /// Right-click-a-tab context menu, built by the owning Window. `anchor`
    /// is the clicked tab widget and `x`/`y` are click coords within it.
    context_ctx: ?*anyopaque = null,
    on_context: ?*const fn (ctx: ?*anyopaque, page: *c.AdwTabPage, anchor: *c.GtkWidget, x: f64, y: f64) void = null,
    /// Tree-style tabs: pages inside a collapsed subtree are hidden
    /// from the strip. The owning Window supplies the predicate; the
    /// strip stays tree-agnostic. Applied in `rebuild` and on demand
    /// via `refreshHidden`.
    hidden_ctx: ?*anyopaque = null,
    is_hidden: ?*const fn (ctx: ?*anyopaque, page: *c.AdwTabPage) bool = null,

    pub const Tab = struct {
        bar: *TabBar,
        page: *c.AdwTabPage,
        /// `tabboxchild` node appended to the `tabbox` (what the strip
        /// adds/removes); wraps the `tab` node.
        child: *c.GtkWidget,
        /// `separator` placed before this tab (none for the first), like
        /// AdwTabBox. Hidden when adjacent to the selected tab.
        sep_before: ?*c.GtkWidget = null,
        /// The `tab` CSS node; draws its own glow in `tabSnapshot`.
        tab_box: *c.GtkWidget,
        label: *c.GtkWidget,
        icon: *c.GtkWidget,
        /// Always present (so it sets the tab height like AdwTab); hidden
        /// on pinned tabs.
        close_btn: ?*c.GtkWidget = null,
        middle_click: ?*c.GtkGesture = null,
        right_click: ?*c.GtkGesture = null,
        title_handler: c.gulong = 0,
        icon_handler: c.gulong = 0,
        /// Signals carrying this Tab as user-data, counted where they are
        /// connected; `clearTabs` checks its disconnect count against it.
        signals: c.guint = 0,
        /// Visual horizontal shift (px) used during a reorder: the
        /// dragged tab carries `drag_dx` (glued to the cursor); its
        /// neighbours carry an animated `slide` that eases toward
        /// `slide_target` to open a gap. Applied in `tabSnapshot`.
        drag_dx: f64 = 0,
        slide: f64 = 0,
        slide_target: f64 = 0,
        /// True while this is the tab under the cursor, so the tabbox
        /// snapshots it last (on top of its neighbours).
        dragging: bool = false,
    };

    /// Live in-bar reorder state, mirroring AdwTabBox: one pressed tab
    /// followed by the cursor while neighbours slide aside; committed to
    /// AdwTabView only on release.
    const Reorder = struct {
        tab: *Tab,
        /// Index of the pressed tab in `tabs` at press time.
        start_index: usize,
        /// Index the tab will land on at release (midpoint-based).
        index: usize,
        /// Cursor x within the pressed tab at press (box coords).
        offset_x: f64,
        /// Width of one tab slot incl. the separator gap.
        advance: f64,
        /// True once the drag threshold is crossed.
        active: bool = false,
    };

    pub fn create(allocator: std.mem.Allocator, view: *c.AdwTabView) !*TabBar {
        const self = try allocator.create(TabBar);
        errdefer allocator.destroy(self);

        registerTypes();

        // Mirror AdwTabBar's node tree exactly so libadwaita's stylesheet
        // (and the user's overrides) style us identically:
        //   tabbar > .box(scroller) > tabbox > tabboxchild > tab
        const box = newNode(tabbox_gtype); // css "tabbox"
        const scroller = c.gtk_scrolled_window_new() orelse return error.GtkFail;
        c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_EXTERNAL, c.GTK_POLICY_NEVER);
        c.gtk_scrolled_window_set_child(@ptrCast(scroller), box);
        c.gtk_widget_add_css_class(scroller, "box");
        c.gtk_widget_set_hexpand(scroller, 1);

        const tabbar = newNode(tabbar_gtype); // css "tabbar"
        c.gtk_box_append(@ptrCast(tabbar), scroller);

        installCss(tabbar);

        self.* = .{
            .allocator = allocator,
            .view = view,
            .root = tabbar,
            .box = @ptrCast(box),
            .verify_teardown = c.getenv("SKETERM_VERIFY_TABBAR_TEARDOWN") != null,
        };

        // In-bar visual reorder (AdwTabBox-style): one drag gesture on the
        // strip follows the pressed tab and slides neighbours aside; a
        // real GDK drag only begins once the cursor is pulled out of the
        // bar (cross-window transfer / drag-out to a new window).
        const reorder = c.gtk_gesture_drag_new();
        c.gtk_gesture_single_set_button(@ptrCast(reorder), c.GDK_BUTTON_PRIMARY);
        // Capture phase so we claim the press before the header-bar's
        // window-drag gesture (otherwise dragging a tab moves the window).
        c.gtk_event_controller_set_propagation_phase(@ptrCast(@alignCast(reorder)), c.GTK_PHASE_CAPTURE);
        self.connectSelf(reorder, "drag-begin", @ptrCast(&onReorderBegin));
        self.connectSelf(reorder, "drag-update", @ptrCast(&onReorderUpdate));
        self.connectSelf(reorder, "drag-end", @ptrCast(&onReorderEnd));
        c.gtk_widget_add_controller(box, @ptrCast(@alignCast(reorder)));
        self.reorder_gesture = reorder;

        // Accept GDK drags pulled in from another window's strip (the
        // cross-window transfer half of the hybrid; in-bar reorder never
        // uses content-DnD).
        const drop = c.gtk_drop_target_new(c.G_TYPE_INT, c.GDK_ACTION_MOVE);
        self.connectSelf(drop, "drop", @ptrCast(&onDrop));
        c.gtk_widget_add_controller(box, @ptrCast(@alignCast(drop)));
        self.drop_target = drop;

        self.connectSelf(view, "page-attached", @ptrCast(&onStructure));
        self.connectSelf(view, "page-detached", @ptrCast(&onStructure));
        self.connectSelf(view, "page-reordered", @ptrCast(&onStructure));
        self.connectSelf(view, "notify::selected-page", @ptrCast(&onSelection));

        self.rebuild();
        return self;
    }

    pub fn ensureTick(self: *TabBar) void {
        if (self.callbacks_severed or self.tick_id != 0) return;
        self.tick_id = c.g_timeout_add(33, @ptrCast(&onTick), self);
    }

    /// The inactive-warning fires on *silence*, with no event to wake the
    /// 33ms tick (which sleeps once the aurora has faded). A single timer
    /// re-runs the tick when silence is reached — but it must target the
    /// SOONEST deadline across ALL warn-enabled tabs, not just the one that
    /// last changed. The old code armed a flat threshold from `page` and
    /// clobbered the shared timer every call, so with two+ warn tabs one
    /// tab's wake-up cancelled another's and that tab never lit up. `page` is
    /// only a hint that something changed; we recompute globally.
    pub fn armWarn(self: *TabBar, page: *c.AdwTabPage) void {
        _ = page;
        self.rescheduleWarn();
    }

    /// Point the single silence wake-up at the nearest future inactive-warning
    /// deadline among all warn-enabled tabs. Tabs already past their threshold
    /// are excluded — the tick is animating those (warnEval keeps it awake);
    /// they need no wake-up.
    fn rescheduleWarn(self: *TabBar) void {
        if (self.callbacks_severed) return;
        if (self.warn_arm_id != 0) {
            _ = c.g_source_remove(self.warn_arm_id);
            self.warn_arm_id = 0;
        }
        const now = c.g_get_monotonic_time();
        const threshold_us: i64 = @as(i64, self.config.inactive_warn_secs) * 1_000_000;
        var soonest: ?i64 = null;
        for (self.tabs.items) |t| {
            if (!tab_effects.tabSettings(t.page).warn_inactive) continue;
            const deadline = tab_effects.warnDeadline(t.page, threshold_us) orelse continue;
            soonest = soonerDeadline(soonest, deadline, now);
        }
        const d = soonest orelse {
            // Keep the one-shot source genuinely live until teardown in the
            // focused smokes, even after a warning crossed its deadline.
            if (self.verify_teardown)
                self.warn_arm_id = c.g_timeout_add(3_600_000, @ptrCast(&onWarnArm), self);
            return;
        };
        self.warn_arm_id = c.g_timeout_add(wakeDelayMs(d, now), @ptrCast(&onWarnArm), self);
    }

    /// Mark the selected tab's `:selected` state (what libadwaita's
    /// `tabbar tab:selected` rule styles) and repaint glows.
    pub fn refresh(self: *TabBar) void {
        if (self.callbacks_severed) return;
        const sel = c.adw_tab_view_get_selected_page(self.view);
        var sel_idx: ?usize = null;
        for (self.tabs.items, 0..) |t, idx| {
            if (sel == @as(?*c.AdwTabPage, t.page)) sel_idx = idx;
        }
        for (self.tabs.items, 0..) |t, idx| {
            if (if (sel_idx) |s| s == idx else false) {
                c.gtk_widget_set_state_flags(t.tab_box, c.GTK_STATE_FLAG_SELECTED, 0);
            } else {
                c.gtk_widget_unset_state_flags(t.tab_box, c.GTK_STATE_FLAG_SELECTED);
            }
            if (t.sep_before) |s| {
                if (separatorHidden(idx, sel_idx)) {
                    c.gtk_widget_add_css_class(s, "hidden");
                } else {
                    c.gtk_widget_remove_css_class(s, "hidden");
                }
            }
            c.gtk_widget_queue_draw(t.tab_box);
        }
    }

    fn clearTabs(self: *TabBar) void {
        // Structure signals can rebuild during an in-bar reorder. Do not
        // retain a pointer to a Tab that this loop is about to free.
        self.reorder = null;
        for (self.tabs.items) |t| {
            var disconnected = c.g_signal_handlers_disconnect_matched(
                @as(c.gpointer, @ptrCast(t.page)),
                c.G_SIGNAL_MATCH_DATA,
                0,
                0,
                null,
                null,
                @as(c.gpointer, @ptrCast(t)),
            );
            if (t.close_btn) |close| {
                disconnected += c.g_signal_handlers_disconnect_matched(
                    @as(c.gpointer, @ptrCast(close)),
                    c.G_SIGNAL_MATCH_DATA,
                    0,
                    0,
                    null,
                    null,
                    @as(c.gpointer, @ptrCast(t)),
                );
            }
            if (t.middle_click) |click| {
                disconnected += c.g_signal_handlers_disconnect_matched(
                    @as(c.gpointer, @ptrCast(click)),
                    c.G_SIGNAL_MATCH_DATA,
                    0,
                    0,
                    null,
                    null,
                    @as(c.gpointer, @ptrCast(t)),
                );
            }
            if (t.right_click) |click| {
                disconnected += c.g_signal_handlers_disconnect_matched(
                    @as(c.gpointer, @ptrCast(click)),
                    c.G_SIGNAL_MATCH_DATA,
                    0,
                    0,
                    null,
                    null,
                    @as(c.gpointer, @ptrCast(t)),
                );
            }
            t.title_handler = 0;
            t.icon_handler = 0;
            c.g_object_set_data(@ptrCast(@alignCast(t.tab_box)), "sketerm-tab", null);
            c.g_object_set_data(@ptrCast(@alignCast(t.child)), "sketerm-tab", null);
            if (t.sep_before) |s|
                c.g_object_set_data(@ptrCast(@alignCast(s)), "sketerm-sep-tab", null);
            if (self.verify_teardown and disconnected != t.signals) {
                std.debug.print(
                    "sketerm: TabBar tab sever mismatch (signals={d}, connected={d})\n",
                    .{ disconnected, t.signals },
                );
                c.abort();
            }
            if (t.sep_before) |s| c.gtk_box_remove(@ptrCast(self.box), s);
            c.gtk_box_remove(@ptrCast(self.box), t.child);
            self.allocator.destroy(t);
        }
        self.tabs.clearRetainingCapacity();
    }

    pub fn rebuild(self: *TabBar) void {
        if (self.callbacks_severed) return;
        self.clearTabs();
        const n = c.adw_tab_view_get_n_pages(self.view);
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const page = c.adw_tab_view_get_nth_page(self.view, i) orelse continue;
            const t = self.allocator.create(Tab) catch continue;
            self.buildTab(t, page);
            // `separator` between tabs (AdwTabBox does the same).
            if (self.tabs.items.len > 0) {
                const sep = c.gtk_separator_new(c.GTK_ORIENTATION_VERTICAL);
                c.gtk_box_append(@ptrCast(self.box), sep);
                t.sep_before = @ptrCast(sep);
                // The leading separator belongs to this tab and travels
                // with it during a reorder (tabboxSnapshot reads this).
                c.g_object_set_data(@ptrCast(@alignCast(sep)), "sketerm-sep-tab", t);
            }
            c.gtk_box_append(@ptrCast(self.box), t.child);
            self.tabs.append(self.allocator, t) catch {
                self.allocator.destroy(t);
                continue;
            };
        }
        self.refreshHidden();
        self.refresh();
        if (self.verify_teardown) {
            // Exercise real effect state and a silence deadline while the
            // source assertions keep both raw-pointer callbacks pending.
            for (self.tabs.items) |t| {
                var settings = tab_effects.tabSettings(t.page);
                settings.show_activity = true;
                settings.warn_inactive = true;
                tab_effects.setTabSettings(t.page, settings);
                tab_effects.recordActivity(t.page);
            }
            self.ensureTick();
            self.rescheduleWarn();
        }
    }

    /// Re-apply `close_button_on_tab` to every tab after a config
    /// change; hiding keeps each button's height in the measure.
    pub fn refreshCloseButtons(self: *TabBar) void {
        if (self.callbacks_severed) return;
        for (self.tabs.items) |t| {
            const close = t.close_btn orelse continue;
            const pinned = c.adw_tab_page_get_pinned(t.page) != 0;
            c.gtk_widget_set_visible(close, @intFromBool(closeButtonShown(self.config.close_button_on_tab, pinned)));
        }
    }

    /// Apply the tree-collapse hidden state to the strip: a hidden
    /// tab's widget (and its leading separator) goes invisible. Cheap
    /// enough to run after any collapse/expand without a rebuild.
    pub fn refreshHidden(self: *TabBar) void {
        if (self.callbacks_severed) return;
        const f = self.is_hidden orelse return;
        for (self.tabs.items) |t| {
            const hid = f(self.hidden_ctx, t.page);
            c.gtk_widget_set_visible(t.child, @intFromBool(!hid));
            if (t.sep_before) |s| c.gtk_widget_set_visible(s, @intFromBool(!hid));
        }
    }

    fn buildTab(self: *TabBar, t: *Tab, page: *c.AdwTabPage) void {
        const pinned = c.adw_tab_page_get_pinned(page) != 0;

        // `tabboxchild` wraps the `tab` (libadwaita puts the border-radius
        // and focus outline on the child). Both expand so tabs share the
        // bar like the native AdwTabBar.
        const child = newNode(tabboxchild_gtype);
        c.gtk_widget_set_hexpand(child, @intFromBool(!pinned));

        // Real `tab` node (so the theme styles it). It is a custom widget:
        // its children (icon, title, close) are positioned by the ported
        // AdwTab layout in tabSizeAllocate, not by a box/overlay.
        const tab_box = newNode(tab_gtype);
        c.gtk_widget_set_hexpand(tab_box, @intFromBool(!pinned));
        c.gtk_box_append(@ptrCast(child), tab_box);

        // Colour swatch (page icon) — margins per adw-tab.ui.
        const icon = c.gtk_image_new_from_gicon(c.adw_tab_page_get_icon(page));
        c.gtk_widget_set_margin_start(icon, 4);
        c.gtk_widget_set_margin_end(icon, 2);
        c.gtk_widget_set_valign(icon, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_visible(icon, @intFromBool(c.adw_tab_page_get_icon(page) != null));
        // Decorative: never a pointer target, so a drag begun on it falls
        // through to the strip's drag gesture.
        c.gtk_widget_set_can_target(icon, 0);
        c.gtk_widget_set_parent(icon, tab_box);

        // Title — margins per adw-tab.ui; the layout centres it.
        const label = c.gtk_label_new(c.adw_tab_page_get_title(page));
        c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
        c.gtk_label_set_xalign(@ptrCast(label), 0.5);
        c.gtk_widget_set_margin_start(label, 4);
        c.gtk_widget_set_margin_end(label, 4);
        c.gtk_widget_set_valign(label, c.GTK_ALIGN_CENTER);
        c.gtk_widget_add_css_class(label, "tab-title");
        c.gtk_widget_set_can_target(label, 0);
        c.gtk_widget_set_parent(label, tab_box);

        // Close — flat button, revealed on hover (CSS). Always created so
        // it sets the tab height (AdwTab measures it unconditionally);
        // hidden per `closeButtonShown`.
        const close = c.gtk_button_new_from_icon_name("window-close-symbolic");
        c.gtk_button_set_has_frame(@ptrCast(close), 0);
        c.gtk_widget_add_css_class(close, "flat");
        c.gtk_widget_add_css_class(close, "tab-close-button");
        c.gtk_widget_set_valign(close, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_visible(close, @intFromBool(closeButtonShown(self.config.close_button_on_tab, pinned)));
        c.gtk_widget_set_parent(close, tab_box);

        t.* = .{
            .bar = self,
            .page = page,
            .child = @ptrCast(child),
            .tab_box = @ptrCast(tab_box),
            .label = @ptrCast(label),
            .icon = @ptrCast(icon),
            .close_btn = @ptrCast(close),
        };
        // The tab node finds its Tab here to draw the glow; the child
        // node carries the same pointer so tabboxSnapshot can read the
        // reorder offset.
        c.g_object_set_data(@ptrCast(@alignCast(tab_box)), "sketerm-tab", t);
        c.g_object_set_data(@ptrCast(@alignCast(child)), "sketerm-tab", t);

        // Middle-click closes. Left-press selection and dragging are owned
        // by the strip's drag gesture (a claiming left-click gesture here
        // would deny it) — see onReorderBegin.
        const click = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(click), 2);
        connectTab(t, click, "pressed", @ptrCast(&onPressed));
        c.gtk_widget_add_controller(tab_box, @ptrCast(@alignCast(click)));
        t.middle_click = click;

        // Right-click → tab context menu (rename, effect toggles, …). Owned
        // by the Window via the `on_context` hook.
        const rclick = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(rclick), 3);
        connectTab(t, rclick, "pressed", @ptrCast(&onRightPressed));
        c.gtk_widget_add_controller(tab_box, @ptrCast(@alignCast(rclick)));
        t.right_click = rclick;

        connectTab(t, close, "clicked", @ptrCast(&onClose));
        t.title_handler = c.g_signal_connect_data(@ptrCast(page), "notify::title", @ptrCast(&onTitle), t, null, c.G_CONNECT_DEFAULT);
        t.signals += 1;
        t.icon_handler = c.g_signal_connect_data(@ptrCast(page), "notify::icon", @ptrCast(&onIcon), t, null, c.G_CONNECT_DEFAULT);
        t.signals += 1;
    }

    /// Connect one signal carrying this controller as user-data and
    /// record it, so `sever`'s expected count comes from the connect
    /// sites rather than a hand-maintained literal.
    fn connectSelf(self: *TabBar, obj: anytype, name: [*:0]const u8, cb: c.GCallback) void {
        _ = c.g_signal_connect_data(obj, name, cb, self, null, c.G_CONNECT_DEFAULT);
        self.signals += 1;
    }

    /// Same for a per-tab signal; `clearTabs` checks against `t.signals`.
    fn connectTab(t: *Tab, obj: anytype, name: [*:0]const u8, cb: c.GCallback) void {
        _ = c.g_signal_connect_data(obj, name, cb, t, null, c.G_CONNECT_DEFAULT);
        t.signals += 1;
    }

    /// Fence every callback carrying this controller or one of its Tab records while widgets are valid.
    /// Append a widget after the tab scroller, at the END of the strip
    /// (the scroller expands, so it sits flush right). The strip stays
    /// agnostic about what it is; the caller owns its lifetime rules.
    pub fn appendEnd(self: *TabBar, widget: *c.GtkWidget) void {
        c.gtk_box_append(@ptrCast(self.root), widget);
    }

    pub fn sever(self: *TabBar) void {
        if (self.callbacks_severed) return;
        self.callbacks_severed = true;

        const sources_live = self.tick_id != 0 and self.warn_arm_id != 0;
        if (self.tick_id != 0) {
            _ = c.g_source_remove(self.tick_id);
            self.tick_id = 0;
        }
        if (self.warn_arm_id != 0) {
            _ = c.g_source_remove(self.warn_arm_id);
            self.warn_arm_id = 0;
        }
        if (dragged) |d| {
            if (d.view == self.view) clearDragged();
        }

        var disconnected: c.guint = c.g_signal_handlers_disconnect_matched(
            @as(c.gpointer, @ptrCast(self.view)),
            c.G_SIGNAL_MATCH_DATA,
            0,
            0,
            null,
            null,
            @as(c.gpointer, @ptrCast(self)),
        );
        if (self.reorder_gesture) |gesture| {
            disconnected += c.g_signal_handlers_disconnect_matched(
                @as(c.gpointer, @ptrCast(gesture)),
                c.G_SIGNAL_MATCH_DATA,
                0,
                0,
                null,
                null,
                @as(c.gpointer, @ptrCast(self)),
            );
            self.reorder_gesture = null;
        }
        if (self.drop_target) |target| {
            disconnected += c.g_signal_handlers_disconnect_matched(
                @as(c.gpointer, @ptrCast(target)),
                c.G_SIGNAL_MATCH_DATA,
                0,
                0,
                null,
                null,
                @as(c.gpointer, @ptrCast(self)),
            );
            self.drop_target = null;
        }

        self.detach_ctx = null;
        self.on_detach = null;
        self.transfer_ctx = null;
        self.on_transfer = null;
        self.context_ctx = null;
        self.on_context = null;
        self.hidden_ctx = null;
        self.is_hidden = null;
        self.config = &default_config;
        self.clearTabs();
        self.tabs.deinit(self.allocator);

        if (self.verify_teardown and (!sources_live or disconnected != self.signals)) {
            std.debug.print(
                "sketerm: TabBar sever mismatch (sources={}, signals={d}, connected={d})\n",
                .{ sources_live, disconnected, self.signals },
            );
            c.abort();
        }
    }

    pub fn deinit(self: *TabBar) void {
        if (self.verify_teardown and !self.callbacks_severed) {
            std.debug.print("sketerm: TabBar deinit reached before pre-widget sever\n", .{});
            c.abort();
        }
        self.sever();
        self.allocator.destroy(self);
    }
};

/// The tabs are now real `tabbar`/`tab` CSS nodes, so Adwaita's base
/// stylesheet AND the user's theme style them natively — we add nothing
/// of our own except the native-style close-button reveal-on-hover
/// (which AdwTab does in C, not CSS).
fn installCss(any_widget: *c.GtkWidget) void {
    const css =
        \\tab .tab-close-button {
        \\  opacity: 0;
        \\  transition: opacity 150ms ease-in-out;
        \\}
        \\tab:hover .tab-close-button, tab:selected .tab-close-button { opacity: 1; }
        \\/* Lifted tab during a reorder: opaque so it hides tabs underneath
        \\   (libadwaita's `dnd tab` representation). */
        \\tab.dragging {
        \\  background-color: var(--headerbar-bg-color, @headerbar_bg_color);
        \\  background-image: image(color-mix(in srgb, currentColor 19%, transparent));
        \\  color: var(--headerbar-fg-color, @headerbar_fg_color);
        \\  box-shadow: 0 0 0 1px rgba(0,0,0,0.06), 0 1px 3px 1px rgba(0,0,0,0.12), 0 2px 6px 2px rgba(0,0,0,0.08);
        \\}
    ;
    cssutil.install("tabbar", any_widget, css);
}

var theme_loaded = false;

/// Load a GTK theme's `gtk-4.0/gtk.css` over libadwaita's stylesheet so
/// the user's styling (e.g. `tabbar tab`, which now matches our real
/// `tab` nodes) applies. `configured` is the sketerm `gtk_theme` config
/// value; empty falls back to the GTK_THEME env var. No-op if neither
/// names a theme or the file isn't found. Loaded once per process.
pub fn loadTheme(self: *TabBar, configured: []const u8) void {
    if (theme_loaded) return;
    const name = themeName(configured, profile.getenv("GTK_THEME"));
    if (name.len == 0) return;
    theme_loaded = true;

    const home = profile.getenv("HOME") orelse "";
    var b1: [512]u8 = undefined;
    var b2: [512]u8 = undefined;
    const home_themes = if (home.len > 0) (std.fmt.bufPrint(&b1, "{s}/.themes", .{home}) catch "") else "";
    const home_local = if (home.len > 0) (std.fmt.bufPrint(&b2, "{s}/.local/share/themes", .{home}) catch "") else "";
    const bases = [_][]const u8{ home_themes, home_local, "/usr/share/themes", "/usr/local/share/themes" };

    const display = c.gtk_widget_get_display(self.root);
    var path_buf: [1024]u8 = undefined;
    for (bases) |base| {
        if (base.len == 0) continue;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}/gtk-4.0/gtk.css", .{ base, name }) catch continue;
        if (c.access(path.ptr, @as(c_int, 0)) != 0) continue; // F_OK
        const provider = c.gtk_css_provider_new();
        c.gtk_css_provider_load_from_path(provider, path.ptr);
        c.gtk_style_context_add_provider_for_display(display, @ptrCast(@alignCast(provider)), c.GTK_STYLE_PROVIDER_PRIORITY_USER);
        std.debug.print("sketerm: loaded GTK theme '{s}' from {s}\n", .{ name, path });
        return;
    }
}

/// The GTK theme to load: the configured one, else the name part of
/// GTK_THEME ("Name:variant"); empty for none, and for a name too long
/// to be a real theme directory.
fn themeName(configured: []const u8, gtk_theme_env: ?[]const u8) []const u8 {
    if (configured.len > 0) return configured;
    const env = gtk_theme_env orelse return "";
    const colon = std.mem.indexOfScalar(u8, env, ':') orelse env.len;
    const n = env[0..colon];
    if (n.len >= 256) return "";
    return n;
}

// ── signal handlers ──────────────────────────────────────────────────

fn onStructure(_: ?*anyopaque, _: ?*anyopaque, _: c_int, user: ?*anyopaque) callconv(.c) void {
    cast.userData(TabBar, user).rebuild();
}

fn onSelection(_: ?*anyopaque, _: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    cast.userData(TabBar, user).refresh();
}

fn onTitle(_: ?*anyopaque, _: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const t = cast.userData(TabBar.Tab, user);
    c.gtk_label_set_label(@ptrCast(t.label), c.adw_tab_page_get_title(t.page));
}

fn onIcon(_: ?*anyopaque, _: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const t = cast.userData(TabBar.Tab, user);
    const gicon = c.adw_tab_page_get_icon(t.page);
    c.gtk_image_set_from_gicon(@ptrCast(t.icon), gicon);
    c.gtk_widget_set_visible(t.icon, @intFromBool(gicon != null));
}

fn onPressed(_: ?*anyopaque, _: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    const t = cast.userData(TabBar.Tab, user);
    _ = c.adw_tab_view_close_page(t.bar.view, t.page);
}

/// Right-click: select the tab (so menu actions target it) and ask the
/// Window to pop its context menu anchored on this tab.
fn onRightPressed(_: ?*anyopaque, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const t = cast.userData(TabBar.Tab, user);
    c.adw_tab_view_set_selected_page(t.bar.view, t.page);
    if (t.bar.on_context) |f| f(t.bar.context_ctx, t.page, t.tab_box, x, y);
}

fn onClose(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const t = cast.userData(TabBar.Tab, user);
    _ = c.adw_tab_view_close_page(t.bar.view, t.page);
}

/// Effect + reorder tick: repaint effects, ease neighbour slides toward
/// their targets; stop once nothing is animating and nothing is mid-slide.
fn onTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(TabBar, user);
    var any_active = false;
    const dragging = if (self.reorder) |r| r.active else false;
    for (self.tabs.items) |t| {
        const eased = easeSlide(t.slide, t.slide_target);
        t.slide = eased.value;
        if (eased.moving) any_active = true;
        const sel = c.adw_tab_view_get_selected_page(self.view) == @as(?*c.AdwTabPage, t.page);
        if (!sel and tabAnimating(self.config, t.page)) any_active = true;
        c.gtk_widget_queue_draw(t.tab_box);
    }
    // Reorder offsets live on the tabbox snapshot; keep it repainting
    // while any tab is mid-slide or being dragged.
    if (dragging or any_active) c.gtk_widget_queue_draw(self.box);
    if (!any_active and !dragging) {
        if (self.verify_teardown) return 1;
        self.tick_id = 0;
        return 0;
    }
    return 1;
}

/// One-shot: a tab has now been silent past the warning threshold. Wake the
/// tick so the inactive-warning effect can evaluate active and start
/// flashing.
fn onWarnArm(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(TabBar, user);
    self.warn_arm_id = 0;
    self.ensureTick();
    // A nearer tab just crossed its threshold (the tick will draw it); arm
    // for the NEXT-soonest deadline so later-silent tabs still wake the tick.
    self.rescheduleWarn();
    return 0;
}

// ── drag and drop ────────────────────────────────────────────────────
//
// Faithful AdwTabBox port: a single GtkGestureDrag on the strip drives an
// in-bar VISUAL reorder (the pressed tab follows the cursor, neighbours
// ease aside, committed to AdwTabView only on release). When the cursor is
// pulled out of the bar a real GDK drag begins instead, carrying a
// paintable of the tab — that half handles cross-window transfer and
// drag-out-to-new-window, exactly like libadwaita's hybrid.

/// Base drag threshold (px); libadwaita reads gtk-dnd-drag-threshold.
const DRAG_THRESHOLD: f64 = 8;
/// Cursor must leave the bar inset by this × the threshold to detach.
const DND_THRESHOLD_MULTIPLIER: f64 = 4;

/// x (in `box` coords) of a tab's left edge, and its width.
const Bounds = struct { x: f64, w: f64 };

fn tabBounds(box: *c.GtkWidget, child: *c.GtkWidget) ?Bounds {
    var r: c.graphene_rect_t = undefined;
    if (c.gtk_widget_compute_bounds(child, box, &r) == 0) return null;
    return .{ .x = r.origin.x, .w = r.size.width };
}

/// Spacing between neighbouring slots, measured to the next tab, or
/// from the previous one for the last tab (`prev` is only consulted
/// when there is no next tab), else own width plus the separator gap.
fn slotAdvance(own: Bounds, next: ?Bounds, prev: ?Bounds) f64 {
    if (next) |nb| return nb.x - own.x;
    if (prev) |pb| return own.x - pb.x;
    return own.w + 6;
}

/// How far tab `i` slides while the tab pressed at `start` hovers over
/// slot `target`: the tabs in between shift one advance toward the
/// vacated slot to open the gap, everyone else rests.
fn slideOffset(i: usize, start: usize, target: usize, advance: f64) f64 {
    if (i == start) return 0;
    if (start < target and i > start and i <= target) return -advance;
    if (start > target and i >= target and i < start) return advance;
    return 0;
}

fn onReorderBegin(_: ?*anyopaque, start_x: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(TabBar, user);
    self.reorder = null;
    // Locate the pressed tab and select it (left-press selection lives
    // here now that the per-tab click gesture is middle-only).
    for (self.tabs.items, 0..) |t, idx| {
        const b = tabBounds(self.box, t.child) orelse continue;
        if (start_x < b.x or start_x > b.x + b.w) continue;
        c.adw_tab_view_set_selected_page(self.view, t.page);
        const n = self.tabs.items.len;
        const next: ?Bounds = if (idx + 1 < n) tabBounds(self.box, self.tabs.items[idx + 1].child) else null;
        const prev: ?Bounds = if (idx + 1 >= n and idx > 0) tabBounds(self.box, self.tabs.items[idx - 1].child) else null;
        const advance = slotAdvance(b, next, prev);
        self.reorder = .{
            .tab = t,
            .start_index = idx,
            .index = idx,
            .offset_x = start_x - b.x,
            .advance = advance,
        };
        return;
    }
}

fn onReorderUpdate(gesture: ?*anyopaque, off_x: f64, off_y: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(TabBar, user);
    const r = if (self.reorder) |*rp| rp else return;

    // Claim on the FIRST motion, before the drag threshold — the header
    // bar's window-drag gesture is an ancestor and would otherwise win the
    // sequence first (intermittently dragging the whole window). Claiming
    // here denies it; we still only start the visual reorder past the
    // threshold below. A plain click (no motion) never reaches this, so the
    // close button / selection still work.
    _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_CLAIMED);

    if (!r.active) {
        if (c.gtk_drag_check_threshold(self.box, 0, 0, @intFromFloat(off_x), @intFromFloat(off_y)) == 0) return;
        r.active = true;
        r.tab.drag_dx = 0;
        r.tab.dragging = true;
        c.gtk_widget_add_css_class(r.tab.tab_box, "dragging");
        self.ensureTick();
    }

    var sx: f64 = 0;
    var sy: f64 = 0;
    _ = c.gtk_gesture_drag_get_start_point(@ptrCast(gesture), &sx, &sy);
    const px = sx + off_x;
    const py = sy + off_y;

    // Pull-out → real GDK drag (cross-window / new window). Mirrors
    // check_dnd_threshold: outside the bar rect inset by threshold×4.
    const npages = c.adw_tab_view_get_n_pages(self.view);
    if (npages > 1 and c.adw_tab_page_get_pinned(r.tab.page) == 0) {
        const inset = DRAG_THRESHOLD * DND_THRESHOLD_MULTIPLIER;
        var rect: c.graphene_rect_t = undefined;
        _ = c.graphene_rect_init(&rect, 0, 0, @floatFromInt(c.gtk_widget_get_width(self.box)), @floatFromInt(c.gtk_widget_get_height(self.box)));
        _ = c.graphene_rect_inset(&rect, @floatCast(-inset), @floatCast(-inset));
        var pt: c.graphene_point_t = undefined;
        _ = c.graphene_point_init(&pt, @floatCast(px), @floatCast(py));
        if (!c.graphene_rect_contains_point(&rect, &pt)) {
            beginExternalDrag(self, @ptrCast(gesture), r.tab, r.offset_x, py);
            clearReorder(self);
            _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_DENIED);
            return;
        }
    }

    // In-bar: glue the dragged tab to the cursor.
    const home = tabBounds(self.box, r.tab.child) orelse return;
    const desired_left = px - r.offset_x;
    r.tab.drag_dx = desired_left - home.x;

    // Target index: count tabs whose centre sits left of the dragged
    // tab's centre (AdwTabBox midpoint rule), excluding the dragged one.
    const desired_center = desired_left + home.w / 2.0;
    var target: usize = 0;
    for (self.tabs.items, 0..) |t, i| {
        if (i == r.start_index) continue;
        const b = tabBounds(self.box, t.child) orelse continue;
        if (b.x + b.w / 2.0 < desired_center) target += 1;
    }
    if (target >= self.tabs.items.len) target = self.tabs.items.len - 1;
    r.index = target;

    for (self.tabs.items, 0..) |t, i| t.slide_target = slideOffset(i, r.start_index, target, r.advance);

    // The offsets are applied by the tabbox snapshot, so invalidate it
    // (not just the individual tab nodes) on every motion.
    c.gtk_widget_queue_draw(self.box);
}

fn onReorderEnd(_: ?*anyopaque, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(TabBar, user);
    const r = if (self.reorder) |rp| rp else return;
    defer clearReorder(self);
    if (!r.active) return;
    if (r.index != r.start_index) {
        // Commit to the model; page-reordered → rebuild snaps to final.
        _ = c.adw_tab_view_reorder_page(self.view, r.tab.page, @intCast(r.index));
    }
}

/// Drop every transient reorder offset and forget the drag.
fn clearReorder(self: *TabBar) void {
    for (self.tabs.items) |t| {
        t.drag_dx = 0;
        t.slide = 0;
        t.slide_target = 0;
        t.dragging = false;
        c.gtk_widget_remove_css_class(t.tab_box, "dragging");
        c.gtk_widget_queue_draw(t.tab_box);
    }
    self.reorder = null;
}

/// Cursor left the bar: hand the tab to a real GDK drag so it can move to
/// another window or spawn a new one. The drag icon is a live paintable of
/// the tab (libadwaita's `dnd tab` representation).
fn beginExternalDrag(self: *TabBar, controller: *c.GtkEventController, tab: *TabBar.Tab, hot_x: f64, hot_y: f64) void {
    const native = c.gtk_widget_get_native(self.box) orelse return;
    const surface = c.gtk_native_get_surface(native) orelse return;
    const device = c.gtk_event_controller_get_current_event_device(controller) orelse return;
    publishDrag(self.view, tab.page, self.detach_ctx, self.on_detach);
    clearGdkDrag();
    // gdk_drag_begin takes the provider as transfer-none (it refs its own),
    // so the constructor's ref is ours to drop on every path out of here.
    const content = c.gdk_content_provider_new_typed(c.G_TYPE_INT, @as(c_int, 1));
    defer if (content) |p| c.g_object_unref(p);
    const drag = c.gdk_drag_begin(surface, device, content, c.GDK_ACTION_MOVE, -hot_x, -hot_y) orelse {
        clearDragged();
        return;
    };
    gdk_drag = drag;
    const icon = c.gtk_drag_icon_get_for_drag(drag);
    const paintable = c.gtk_widget_paintable_new(tab.tab_box);
    const img = c.gtk_image_new_from_paintable(paintable);
    c.gtk_drag_icon_set_child(@ptrCast(@alignCast(icon)), img);
    if (paintable) |p| c.g_object_unref(p);
    _ = c.g_signal_connect_data(drag, "cancel", @ptrCast(&onGdkDragCancel), null, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(drag, "dnd-finished", @ptrCast(&onGdkDragFinished), null, null, c.G_CONNECT_DEFAULT);
}

/// GDK drag ended with no drop target: spawn a new window for the tab
/// (drag-out), the create-window half of libadwaita's behaviour.
///
/// `GdkDrag::cancel` is a VOID signal, so `dragCancelled`'s "consumed"
/// answer has nowhere to go here and the detach it performs is the whole
/// effect. Only `GtkDragSource::drag-cancel` -- the sidebar's gesture --
/// declares a gboolean return, and that one still uses it.
fn onGdkDragCancel(drag: ?*anyopaque, reason: c_int, _: ?*anyopaque) callconv(.c) void {
    _ = dragCancelled(reason);
    releaseGdkDrag(drag);
}

fn onGdkDragFinished(drag: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    releaseGdkDrag(drag);
    clearDragged();
}

/// A tab dragged out of another window's strip was dropped on ours.
fn onDrop(_: ?*anyopaque, _: ?*anyopaque, x: f64, _: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(TabBar, user);
    const src = dragged orelse return 0;
    dragged = null;
    defer releaseDragged(src);

    const slot: f64 = @floatFromInt(TAB_W);
    var idx: c_int = @intFromFloat(@max(0.0, (x + slot / 2.0) / slot));
    const n = c.adw_tab_view_get_n_pages(self.view);
    if (idx > n) idx = n;

    if (src.view == self.view) {
        var pos = idx;
        if (pos >= n) pos = n - 1;
        if (pos < 0) pos = 0;
        _ = c.adw_tab_view_reorder_page(self.view, src.page, pos);
    } else {
        if (self.on_transfer) |transfer| {
            if (!transfer(self.transfer_ctx, src.view, src.page, idx)) return 0;
        } else {
            c.adw_tab_view_transfer_page(src.view, src.page, self.view, idx);
        }
    }
    return 1;
}

// -- strip decisions, free of widgets -------------------------------------

/// Whether the separator before tab `idx` is hidden: AdwTabBox hides
/// the one on each side of the selected tab.
fn separatorHidden(idx: usize, selected: ?usize) bool {
    const sel = selected orelse return false;
    return sel == idx or sel + 1 == idx;
}

/// One reorder tick: the slide eases (ADW_EASE-ish) toward `target`
/// and snaps onto it once within half a pixel.
fn easeSlide(slide: f64, target: f64) struct { value: f64, moving: bool } {
    if (@abs(slide - target) > 0.5) return .{ .value = slide + (target - slide) * 0.35, .moving = true };
    return .{ .value = target, .moving = false };
}

/// Fold one tab's inactive-warning deadline into the soonest one still
/// ahead; a deadline already past is the animating tick's business and
/// needs no wake-up.
fn soonerDeadline(soonest: ?i64, deadline: i64, now: i64) ?i64 {
    if (deadline <= now) return soonest;
    if (soonest) |s| return @min(s, deadline);
    return deadline;
}

/// Milliseconds until the silence wake-up for a deadline in the
/// future, 50ms late so warnEval is comfortably past the threshold.
fn wakeDelayMs(deadline_us: i64, now_us: i64) c.guint {
    return @intCast(@max(@divFloor(deadline_us - now_us, 1000) + 50, 1));
}

// -- tests --------------------------------------------------------------

const testing = std.testing;

test "the icon and title group is centred, never wider than the tab" {
    try testing.expectEqual(Span{ .x = 29, .width = 60 }, centerGroup(118, 60));
    try testing.expectEqual(Span{ .x = 0, .width = 118 }, centerGroup(118, 400));
    // An odd leftover rounds toward the start.
    try testing.expectEqual(Span{ .x = 2, .width = 5 }, centerGroup(10, 5));
    try testing.expectEqual(Span{ .x = 0, .width = 0 }, centerGroup(0, 30));
}

test "the separators on both sides of the selected tab are hidden" {
    // Separator i sits before tab i, so tab 2 selected hides 2 and 3.
    try testing.expect(!separatorHidden(1, 2));
    try testing.expect(separatorHidden(2, 2));
    try testing.expect(separatorHidden(3, 2));
    try testing.expect(!separatorHidden(4, 2));
    try testing.expect(!separatorHidden(1, null));
}

test "a slot's advance is measured to the next tab, else from the previous" {
    const own = Bounds{ .x = 200, .w = 180 };
    try testing.expectEqual(@as(f64, 190), slotAdvance(own, .{ .x = 390, .w = 180 }, null));
    try testing.expectEqual(@as(f64, 186), slotAdvance(own, null, .{ .x = 14, .w = 180 }));
    // A lone tab: its own width plus the separator gap.
    try testing.expectEqual(@as(f64, 186), slotAdvance(own, null, null));
}

test "only the tabs between the old and new slot slide, toward the gap" {
    // Tab 1 dragged right over slot 3: tabs 2 and 3 shift left.
    try testing.expectEqual(@as(f64, 0), slideOffset(0, 1, 3, 100));
    try testing.expectEqual(@as(f64, 0), slideOffset(1, 1, 3, 100));
    try testing.expectEqual(@as(f64, -100), slideOffset(2, 1, 3, 100));
    try testing.expectEqual(@as(f64, -100), slideOffset(3, 1, 3, 100));
    try testing.expectEqual(@as(f64, 0), slideOffset(4, 1, 3, 100));
    // Tab 3 dragged left over slot 1: tabs 1 and 2 shift right.
    try testing.expectEqual(@as(f64, 0), slideOffset(0, 3, 1, 100));
    try testing.expectEqual(@as(f64, 100), slideOffset(1, 3, 1, 100));
    try testing.expectEqual(@as(f64, 100), slideOffset(2, 3, 1, 100));
    try testing.expectEqual(@as(f64, 0), slideOffset(3, 3, 1, 100));
    // Back over its own slot: nothing moves.
    for (0..4) |i| try testing.expectEqual(@as(f64, 0), slideOffset(i, 2, 2, 100));
}

test "a slide eases toward its target and then snaps and stops" {
    const first = easeSlide(0, 100);
    try testing.expect(first.moving);
    try testing.expectApproxEqAbs(@as(f64, 35), first.value, 1e-9);
    const settled = easeSlide(99.7, 100);
    try testing.expect(!settled.moving);
    try testing.expectEqual(@as(f64, 100), settled.value);
    // It always converges.
    var s: f64 = -180;
    var ticks: usize = 0;
    while (easeSlide(s, 0).moving) : (ticks += 1) s = easeSlide(s, 0).value;
    try testing.expect(ticks < 30);
}

test "the silence wake-up targets the soonest deadline still ahead" {
    const now: i64 = 10_000_000;
    var soonest: ?i64 = null;
    soonest = soonerDeadline(soonest, now + 5_000_000, now);
    soonest = soonerDeadline(soonest, now - 1, now); // already past
    soonest = soonerDeadline(soonest, now + 2_000_000, now);
    soonest = soonerDeadline(soonest, now, now); // due right now: the tick has it
    try testing.expectEqual(@as(?i64, now + 2_000_000), soonest);
    try testing.expectEqual(@as(?i64, null), soonerDeadline(null, now - 5, now));

    try testing.expectEqual(@as(c.guint, 2050), wakeDelayMs(now + 2_000_000, now));
    // Sub-millisecond remainders still wait the margin, never zero.
    try testing.expectEqual(@as(c.guint, 50), wakeDelayMs(now + 999, now));
    try testing.expectEqual(@as(c.guint, 1), wakeDelayMs(now - 1_000_000, now));
}

test "the theme is the configured one, else GTK_THEME without its variant" {
    try testing.expectEqualStrings("Nordic", themeName("Nordic", "Adwaita:dark"));
    try testing.expectEqualStrings("Adwaita", themeName("", "Adwaita:dark"));
    try testing.expectEqualStrings("Materia", themeName("", "Materia"));
    try testing.expectEqualStrings("", themeName("", ":dark"));
    try testing.expectEqualStrings("", themeName("", null));
    const long = "x" ** 256;
    try testing.expectEqualStrings("", themeName("", long));
}
