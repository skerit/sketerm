//! The entry context menu: its popover construction, the declarative
//! .action buttons, and the handlers that dispatch a menu item into
//! the module that owns the behavior.

const std = @import("std");
const c = @import("../../c.zig").c;
const browser_model = @import("../../filebrowser/model.zig");

const classicmenu = @import("classicmenu.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const colview = @import("colview.zig");
const copyToClip = @import("ops.zig").copyToClip;
const countSelected = @import("nav.zig").countSelected;
const hostEq = @import("../../filebrowser/paths.zig").hostEq;
const isArchivePath = @import("../../filebrowser/paths.zig").isArchivePath;
const isSketermMount = @import("../../filebrowser/paths.zig").isSketermMount;
const isTrashPath = @import("../../filebrowser/paths.zig").isTrashPath;
const launchLocal = @import("open.zig").launchLocal;
const launchLocalWithApp = @import("open.zig").launchLocalWithApp;
const onMenuBatchRename = @import("ops.zig").onMenuBatchRename;
const onMenuDelete = @import("ops.zig").onMenuDelete;
const onMenuEditorRename = @import("ops.zig").onMenuEditorRename;
const onMenuExportSel = @import("ops.zig").onMenuExportSel;
const onMenuProperties = @import("props.zig").onMenuProperties;
const onMenuRegisterAdd = @import("selection.zig").onMenuRegisterAdd;
const onMenuRegisterAddNamed = @import("selection.zig").onMenuRegisterAddNamed;
const onMenuRegisterRemove = @import("selection.zig").onMenuRegisterRemove;
const onMenuSyncHere = @import("compare.zig").onMenuSyncHere;
const onMenuTags = @import("ops.zig").onMenuTags;
const onMenuTrash = @import("ops.zig").onMenuTrash;
const parseSpec = @import("../../filebrowser/paths.zig").parseSpec;
const setMountXattr = @import("ops.zig").setMountXattr;

/// Heap context for one open menu/dialog popover; owned by the
/// popover via g_object_set_data_full (freed when it dies).
pub const MenuCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    tab: *BTab,
    /// Target entry (null = background click).
    path: ?[]u8,
    name: ?[]u8,
    is_dir: bool,
    popover: *c.GtkWidget,
    /// Entry-dialog mode: what Enter commits.
    mode: enum { none, rename, mkdir, tags, newfile } = .none,
    entry: ?*c.GtkWidget = null,
    entry2: ?*c.GtkWidget = null,

    pub fn free(user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        if (ctx.path) |p| ctx.allocator.free(p);
        if (ctx.name) |n| ctx.allocator.free(n);
        ctx.allocator.destroy(ctx);
    }
};

/// One menu row. `ctx` is the caller's heap context (the entry menu
/// passes its MenuCtx, the tab menu its own); the popover owning it
/// is what frees it.
pub fn menuButton(box: *c.GtkWidget, label: [*:0]const u8, cb: anytype, ctx: *anyopaque, destructive: bool) void {
    const btn = c.gtk_button_new_with_label(label);
    c.gtk_button_set_has_frame(@ptrCast(btn), 0);
    c.gtk_widget_set_halign(c.gtk_button_get_child(@ptrCast(btn)), c.GTK_ALIGN_START);
    if (destructive) c.gtk_widget_add_css_class(btn, "destructive-action");
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(cb), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(box), btn);
}

pub fn onRightClick(gesture: *c.GtkGestureClick, n_press: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    _ = n_press;
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    const self = tab.view;

    // Right-click on the column header strip: the column picker,
    // like every file manager's header.
    if (colview.pickIsHeader(tab, x, y)) {
        _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_CLAIMED);
        @import("render.zig").showColumnPicker(tab, @ptrCast(@alignCast(tab.colview)), .{ .x = x, .y = y });
        return;
    }

    var path: ?[]u8 = null;
    var name: ?[]u8 = null;
    var is_dir = false;
    if (colview.pickItem(tab, x, y)) |p| {
        if (p.data.kind == .entry) {
            path = self.allocator.dupe(u8, p.data.path) catch null;
            name = self.allocator.dupe(u8, std.fs.path.basename(p.data.path)) catch null;
            is_dir = p.data.is_dir;
            keepOrSelect(gesture, tab, p.pos);
        }
    }
    self.showEntryMenu(tab, @ptrCast(@alignCast(tab.colview)), x, y, path, name, is_dir);
}

/// Right-click on the listing AREA while the rows are hidden (empty
/// folder, failed listing, no matches): the background menu, parented
/// to the always-visible content box -- the listbox is hidden then, so
/// its gesture never fires and a popover on it would not map. Without
/// this an empty directory had no context menu at all, so nothing
/// could be pasted into it.
pub fn onAreaRightClick(_: *c.GtkGestureClick, n_press: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    _ = n_press;
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    if (c.gtk_widget_get_visible(tab.empty_box) == 0) return;
    const parent = c.gtk_widget_get_parent(tab.empty_box) orelse return;
    tab.view.showEntryMenu(tab, parent, x, y, null, null, false);
}

/// Right-clicking INSIDE a multi-selection must KEEP it: the menu's
/// verbs (Copy, Move to Trash, Batch Rename, register marks) all act
/// on the whole selection, and collapsing it here made the menu
/// silently target one row instead of all of them.
///
/// The view's own click handling answers EVERY button, so simply not
/// selecting is not enough -- the sequence has to be CLAIMED (this
/// controller runs in the capture phase) before the view can act on
/// it. An unselected row is selected exclusively, since claiming
/// denies the view the chance to do it.
fn keepOrSelect(gesture: *c.GtkGestureClick, tab: *BTab, pos: c.guint) void {
    _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_CLAIMED);
    const model: *c.GtkSelectionModel = @ptrCast(@alignCast(tab.selmodel));
    if (c.gtk_selection_model_is_selected(model, pos) == 0) {
        // OUTSIDE the selection: the click retargets — select only
        // the clicked row.
        _ = c.gtk_selection_model_select_item(model, pos, 1);
    }
}

