//! Shared GtkNotebook tab-strip mechanics, extracted from the file
//! browser so the editor face can reuse them: notebook creation,
//! the ellipsized tab label + close button recipe, middle-click
//! close, scroll-to-switch with a touchpad accumulator, and the
//! strip's empty-area gestures (double-click = new tab, right-click
//! = consumer-provided menu).
//!
//! Consumers keep everything domain-specific (context menus, DnD
//! targets, closed-tab rings) layered on the returned TabLabel's
//! `box`. The host struct's address must be stable for the lifetime
//! of the notebook widgets (gesture callbacks hold it raw).

const std = @import("std");
const c = @import("../c.zig").c;

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

        _ = c.gtk_notebook_append_page(self.notebook, content, label_box);
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

    /// Wire the strip's empty-area gestures: right-click for the
    /// consumer's menu, double-click for a new tab. Install once,
    /// after the callbacks are set.
    pub fn installStripGestures(self: *TabHost) void {
        const nb: *c.GtkWidget = self.widget();
        const rclick = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(rclick), 3);
        _ = c.g_signal_connect_data(rclick, "pressed", @ptrCast(&onStripRightClick), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(nb, @ptrCast(rclick));
        const dclick = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(dclick), c.GDK_BUTTON_PRIMARY);
        _ = c.g_signal_connect_data(dclick, "pressed", @ptrCast(&onStripDoubleClick), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(nb, @ptrCast(dclick));
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
