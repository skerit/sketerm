//! Shared GtkNotebook tab-strip mechanics, extracted from the file
//! browser so the editor face can reuse them: notebook creation,
//! the ellipsized tab label + close button recipe, middle-click
//! close, scroll-to-switch with a touchpad accumulator, the strip's
//! empty-area gestures (double-click = new tab, right-click =
//! consumer-provided menu), and the PER-TAB context menu.
//!
//! The per-tab menu is shared on purpose. Close / Close Others /
//! Close to the Right / Close Unmodified / Duplicate / Open in New
//! Window are the same verbs in any tabbed host, so TabHost builds
//! those rows itself out of `on_close` plus the `TabMenu` predicates,
//! and each consumer contributes only its DOMAIN rows through
//! `TabMenu.extra`. Neither consumer owns a second implementation of
//! "close every tab but this one".
//!
//! Consumers keep everything else domain-specific (DnD targets,
//! closed-tab rings) layered on the returned TabLabel's `box`. The
//! host struct's address must be stable for the lifetime of the
//! notebook widgets (gesture callbacks hold it raw).

const std = @import("std");
const c = @import("../c.zig").c;
const classicmenu = @import("browser/classicmenu.zig");

/// Per-page label handle. Heap-allocated by addPage and freed
/// automatically when the label box is destroyed (qdata notify), so
/// consumers never free it, and must not touch it after removing or
/// destroying the page.
pub const TabLabel = struct {
    allocator: std.mem.Allocator,
    host: *TabHost,
    /// The notebook page content this label fronts.
    page: *c.GtkWidget,
    /// The label box (what the notebook shows in the strip). Extra
    /// gestures/targets belong here.
    box: *c.GtkWidget,
    label: *c.GtkLabel,
    title: [160]u8 = undefined,
    title_len: usize = 0,
    dirty: bool = false,

    /// Set the shown title (kept for the dirty-marker re-render).
    pub fn setTitle(self: *TabLabel, title: []const u8) void {
        self.title_len = @min(title.len, self.title.len);
        @memcpy(self.title[0..self.title_len], title[0..self.title_len]);
        self.render();
    }

    /// Subtle unsaved-changes marker: a bullet prefix, Adwaita-style.
    pub fn setDirty(self: *TabLabel, dirty: bool) void {
        if (self.dirty == dirty) return;
        self.dirty = dirty;
        self.render();
    }

    fn render(self: *TabLabel) void {
        var buf: [170:0]u8 = undefined;
        const t = self.title[0..self.title_len];
        const txt = if (self.dirty)
            std.fmt.bufPrintZ(&buf, "\u{2022} {s}", .{t}) catch return
        else
            std.fmt.bufPrintZ(&buf, "{s}", .{t}) catch return;
        c.gtk_label_set_text(self.label, txt.ptr);
    }

    fn freeCb(user: ?*anyopaque) callconv(.c) void {
        const self: *TabLabel = @ptrCast(@alignCast(user.?));
        self.allocator.destroy(self);
    }
};

/// Per-tab context-menu contract. Every hook is optional and a null
/// one simply removes its row — that is how "Close Unmodified Tabs"
/// exists in the editor (documents have unsaved changes) and not in
/// the file browser (listings do not).
///
/// The predicates are asked at POPUP time, never cached: a row whose
/// predicate answers false is built insensitive.
pub const TabMenu = struct {
    /// Domain rows, built into the top of the menu ahead of the
    /// mechanical section. The consumer gets the `Root` so it can
    /// register its own per-row heap contexts with `root.own`.
    extra: ?*const fn (ctx: ?*anyopaque, page: *c.GtkWidget, root: *classicmenu.Root, menu: classicmenu.Menu) void = null,
    /// "Duplicate Tab". No row when null.
    duplicate: ?*const fn (ctx: ?*anyopaque, page: *c.GtkWidget) void = null,
    can_duplicate: ?*const fn (ctx: ?*anyopaque, page: *c.GtkWidget) bool = null,
    /// "Open in New Window". No row when null.
    new_window: ?*const fn (ctx: ?*anyopaque, page: *c.GtkWidget) void = null,
    can_new_window: ?*const fn (ctx: ?*anyopaque, page: *c.GtkWidget) bool = null,
    /// Unsaved-changes predicate. No "Close Unmodified Tabs" row when
    /// null (a host whose tabs cannot be modified).
    modified: ?*const fn (ctx: ?*anyopaque, page: *c.GtkWidget) bool = null,
};