/// Build and pop the entry context menu. Takes ownership of
/// `path`/`name`; `parent` is the visible widget the click hit.
///
/// A classic menu: GtkPopoverMenu over a GMenuModel (classicmenu),
/// so the rows are compact and submenus open to the side on hover.
/// Long menus scroll inside the popover, which is what makes the old
/// too-tall-to-map failure impossible here.
pub fn showEntryMenu(
    self: *BrowserView,
    tab: *BTab,
    parent: *c.GtkWidget,
    x: f64,
    y: f64,
    path: ?[]u8,
    name: ?[]u8,
    is_dir: bool,
) void {
    const ctx = self.allocator.create(MenuCtx) catch {
        if (path) |p| self.allocator.free(p);
        if (name) |n| self.allocator.free(n);
        return;
    };
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .tab = tab,
        .path = path,
        .name = name,
        .is_dir = is_dir,
        .popover = undefined, // set right after popup, before any item can fire
    };
    const root = classicmenu.Root.create(self.allocator) orelse {
        MenuCtx.free(@ptrCast(ctx));
        return;
    };
    const m = root.top();

    const is_local = tab.hc.host == null;
    if (tab.root.archive.len > 0) {
        // Archive members: extract-and-open is the only verb
        // (path ops would misparse member names).
        if (ctx.path != null and !is_dir)
            m.item("Extract and Open", &onMenuExtractMember, ctx);
    } else if (tab.root.collection) {
        // Register rows: specs spanning hosts: navigation +
        // membership only (path verbs would misparse specs).
        if (ctx.path != null) {
            m.item("Open in New Browser Tab", &onMenuCollectionOpen, ctx);
            m.item("Unmark (remove from this register)", &onMenuRegisterRemove, ctx);
        }
    } else if (ctx.path != null) {
        // ── an entry's menu, Nemo's shape: open verbs, clipboard,
        // reshaping, create-new, the dangerous pair, and Properties
        // LAST (never Close Pane -- that is a background verb).
        const tools = toolsApply(ctx, is_dir, is_local);
        buildOpen(self, ctx, m, is_dir, is_local);
        const edit = m.section();
        edit.itemIcon("Cut", .{ .name = "edit-cut-symbolic" }, &onMenuCut, ctx);
        edit.itemIcon("Copy", .{ .name = "edit-copy-symbolic" }, &onMenuCopy, ctx);
        // The clipboard is process-wide, so this offers Paste for a
        // copy made in ANY pane -- which is what made a remote folder
        // look like it had no Paste at all.
        if (!self.clipboard().isEmpty())
            buildPaste(self, tab, ctx, edit.submenuIcon("Paste", .{ .name = "edit-paste-symbolic" }));
        const org = m.section();
        org.item("Rename…", &onMenuRename, ctx);
        buildCopyTo(self, ctx, org.submenu("Copy To"));
        buildOrganize(tab, ctx, org.submenu("Organize"), is_dir);
        // Compress is its own top-level submenu, like Dolphin's --
        // and a submenu inside Organize would be nested one popover
        // too deep to receive clicks (classicmenu's depth limit).
        buildCompress(self, ctx, org.submenuIcon("Compress", .{ .name = "package-x-generic" }));
        if (tools) buildTools(ctx, org.submenu("Tools"), is_dir, is_local);
        const create = m.section();
        buildCreateNew(self, ctx, create.submenuIcon("Create New", .{ .name = "list-add-symbolic" }), true);
        const acts = m.section();
        self.appendActionItems(acts, ctx);
        const danger = m.section();
        danger.itemIcon("Move to Trash", .{ .name = "user-trash-symbolic" }, &onMenuTrash, ctx);
        danger.item("Delete Permanently…", &onMenuDelete, ctx);
        const tail = m.section();
        appendUndoItem(self, tail, ctx);
        tail.itemIcon("Properties…", .{ .name = "document-properties-symbolic" }, &onMenuProperties, ctx);
    } else {
        // ── the background menu, Nemo's order: create-new first,
        // Paste, the view toggles, terminal, then folder Properties
        // last. Close Pane lives here (and only here): a background
        // click is the pane, not a file.
        buildCreateNew(self, ctx, m, false);
        const paste = m.section();
        if (!self.clipboard().isEmpty()) {
            paste.itemIcon("Paste", .{ .name = "edit-paste-symbolic" }, &onMenuPaste, ctx);
            buildPasteSpecial(self, tab, ctx, paste.submenu("Paste Special"));
        }
        const viewsec = m.section();
        viewsec.check("Show Hidden Files", tab.show_hidden, &onMenuToggleHidden, ctx);
        const term = m.section();
        if (is_local) term.itemIcon("Open in Terminal", .{ .name = "sketerm-terminal-symbolic" }, &onMenuTerminalHere, ctx);
        if (self.on_host_term != null) term.item("Open Terminal Tab Here", &onMenuTermTab, ctx);
        const acts = m.section();
        self.appendActionItems(acts, ctx);
        const pane = m.section();
        appendUndoItem(self, pane, ctx);
        pane.item("Close Pane", &onMenuClosePane, ctx);
        const tail = m.section();
        tail.itemIcon("Properties…", .{ .name = "document-properties-symbolic" }, &onMenuFolderProperties, ctx);
        tail.itemIcon("Preferences…", .{ .name = "preferences-system-symbolic" }, &onMenuPrefs, ctx);
    }

    const popover = root.popupVia(parent, self.root_box, x, y);
    ctx.popover = popover;
    c.g_object_set_data_full(@ptrCast(popover), "sketerm-menu", @ptrCast(ctx), @ptrCast(&MenuCtx.free));
}

/// Heap context for one hamburger view-mode row.
const HamModeCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    mode: browser_model.ViewMode,
};

fn hamModeCleanup(user: ?*anyopaque) callconv(.c) void {
    const hm: *HamModeCtx = @ptrCast(@alignCast(user.?));
    hm.allocator.destroy(hm);
}

fn onHamModeChosen(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const hm: *HamModeCtx = @ptrCast(@alignCast(user.?));
    const self = hm.view;
    const tab = self.currentTab() orelse return;
    if (tab.view_mode == hm.mode) return;
    tab.view_mode = hm.mode;
    self.setStatusFmt("view: {s}", .{@tagName(hm.mode)});
    @import("views.zig").rememberFolder(self, tab);
    self.renderTab(tab);
}

fn onHamTogglePlaces(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const on = c.gtk_toggle_button_get_active(self.places_toggle);
    c.gtk_toggle_button_set_active(self.places_toggle, @intFromBool(on == 0));
}

fn onHamToggleInfo(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const on = c.gtk_toggle_button_get_active(self.info_toggle);
    c.gtk_toggle_button_set_active(self.info_toggle, @intFromBool(on == 0));
}

