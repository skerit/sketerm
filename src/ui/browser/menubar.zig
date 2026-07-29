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
const BrowserView = @import("view.zig").BrowserView;
const classicmenu = @import("classicmenu.zig");
const ops = @import("ops.zig");
const places_ui = @import("places.zig");

/// One top-level menu button's ctx (lives as long as the window).
const BarCtx = struct {
    allocator: std.mem.Allocator,
    win: *Window,
    which: Which,

    const Which = enum { file, edit, view, go, bookmarks, help };

    fn free(user: ?*anyopaque) callconv(.c) void {
        const ctx: *BarCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.destroy(ctx);
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
    ;
    const provider = c.gtk_css_provider_new();
    c.gtk_css_provider_load_from_string(provider, css);
    const display = c.gtk_widget_get_display(any_widget);
    c.gtk_style_context_add_provider_for_display(display, @ptrCast(@alignCast(provider)), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

pub fn build(allocator: std.mem.Allocator, win: *Window) *c.GtkWidget {
    const bar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    c.gtk_widget_add_css_class(bar, "sketerm-fb-menubar");
    installCss(bar);
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
        ctx.* = .{ .allocator = allocator, .win = win, .which = e.which };
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onMenuButton), @ptrCast(ctx), @ptrCast(&freeBarCtx), c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), btn);
    }
    return bar;
}