/// Heap context for one popped tab menu; owned by the menu Root, so
/// it dies with the popover (`classicmenu.Root.own`).
const TabMenuCtx = struct {
    allocator: std.mem.Allocator,
    host: *TabHost,
    /// The page the menu was opened ON — not necessarily the current
    /// one (right-clicking an inactive tab acts on that tab).
    page: *c.GtkWidget,

    fn free(user: ?*anyopaque) callconv(.c) void {
        const self: *TabMenuCtx = @ptrCast(@alignCast(user.?));
        self.allocator.destroy(self);
    }
};

pub const TabHost = struct {
    allocator: std.mem.Allocator,
    notebook: *c.GtkNotebook,
    /// Touchpad smooth-scroll accumulator: each ~1.0 of delta moves
    /// exactly one tab (same rule as the terminal tab bar).
    scroll_accum: f64 = 0,
    ctx: ?*anyopaque = null,
    /// Close request for a page (its close button or a middle click
    /// on its label). The consumer owns the actual close.
    on_close: ?*const fn (ctx: ?*anyopaque, page: *c.GtkWidget) void = null,
    /// Double-click on the strip's empty area.
    on_new: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Right-click on the strip's empty area, at notebook-space
    /// coordinates; the consumer builds and pops its own menu.
    on_strip_menu: ?*const fn (ctx: ?*anyopaque, x: f64, y: f64) void = null,
    /// A page was drag-reordered to `new_index` (its new notebook
    /// position). The consumer MUST resync its model list here, or
    /// every "model index == page index" assumption (persistence
    /// order, active-tab index) silently breaks after a drag.
    on_reordered: ?*const fn (ctx: ?*anyopaque, page: *c.GtkWidget, new_index: usize) void = null,
    /// Per-tab context menu. Null = no per-tab menu at all (the
    /// right-click and the Menu key then do nothing).
    tab_menu: ?TabMenu = null,
    /// Event time of the press a TAB's menu just answered. The strip
    /// gesture (on the notebook) can still see that press — its
    /// empty-area hit test picks the tab area's gizmo rather than the
    /// label box when the press lands on a tab's very edge — and would
    /// pop the strip menu ON TOP of the tab menu. Same press, one menu.
    tab_press_time: u32 = 0,

    /// Build the notebook (scrollable strip, expand both ways). The
    /// caller appends `notebook` to its layout and connects any
    /// switch-page handler itself.
    pub fn init(allocator: std.mem.Allocator) TabHost {
        const notebook = c.gtk_notebook_new();
        c.gtk_notebook_set_scrollable(@ptrCast(notebook), 1);
        c.gtk_widget_set_hexpand(notebook, 1);
        c.gtk_widget_set_vexpand(notebook, 1);
        return .{ .allocator = allocator, .notebook = @ptrCast(@alignCast(notebook)) };
    }

    pub fn widget(self: *TabHost) *c.GtkWidget {
        return @ptrCast(@alignCast(self.notebook));
    }

    /// Append `content` as a page with the shared label recipe:
    /// middle-ellipsized title (14..24 chars) + frameless close
    /// button, middle-click close and scroll-to-switch wired. The
    /// page is NOT made current (callers decide).
    pub fn addPage(self: *TabHost, content: *c.GtkWidget, title: []const u8) ?*TabLabel {
        const label = c.gtk_label_new("...");
        c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_MIDDLE);
        // An ellipsizing label reports the ellipsis itself as its
        // minimum width, so without width_chars the notebook collapses
        // every tab to "...". width_chars is the floor it always gets,
        // max_width_chars the ceiling before it ellipsizes.
        c.gtk_label_set_width_chars(@ptrCast(label), 14);
        c.gtk_label_set_max_width_chars(@ptrCast(label), 24);
        const label_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        c.gtk_box_append(@ptrCast(label_box), label);
        const close_btn = c.gtk_button_new_from_icon_name("window-close-symbolic");
        c.gtk_button_set_has_frame(@ptrCast(close_btn), 0);
        c.gtk_box_append(@ptrCast(label_box), close_btn);

        const handle = self.allocator.create(TabLabel) catch return null;
        handle.* = .{
            .allocator = self.allocator,
            .host = self,
            .page = content,
            .box = label_box.?,
            .label = @ptrCast(@alignCast(label)),
        };
        handle.setTitle(title);
        // Freed when the label box dies (page removal / notebook
        // destroy) — consumers never free the handle.
        c.g_object_set_data_full(
            @ptrCast(@alignCast(label_box)),
            "sketerm-tabhandle",
            @ptrCast(handle),
            @ptrCast(&TabLabel.freeCb),
        );
        // The strip gestures below hit-test against this mark to tell
        // "on a tab" from "on the strip's empty space".
        c.g_object_set_data(@ptrCast(@alignCast(label_box)), "sketerm-tablabel", @ptrCast(label_box));

        _ = c.g_signal_connect_data(close_btn, "clicked", @ptrCast(&onCloseClicked), @ptrCast(handle), null, c.G_CONNECT_DEFAULT);

        const mclick = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(mclick), c.GDK_BUTTON_MIDDLE);
        _ = c.g_signal_connect_data(mclick, "pressed", @ptrCast(&onMiddleClick), @ptrCast(handle), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(label_box, @ptrCast(mclick));

        // Scroll on a tab label switches tabs, like the main terminal
        // tab bar. CAPTURE so the notebook's own strip panning never
        // eats the event first.
        const scr = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
        c.gtk_event_controller_set_propagation_phase(@ptrCast(scr), c.GTK_PHASE_CAPTURE);
        _ = c.g_signal_connect_data(scr, "scroll", @ptrCast(&onStripScroll), @ptrCast(handle), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(label_box, @ptrCast(scr));

        // Per-tab context menu (shared rows + the consumer's own).
        // Installed unconditionally: `tab_menu` is read at popup time,
        // so a consumer may set it after its first page exists.
        const rclick = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(rclick), 3);
        _ = c.g_signal_connect_data(rclick, "pressed", @ptrCast(&onTabRightClick), @ptrCast(handle), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(label_box, @ptrCast(rclick));

        _ = c.gtk_notebook_append_page(self.notebook, content, label_box);
        c.gtk_notebook_set_tab_reorderable(self.notebook, content, 1);
        return handle;
    }

    /// Remove a page (its handle is freed with the label widgets).
    pub fn removePage(self: *TabHost, page: *c.GtkWidget) void {
        const idx = c.gtk_notebook_page_num(self.notebook, page);
        if (idx >= 0) c.gtk_notebook_remove_page(self.notebook, idx);
    }

    pub fn setCurrentPage(self: *TabHost, page: *c.GtkWidget) void {
        const idx = c.gtk_notebook_page_num(self.notebook, page);
        if (idx >= 0) c.gtk_notebook_set_current_page(self.notebook, idx);
    }

    /// The widget of the current page, if any.
    pub fn currentPage(self: *TabHost) ?*c.GtkWidget {
        const idx = c.gtk_notebook_get_current_page(self.notebook);
        if (idx < 0) return null;
        return c.gtk_notebook_get_nth_page(self.notebook, idx);
    }

    pub fn pageCount(self: *TabHost) usize {
        const n = c.gtk_notebook_get_n_pages(self.notebook);
        return if (n > 0) @intCast(n) else 0;
    }

    /// Page at `idx`, or null past the end.
    pub fn pageAt(self: *TabHost, idx: usize) ?*c.GtkWidget {
        if (idx >= self.pageCount()) return null;
        return c.gtk_notebook_get_nth_page(self.notebook, @intCast(idx));
    }

    fn pageIndex(self: *TabHost, page: *c.GtkWidget) ?usize {
        const idx = c.gtk_notebook_page_num(self.notebook, page);
        return if (idx < 0) null else @intCast(idx);
    }

    /// Wire the strip's empty-area gestures (right-click for the
    /// consumer's menu, double-click for a new tab) and the
    /// page-reordered relay. Install once, after the callbacks are
    /// set and the host struct sits at its stable address.
    pub fn installStripGestures(self: *TabHost) void {
        const nb: *c.GtkWidget = self.widget();
        _ = c.g_signal_connect_data(nb, "page-reordered", @ptrCast(&onPageReordered), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        const rclick = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(rclick), 3);
        _ = c.g_signal_connect_data(rclick, "pressed", @ptrCast(&onStripRightClick), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(nb, @ptrCast(rclick));
        const dclick = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(dclick), c.GDK_BUTTON_PRIMARY);
        _ = c.g_signal_connect_data(dclick, "pressed", @ptrCast(&onStripDoubleClick), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(nb, @ptrCast(dclick));
        // Keyboard parity for the per-tab menu. The controller sits on
        // the NOTEBOOK, not on the label boxes: GtkNotebook focuses its
        // own per-tab gizmo (the label box's PARENT), so a controller
        // on the label would never see the key. Bubble phase, and only
        // while focus is actually in the tab strip, so a page's own
        // content keeps every Menu press it wants.
        const keys = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onStripKey), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(nb, @ptrCast(keys));
    }

    /// GtkNotebook "page-reordered": relay a drag reorder to the
    /// consumer so its model list can follow the widget order.
    fn onPageReordered(_: *c.GtkNotebook, child: *c.GtkWidget, page_num: c.guint, user: ?*anyopaque) callconv(.c) void {
        const self: *TabHost = @ptrCast(@alignCast(user.?));
        const cb = self.on_reordered orelse return;
        cb(self.ctx, child, @intCast(page_num));
    }

    // -- per-tab context menu -----------------------------------------

    /// The page whose tab label currently holds focus, or null when
    /// focus is anywhere else (page content, another widget).
    fn focusedStripPage(self: *TabHost) ?*c.GtkWidget {
        const root = c.gtk_widget_get_root(self.widget()) orelse return null;
        const focus = c.gtk_root_get_focus(@ptrCast(root)) orelse return null;
        var i: usize = 0;
        while (self.pageAt(i)) |page| : (i += 1) {
            const label = c.gtk_notebook_get_tab_label(self.notebook, page) orelse continue;
            if (label == focus) return page;
            // The focused widget is the notebook's tab gizmo, i.e. an
            // ANCESTOR of our label box; a theme could equally focus
            // something inside it, so both directions count.
            if (c.gtk_widget_is_ancestor(label, focus) != 0) return page;
            if (c.gtk_widget_is_ancestor(focus, label) != 0) return page;
        }
        return null;
    }

    /// Menu key / Shift+F10 on the tab strip: the same menu the
    /// right-click builds, anchored at the focused tab's label.
    fn onStripKey(
        _: *c.GtkEventControllerKey,
        keyval: c.guint,
        _: c.guint,
        state: c.GdkModifierType,
        user: ?*anyopaque,
    ) callconv(.c) c.gboolean {
        const self: *TabHost = @ptrCast(@alignCast(user.?));
        const wanted = keyval == c.GDK_KEY_Menu or
            (keyval == c.GDK_KEY_F10 and (state & c.GDK_SHIFT_MASK) != 0);
        if (!wanted) return 0;
        const page = self.focusedStripPage() orelse return 0;
        const label = c.gtk_notebook_get_tab_label(self.notebook, page) orelse return 0;
        // Anchor under the label's bottom-left corner, the same place a
        // right-click near the label's start would put it.
        const x: f64 = @floatFromInt(@divTrunc(c.gtk_widget_get_width(label), 2));
        const y: f64 = @floatFromInt(c.gtk_widget_get_height(label));
        return @intFromBool(self.showTabMenu(page, label, x, y));
    }

    /// Build and pop the per-tab menu for `page`. `(x, y)` are in
    /// `anchor`'s coordinates; the popover itself is parented to the
    /// NOTEBOOK, so closing the tab it acts on cannot destroy its
    /// parent mid-handler.
    ///
    /// @return false when no per-tab menu is configured.
    pub fn showTabMenu(self: *TabHost, page: *c.GtkWidget, anchor: *c.GtkWidget, x: f64, y: f64) bool {
        const spec = self.tab_menu orelse return false;
        const idx = self.pageIndex(page) orelse return false;
        const total = self.pageCount();

        const ctx = self.allocator.create(TabMenuCtx) catch return false;
        ctx.* = .{ .allocator = self.allocator, .host = self, .page = page };
        const root = classicmenu.Root.create(self.allocator) orelse {
            self.allocator.destroy(ctx);
            return false;
        };
        root.own(&TabMenuCtx.free, @ptrCast(ctx));

        const m = root.top();
        if (spec.extra) |f| f(self.ctx, page, root, m);

        const tools = m.section();
        if (spec.duplicate != null) {
            const ok = if (spec.can_duplicate) |p| p(self.ctx, page) else true;
            tools.itemIconEnabled("Duplicate Tab", .{ .name = "edit-copy-symbolic" }, ok, &onMenuDuplicate, @ptrCast(ctx));
        }
        if (spec.new_window != null) {
            const ok = if (spec.can_new_window) |p| p(self.ctx, page) else true;
            tools.itemIconEnabled("Open in New Window", .{ .name = "window-new-symbolic" }, ok, &onMenuNewWindow, @ptrCast(ctx));
        }

        const closes = m.section();
        closes.itemIcon("Close Tab", .{ .name = "window-close-symbolic" }, &onMenuClose, @ptrCast(ctx));
        closes.itemIconEnabled("Close Other Tabs", .none, total > 1, &onMenuCloseOthers, @ptrCast(ctx));
        closes.itemIconEnabled("Close Tabs to the Right", .none, idx + 1 < total, &onMenuCloseRight, @ptrCast(ctx));
        if (spec.modified) |is_dirty| {
            var closable: usize = 0;
            var i: usize = 0;
            while (self.pageAt(i)) |p| : (i += 1) {
                if (!is_dirty(self.ctx, p)) closable += 1;
            }
            closes.itemIconEnabled("Close Unmodified Tabs", .none, closable > 0, &onMenuCloseUnmodified, @ptrCast(ctx));
        }

        const pop = root.popupVia(anchor, self.widget(), x, y);
        // Focus return, ui/menu.zig's rule reused verbatim: a menu
        // opened from the keyboard would otherwise strand focus in a
        // dead popover, while a row that opens a dialog must keep the
        // focus it just took.
        _ = c.g_signal_connect_data(pop, "closed", @ptrCast(&onTabMenuClosed), @ptrCast(self.widget()), null, c.G_CONNECT_DEFAULT);
        return true;
    }

    fn onTabMenuClosed(pop: *c.GtkPopover, user: ?*anyopaque) callconv(.c) void {
        const nb: *c.GtkWidget = @ptrCast(@alignCast(user.?));
        @import("menu.zig").returnFocusTo(nb, @ptrCast(pop));
    }

    /// Close every page the predicate selects. The page list is
    /// snapshotted FIRST: `on_close` destroys that page's widget tree
    /// (and may raise a dialog), so walking the live notebook while it
    /// is being torn down is not safe. The pages that are NOT being
    /// closed keep their pointers, which is what makes the snapshot
    /// valid for the whole loop.
    fn closeMatching(
        self: *TabHost,
        keep: *c.GtkWidget,
        want: *const fn (self: *TabHost, page: *c.GtkWidget, keep: *c.GtkWidget) bool,
    ) void {
        const cb = self.on_close orelse return;
        var pages: std.ArrayList(*c.GtkWidget) = .empty;
        defer pages.deinit(self.allocator);
        var i: usize = 0;
        while (self.pageAt(i)) |p| : (i += 1) {
            if (want(self, p, keep)) pages.append(self.allocator, p) catch return;
        }
        for (pages.items) |p| cb(self.ctx, p);
    }

    fn wantOthers(_: *TabHost, page: *c.GtkWidget, keep: *c.GtkWidget) bool {
        return page != keep;
    }

    fn wantRight(self: *TabHost, page: *c.GtkWidget, keep: *c.GtkWidget) bool {
        const at = self.pageIndex(page) orelse return false;
        const pivot = self.pageIndex(keep) orelse return false;
        return at > pivot;
    }

    fn wantUnmodified(self: *TabHost, page: *c.GtkWidget, _: *c.GtkWidget) bool {
        const spec = self.tab_menu orelse return false;
        const is_dirty = spec.modified orelse return false;
        return !is_dirty(self.ctx, page);
    }

    fn onTabRightClick(gesture: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const handle: *TabLabel = @ptrCast(@alignCast(user.?));
        const host = handle.host;
        if (host.tab_menu == null) return;
        // Claim before popping up: an unclaimed release dismisses the
        // popover the frame it maps (ui/menu.zig documents the race).
        _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_CLAIMED);
        host.tab_press_time = c.gtk_event_controller_get_current_event_time(@ptrCast(gesture));
        _ = host.showTabMenu(handle.page, handle.box, x, y);
    }

    fn onMenuClose(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const ctx: *TabMenuCtx = @ptrCast(@alignCast(user.?));
        const cb = ctx.host.on_close orelse return;
        cb(ctx.host.ctx, ctx.page);
    }

    fn onMenuCloseOthers(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const ctx: *TabMenuCtx = @ptrCast(@alignCast(user.?));
        ctx.host.closeMatching(ctx.page, &wantOthers);
    }

    fn onMenuCloseRight(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const ctx: *TabMenuCtx = @ptrCast(@alignCast(user.?));
        ctx.host.closeMatching(ctx.page, &wantRight);
    }

    fn onMenuCloseUnmodified(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const ctx: *TabMenuCtx = @ptrCast(@alignCast(user.?));
        ctx.host.closeMatching(ctx.page, &wantUnmodified);
    }

    fn onMenuDuplicate(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const ctx: *TabMenuCtx = @ptrCast(@alignCast(user.?));
        const spec = ctx.host.tab_menu orelse return;
        const f = spec.duplicate orelse return;
        f(ctx.host.ctx, ctx.page);
    }

    fn onMenuNewWindow(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const ctx: *TabMenuCtx = @ptrCast(@alignCast(user.?));
        const spec = ctx.host.tab_menu orelse return;
        const f = spec.new_window orelse return;
        f(ctx.host.ctx, ctx.page);
    }

    /// Was this notebook-space click on the strip's EMPTY area? False
    /// for clicks on a tab label (their own gestures handle those) and
    /// for clicks below the strip (the page content).
    fn onStripEmpty(self: *TabHost, x: f64, y: f64) bool {
        const nb: *c.GtkWidget = self.widget();
        // The strip's height comes from any tab label's bounds;
        // without a page there is no strip at all.
        const page = c.gtk_notebook_get_nth_page(self.notebook, 0) orelse return false;
        const label = c.gtk_notebook_get_tab_label(self.notebook, page) orelse return false;
        var bounds: c.graphene_rect_t = undefined;
        if (c.gtk_widget_compute_bounds(label, nb, &bounds) == 0) return false;
        if (y > bounds.origin.y + bounds.size.height + 6) return false;
        // On a tab? Walk the picked widget's ancestry for a label mark.
        var w = c.gtk_widget_pick(nb, x, y, c.GTK_PICK_DEFAULT);
        while (w) |cur| : (w = c.gtk_widget_get_parent(cur)) {
            if (cur == nb) break;
            if (c.g_object_get_data(@ptrCast(@alignCast(cur)), "sketerm-tablabel") != null) return false;
        }
        return true;
    }

    fn onCloseClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const handle: *TabLabel = @ptrCast(@alignCast(user.?));
        const host = handle.host;
        if (host.on_close) |cb| cb(host.ctx, handle.page);
    }

    fn onMiddleClick(_: *c.GtkGestureClick, _: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
        const handle: *TabLabel = @ptrCast(@alignCast(user.?));
        const host = handle.host;
        if (host.on_close) |cb| cb(host.ctx, handle.page);
    }

    /// Scroll over the tab strip: down/right = next tab, up/left =
    /// previous. Touchpad smooth-scroll bursts accumulate so each
    /// ~1.0 of delta moves exactly one tab.
    fn onStripScroll(_: *c.GtkEventControllerScroll, dx: f64, dy: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const handle: *TabLabel = @ptrCast(@alignCast(user.?));
        const host = handle.host;
        const delta = if (dy != 0) dy else dx;
        if (delta == 0) return 0;
        host.scroll_accum += delta;
        const nb = host.notebook;
        while (host.scroll_accum >= 1.0) : (host.scroll_accum -= 1.0) _ = c.gtk_notebook_next_page(nb);
        while (host.scroll_accum <= -1.0) : (host.scroll_accum += 1.0) _ = c.gtk_notebook_prev_page(nb);
        return 1;
    }

    fn onStripRightClick(gesture: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const self: *TabHost = @ptrCast(@alignCast(user.?));
        // A tab's own menu already answered this press.
        const when = c.gtk_event_controller_get_current_event_time(@ptrCast(gesture));
        if (when != 0 and when == self.tab_press_time) return;
        if (!self.onStripEmpty(x, y)) return;
        const cb = self.on_strip_menu orelse return;
        _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_CLAIMED);
        cb(self.ctx, x, y);
    }

    fn onStripDoubleClick(gesture: *c.GtkGestureClick, n_press: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        if (n_press != 2) return;
        const self: *TabHost = @ptrCast(@alignCast(user.?));
        if (!self.onStripEmpty(x, y)) return;
        const cb = self.on_new orelse return;
        _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_CLAIMED);
        cb(self.ctx);
    }
};