/// The toolbar hamburger's menu, Dolphin's shape: Create New on top,
/// the view toggles as check rows (plus the collapsed toolbar
/// cluster's toggles when the bar is narrow), a View Mode submenu
/// instead of a blind "cycle" row, then the tab/pane verbs.
pub fn showHamburgerMenu(self: *BrowserView, anchor: *c.GtkWidget) void {
    const tab = self.currentTab() orelse return;
    const ctx = self.allocator.create(MenuCtx) catch return;
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .tab = tab,
        .path = null,
        .name = null,
        .is_dir = false,
        .popover = undefined,
    };
    const root = classicmenu.Root.create(self.allocator) orelse {
        MenuCtx.free(@ptrCast(ctx));
        return;
    };
    const m = root.top();

    buildCreateNew(self, ctx, m, false);

    const toggles = m.section();
    if (self.bar_collapsed) {
        toggles.check("Places Sidebar", c.gtk_toggle_button_get_active(self.places_toggle) != 0, &onHamTogglePlaces, @ptrCast(self));
        toggles.check("Information Panel", c.gtk_toggle_button_get_active(self.info_toggle) != 0, &onHamToggleInfo, @ptrCast(self));
    }
    toggles.check("Show Hidden Files", tab.show_hidden, &onMenuToggleHidden, ctx);

    const modes = m.section().submenu("View Mode");
    const mode_rows = [_]struct { label: [*:0]const u8, mode: browser_model.ViewMode }{
        .{ .label = "Details list", .mode = .details },
        .{ .label = "Compact list", .mode = .compact },
        .{ .label = "Icon grid", .mode = .icons },
        .{ .label = "Miller columns", .mode = .miller },
    };
    for (mode_rows) |mr| {
        const hm = self.allocator.create(HamModeCtx) catch break;
        hm.* = .{ .allocator = self.allocator, .view = self, .mode = mr.mode };
        root.own(&hamModeCleanup, @ptrCast(hm));
        modes.check(mr.label, tab.view_mode == mr.mode, &onHamModeChosen, @ptrCast(hm));
    }

    const panes = m.section();
    panes.itemIcon("New Tab", .{ .name = "tab-new-symbolic" }, &BrowserView.onNewTabClicked, @ptrCast(self));
    panes.item("Split Pane", &BrowserView.onSplitClicked, @ptrCast(self));
    panes.item("Close Pane", &onMenuClosePane, ctx);

    const tail = m.section();
    tail.itemIcon("Go to Shell Directory", .{ .name = "sketerm-terminal-symbolic" }, &BrowserView.onCwdSyncClicked, @ptrCast(self));
    tail.itemIcon("Preferences…", .{ .name = "preferences-system-symbolic" }, &onMenuPrefs, ctx);

    const popover = root.popup(anchor, @floatFromInt(@divTrunc(c.gtk_widget_get_width(anchor), 2)), @floatFromInt(c.gtk_widget_get_height(anchor)));
    ctx.popover = popover;
    c.g_object_set_data_full(@ptrCast(popover), "sketerm-menu", @ptrCast(ctx), @ptrCast(&MenuCtx.free));
}

/// The primary open verb inline, the rest behind an "Open" side
/// submenu. Which one is primary depends on the entry: a directory
/// is opened, a file is handed to an application.
fn buildOpen(
    self: *BrowserView,
    ctx: *MenuCtx,
    m: classicmenu.Menu,
    is_dir: bool,
    is_local: bool,
) void {
    if (is_dir) {
        m.item("Open in New Browser Tab", &onMenuOpenTab, ctx);
    } else {
        buildOpenWith(self, ctx, m);
    }
    const has_more = (is_dir and (is_local or self.on_host_term != null)) or
        (!is_dir and !is_local and self.on_host_open != null);
    if (!has_more) return;
    const p = m.submenu("Open");
    if (is_dir) {
        if (is_local) p.item("Open Terminal Here", &onMenuTerminalHere, ctx);
        if (self.on_host_term != null)
            p.item("Open Terminal Tab Here", &onMenuTermTab, ctx);
    } else if (!is_local and self.on_host_open != null) {
        p.item("Open on Host (app forward)", &onMenuHostOpen, ctx);
    }
}

/// Per-item context for a direct "open with app X" row; owned by the
/// menu root, not the popover's MenuCtx.
const OpenAppCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    tab: *BTab,
    path: []u8,
    /// null = default handler.
    appid: ?[]u8,
};

fn openAppCleanup(user: ?*anyopaque) callconv(.c) void {
    const a: *OpenAppCtx = @ptrCast(@alignCast(user.?));
    a.allocator.free(a.path);
    if (a.appid) |s| a.allocator.free(s);
    a.allocator.destroy(a);
}

fn onOpenAppActivated(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const actx: *OpenAppCtx = @ptrCast(@alignCast(user.?));
    const self = actx.view;
    if (actx.tab.hc.host != null) {
        self.openRemoteFile(actx.tab, actx.path, if (actx.appid) |id| id else null);
    } else if (actx.appid) |id| {
        launchLocalWithApp(id, actx.path);
    } else {
        launchLocal(actx.path);
    }
}

fn addOpenAppItem(
    self: *BrowserView,
    ctx: *MenuCtx,
    m: classicmenu.Menu,
    label: []const u8,
    appid: ?[]const u8,
    app_icon: ?*c.GIcon,
) void {
    const path = ctx.path orelse return;
    const actx = self.allocator.create(OpenAppCtx) catch return;
    actx.* = .{
        .allocator = self.allocator,
        .view = self,
        .tab = ctx.tab,
        .path = self.allocator.dupe(u8, path) catch {
            self.allocator.destroy(actx);
            return;
        },
        .appid = if (appid) |id| (self.allocator.dupe(u8, id) catch null) else null,
    };
    m.root.own(&openAppCleanup, @ptrCast(actx));
    var ebuf: [320]u8 = undefined;
    const ltxt = classicmenu.escapeLabel(label, &ebuf);
    if (app_icon) |gi| {
        m.itemIcon(ltxt, .{ .gicon = gi }, &onOpenAppActivated, @ptrCast(actx));
    } else {
        m.item(ltxt, &onOpenAppActivated, @ptrCast(actx));
    }
}

