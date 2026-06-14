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

const TAB_W: c_int = 170;
/// Activity glow fade time once a tab goes quiet (after any sustain
/// window): full → gone over this many microseconds.
const GLOW_DECAY_US: f64 = 2_600_000;
/// Aurora glow: soft full-spectrum colour blobs that blend and drift
/// right-to-left, breathing in and out of place so the colour flows
/// organically instead of a hard rainbow sliding by.
const AURORA_BLOBS: usize = 6;
/// Period of the slow right-to-left drift, microseconds.
const AURORA_DRIFT_US: f64 = 5_000_000;
/// Period of each blob's in-place wobble, microseconds.
const AURORA_WOBBLE_US: f64 = 2_600_000;
/// Blob spread (fraction of tab width) and wobble amplitude.
const AURORA_SIGMA: f64 = 0.17;
const AURORA_WOBBLE: f64 = 0.06;
/// Blending colours in RGB greys them out; push the blend back toward full
/// saturation by this factor (1 = none) so the aurora stays vivid.
const AURORA_SAT: f64 = 1.55;
const ACTIVITY_KEY = "sketerm-tab-activity-us";
/// EMA of the inter-arrival gap between activity events, per page.
const GAP_KEY = "sketerm-tab-gap-us";
/// A source whose refresh period is under this (e.g. htop every ~1.5s) is
/// treated as "ongoing": the glow is held steady so it keeps sweeping
/// smoothly instead of fading and snapping back on each refresh.
const SUSTAIN_THRESHOLD_US: f64 = 4_500_000;
/// Hold the glow for this multiple of the refresh period (generous margin
/// so jitter / a slightly-late refresh never causes a visible dip).
const SUSTAIN_FACTOR: f64 = 2.2;
/// Cap on the sustain window so even near-threshold sources fade eventually.
const SUSTAIN_MAX_US: f64 = 9_000_000;
/// A gap larger than this means activity restarted; the average resets to
/// it rather than blending, so a long pause never inflates the window.
const SUSTAIN_RESET_GAP_US: i64 = 6_000_000;
/// Gaps below this are intra-refresh noise (a full-screen TUI repaint emits
/// several events milliseconds apart) and are ignored — only the quiet
/// between refreshes reveals the true period.
const MIN_MEANINGFUL_GAP_US: i64 = 500_000;

/// CSS installed once per display.
var css_installed = false;

/// The tab currently being dragged. In-process DnD across windows shares
/// one address space, so a module global is the simplest reliable
/// carrier; the GdkContentProvider just supplies a matching marker type.
var dragged: ?*TabBar.Tab = null;

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
    const start_width: c_int = 0;
    const end_width: c_int = 0;
    if (t.close_btn) |cb| {
        if (c.gtk_widget_get_visible(@ptrCast(cb)) != 0) {
            const close_w = measureChildWidth(cb, height);
            allocateChild(cb, width - close_w, close_w, height, baseline);
        }
    }

    // Centre the icon+title group across the full width, clamped so it
    // can't spill past the (here zero-width) reserved edges.
    var center_width = @min(width - start_width - end_width, icon_w + title_w);
    if (center_width < 0) center_width = 0;
    const hi = width - center_width - end_width;
    var center_x = @divTrunc(width - center_width, 2);
    if (center_x < start_width) center_x = start_width;
    if (center_x > hi) center_x = hi;

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

/// Tab `snapshot`: draw the activity glow BEHIND, then the tab's children
/// (icon, title, close) on top so the text/button stay legible.
fn tabSnapshot(widget: [*c]c.GtkWidget, snapshot: ?*c.GtkSnapshot) callconv(.c) void {
    drawGlow(widget, snapshot);
    var child = c.gtk_widget_get_first_child(widget);
    while (child != null) : (child = c.gtk_widget_get_next_sibling(child)) {
        c.gtk_widget_snapshot_child(widget, child, snapshot);
    }
}