fn freeBarCtx(user: ?*anyopaque, _: ?*c.GClosure) callconv(.c) void {
    BarCtx.free(user);
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

/// Per-item ctx: window + verb id (+ an owned spec for bookmarks).
const ItemCtx = struct {
    allocator: std.mem.Allocator,
    win: *Window,
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

    fn make(root: *classicmenu.Root, allocator: std.mem.Allocator, win: *Window, verb: Verb, spec: []const u8) ?*ItemCtx {
        const ctx = allocator.create(ItemCtx) catch return null;
        ctx.* = .{
            .allocator = allocator,
            .win = win,
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
    const win = ctx.win;
    const a = ctx.allocator;
    const root = classicmenu.Root.create(a) orelse return;
    const m = root.top();
    const bv = activeBrowser(win);
    switch (ctx.which) {
        .file => {
            addItem(root, m, a, win, "New Tab", .new_tab);
            addItem(root, m, a, win, "New Window", .new_window);
            const pane = m.section();
            addItem(root, pane, a, win, "Split Pane", .split_pane);
            addItem(root, pane, a, win, "Close Pane", .close_pane);
            const tail = m.section();
            addItem(root, tail, a, win, "Close Window", .close_window);
        },
        .edit => {
            addItem(root, m, a, win, "Cut", .cut);
            addItem(root, m, a, win, "Copy", .copy);
            addItem(root, m, a, win, "Paste", .paste);
            const sel = m.section();
            addItem(root, sel, a, win, "Select All", .select_all);
            addItem(root, sel, a, win, "Invert Selection", .invert_selection);
            const tail = m.section();
            addItem(root, tail, a, win, "Preferences…", .prefs);
        },
        .view => {
            addItem(root, m, a, win, "Reload", .reload);
            const toggles = m.section();
            const tab = if (bv) |v| v.currentTab() else null;
            addCheck(root, toggles, a, win, "Show Hidden Files", if (tab) |t| t.show_hidden else false, .toggle_hidden);
            addCheck(root, toggles, a, win, "Places Sidebar", if (bv) |v| v.places_on else true, .toggle_sidebar);
            const modes = m.section();
            const mode: ?browser_model.ViewMode = if (tab) |t| t.view_mode else null;
            addCheck(root, modes, a, win, "Details List", mode == .details, .mode_details);
            addCheck(root, modes, a, win, "Compact List", mode == .compact, .mode_compact);
            addCheck(root, modes, a, win, "Icon Grid", mode == .icons, .mode_icons);
            addCheck(root, modes, a, win, "Miller Columns", mode == .miller, .mode_miller);
        },
        .go => {
            addItem(root, m, a, win, "Back", .back);
            addItem(root, m, a, win, "Forward", .forward);
            addItem(root, m, a, win, "Up", .up);
            const placesec = m.section();
            addItem(root, placesec, a, win, "Home", .home);
            addItem(root, placesec, a, win, "Trash", .trash);
        },
        .bookmarks => {
            addItem(root, m, a, win, "Add Bookmark", .add_bookmark);
            if (bv) |v| {
                if (v.bookmarks.items.len > 0) {
                    const list = m.section();
                    for (v.bookmarks.items, 0..) |b, i| {
                        var lz: [256:0]u8 = undefined;
                        const label = places_ui.bookmarkLabelAt(v, i) orelse std.fs.path.basename(b);
                        const n = @min(label.len, lz.len - 1);
                        @memcpy(lz[0..n], label[0..n]);
                        lz[n] = 0;
                        const ictx = ItemCtx.make(root, a, win, .open_bookmark, b) orelse continue;
                        list.itemIcon(&lz, .{ .name = "starred-symbolic" }, &onItem, @ptrCast(ictx));
                    }
                }
            }
        },
        .help => {
            addItem(root, m, a, win, "About Sketerm Files", .about);
        },
    }
    // Anchor under the button, classic menubar drop.
    const w: *c.GtkWidget = @ptrCast(@alignCast(btn));
    _ = root.popup(w, 0, @floatFromInt(c.gtk_widget_get_height(w)));
}

fn addItem(root: *classicmenu.Root, m: classicmenu.Menu, a: std.mem.Allocator, win: *Window, label: [*:0]const u8, verb: ItemCtx.Verb) void {
    const ctx = ItemCtx.make(root, a, win, verb, "") orelse return;
    m.item(label, &onItem, @ptrCast(ctx));
}

fn addCheck(root: *classicmenu.Root, m: classicmenu.Menu, a: std.mem.Allocator, win: *Window, label: [*:0]const u8, checked: bool, verb: ItemCtx.Verb) void {
    const ctx = ItemCtx.make(root, a, win, verb, "") orelse return;
    m.check(label, checked, &onItem, @ptrCast(ctx));
}

fn onItem(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *ItemCtx = @ptrCast(@alignCast(user.?));
    const win = ctx.win;
    const bv = activeBrowser(win);
    switch (ctx.verb) {
        .new_tab => win.newBrowserTabFrom(null, null) catch {},
        .new_window => _ = win.openFilesWindow(null) catch {},
        .split_pane => win.newBrowserSplit(@intCast(c.GTK_ORIENTATION_HORIZONTAL)) catch {},
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
    const dlg = c.adw_about_dialog_new();
    c.adw_about_dialog_set_application_name(@ptrCast(dlg), "Sketerm Files");
    c.adw_about_dialog_set_application_icon(@ptrCast(dlg), "dev.sker.sketerm.files");
    c.adw_about_dialog_set_developer_name(@ptrCast(dlg), "Jelle De Loecker");
    c.adw_about_dialog_set_license_type(@ptrCast(dlg), c.GTK_LICENSE_GPL_3_0);
    var vz: [192:0]u8 = undefined;
    const ver = std.fmt.bufPrintZ(&vz, "{s} ({s}, {s})", .{
        version.string,
        build_options.commit,
        build_options.commit_date,
    }) catch "0";
    c.adw_about_dialog_set_version(@ptrCast(dlg), ver.ptr);
    var cz: [256:0]u8 = undefined;
    const info = std.fmt.bufPrintZ(&cz, "Commit {s}, built from source dated {s}.", .{
        build_options.commit,
        build_options.commit_date,
    }) catch "";
    c.adw_about_dialog_set_comments(@ptrCast(dlg), info.ptr);
    c.adw_dialog_present(@ptrCast(dlg), @ptrCast(@alignCast(win.app_window)));
}