/// Nemo-style open block for a file: "Open with <Default>" launches
/// directly, then an "Open With" hover submenu lists every candidate
/// plus "Other Application…" (the full chooser, with the always-use
/// checkbox and host-side apps).
///
/// On a remote tab the candidates are still LOCAL applications — the
/// launch downloads a cache copy first (openRemoteFile), same as the
/// chooser dialog's local section.
fn buildOpenWith(self: *BrowserView, ctx: *MenuCtx, m: classicmenu.Menu) void {
    const path = ctx.path orelse return;
    var namez: [512:0]u8 = undefined;
    var ct: [*c]c.gchar = null;
    if (std.fmt.bufPrintZ(&namez, "{s}", .{std.fs.path.basename(path)})) |bz| {
        var uncertain: c.gboolean = 0;
        ct = c.g_content_type_guess(bz.ptr, null, 0, &uncertain);
    } else |_| {}
    defer if (ct != null) c.g_free(ct);

    if (ct != null) {
        if (c.g_app_info_get_default_for_type(ct, 0)) |info| {
            defer c.g_object_unref(@as(?*anyopaque, @ptrCast(info)));
            if (c.g_app_info_get_name(info)) |nm| {
                var lbl: [192]u8 = undefined;
                if (std.fmt.bufPrint(&lbl, "Open with {s}", .{std.mem.span(@as([*:0]const u8, @ptrCast(nm)))})) |ltxt| {
                    const id: ?[]const u8 = if (c.g_app_info_get_id(info)) |i|
                        std.mem.span(@as([*:0]const u8, @ptrCast(i)))
                    else
                        null;
                    // The icon is borrowed from the app info; the row
                    // resolves (or refs) it during the call.
                    addOpenAppItem(self, ctx, m, ltxt, id, c.g_app_info_get_icon(info));
                } else |_| {}
            }
        }
    }

    const ow = m.submenu("Open With");
    var count: usize = 0;
    if (ct != null) {
        const apps = c.g_app_info_get_all_for_type(ct);
        var it = apps;
        while (it != null and count < 20) : (it = it.*.next) {
            const app: *c.GAppInfo = @ptrCast(@alignCast(it.*.data orelse continue));
            const id = c.g_app_info_get_id(app) orelse continue;
            const nm = c.g_app_info_get_name(app) orelse continue;
            addOpenAppItem(self, ctx, ow, std.mem.span(nm), std.mem.span(id), c.g_app_info_get_icon(app));
            count += 1;
        }
        if (apps != null) c.g_list_free_full(apps, @ptrCast(&c.g_object_unref));
    }
    const tail = if (count > 0) ow.section() else ow;
    tail.item("Other Application…", &onMenuOpenWith, ctx);
}

fn buildPaste(self: *BrowserView, tab: *BTab, ctx: *MenuCtx, p: classicmenu.Menu) void {
    p.item("Paste Here", &onMenuPaste, ctx);
    buildPasteSpecial(self, tab, ctx, p);
}

/// The link/sync variants, shared by the entry menu's Paste submenu
/// and the background menu's Paste Special submenu (whose plain Paste
/// is a first-class item beside it, like Nemo's).
fn buildPasteSpecial(self: *BrowserView, tab: *BTab, ctx: *MenuCtx, p: classicmenu.Menu) void {
    p.item("Paste as Symbolic Link", &onMenuPasteSymlink, ctx);
    // A hard link is offered only where it can succeed: same host,
    // same filesystem. Everywhere else the verb is simply absent.
    if (self.hardlinkPossible(tab))
        p.item("Paste as Hard Link", &onMenuPasteHardlink, ctx);
    p.item("Sync Here (mirror copy, resumable)", &onMenuSyncHere, ctx);
    p.item("Compare / Sync with Copied…", &onMenuCompare, ctx);
}

/// The tail Undo row, present on both menus when there is anything
/// to undo.
fn appendUndoItem(self: *BrowserView, m: classicmenu.Menu, ctx: *MenuCtx) void {
    if (self.undo_stack.items.len == 0) return;
    var ubuf: [96]u8 = undefined;
    var uz: [200]u8 = undefined;
    const last = self.undo_stack.items[self.undo_stack.items.len - 1];
    const utxt = std.fmt.bufPrint(&ubuf, "Undo ({s})", .{last.describe()}) catch "Undo";
    m.itemIcon(classicmenu.escapeLabel(utxt, &uz), .{ .name = "edit-undo-symbolic" }, &onMenuUndo, ctx);
}

/// Everywhere the selection can be sent: the other pane, the
/// collection, a named register, the shell.
fn buildCopyTo(self: *BrowserView, ctx: *MenuCtx, p: classicmenu.Menu) void {
    if (self.peerView()) |peer| {
        if (peer.currentTab()) |pt| {
            var pbuf: [4300]u8 = undefined;
            var lbuf: [4400]u8 = undefined;
            var ebuf: [4500]u8 = undefined;
            const dest = pt.spec(&pbuf);
            if (std.fmt.bufPrint(&lbuf, "Copy to Other Pane ({s})  F5", .{dest})) |t| {
                p.item(classicmenu.escapeLabel(t, &ebuf), &onMenuCopyToPeer, ctx);
            } else |_| {}
            if (std.fmt.bufPrint(&lbuf, "Move to Other Pane ({s})  F6", .{dest})) |t| {
                p.item(classicmenu.escapeLabel(t, &ebuf), &onMenuMoveToPeer, ctx);
            } else |_| {}
        }
    }
    p.item("Copy Path", &onMenuCopyPath, ctx);
    p.item("Add to Collection", &onMenuRegisterAdd, ctx);
    p.item("Mark in Register...", &onMenuRegisterAddNamed, ctx);
    p.item("Export Selection to Shell ($SK__SEL)", &onMenuExportSel, ctx);
}

/// The verbs that reshape an entry in place: rename variants, tags,
/// bookmarks and the archive pair (compressing IS a reshape, and its
/// two extract verbs only exist for archives anyway).
fn buildOrganize(tab: *BTab, ctx: *MenuCtx, p: classicmenu.Menu, is_dir: bool) void {
    p.item("Duplicate", &onMenuDuplicate, ctx);
    p.item("Tags…", &onMenuTags, ctx);
    if (is_dir) p.item("Add Bookmark", &onMenuBookmark, ctx);
    if (countSelected(tab) > 1) {
        p.item("Batch Rename Selected…", &onMenuBatchRename, ctx);
        p.item("Batch Rename in $EDITOR…", &onMenuEditorRename, ctx);
    }
    if (!is_dir and isArchivePath(ctx.path.?)) {
        p.item("Browse Archive", &onMenuBrowseArchive, ctx);
        p.item("Extract Here", &onMenuExtractHere, ctx);
    }
}

/// The formats bsdtar -caf can produce from the destination name.
const COMPRESS_FORMATS = [_][:0]const u8{ "zip", "tar.gz", "tar.xz", "tar.zst", "7z", "tar" };

/// Per-item context for one Compress format row.
const CompressCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    tab: *BTab,
    path: []u8,
    ext: [:0]const u8,
};

