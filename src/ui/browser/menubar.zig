//! Classic menu bar for the files-mode window (Nemo's shape): File,
//! Edit, View, Go, Bookmarks, Help. Each menu is built FRESH on click
//! from the active browser view's state (check marks, bookmark list),
//! using the classicmenu popover machinery the context menus already
//! use, so the rows look and behave identically everywhere.

const std = @import("std");
const c = @import("../../c.zig").c;
const build_options = @import("build_options");
const version = @import("../../version.zig");
const places_mod = @import("../../filebrowser/places.zig");
const browser_model = @import("../../filebrowser/model.zig");

const Window = @import("../window.zig").Window;
const Pane = @import("../pane.zig").Pane;
const BrowserView = @import("view.zig").BrowserView;
const classicmenu = @import("classicmenu.zig");
const ops = @import("ops.zig");
const places_ui = @import("places.zig");

/// One top-level menu button's ctx (lives as long as the window).
const BarCtx = struct {
    allocator: std.mem.Allocator,
    win: *Window,
    state: *BarState,
    which: Which,

    const Which = enum { file, edit, view, go, bookmarks, help };

    fn free(user: ?*anyopaque) callconv(.c) void {
        const ctx: *BarCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.destroy(ctx);
    }
};

const BarState = struct {
    allocator: std.mem.Allocator,
    bar: ?*c.GtkWidget,
    active_button: ?*c.GtkWidget = null,
    active_popover: ?*c.GtkWidget = null,
    target_pane: ?*Pane = null,

    fn free(user: ?*anyopaque) callconv(.c) void {
        const self: *BarState = @ptrCast(@alignCast(user.?));
        self.allocator.destroy(self);
    }
};

/// Build the menu bar row. `win` may still be mid-init: the pointer is
/// only stored, never dereferenced until a menu opens.
var css_installed = false;

