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
const PIN_W: c_int = 56;
/// Activity glow lifetime: full at the moment of activity, gone after
/// this many microseconds of silence.
const GLOW_DECAY_US: f64 = 1_300_000;
/// One full left-to-right rainbow sweep, in microseconds.
const SWEEP_US: f64 = 1_400_000;
const ACTIVITY_KEY = "sketerm-tab-activity-us";

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
/// Saved GtkBox snapshot vfunc, chained to before drawing the glow.
var orig_tab_snapshot: ?*const fn (widget: [*c]c.GtkWidget, snapshot: ?*c.GtkSnapshot) callconv(.c) void = null;

fn tabClassInit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const wc: *c.GtkWidgetClass = @ptrCast(@alignCast(klass));
    c.gtk_widget_class_set_css_name(wc, "tab");
    // Draw the activity glow ourselves, after the normal tab content.
    orig_tab_snapshot = wc.snapshot;
    wc.snapshot = tabSnapshot;
}

/// Tab `snapshot`: draw the tab normally, then the rainbow activity glow
/// on top (full widget size — no fragile overlay sizing).
fn tabSnapshot(widget: [*c]c.GtkWidget, snapshot: ?*c.GtkSnapshot) callconv(.c) void {
    if (orig_tab_snapshot) |f| f(widget, snapshot);
    const data = c.g_object_get_data(@ptrCast(@alignCast(widget)), "sketerm-tab") orelse return;
    const t: *TabBar.Tab = @ptrCast(@alignCast(data));
    if (c.adw_tab_view_get_selected_page(t.bar.view) == @as(?*c.AdwTabPage, t.page)) return;
    const intensity = activityIntensity(t.page);
    if (intensity <= 0.01) return;

    const w: f64 = @floatFromInt(c.gtk_widget_get_width(@ptrCast(widget)));
    const h: f64 = @floatFromInt(c.gtk_widget_get_height(@ptrCast(widget)));
    var rect: c.graphene_rect_t = undefined;
    _ = c.graphene_rect_init(&rect, 0, 0, @floatCast(w), @floatCast(h));
    const cr = c.gtk_snapshot_append_cairo(snapshot, &rect) orelse return;
    const phase = nowPhase();
    if (makeRainbow(0, w, 0.16 * intensity, phase)) |glow| {
        defer c.cairo_pattern_destroy(glow);
        c.cairo_set_source(cr, glow);
        c.cairo_rectangle(cr, 0, h - 12, w, 12);
        c.cairo_fill(cr);
    }
    if (makeRainbow(0, w, 0.92 * intensity, phase)) |bar| {
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
    c.gtk_widget_class_set_css_name(@ptrCast(@alignCast(klass)), "tabbox");
}
fn tabboxchildClassInit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    c.gtk_widget_class_set_css_name(@ptrCast(@alignCast(klass)), "tabboxchild");
}
fn registerTypes() void {
    if (tab_gtype != 0) return;
    tab_gtype = c.g_type_register_static_simple(c.gtk_box_get_type(), "SketermTab", @sizeOf(c.GtkBoxClass), tabClassInit, @sizeOf(c.GtkBox), null, c.G_TYPE_FLAG_NONE);
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
        title_handler: c.gulong = 0,
        icon_handler: c.gulong = 0,
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

        // Accept dropped tabs anywhere on the strip (reorder / transfer).
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
        c.gtk_widget_set_hexpand(child, 1);

        // Real `tab` node (so the theme styles it), mirroring
        // adw-tab.ui: icon | title | close button.
        const tab_box = newNode(tab_gtype);
        c.gtk_widget_set_hexpand(tab_box, 1);
        c.gtk_widget_set_size_request(tab_box, if (pinned) PIN_W else 0, -1);
        c.gtk_box_append(@ptrCast(child), tab_box);

        // Colour swatch (page icon) — margins per adw-tab.ui.
        const icon = c.gtk_image_new_from_gicon(c.adw_tab_page_get_icon(page));
        c.gtk_widget_set_margin_start(icon, 4);
        c.gtk_widget_set_margin_end(icon, 2);
        c.gtk_widget_set_visible(icon, @intFromBool(c.adw_tab_page_get_icon(page) != null));
        c.gtk_box_append(@ptrCast(tab_box), icon);

        // Title — centred, ellipsized, expands to fill (native tabs
        // share the bar and shrink as more are added).
        const label = c.gtk_label_new(c.adw_tab_page_get_title(page));
        c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
        c.gtk_label_set_xalign(@ptrCast(label), 0.5);
        c.gtk_widget_set_margin_start(label, 4);
        c.gtk_widget_set_margin_end(label, 4);
        c.gtk_widget_set_hexpand(label, 1);
        c.gtk_widget_add_css_class(label, "tab-title");
        c.gtk_box_append(@ptrCast(tab_box), label);

        // Close — flat button, revealed on hover (CSS), like the native one.
        if (!pinned) {
            const close = c.gtk_button_new_from_icon_name("window-close-symbolic");
            c.gtk_button_set_has_frame(@ptrCast(close), 0);
            c.gtk_widget_add_css_class(close, "flat");
            c.gtk_widget_add_css_class(close, "tab-close-button");
            c.gtk_widget_set_valign(close, c.GTK_ALIGN_CENTER);
            _ = c.g_signal_connect_data(close, "clicked", @ptrCast(&onClose), t, null, c.G_CONNECT_DEFAULT);
            c.gtk_box_append(@ptrCast(tab_box), close);
        }

        t.* = .{
            .bar = self,
            .page = page,
            .child = @ptrCast(child),
            .tab_box = @ptrCast(tab_box),
            .label = @ptrCast(label),
            .icon = @ptrCast(icon),
        };
        // The tab's snapshot vfunc finds its Tab here to draw the glow.
        c.g_object_set_data(@ptrCast(@alignCast(tab_box)), "sketerm-tab", t);

        // Select on press (body); middle-click closes.
        const click = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(click), 0);
        _ = c.g_signal_connect_data(click, "pressed", @ptrCast(&onPressed), t, null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(tab_box, @ptrCast(@alignCast(click)));

        // Drag source for reorder / transfer / detach.
        const drag = c.gtk_drag_source_new();
        c.gtk_drag_source_set_actions(@ptrCast(drag), c.GDK_ACTION_MOVE);
        _ = c.g_signal_connect_data(drag, "prepare", @ptrCast(&onDragPrepare), t, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(drag, "drag-cancel", @ptrCast(&onDragCancel), t, null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(tab_box, @ptrCast(@alignCast(drag)));

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

fn onPressed(gesture: ?*anyopaque, _: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    const t = cast.userData(TabBar.Tab, user);
    const button = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
    if (button == 1) {
        c.adw_tab_view_set_selected_page(t.bar.view, t.page);
    } else if (button == 2) {
        _ = c.adw_tab_view_close_page(t.bar.view, t.page);
    }
}

fn onClose(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const t = cast.userData(TabBar.Tab, user);
    _ = c.adw_tab_view_close_page(t.bar.view, t.page);
}

/// Glow tick: redraw glows; stop once nothing is active.
fn onTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(TabBar, user);
    var any_active = false;
    for (self.tabs.items) |t| {
        const sel = c.adw_tab_view_get_selected_page(self.view) == @as(?*c.AdwTabPage, t.page);
        if (!sel and activityIntensity(t.page) > 0.01) any_active = true;
        c.gtk_widget_queue_draw(t.tab_box);
    }
    if (!any_active) {
        self.tick_id = 0;
        return 0;
    }
    return 1;
}

// ── drag and drop ────────────────────────────────────────────────────

fn onDragPrepare(_: ?*anyopaque, _: f64, _: f64, user: ?*anyopaque) callconv(.c) ?*c.GdkContentProvider {
    dragged = cast.userData(TabBar.Tab, user);
    return c.gdk_content_provider_new_typed(c.G_TYPE_INT, @as(c_int, 1));
}

fn onDragCancel(_: ?*anyopaque, _: ?*anyopaque, reason: c_int, user: ?*anyopaque) callconv(.c) c.gboolean {
    const t = cast.userData(TabBar.Tab, user);
    defer dragged = null;
    if (reason == c.GDK_DRAG_CANCEL_NO_TARGET) {
        if (t.bar.on_detach) |f| f(t.bar.detach_ctx, t.bar.view, t.page);
        return 1;
    }
    return 0;
}

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

fn activityIntensity(page: *c.AdwTabPage) f64 {
    const data = c.g_object_get_data(@ptrCast(@alignCast(page)), ACTIVITY_KEY) orelse return 0;
    const ts: i64 = @bitCast(@as(u64, @intFromPtr(data)));
    const now = c.g_get_monotonic_time();
    const elapsed: f64 = @floatFromInt(now - ts);
    if (elapsed <= 0) return 1.0;
    if (elapsed >= GLOW_DECAY_US) return 0;
    return 1.0 - elapsed / GLOW_DECAY_US;
}

fn nowPhase() f64 {
    const us: f64 = @floatFromInt(c.g_get_monotonic_time());
    return @mod(us / SWEEP_US, 1.0);
}

fn makeRainbow(x0: f64, x1: f64, alpha: f64, phase: f64) ?*c.cairo_pattern_t {
    const pat = c.cairo_pattern_create_linear(x0, 0, x1, 0) orelse return null;
    const N: usize = 8;
    var k: usize = 0;
    while (k <= N) : (k += 1) {
        const pos = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(N));
        var hue = pos + phase;
        hue -= @floor(hue);
        const rgb = hsv2rgb(hue, 0.9, 1.0);
        c.cairo_pattern_add_color_stop_rgba(pat, pos, rgb[0], rgb[1], rgb[2], alpha);
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