fn compressCleanup(user: ?*anyopaque) callconv(.c) void {
    const cc: *CompressCtx = @ptrCast(@alignCast(user.?));
    cc.allocator.free(cc.path);
    cc.allocator.destroy(cc);
}

fn onCompressActivated(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const cc: *CompressCtx = @ptrCast(@alignCast(user.?));
    var out: [4096]u8 = undefined;
    const archive = std.fmt.bufPrint(&out, "{s}.{s}", .{ cc.path, cc.ext }) catch return;
    cc.view.startDaemonJob(cc.tab.hc, "archive_create", cc.path, archive, "create archive");
}

/// Dolphin's Compress submenu: one row per format, named after what
/// it will create. The daemon's bsdtar derives the format from the
/// destination extension.
fn buildCompress(self: *BrowserView, ctx: *MenuCtx, p: classicmenu.Menu) void {
    const path = ctx.path orelse return;
    const base = std.fs.path.basename(path);
    for (COMPRESS_FORMATS) |ext| {
        const cc = self.allocator.create(CompressCtx) catch return;
        cc.* = .{
            .allocator = self.allocator,
            .view = self,
            .tab = ctx.tab,
            .path = self.allocator.dupe(u8, path) catch {
                self.allocator.destroy(cc);
                return;
            },
            .ext = ext,
        };
        p.root.own(&compressCleanup, @ptrCast(cc));
        var lbl: [320]u8 = undefined;
        var lz: [400]u8 = undefined;
        const ltxt = std.fmt.bufPrint(&lbl, "Compress to \"{s}.{s}\"", .{ base, ext }) catch continue;
        p.item(classicmenu.escapeLabel(ltxt, &lz), &onCompressActivated, @ptrCast(cc));
    }
}

/// Does the Tools submenu have anything in it? Every one of its verbs
/// is conditional, so the row is only offered when at least one
/// applies.
fn toolsApply(ctx: *MenuCtx, is_dir: bool, is_local: bool) bool {
    const p = ctx.path orelse return false;
    if (is_dir) return true; // Calculate Size + Find Duplicates
    if (isTrashPath(p)) return true;
    return is_local and isSketermMount(p);
}

fn buildTools(ctx: *MenuCtx, p: classicmenu.Menu, is_dir: bool, is_local: bool) void {
    if (is_dir) {
        p.item("Calculate Size", &onMenuCalcSize, ctx);
        p.item("Find Duplicates Here", &onMenuFindDups, ctx);
    }
    if (isTrashPath(ctx.path.?))
        p.item("Restore from Trash", &onMenuTrashRestoreItem, ctx);
    if (is_local and !is_dir and isSketermMount(ctx.path.?)) {
        p.item("Pin (keep hydrated)", &onMenuPin, ctx);
        p.item("Evict Cached Data", &onMenuEvict, ctx);
    }
}

/// Dolphin's "Create New" block / Nemo's background head: New Folder
/// first, then the document templates. `in_submenu` = the entry
/// menu's grouped form, where `m` is already the "Create New" side
/// submenu and everything goes in FLAT (KNewFileMenu's shape) --
/// submenus must not nest: a popover three surfaces deep never
/// receives pointer input (see classicmenu's module doc).
fn buildCreateNew(self: *BrowserView, ctx: *MenuCtx, m: classicmenu.Menu, in_submenu: bool) void {
    m.itemIcon(
        if (in_submenu) "New Folder…" else "Create New Folder…",
        .{ .name = "folder-new-symbolic" },
        &onMenuNewFolder,
        ctx,
    );
    const docs = if (in_submenu)
        m.section()
    else
        m.submenuIcon("Create New Document", .{ .name = "document-new-symbolic" });
    const listed = appendTemplateItems(self, ctx, docs);
    if (ctx.tab.hc.host != null)
        docs.item("From Template…", &onMenuNewFromTemplate, ctx);
    const tail = if (listed or ctx.tab.hc.host != null) docs.section() else docs;
    tail.itemIcon("Empty Document…", .{ .name = "document-new-symbolic" }, &onMenuNewEmptyFile, ctx);
}

/// Cap on the template rows the Create New Document submenu lists; a
/// Templates directory is a hand-curated place.
const MAX_INLINE_TEMPLATES = 64;

/// Heap context for one inline template row; owned by the menu root.
const TemplateItemCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    tab: *BTab,
    source: []u8,
};

fn templateItemCleanup(user: ?*anyopaque) callconv(.c) void {
    const t: *TemplateItemCtx = @ptrCast(@alignCast(user.?));
    t.allocator.free(t.source);
    t.allocator.destroy(t);
}

fn onTemplateItemActivated(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const t: *TemplateItemCtx = @ptrCast(@alignCast(user.?));
    @import("templates.zig").instantiate(t.view, t.tab, t.source);
}

/// List the LOCAL Templates directory straight into the submenu,
/// Nemo-style: each template is one row with its type's icon. Remote
/// tabs keep the async "From Template…" popover instead (that
/// listing is a round trip; a hover submenu cannot wait for it).
/// @return true when at least one template row was added.
fn appendTemplateItems(self: *BrowserView, ctx: *MenuCtx, docs: classicmenu.Menu) bool {
    if (ctx.tab.hc.host != null) return false;
    var dbuf: [4096]u8 = undefined;
    const dir = localTemplatesDir(&dbuf) orelse return false;
    var dz: [4096:0]u8 = undefined;
    const dzs = std.fmt.bufPrintZ(&dz, "{s}", .{dir}) catch return false;
    const d = c.opendir(dzs.ptr) orelse return false;
    defer _ = c.closedir(d);

    // readdir order is arbitrary; collect and sort so the menu is
    // stable across opens.
    var names_buf: [MAX_INLINE_TEMPLATES][256]u8 = undefined;
    var names: [MAX_INLINE_TEMPLATES][]const u8 = undefined;
    var count: usize = 0;
    while (c.readdir(d)) |de| {
        if (count >= MAX_INLINE_TEMPLATES) break;
        const fname = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
        if (fname.len == 0 or fname[0] == '.') continue;
        if (fname.len >= names_buf[count].len) continue;
        @memcpy(names_buf[count][0..fname.len], fname);
        names[count] = names_buf[count][0..fname.len];
        count += 1;
    }
    std.mem.sort([]const u8, names[0..count], {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.lt);

    for (names[0..count]) |name| {
        const t = self.allocator.create(TemplateItemCtx) catch return count > 0;
        const source = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, name }) catch {
            self.allocator.destroy(t);
            return count > 0;
        };
        t.* = .{ .allocator = self.allocator, .view = self, .tab = ctx.tab, .source = @constCast(source) };
        docs.root.own(&templateItemCleanup, @ptrCast(t));
        // Label without the extension, with the type's icon -- the
        // way Nemo presents templates.
        const stem = if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| name[0..i] else name;
        var lz: [300]u8 = undefined;
        const label = classicmenu.escapeLabel(stem, &lz);
        var nz: [256:0]u8 = undefined;
        const n = @min(name.len, nz.len - 1);
        @memcpy(nz[0..n], name[0..n]);
        nz[n] = 0;
        var uncertain: c.gboolean = 0;
        const ctype = c.g_content_type_guess(&nz, null, 0, &uncertain);
        if (ctype != null) {
            defer c.g_free(ctype);
            if (c.g_content_type_get_icon(ctype)) |gicon| {
                defer c.g_object_unref(gicon);
                docs.itemIcon(label, .{ .gicon = @ptrCast(gicon) }, &onTemplateItemActivated, @ptrCast(t));
                continue;
            }
        }
        docs.item(label, &onTemplateItemActivated, @ptrCast(t));
    }
    return count > 0;
}