fn installCss(any_widget: *c.GtkWidget) void {
    if (css_installed) return;
    css_installed = true;
    const css =
        \\box.sketerm-fb-menubar > button {
        \\  padding: 2px 10px;
        \\  min-height: 0;
        \\  border-radius: 4px;
        \\}
        \\box.sketerm-fb-menubar > button:selected {
        \\  background-color: alpha(@theme_selected_bg_color, 0.18);
        \\  box-shadow: inset 0 -3px 0 @theme_selected_bg_color;
        \\}
    ;
    const provider = c.gtk_css_provider_new();
    c.gtk_css_provider_load_from_string(provider, css);
    const display = c.gtk_widget_get_display(any_widget);
    c.gtk_style_context_add_provider_for_display(display, @ptrCast(@alignCast(provider)), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

pub fn build(allocator: std.mem.Allocator, win: *Window, app_window: *c.GtkWidget) *c.GtkWidget {
    const bar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    c.gtk_widget_add_css_class(bar, "sketerm-fb-menubar");
    installCss(bar);
    const state = allocator.create(BarState) catch return bar;
    state.* = .{ .allocator = allocator, .bar = bar };
    c.g_object_set_data_full(@ptrCast(app_window), "sketerm-fb-menubar-state", @ptrCast(state), @ptrCast(&BarState.free));
    _ = c.g_signal_connect_data(bar, "destroy", @ptrCast(&onBarDestroyed), @ptrCast(state), null, c.G_CONNECT_DEFAULT);
    const entries = [_]struct { label: [*:0]const u8, which: BarCtx.Which }{
        .{ .label = "File", .which = .file },
        .{ .label = "Edit", .which = .edit },
        .{ .label = "View", .which = .view },
        .{ .label = "Go", .which = .go },
        .{ .label = "Bookmarks", .which = .bookmarks },
        .{ .label = "Help", .which = .help },
    };
    for (entries) |e| {
        const btn = c.gtk_button_new_with_label(e.label);
        c.gtk_button_set_has_frame(@ptrCast(btn), 0);
        c.gtk_widget_set_can_focus(btn, 0);
        c.gtk_widget_add_css_class(btn, "flat");
        const ctx = allocator.create(BarCtx) catch continue;
        ctx.* = .{ .allocator = allocator, .win = win, .state = state, .which = e.which };
        c.g_object_set_data_full(@ptrCast(btn), "sketerm-fb-menubar-ctx", @ptrCast(ctx), @ptrCast(&BarCtx.free));
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onMenuButton), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), btn);
    }
    const motion = c.gtk_event_controller_motion_new();
    c.gtk_event_controller_set_propagation_phase(@ptrCast(motion), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(motion, "motion", @ptrCast(&onBarMotion), @ptrCast(state), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(bar, @ptrCast(motion));
    const keys = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(@ptrCast(keys), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onBarKey), @ptrCast(state), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(app_window, @ptrCast(keys));
    return bar;
}

/// The browser view menu verbs act on: the focused pane's, else the
/// first pane that wears one.
fn activeBrowser(win: *Window) ?*BrowserView {
    if (win.focusedPane()) |pane| {
        if (BrowserView.fromPane(pane)) |bv| return bv;
    }
    for (win.panes.items) |pane| {
        if (BrowserView.fromPane(pane)) |bv| return bv;
    }
    return null;
}

fn browserPane(win: *Window, browser: ?*BrowserView) ?*Pane {
    const bv = browser orelse return null;
    for (win.panes.items) |pane| {
        if (pane == bv.pane) return pane;
    }
    return null;
}

fn targetBrowser(win: *Window, target: ?*Pane) ?*BrowserView {
    const wanted = target orelse return null;
    for (win.panes.items) |pane| {
        if (pane == wanted) return BrowserView.fromPane(pane);
    }
    return null;
}

/// Per-item ctx: window + verb id (+ an owned spec for bookmarks).
const ItemCtx = struct {
    allocator: std.mem.Allocator,
    win: *Window,
    target_pane: ?*Pane,
    verb: Verb,
    spec: []u8 = &.{},

    const Verb = enum {
        new_tab,
        new_window,
        split_pane,
        close_pane,
        close_window,
        cut,
        copy,
        paste,
        select_all,
        invert_selection,
        prefs,
        reload,
        toggle_hidden,
        toggle_sidebar,
        mode_details,
        mode_compact,
        mode_icons,
        mode_miller,
        back,
        forward,
        up,
        home,
        trash,
        add_bookmark,
        open_bookmark,
        about,
    };

    fn make(root: *classicmenu.Root, allocator: std.mem.Allocator, win: *Window, target_pane: ?*Pane, verb: Verb, spec: []const u8) ?*ItemCtx {
        const ctx = allocator.create(ItemCtx) catch return null;
        ctx.* = .{
            .allocator = allocator,
            .win = win,
            .target_pane = target_pane,
            .verb = verb,
            .spec = allocator.dupe(u8, spec) catch &.{},
        };
        root.own(&ItemCtx.free, @ptrCast(ctx));
        return ctx;
    }

    fn free(user: ?*anyopaque) callconv(.c) void {
        const ctx: *ItemCtx = @ptrCast(@alignCast(user.?));
        if (ctx.spec.len > 0) ctx.allocator.free(ctx.spec);
        ctx.allocator.destroy(ctx);
    }
};

fn onMenuButton(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *BarCtx = @ptrCast(@alignCast(user.?));
    const button: *c.GtkWidget = @ptrCast(@alignCast(btn));
    if (ctx.state.active_button == button) {
        closeActive(ctx.state, true);
        return;
    }
    switchMenu(ctx, button);
}

fn onBarMotion(_: *c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const state: *BarState = @ptrCast(@alignCast(user.?));
    if (state.active_popover == null) return;
    switchAtPoint(state, .{ .x = @floatCast(x), .y = @floatCast(y) });
}

fn onPopoverMotion(controller: *c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const state: *BarState = @ptrCast(@alignCast(user.?));
    const pop = c.gtk_event_controller_get_widget(@ptrCast(controller)) orelse return;
    const bar = state.bar orelse return;
    var source = c.graphene_point_t{ .x = @floatCast(x), .y = @floatCast(y) };
    var point: c.graphene_point_t = undefined;
    if (c.gtk_widget_compute_point(pop, bar, &source, &point) == 0) return;
    switchAtPoint(state, point);
}

fn switchAtPoint(state: *BarState, point: c.graphene_point_t) void {
    const bar = state.bar orelse return;
    var child = c.gtk_widget_get_first_child(bar);
    while (child) |button| : (child = c.gtk_widget_get_next_sibling(button)) {
        var bounds: c.graphene_rect_t = undefined;
        if (c.gtk_widget_compute_bounds(button, bar, &bounds) == 0 or
            !c.graphene_rect_contains_point(&bounds, &point)) continue;
        if (button == state.active_button) return;
        const data = c.g_object_get_data(@ptrCast(@alignCast(button)), "sketerm-fb-menubar-ctx") orelse return;
        switchMenu(@ptrCast(@alignCast(data)), button);
        return;
    }
}

fn onBarKey(_: *c.GtkEventControllerKey, keyval: c.guint, _: c.guint, _: c.GdkModifierType, user: ?*anyopaque) callconv(.c) c.gboolean {
    const state: *BarState = @ptrCast(@alignCast(user.?));
    if (keyval == c.GDK_KEY_F10) {
        if (state.active_popover != null) {
            closeActive(state, true);
        } else if (state.bar) |bar| if (c.gtk_widget_get_first_child(bar)) |first| {
            openButton(state, first, true);
        };
        return 1;
    }
    if (state.active_popover == null) return 0;
    switch (keyval) {
        c.GDK_KEY_Escape => closeActive(state, true),
        c.GDK_KEY_Left => switchAdjacent(state, false),
        c.GDK_KEY_Right => switchAdjacent(state, true),
        else => return 0,
    }
    return 1;
}

fn closeActive(state: *BarState, clear_target: bool) void {
    const button = state.active_button;
    const popover = state.active_popover;
    state.active_button = null;
    state.active_popover = null;
    if (clear_target) state.target_pane = null;
    if (button) |b| c.gtk_widget_unset_state_flags(b, c.GTK_STATE_FLAG_SELECTED);
    if (popover) |p| c.gtk_popover_popdown(@ptrCast(p));
}

fn switchMenu(ctx: *BarCtx, button: *c.GtkWidget) void {
    const had_menu = ctx.state.active_popover != null;
    if (!had_menu) ctx.state.target_pane = browserPane(ctx.win, activeBrowser(ctx.win));
    closeActive(ctx.state, false);
    const pop = openMenu(@ptrCast(@alignCast(button)), ctx) orelse return;
    ctx.state.active_button = button;
    ctx.state.active_popover = pop;
    c.gtk_widget_set_state_flags(button, c.GTK_STATE_FLAG_SELECTED, 0);
    _ = c.g_signal_connect_data(pop, "closed", @ptrCast(&onMenuClosed), @ptrCast(ctx.state), null, c.G_CONNECT_DEFAULT);
    const motion = c.gtk_event_controller_motion_new();
    c.gtk_event_controller_set_propagation_phase(@ptrCast(motion), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(motion, "motion", @ptrCast(&onPopoverMotion), @ptrCast(ctx.state), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(pop, @ptrCast(motion));
}

fn openButton(state: *BarState, button: *c.GtkWidget, focus_item: bool) void {
    const data = c.g_object_get_data(@ptrCast(@alignCast(button)), "sketerm-fb-menubar-ctx") orelse return;
    switchMenu(@ptrCast(@alignCast(data)), button);
    if (focus_item) {
        if (state.active_popover) |pop| focusFirstItem(pop);
    }
}

fn switchAdjacent(state: *BarState, forward: bool) void {
    const current = state.active_button orelse return;
    const bar = state.bar orelse return;
    const next = if (forward)
        c.gtk_widget_get_next_sibling(current) orelse c.gtk_widget_get_first_child(bar)
    else
        c.gtk_widget_get_prev_sibling(current) orelse c.gtk_widget_get_last_child(bar);
    if (next) |button| openButton(state, button, true);
}

fn focusFirstItem(pop: *c.GtkWidget) void {
    const scroll = c.gtk_popover_get_child(@ptrCast(pop)) orelse return;
    const box = classicmenu.scrollContent(scroll) orelse return;
    var child = c.gtk_widget_get_first_child(box);
    while (child) |row| : (child = c.gtk_widget_get_next_sibling(row)) {
        if (c.gtk_widget_get_visible(row) != 0 and c.gtk_widget_grab_focus(row) != 0) return;
    }
}

fn onMenuClosed(pop: *c.GtkPopover, user: ?*anyopaque) callconv(.c) void {
    const state: *BarState = @ptrCast(@alignCast(user.?));
    const widget: *c.GtkWidget = @ptrCast(@alignCast(pop));
    if (state.active_popover != widget) return;
    if (state.active_button) |button| c.gtk_widget_unset_state_flags(button, c.GTK_STATE_FLAG_SELECTED);
    state.active_button = null;
    state.active_popover = null;
    state.target_pane = null;
}

fn onBarDestroyed(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const state: *BarState = @ptrCast(@alignCast(user.?));
    closeActive(state, true);
    state.bar = null;
}

fn openMenu(btn: *c.GtkButton, ctx: *BarCtx) ?*c.GtkWidget {
    const win = ctx.win;
    const a = ctx.allocator;
    const root = classicmenu.Root.create(a) orelse return null;
    const m = root.top();
    const bv = targetBrowser(win, ctx.state.target_pane);
    const target_pane = ctx.state.target_pane;
    switch (ctx.which) {
        .file => {
            addItem(root, m, a, win, target_pane, "New Tab", .{ .name = "tab-new-symbolic" }, .new_tab);
            addItem(root, m, a, win, target_pane, "New Window", .{ .name = "window-new-symbolic" }, .new_window);
            const pane = m.section();
            addItem(root, pane, a, win, target_pane, "Split Pane", .none, .split_pane);
            addItem(root, pane, a, win, target_pane, "Close Pane", .none, .close_pane);
            const tail = m.section();
            addItem(root, tail, a, win, target_pane, "Close Window", .{ .name = "window-close-symbolic" }, .close_window);
        },
        .edit => {
            addItem(root, m, a, win, target_pane, "Cut", .{ .name = "edit-cut-symbolic" }, .cut);
            addItem(root, m, a, win, target_pane, "Copy", .{ .name = "edit-copy-symbolic" }, .copy);
            addItem(root, m, a, win, target_pane, "Paste", .{ .name = "edit-paste-symbolic" }, .paste);
            const sel = m.section();
            addItem(root, sel, a, win, target_pane, "Select All", .{ .name = "edit-select-all-symbolic" }, .select_all);
            addItem(root, sel, a, win, target_pane, "Invert Selection", .none, .invert_selection);
            const tail = m.section();
            addItem(root, tail, a, win, target_pane, "Preferences…", .{ .name = "preferences-system-symbolic" }, .prefs);
        },
        .view => {
            addItem(root, m, a, win, target_pane, "Reload", .{ .name = "view-refresh-symbolic" }, .reload);
            const toggles = m.section();
            const tab = if (bv) |v| v.currentTab() else null;
            addCheck(root, toggles, a, win, target_pane, "Show Hidden Files", if (tab) |t| t.show_hidden else false, .toggle_hidden);
            addCheck(root, toggles, a, win, target_pane, "Places Sidebar", if (bv) |v| v.places_on else true, .toggle_sidebar);
            const modes = m.section();
            const mode: ?browser_model.ViewMode = if (tab) |t| t.view_mode else null;
            addCheck(root, modes, a, win, target_pane, "Details List", mode == .details, .mode_details);
            addCheck(root, modes, a, win, target_pane, "Compact List", mode == .compact, .mode_compact);
            addCheck(root, modes, a, win, target_pane, "Icon Grid", mode == .icons, .mode_icons);
            addCheck(root, modes, a, win, target_pane, "Miller Columns", mode == .miller, .mode_miller);
        },
        .go => {
            addItem(root, m, a, win, target_pane, "Back", .{ .name = "go-previous-symbolic" }, .back);
            addItem(root, m, a, win, target_pane, "Forward", .{ .name = "go-next-symbolic" }, .forward);
            addItem(root, m, a, win, target_pane, "Up", .{ .name = "go-up-symbolic" }, .up);
            const placesec = m.section();
            addItem(root, placesec, a, win, target_pane, "Home", .{ .name = "user-home-symbolic" }, .home);
            addItem(root, placesec, a, win, target_pane, "Trash", .{ .name = "user-trash-symbolic" }, .trash);
        },
        .bookmarks => {
            addItem(root, m, a, win, target_pane, "Add Bookmark", .{ .name = "bookmark-new-symbolic" }, .add_bookmark);
            if (bv) |v| {
                if (v.bookmarks.items.len > 0) {
                    const list = m.section();
                    for (v.bookmarks.items, 0..) |b, i| {
                        var lz: [256:0]u8 = undefined;
                        const label = places_ui.bookmarkLabelAt(v, i) orelse std.fs.path.basename(b);
                        const n = @min(label.len, lz.len - 1);
                        @memcpy(lz[0..n], label[0..n]);
                        lz[n] = 0;
                        const ictx = ItemCtx.make(root, a, win, target_pane, .open_bookmark, b) orelse continue;
                        list.itemIcon(&lz, .{ .name = "starred-symbolic" }, &onItem, @ptrCast(ictx));
                    }
                }
            }
        },
        .help => {
            addItem(root, m, a, win, target_pane, "About Sketerm Files", .{ .name = "help-about-symbolic" }, .about);
        },
    }
    // Anchor under the button, classic menubar drop.
    const w: *c.GtkWidget = @ptrCast(@alignCast(btn));
    return root.popupStyled(w, 0, @floatFromInt(c.gtk_widget_get_height(w)), "sketerm-cm-menubar");
}

fn addItem(root: *classicmenu.Root, m: classicmenu.Menu, a: std.mem.Allocator, win: *Window, target_pane: ?*Pane, label: [*:0]const u8, icon: classicmenu.Icon, verb: ItemCtx.Verb) void {
    const ctx = ItemCtx.make(root, a, win, target_pane, verb, "") orelse return;
    m.itemIcon(label, icon, &onItem, @ptrCast(ctx));
}

fn addCheck(root: *classicmenu.Root, m: classicmenu.Menu, a: std.mem.Allocator, win: *Window, target_pane: ?*Pane, label: [*:0]const u8, checked: bool, verb: ItemCtx.Verb) void {
    const ctx = ItemCtx.make(root, a, win, target_pane, verb, "") orelse return;
    m.check(label, checked, &onItem, @ptrCast(ctx));
}

fn onItem(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *ItemCtx = @ptrCast(@alignCast(user.?));
    const win = ctx.win;
    const target = targetBrowser(win, ctx.target_pane);
    const bv = target;
    switch (ctx.verb) {
        .new_tab => win.newBrowserTabFrom(if (target) |v| v.pane else null, null) catch {},
        .new_window => _ = win.openFilesWindow(null) catch {},
        .split_pane => if (target) |v| {
            v.focusOwnPane();
            win.newBrowserSplit(@intCast(c.GTK_ORIENTATION_HORIZONTAL)) catch {};
        },
        .close_pane => if (bv) |v| v.closePaneDeferred(),
        .close_window => c.gtk_window_close(@ptrCast(win.app_window)),
        .cut => if (bv) |v| ops.clipSelection(v, true),
        .copy => if (bv) |v| ops.clipSelection(v, false),
        .paste => if (bv) |v| ops.pasteIntoCurrent(v),
        .select_all => if (bv) |v| v.selectPattern("*", false),
        .invert_selection => if (bv) |v| v.selectPattern("*", true),
        .prefs => win.openPrefs(),
        .reload => if (bv) |v| {
            if (v.currentTab()) |tab| {
                v.clearFailureCaches();
                v.refreshDir(tab, tab.root);
                for (tab.subdirs.items) |d| v.refreshDir(tab, d);
            }
        },
        .toggle_hidden => if (bv) |v| {
            const active = c.gtk_toggle_button_get_active(v.hidden_toggle);
            c.gtk_toggle_button_set_active(v.hidden_toggle, @intFromBool(active == 0));
        },
        .toggle_sidebar => if (bv) |v| {
            const active = c.gtk_toggle_button_get_active(v.places_toggle);
            c.gtk_toggle_button_set_active(v.places_toggle, @intFromBool(active == 0));
        },
        .mode_details => setMode(bv, .details),
        .mode_compact => setMode(bv, .compact),
        .mode_icons => setMode(bv, .icons),
        .mode_miller => setMode(bv, .miller),
        .back => if (bv) |v| {
            if (v.currentTab()) |t| v.goBack(t);
        },
        .forward => if (bv) |v| {
            if (v.currentTab()) |t| v.goForward(t);
        },
        .up => if (bv) |v| {
            if (v.currentTab()) |t| v.goUp(t);
        },
        .home => if (bv) |v| goHome(v),
        .trash => if (bv) |v| goTrash(v),
        .add_bookmark => if (bv) |v| places_ui.bookmarkCurrent(v),
        .open_bookmark => if (bv) |v| {
            var buf: [4600]u8 = undefined;
            if (ctx.spec.len == 0 or ctx.spec.len >= buf.len) return;
            @memcpy(buf[0..ctx.spec.len], ctx.spec);
            const tab = v.currentTab() orelse {
                _ = v.newTabSpec(buf[0..ctx.spec.len]);
                return;
            };
            v.navigateSpec(tab, buf[0..ctx.spec.len]);
        },
        .about => showAbout(win),
    }
}

fn setMode(bv: ?*BrowserView, mode: browser_model.ViewMode) void {
    const v = bv orelse return;
    const tab = v.currentTab() orelse return;
    if (tab.view_mode == mode) return;
    tab.view_mode = mode;
    @import("views.zig").rememberFolder(v, tab);
    v.renderTab(tab);
}

fn goHome(v: *BrowserView) void {
    const tab = v.currentTab() orelse return;
    if (tab.hc.host) |host| {
        var buf: [4600]u8 = undefined;
        const hd = tab.hc.home_dir orelse "/";
        const spec = std.fmt.bufPrint(&buf, "{s}:{s}", .{ host, hd }) catch return;
        v.navigateSpec(tab, spec);
        return;
    }
    const home = if (c.getenv("HOME")) |h| std.mem.span(@as([*:0]const u8, @ptrCast(h))) else "/";
    var buf: [4300]u8 = undefined;
    const spec = std.fmt.bufPrint(&buf, "local:{s}", .{home}) catch return;
    v.navigateSpec(tab, spec);
}

fn goTrash(v: *BrowserView) void {
    const tab = v.currentTab() orelse return;
    var buf: [4200]u8 = undefined;
    const td = @import("../../filebrowser/paths.zig").trashFilesDir(&buf) orelse return;
    var spec_buf: [4300]u8 = undefined;
    if (spec_buf.len < td.len) return;
    @memcpy(spec_buf[0..td.len], td);
    v.navigateSpec(tab, spec_buf[0..td.len]);
}

/// Help > About: version, commit and commit date from build time.
fn showAbout(win: *Window) void {
    const about = c.adw_about_window_new();
    c.adw_about_window_set_application_name(@ptrCast(about), "Sketerm Files");
    c.adw_about_window_set_application_icon(@ptrCast(about), "dev.sker.sketerm.files");
    c.adw_about_window_set_developer_name(@ptrCast(about), "Jelle De Loecker");
    c.adw_about_window_set_license_type(@ptrCast(about), c.GTK_LICENSE_GPL_3_0);
    var vz: [192:0]u8 = undefined;
    const ver = std.fmt.bufPrintZ(&vz, "{s} ({s}, {s})", .{
        version.string,
        build_options.commit,
        build_options.commit_date,
    }) catch "0";
    c.adw_about_window_set_version(@ptrCast(about), ver.ptr);
    var cz: [256:0]u8 = undefined;
    const info = std.fmt.bufPrintZ(&cz, "Commit {s}, built from source dated {s}.", .{
        build_options.commit,
        build_options.commit_date,
    }) catch "";
    c.adw_about_window_set_comments(@ptrCast(about), info.ptr);
    c.gtk_window_set_transient_for(@ptrCast(about), @ptrCast(@alignCast(win.app_window)));
    c.gtk_window_present(@ptrCast(about));
}