/// The aurora glow (full-width soft wash + opaque bottom border), drawn
/// before the children so it sits underneath them.
fn drawGlow(widget: [*c]c.GtkWidget, snapshot: ?*c.GtkSnapshot) void {
    const data = c.g_object_get_data(@ptrCast(@alignCast(widget)), "sketerm-tab") orelse return;
    const tab: *TabBar.Tab = @ptrCast(@alignCast(data));
    if (c.adw_tab_view_get_selected_page(tab.bar.view) == @as(?*c.AdwTabPage, tab.page)) return;
    const intensity = activityIntensity(tab.page);
    if (intensity <= 0.01) return;

    const w: f64 = @floatFromInt(c.gtk_widget_get_width(@ptrCast(widget)));
    const h: f64 = @floatFromInt(c.gtk_widget_get_height(@ptrCast(widget)));
    var rect: c.graphene_rect_t = undefined;
    _ = c.graphene_rect_init(&rect, 0, 0, @floatCast(w), @floatCast(h));
    const cr = c.gtk_snapshot_append_cairo(snapshot, &rect) orelse return;
    const t_us: f64 = @floatFromInt(c.g_get_monotonic_time());

    // Soft aurora wash over the WHOLE tab, faint at the top and growing
    // toward the bottom (a vertical alpha mask gives the glow gradient).
    if (makeAurora(w, intensity, t_us)) |wash| {
        defer c.cairo_pattern_destroy(wash);
        c.cairo_set_source(cr, wash);
        if (c.cairo_pattern_create_linear(0, 0, 0, h)) |mask| {
            defer c.cairo_pattern_destroy(mask);
            c.cairo_pattern_add_color_stop_rgba(mask, 0.0, 1, 1, 1, 0.04);
            c.cairo_pattern_add_color_stop_rgba(mask, 0.75, 1, 1, 1, 0.16);
            c.cairo_pattern_add_color_stop_rgba(mask, 1.0, 1, 1, 1, 0.38);
            c.cairo_mask(cr, mask);
        }
    }

    // Opaque aurora bottom border.
    if (makeAurora(w, intensity, t_us)) |bar| {
        defer c.cairo_pattern_destroy(bar);
        c.cairo_set_source(cr, bar);
        c.cairo_rectangle(cr, 0, h - 3, w, 3);
        c.cairo_fill(cr);
    }
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
    detach_ctx: ?*anyopaque = null,
    on_detach: ?*const fn (ctx: ?*anyopaque, view: *c.AdwTabView, page: *c.AdwTabPage) void = null,
    reorder: ?Reorder = null,

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
        title_handler: c.gulong = 0,
        icon_handler: c.gulong = 0,
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
        _ = c.g_signal_connect_data(reorder, "drag-begin", @ptrCast(&onReorderBegin), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(reorder, "drag-update", @ptrCast(&onReorderUpdate), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(reorder, "drag-end", @ptrCast(&onReorderEnd), self, null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(box, @ptrCast(@alignCast(reorder)));

        // Accept GDK drags pulled in from another window's strip (the
        // cross-window transfer half of the hybrid; in-bar reorder never
        // uses content-DnD).
        const drop = c.gtk_drop_target_new(c.G_TYPE_INT, c.GDK_ACTION_MOVE);
        _ = c.g_signal_connect_data(drop, "drop", @ptrCast(&onDrop), self, null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(box, @ptrCast(@alignCast(drop)));

        _ = c.g_signal_connect_data(view, "page-attached", @ptrCast(&onStructure), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(view, "page-detached", @ptrCast(&onStructure), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(view, "page-reordered", @ptrCast(&onStructure), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(view, "notify::selected-page", @ptrCast(&onSelection), self, null, c.G_CONNECT_DEFAULT);

        self.rebuild();
        return self;
    }

    pub fn ensureTick(self: *TabBar) void {
        if (self.tick_id != 0) return;
        self.tick_id = c.g_timeout_add(33, @ptrCast(&onTick), self);
    }

    /// Mark the selected tab's `:selected` state (what libadwaita's
    /// `tabbar tab:selected` rule styles) and repaint glows.
    pub fn refresh(self: *TabBar) void {
        const sel = c.adw_tab_view_get_selected_page(self.view);
        for (self.tabs.items, 0..) |t, idx| {
            const this_sel = sel == @as(?*c.AdwTabPage, t.page);
            if (this_sel) {
                c.gtk_widget_set_state_flags(t.tab_box, c.GTK_STATE_FLAG_SELECTED, 0);
            } else {
                c.gtk_widget_unset_state_flags(t.tab_box, c.GTK_STATE_FLAG_SELECTED);
            }
            // Hide the separator that touches the selected tab (AdwTabBox).
            if (t.sep_before) |s| {
                const prev_sel = idx > 0 and sel == @as(?*c.AdwTabPage, self.tabs.items[idx - 1].page);
                if (this_sel or prev_sel) {
                    c.gtk_widget_add_css_class(s, "hidden");
                } else {
                    c.gtk_widget_remove_css_class(s, "hidden");
                }
            }
            c.gtk_widget_queue_draw(t.tab_box);
        }
    }

    fn clearTabs(self: *TabBar) void {
        for (self.tabs.items) |t| {
            if (t.title_handler != 0) c.g_signal_handler_disconnect(@ptrCast(t.page), t.title_handler);
            if (t.icon_handler != 0) c.g_signal_handler_disconnect(@ptrCast(t.page), t.icon_handler);
            if (t.sep_before) |s| c.gtk_box_remove(@ptrCast(self.box), s);
            c.gtk_box_remove(@ptrCast(self.box), t.child);
            self.allocator.destroy(t);
        }
        self.tabs.clearRetainingCapacity();
    }

    pub fn rebuild(self: *TabBar) void {
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
        self.refresh();
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
        // hidden on pinned tabs.
        const close = c.gtk_button_new_from_icon_name("window-close-symbolic");
        c.gtk_button_set_has_frame(@ptrCast(close), 0);
        c.gtk_widget_add_css_class(close, "flat");
        c.gtk_widget_add_css_class(close, "tab-close-button");
        c.gtk_widget_set_valign(close, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_visible(close, @intFromBool(!pinned));
        _ = c.g_signal_connect_data(close, "clicked", @ptrCast(&onClose), t, null, c.G_CONNECT_DEFAULT);
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
        _ = c.g_signal_connect_data(click, "pressed", @ptrCast(&onPressed), t, null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(tab_box, @ptrCast(@alignCast(click)));

        t.title_handler = c.g_signal_connect_data(@ptrCast(page), "notify::title", @ptrCast(&onTitle), t, null, c.G_CONNECT_DEFAULT);
        t.icon_handler = c.g_signal_connect_data(@ptrCast(page), "notify::icon", @ptrCast(&onIcon), t, null, c.G_CONNECT_DEFAULT);
    }

    pub fn deinit(self: *TabBar) void {
        if (self.tick_id != 0) {
            _ = c.g_source_remove(self.tick_id);
            self.tick_id = 0;
        }
        self.clearTabs();
        self.tabs.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// The tabs are now real `tabbar`/`tab` CSS nodes, so Adwaita's base
/// stylesheet AND the user's theme style them natively — we add nothing
/// of our own except the native-style close-button reveal-on-hover
/// (which AdwTab does in C, not CSS).
fn installCss(any_widget: *c.GtkWidget) void {
    if (css_installed) return;
    css_installed = true;
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
    const provider = c.gtk_css_provider_new();
    c.gtk_css_provider_load_from_string(provider, css);
    const display = c.gtk_widget_get_display(any_widget);
    c.gtk_style_context_add_provider_for_display(display, @ptrCast(@alignCast(provider)), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

var theme_loaded = false;

/// Load a GTK theme's `gtk-4.0/gtk.css` over libadwaita's stylesheet so
/// the user's styling (e.g. `tabbar tab`, which now matches our real
/// `tab` nodes) applies. `configured` is the sketerm `gtk_theme` config
/// value; empty falls back to the GTK_THEME env var. No-op if neither
/// names a theme or the file isn't found. Loaded once per process.
pub fn loadTheme(self: *TabBar, configured: []const u8) void {
    if (theme_loaded) return;
    var env_buf: [256]u8 = undefined;
    const name: []const u8 = blk: {
        if (configured.len > 0) break :blk configured;
        const env = profile.getenv("GTK_THEME") orelse break :blk "";
        // GTK_THEME may be "Name:variant"; take the name part.
        const colon = std.mem.indexOfScalar(u8, env, ':') orelse env.len;
        const n = env[0..colon];
        if (n.len == 0 or n.len >= env_buf.len) break :blk "";
        @memcpy(env_buf[0..n.len], n);
        break :blk env_buf[0..n.len];
    };
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

fn onClose(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const t = cast.userData(TabBar.Tab, user);
    _ = c.adw_tab_view_close_page(t.bar.view, t.page);
}

/// Glow + reorder tick: redraw glows, ease neighbour slides toward their
/// targets; stop once nothing is active and nothing is mid-slide.
fn onTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(TabBar, user);
    var any_active = false;
    const dragging = if (self.reorder) |r| r.active else false;
    for (self.tabs.items) |t| {
        // Ease the slide offset (ADW_EASE-ish) toward its target.
        if (@abs(t.slide - t.slide_target) > 0.5) {
            t.slide += (t.slide_target - t.slide) * 0.35;
            any_active = true;
        } else {
            t.slide = t.slide_target;
        }
        const sel = c.adw_tab_view_get_selected_page(self.view) == @as(?*c.AdwTabPage, t.page);
        if (!sel and activityIntensity(t.page) > 0.01) any_active = true;
        c.gtk_widget_queue_draw(t.tab_box);
    }
    // Reorder offsets live on the tabbox snapshot; keep it repainting
    // while any tab is mid-slide or being dragged.
    if (dragging or any_active) c.gtk_widget_queue_draw(self.box);
    if (!any_active and !dragging) {
        self.tick_id = 0;
        return 0;
    }
    return 1;
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
fn tabBounds(box: *c.GtkWidget, child: *c.GtkWidget) ?struct { x: f64, w: f64 } {
    var r: c.graphene_rect_t = undefined;
    if (c.gtk_widget_compute_bounds(child, box, &r) == 0) return null;
    return .{ .x = r.origin.x, .w = r.size.width };
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
        // Advance = spacing between this slot and the next (falls back to
        // own width + a separator gap for a lone tab).
        var advance = b.w + 6;
        if (idx + 1 < self.tabs.items.len) {
            if (tabBounds(self.box, self.tabs.items[idx + 1].child)) |nb| advance = nb.x - b.x;
        } else if (idx > 0) {
            if (tabBounds(self.box, self.tabs.items[idx - 1].child)) |pb| advance = b.x - pb.x;
        }
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

    // Neighbours between the old and new slot shift one advance to open
    // the gap; everyone else returns to rest.
    for (self.tabs.items, 0..) |t, i| {
        if (i == r.start_index) {
            t.slide_target = 0;
            continue;
        }
        var off: f64 = 0;
        if (r.start_index < target and i > r.start_index and i <= target) off = -r.advance;
        if (r.start_index > target and i >= target and i < r.start_index) off = r.advance;
        t.slide_target = off;
    }

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
    dragged = tab;
    const content = c.gdk_content_provider_new_typed(c.G_TYPE_INT, @as(c_int, 1));
    const drag = c.gdk_drag_begin(surface, device, content, c.GDK_ACTION_MOVE, -hot_x, -hot_y) orelse {
        dragged = null;
        return;
    };
    const icon = c.gtk_drag_icon_get_for_drag(drag);
    const paintable = c.gtk_widget_paintable_new(tab.tab_box);
    const img = c.gtk_image_new_from_paintable(paintable);
    c.gtk_drag_icon_set_child(@ptrCast(@alignCast(icon)), img);
    if (paintable) |p| c.g_object_unref(p);
    _ = c.g_signal_connect_data(drag, "cancel", @ptrCast(&onGdkDragCancel), tab, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(drag, "dnd-finished", @ptrCast(&onGdkDragFinished), null, null, c.G_CONNECT_DEFAULT);
}

/// GDK drag ended with no drop target: spawn a new window for the tab
/// (drag-out), the create-window half of libadwaita's behaviour.
fn onGdkDragCancel(_: ?*anyopaque, reason: c_int, user: ?*anyopaque) callconv(.c) c.gboolean {
    const t = cast.userData(TabBar.Tab, user);
    defer dragged = null;
    if (reason == c.GDK_DRAG_CANCEL_NO_TARGET) {
        if (t.bar.on_detach) |f| f(t.bar.detach_ctx, t.bar.view, t.page);
        return 1;
    }
    return 0;
}

fn onGdkDragFinished(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    dragged = null;
}

/// A tab dragged out of another window's strip was dropped on ours.
fn onDrop(_: ?*anyopaque, _: ?*anyopaque, x: f64, _: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(TabBar, user);
    const src = dragged orelse return 0;
    dragged = null;

    const slot: f64 = @floatFromInt(TAB_W);
    var idx: c_int = @intFromFloat(@max(0.0, (x + slot / 2.0) / slot));
    const n = c.adw_tab_view_get_n_pages(self.view);
    if (idx > n) idx = n;

    if (src.bar.view == self.view) {
        var pos = idx;
        if (pos >= n) pos = n - 1;
        if (pos < 0) pos = 0;
        _ = c.adw_tab_view_reorder_page(self.view, src.page, pos);
    } else {
        c.adw_tab_view_transfer_page(src.bar.view, src.page, self.view, idx);
    }
    return 1;
}

// ── glow helpers (drawing is in tabSnapshot) ─────────────────────────

/// Stamp a tab's page with an activity event, maintaining the
/// inter-arrival-gap EMA used to sustain the glow for steady streams.
pub fn recordActivity(page: *c.AdwTabPage) void {
    const obj: [*c]c.GObject = @ptrCast(@alignCast(page));
    const now = c.g_get_monotonic_time();
    if (c.g_object_get_data(obj, ACTIVITY_KEY)) |prev| {
        const prev_ts: i64 = @bitCast(@as(u64, @intFromPtr(prev)));
        const gap = now - prev_ts;
        // Only inter-refresh gaps reveal the period; ignore the burst of
        // tiny gaps a TUI repaint produces (those would drag the average
        // down to a few ms and defeat the sustain entirely).
        if (gap >= MIN_MEANINGFUL_GAP_US) {
            const gap_u: u64 = @intCast(gap);
            const old = c.g_object_get_data(obj, GAP_KEY);
            // Blend at 0.5 so it tracks the real cadence in a couple of
            // refreshes; a long pause resets it so an idle tab doesn't
            // inherit a stale rhythm.
            const ema: u64 = if (old != null and gap < SUSTAIN_RESET_GAP_US)
                (@as(u64, @intFromPtr(old)) + gap_u) / 2
            else
                gap_u;
            c.g_object_set_data(obj, GAP_KEY, @ptrFromInt(@as(usize, @intCast(ema))));
        }
    }
    c.g_object_set_data(obj, ACTIVITY_KEY, @ptrFromInt(@as(usize, @intCast(now))));
}

fn activityIntensity(page: *c.AdwTabPage) f64 {
    const obj: [*c]c.GObject = @ptrCast(@alignCast(page));
    const data = c.g_object_get_data(obj, ACTIVITY_KEY) orelse return 0;
    const ts: i64 = @bitCast(@as(u64, @intFromPtr(data)));
    const now = c.g_get_monotonic_time();
    const elapsed: f64 = @floatFromInt(now - ts);
    if (elapsed <= 0) return 1.0;

    // Adaptive sustain: while a source keeps updating faster than the
    // threshold, hold the glow at full so it sweeps continuously instead
    // of fading and snapping on every update (e.g. htop's 2s refresh).
    var hold: f64 = 0;
    if (c.g_object_get_data(obj, GAP_KEY)) |g| {
        const ema: f64 = @floatFromInt(@as(u64, @intFromPtr(g)));
        if (ema < SUSTAIN_THRESHOLD_US) hold = @min(ema * SUSTAIN_FACTOR, SUSTAIN_MAX_US);
    }
    if (elapsed <= hold) return 1.0;

    const fade = elapsed - hold;
    if (fade >= GLOW_DECAY_US) return 0;
    return 1.0 - fade / GLOW_DECAY_US;
}

/// An aurora ramp across `width`: full-spectrum colour blobs, evenly spaced
/// in hue, that all drift right-to-left while each wobbles in place on its
/// own cycle. The colour at every point is the soft (gaussian) blend of the
/// blobs, computed toroidally so the drift is seamless. The wobble keeps the
/// flow organic instead of a rigid translation.
fn makeAurora(width: f64, alpha: f64, t_us: f64) ?*c.cairo_pattern_t {
    const span = if (width > 1) width else 1;
    const pat = c.cairo_pattern_create_linear(0, 0, span, 0) orelse return null;
    const tau = 2.0 * std.math.pi;
    const nb: f64 = @floatFromInt(AURORA_BLOBS);
    const drift = t_us / AURORA_DRIFT_US;

    var cx: [AURORA_BLOBS]f64 = undefined;
    var col: [AURORA_BLOBS][3]f64 = undefined;
    for (0..AURORA_BLOBS) |i| {
        const fi: f64 = @floatFromInt(i);
        const base = fi / nb;
        const wob = AURORA_WOBBLE * @sin(tau * (t_us / AURORA_WOBBLE_US + base));
        cx[i] = base - drift + wob; // toroidal distance handles the wrap
        col[i] = hsv2rgb(base, 1.0, 1.0);
    }

    const inv2s2 = 1.0 / (2.0 * AURORA_SIGMA * AURORA_SIGMA);
    const N: usize = 64;
    var k: usize = 0;
    while (k <= N) : (k += 1) {
        const pos = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(N));
        var r: f64 = 0;
        var g: f64 = 0;
        var b: f64 = 0;
        var sw: f64 = 0;
        for (0..AURORA_BLOBS) |i| {
            var d = pos - cx[i];
            d -= @round(d); // nearest copy on the [0,1) torus
            const wt = @exp(-d * d * inv2s2);
            r += wt * col[i][0];
            g += wt * col[i][1];
            b += wt * col[i][2];
            sw += wt;
        }
        if (sw > 0) {
            r /= sw;
            g /= sw;
            b /= sw;
        }
        // Re-saturate: push each channel away from the grey of the blend.
        const grey = (r + g + b) / 3.0;
        r = std.math.clamp(grey + (r - grey) * AURORA_SAT, 0.0, 1.0);
        g = std.math.clamp(grey + (g - grey) * AURORA_SAT, 0.0, 1.0);
        b = std.math.clamp(grey + (b - grey) * AURORA_SAT, 0.0, 1.0);
        c.cairo_pattern_add_color_stop_rgba(pat, pos, r, g, b, alpha);
    }
    return pat;
}

fn hsv2rgb(hv: f64, s: f64, v: f64) [3]f64 {
    const i = @floor(hv * 6.0);
    const f = hv * 6.0 - i;
    const p = v * (1.0 - s);
    const q = v * (1.0 - f * s);
    const tt = v * (1.0 - (1.0 - f) * s);
    return switch (@as(i32, @intFromFloat(@mod(i, 6.0)))) {
        0 => .{ v, tt, p },
        1 => .{ q, v, p },
        2 => .{ p, v, tt },
        3 => .{ p, q, v },
        4 => .{ tt, p, v },
        else => .{ v, p, q },
    };
}