/// The local freedesktop Templates directory (XDG special dir with
/// Nemo's $HOME/Templates fallback); null when it does not exist.
fn localTemplatesDir(buf: []u8) ?[]const u8 {
    var candidate: ?[]const u8 = null;
    if (c.g_get_user_special_dir(c.G_USER_DIRECTORY_TEMPLATES)) |p| {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
        // GLib answers $HOME for an unconfigured special dir; that is
        // not a templates directory.
        const home = if (c.getenv("HOME")) |h| std.mem.span(@as([*:0]const u8, @ptrCast(h))) else "";
        if (!std.mem.eql(u8, s, home)) candidate = s;
    }
    if (candidate == null) {
        const homep = c.getenv("HOME") orelse return null;
        const home = std.mem.span(@as([*:0]const u8, @ptrCast(homep)));
        candidate = std.fmt.bufPrint(buf[2048..], "{s}/Templates", .{home}) catch return null;
    }
    const dir = candidate.?;
    var z: [2048:0]u8 = undefined;
    const zs = std.fmt.bufPrintZ(&z, "{s}", .{dir}) catch return null;
    if (c.access(zs.ptr, c.F_OK) != 0) return null;
    const n = @min(dir.len, buf.len - 1);
    @memcpy(buf[0..n], dir[0..n]);
    return buf[0..n];
}

pub fn onPopoverClosed(_: *c.GtkPopover, user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const pop: *c.GtkWidget = @ptrCast(@alignCast(u));
        if (c.gtk_widget_get_parent(pop) != null) c.gtk_widget_unparent(pop);
    }
}

pub fn connectPopoverAutoUnparent(popover: *c.GtkWidget) void {
    _ = c.g_signal_connect_data(popover, "closed", @ptrCast(&onPopoverClosed), @ptrCast(popover), null, c.G_CONNECT_DEFAULT);
}

pub fn menuDone(ctx: *MenuCtx) void {
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
}

/// Un-split from the background menu. The pane binding table owns
/// what closing a pane IS, so this forwards the action; it is
/// deferred because the close destroys the widget tree this popover
/// (and this handler) live in.
pub fn onMenuClosePane(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const view = ctx.view;
    menuDone(ctx);
    view.closePaneDeferred();
}

pub fn onMenuTerminalHere(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    // Entry menus target the clicked directory; the background menu
    // (no path) targets the folder being shown.
    const path = ctx.path orelse ctx.tab.root.path;
    // cd the pane's shell into the target (single-quoted; embedded
    // quotes escaped) and flip to the terminal face.
    var buf: [4600]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.writeAll("cd '") catch return menuDone(ctx);
    for (path) |ch| {
        if (ch == '\'') w.writeAll("'\\''") catch return menuDone(ctx) else w.writeByte(ch) catch return menuDone(ctx);
    }
    w.writeAll("'\n") catch return menuDone(ctx);
    ctx.view.pane.terminal.writeRaw(w.buffered());
    ctx.view.pane.setBrowserVisible(false);
    menuDone(ctx);
}

pub fn onMenuOpenTab(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    if (ctx.path) |p| _ = ctx.view.newTab(ctx.tab.hc.host, p);
    menuDone(ctx);
}

pub fn onMenuCopy(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    copyToClip(@ptrCast(@alignCast(user.?)), false);
}

pub fn onMenuCut(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    copyToClip(@ptrCast(@alignCast(user.?)), true);
}

pub fn onMenuCopyToPeer(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const path = if (ctx.path) |p| self.allocator.dupe(u8, p) catch null else null;
    defer if (path) |p| self.allocator.free(p);
    menuDone(ctx);
    self.sendToPeer(false, path);
}

pub fn onMenuMoveToPeer(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const path = if (ctx.path) |p| self.allocator.dupe(u8, p) catch null else null;
    defer if (path) |p| self.allocator.free(p);
    menuDone(ctx);
    self.sendToPeer(true, path);
}

pub fn onMenuCopyPath(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const path = ctx.path orelse return menuDone(ctx);
    var z: [4096:0]u8 = undefined;
    const n = @min(path.len, z.len - 1);
    @memcpy(z[0..n], path[0..n]);
    z[n] = 0;
    const clip = c.gtk_widget_get_clipboard(@ptrCast(@alignCast(ctx.tab.colview)));
    c.gdk_clipboard_set_text(clip, &z);
    menuDone(ctx);
}

pub fn onMenuPaste(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const board = self.clipboard();
    if (board.isEmpty()) return menuDone(ctx);
    self.beginPaste(ctx.tab, board.hostOpt(), board.items(), board.cut, true);
    menuDone(ctx);
}

pub fn onMenuTermTab(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const path = ctx.path orelse ctx.tab.root.path;
    if (self.on_host_term) |cb| {
        if (self.hooks_ctx) |hctx| cb(hctx, ctx.tab.hc.host orelse "", path);
    }
    menuDone(ctx);
}

pub fn onMenuHostOpen(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const path = ctx.path orelse return menuDone(ctx);
    if (self.on_host_open) |cb| {
        if (self.hooks_ctx) |hctx| {
            cb(hctx, ctx.tab.hc.host orelse "", path);
            self.setStatus("opening on host (app window forwards here)…");
        }
    }
    menuDone(ctx);
}

pub fn onMenuOpenWith(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const mctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = mctx.view;
    const orig = mctx.path orelse return menuDone(mctx);
    const tab = mctx.tab;
    // Copy the path out and close the menu popover FIRST — its
    // popdown must not race the new popover's grab.
    var pbuf: [4096]u8 = undefined;
    if (orig.len >= pbuf.len) return menuDone(mctx);
    @memcpy(pbuf[0..orig.len], orig);
    const path = pbuf[0..orig.len];
    menuDone(mctx);
    self.openWithDialog(tab, path);
}

pub fn onMenuCollectionOpen(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const spec = ctx.path orelse return menuDone(ctx);
    const loc = parseSpec(spec);
    if (loc.path.len > 0) {
        // Open the entry itself (dir) or its parent (file).
        const dirp = if (ctx.is_dir) loc.path else (std.fs.path.dirname(loc.path) orelse loc.path);
        _ = self.newTab(loc.host, dirp);
    }
    menuDone(ctx);
}

pub fn onMenuCompare(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const tab = ctx.tab;
    const target = if (ctx.is_dir and ctx.path != null) ctx.path.? else tab.root.path;
    var tbuf: [4096]u8 = undefined;
    if (target.len >= tbuf.len) return menuDone(ctx);
    @memcpy(tbuf[0..target.len], target);
    const tcopy = tbuf[0..target.len];
    menuDone(ctx);
    self.startCompare(tab, tcopy);
}

pub fn onMenuBookmark(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const path = ctx.path orelse return menuDone(ctx);
    var spec_buf: [4400]u8 = undefined;
    const spec = if (ctx.tab.hc.host) |h|
        std.fmt.bufPrint(&spec_buf, "{s}:{s}", .{ h, path }) catch return menuDone(ctx)
    else
        path;
    self.addBookmark(spec);
    menuDone(ctx);
}

pub fn onMenuPin(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    setMountXattr(@ptrCast(@alignCast(user.?)), "user.sketerm.pin", "pinned — hydrating in the background");
}

pub fn onMenuEvict(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    setMountXattr(@ptrCast(@alignCast(user.?)), "user.sketerm.evict", "cached data evicted");
}

pub fn onMenuTrashRestoreItem(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const path = ctx.path orelse return menuDone(ctx);
    const tab = ctx.tab;
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return menuDone(ctx);
    @memcpy(pbuf[0..path.len], path);
    const pcopy = pbuf[0..path.len];
    menuDone(ctx);
    self.startTrashRestore(tab, pcopy);
}

pub fn onMenuUndo(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const view = ctx.view;
    menuDone(ctx);
    view.performUndo();
}

pub fn onMenuCalcSize(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const path = ctx.path orelse return menuDone(ctx);
    ctx.view.startDaemonJobKind(ctx.tab.hc, "find", path, "", "*", "calculate size", .{ .kind = .calc_size });
    menuDone(ctx);
}

pub fn onMenuFindDups(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const path = ctx.path orelse return menuDone(ctx);
    const tab = ctx.tab;
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return menuDone(ctx);
    @memcpy(pbuf[0..path.len], path);
    const pcopy = pbuf[0..path.len];
    menuDone(ctx);
    self.startDupScan(tab, pcopy);
}

pub fn onMenuNewFolder(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    ctx.view.entryDialog(ctx.tab, .mkdir, null);
    menuDone(ctx);
}

pub fn onMenuNewFromTemplate(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const tab = ctx.tab;
    // A popover opened from inside a menu must be built AFTER the menu
    // is popped down, or the new grab races the old one.
    menuDone(ctx);
    self.showTemplateMenu(tab);
}

pub fn onMenuDuplicate(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const tab = ctx.tab;
    const path = ctx.path orelse return menuDone(ctx);
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return menuDone(ctx);
    @memcpy(pbuf[0..path.len], path);
    const pcopy = pbuf[0..path.len];
    menuDone(ctx);
    self.duplicateEntry(tab, pcopy);
}

pub fn onMenuPasteSymlink(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    pasteAsLink(@ptrCast(@alignCast(user.?)), false);
}

pub fn onMenuPasteHardlink(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    pasteAsLink(@ptrCast(@alignCast(user.?)), true);
}

/// Paste-as-link for every copied path. The clipboard's own storage
/// outlives the menu, so the paths are read directly from it.
fn pasteAsLink(ctx: *MenuCtx, hard: bool) void {
    const self = ctx.view;
    const tab = ctx.tab;
    menuDone(ctx);
    const board = self.clipboard();
    if (!hostEq(board.hostOpt(), tab.hc.host)) {
        self.setStatus("a link can only point at a path on the same host");
        return;
    }
    for (board.items()) |src| self.linkHere(tab, src, hard);
}

pub fn onMenuRename(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const tab = ctx.tab;
    const orig = ctx.path orelse return menuDone(ctx);
    // Close the menu FIRST: its popdown moves focus, and a focus
    // change after the editor grabbed focus would instantly cancel
    // the inline edit.
    var pbuf: [4096]u8 = undefined;
    if (orig.len >= pbuf.len) return menuDone(ctx);
    @memcpy(pbuf[0..orig.len], orig);
    const path = pbuf[0..orig.len];
    menuDone(ctx);
    self.startInlineRename(tab, path);
}

pub fn onMenuBrowseArchive(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const tab = ctx.tab;
    const path = ctx.path orelse return menuDone(ctx);
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return menuDone(ctx);
    @memcpy(pbuf[0..path.len], path);
    const pcopy = pbuf[0..path.len];
    menuDone(ctx);
    self.startArchiveBrowse(tab, pcopy);
}

pub fn onMenuExtractMember(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const tab = ctx.tab;
    const member = ctx.path orelse return menuDone(ctx);
    var mbuf: [4096]u8 = undefined;
    if (member.len >= mbuf.len) return menuDone(ctx);
    @memcpy(mbuf[0..member.len], member);
    const mcopy = mbuf[0..member.len];
    menuDone(ctx);
    self.extractAndOpenMember(tab, mcopy);
}

pub fn onMenuExtractHere(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const path = ctx.path orelse return menuDone(ctx);
    const parent = std.fs.path.dirname(path) orelse "/";
    ctx.view.startDaemonJob(ctx.tab.hc, "extract", path, parent, "extract archive");
    menuDone(ctx);
}

/// Create an empty file here (Nemo's Empty Document): the name is
/// asked via the entry dialog, the daemon `create` op does an
/// O_EXCL create so an existing file can never be clobbered.
pub fn onMenuNewEmptyFile(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    ctx.view.entryDialog(ctx.tab, .newfile, null);
    menuDone(ctx);
}

/// The background menu's Show Hidden Files check row: flips the real
/// hamburger toggle so every surface stays in sync.
pub fn onMenuToggleHidden(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const view = ctx.view;
    menuDone(ctx);
    const active = c.gtk_toggle_button_get_active(view.hidden_toggle);
    c.gtk_toggle_button_set_active(view.hidden_toggle, @intFromBool(active == 0));
}

/// Open the application preferences (same dialog as terminal mode).
pub fn onMenuPrefs(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const view = ctx.view;
    menuDone(ctx);
    if (view.ownerWindow()) |win| win.openPrefs();
}

/// Properties of the folder the background click landed in.
pub fn onMenuFolderProperties(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const view = ctx.view;
    const tab = ctx.tab;
    menuDone(ctx);
    @import("props.zig").folderProperties(view, tab);
}

/// Heap context for one action button; freed with the button.
pub const ActionCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    host: ?[]u8,
    cmdline: []u8,
    runs_on_host: bool,

    fn free(user: ?*anyopaque, closure: ?*anyopaque) callconv(.c) void {
        _ = closure;
        const a: *ActionCtx = @ptrCast(@alignCast(user.?));
        if (a.host) |h| a.allocator.free(h);
        a.allocator.free(a.cmdline);
        a.allocator.destroy(a);
    }
};

/// User actions from $XDG_CONFIG_HOME/sketerm/actions/*.action:
/// Name= / Exec= (%f = quoted path) / Ext=csv / RunsOnHost=true.
/// Local-only actions hide on remote tabs (a local command cannot
/// reach a remote path); RunsOnHost actions run as app sessions
/// on the file's host (windows forward here).
pub fn appendActionItems(self: *BrowserView, m: classicmenu.Menu, ctx: *MenuCtx) void {
    // Background menus run actions against the folder itself.
    const path = ctx.path orelse ctx.tab.root.path;
    var dirbuf: [4096:0]u8 = undefined;
    const cfg = c.g_get_user_config_dir();
    const adir = std.fmt.bufPrintZ(&dirbuf, "{s}/sketerm/actions", .{cfg}) catch return;
    const d = c.opendir(adir.ptr) orelse return;
    defer _ = c.closedir(d);
    const remote = ctx.tab.hc.host != null;
    const base = std.fs.path.basename(path);
    const ext = if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| base[i + 1 ..] else "";

    while (c.readdir(d)) |de| {
        const fname = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
        if (!std.mem.endsWith(u8, fname, ".action")) continue;
        var fbuf: [4200:0]u8 = undefined;
        const fpath = std.fmt.bufPrintZ(&fbuf, "{s}/{s}", .{ adir, fname }) catch continue;
        const f = c.fopen(fpath.ptr, "rb") orelse continue;
        var content: [4096]u8 = undefined;
        const n = c.fread(&content, 1, content.len, f);
        _ = c.fclose(f);
        var name: []const u8 = "";
        var exec: []const u8 = "";
        var exts: []const u8 = "";
        var on_host = false;
        var it = std.mem.tokenizeScalar(u8, content[0..n], '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (std.mem.startsWith(u8, line, "Name=")) name = line[5..];
            if (std.mem.startsWith(u8, line, "Exec=")) exec = line[5..];
            if (std.mem.startsWith(u8, line, "Ext=")) exts = line[4..];
            if (std.mem.startsWith(u8, line, "RunsOnHost=")) on_host = std.mem.eql(u8, line[11..], "true");
        }
        if (name.len == 0 or exec.len == 0) continue;
        if (remote and !on_host) continue;
        if (exts.len > 0) {
            var matched = false;
            var eit = std.mem.tokenizeScalar(u8, exts, ',');
            while (eit.next()) |e| {
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, e, " "), ext)) matched = true;
            }
            if (!matched) continue;
        }
        // %f -> single-quoted path, substituted now.
        var cmd: std.ArrayList(u8) = .empty;
        defer cmd.deinit(self.allocator);
        var rest = exec;
        while (std.mem.indexOf(u8, rest, "%f")) |i| {
            cmd.appendSlice(self.allocator, rest[0..i]) catch return;
            cmd.append(self.allocator, '\'') catch return;
            for (path) |ch| {
                if (ch == '\'') {
                    cmd.appendSlice(self.allocator, "'\\''") catch return;
                } else cmd.append(self.allocator, ch) catch return;
            }
            cmd.append(self.allocator, '\'') catch return;
            rest = rest[i + 2 ..];
        }
        cmd.appendSlice(self.allocator, rest) catch return;

        const actx = self.allocator.create(ActionCtx) catch return;
        actx.* = .{
            .allocator = self.allocator,
            .view = self,
            .host = if (ctx.tab.hc.host) |h| (self.allocator.dupe(u8, h) catch null) else null,
            .cmdline = self.allocator.dupe(u8, cmd.items) catch {
                self.allocator.destroy(actx);
                return;
            },
            .runs_on_host = on_host,
        };
        // The item's ctx is not the popover-owned MenuCtx, so the
        // menu root owns its release.
        m.root.own(&actionCtxCleanup, @ptrCast(actx));
        var lbl: [128]u8 = undefined;
        var ebuf: [200]u8 = undefined;
        const ltxt = std.fmt.bufPrint(&lbl, "{s}{s}", .{
            name, if (on_host) " (on host)" else "",
        }) catch continue;
        m.item(classicmenu.escapeLabel(ltxt, &ebuf), &onActionActivated, @ptrCast(actx));
    }
}

fn actionCtxCleanup(user: ?*anyopaque) callconv(.c) void {
    ActionCtx.free(user, null);
}

/// A user .action item fired. The popover closes itself (classic
/// menu); this only runs the command.
pub fn onActionActivated(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const actx: *ActionCtx = @ptrCast(@alignCast(user.?));
    const self = actx.view;
    if (actx.runs_on_host) {
        if (self.on_host_exec) |cb| {
            if (self.hooks_ctx) |hctx| {
                var z: [4096:0]u8 = undefined;
                const cl = std.fmt.bufPrintZ(&z, "{s}", .{actx.cmdline}) catch return;
                cb(hctx, actx.host orelse "", cl);
                self.setStatus("action started (app session)");
            }
        }
    } else {
        var z: [4096:0]u8 = undefined;
        const cl = std.fmt.bufPrintZ(&z, "{s}", .{actx.cmdline}) catch return;
        _ = c.g_spawn_command_line_async(cl.ptr, null);
        self.setStatus("action started");
    }
}
