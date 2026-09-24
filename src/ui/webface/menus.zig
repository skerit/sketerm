//! The face's menus: the page context menu (with the clipboard verbs it
//! offers) and the toolbar hamburger. Split out of `webface.zig`; the `WebFace` methods are free functions
//! taking `*WebFace`, re-exported from `WebFace` by name.

const std = @import("std");
const appmenu = @import("../appmenu.zig");
const c = @import("../../c.zig").c;
const cast = @import("../../util/cast.zig");
const classicmenu = @import("../browser/classicmenu.zig");
const clipboard = @import("../clipboard.zig");
const proto = @import("../../web/protocol.zig");
const suggest = @import("../../util/suggest.zig");
const webhistory = @import("../webhistory.zig");
const webroute = @import("../../web/route.zig");
const webstore = @import("../webstore.zig");
const webuserscripts = @import("../webuserscripts.zig");
const host_mod = @import("../webface.zig");
const PasteCtx = host_mod.PasteCtx;
const WebFace = host_mod.WebFace;
const containers = host_mod.containers;
const hostOfUrl = host_mod.hostOfUrl;
const onMenuReader = WebFace.onMenuReader;
const onMenuTorTab = WebFace.onMenuTorTab;
const onWebPasteRead = host_mod.onWebPasteRead;
const searchTemplate = host_mod.searchTemplate;
const setSiteContainer = host_mod.setSiteContainer;

// ---- context menu ----------------------------------------------

/// Per-popup state for the context menu's rows; owned by the menu
/// Root (freed when the popover dies), never by the rows.
pub const MenuCtx = struct {
    allocator: std.mem.Allocator,
    face: *WebFace,
    /// The root the rows live in, so custom (non-classicmenu)
    /// widgets can pop the menu down before acting.
    root: ?*classicmenu.Root = null,
    page: ?[]u8 = null,
    link: ?[]u8 = null,
    image: ?[]u8 = null,
    sel: ?[]u8 = null,
};

pub fn freeMenuCtx(user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    if (ctx.page) |p| ctx.allocator.free(p);
    if (ctx.link) |l| ctx.allocator.free(l);
    if (ctx.image) |i| ctx.allocator.free(i);
    if (ctx.sel) |s| ctx.allocator.free(s);
    ctx.allocator.destroy(ctx);
}

/// The helper suppressed the engine's menu and reported the hit
/// test; show ours at the reported page position.
pub fn onContextMenu(self: *WebFace, ev: proto.EvContextMenu) void {
    if (self.widgets_dead) return;
    // Not on an inspector pane: our menu's verbs (Back, Reload,
    // Copy Page URL) would act on the DEVTOOLS browser, which is
    // never what a right-click inside the inspector means. An
    // observed page under control is the assistant's page driven
    // by this user, and those verbs mean exactly that.
    if (self.attached and !self.observed) return;
    const root = classicmenu.Root.create(self.allocator) orelse return;
    const ctx = self.allocator.create(MenuCtx) catch {
        root.destroy();
        return;
    };
    ctx.* = .{ .allocator = self.allocator, .face = self, .root = root };
    if (self.url) |u| ctx.page = self.allocator.dupe(u8, u) catch null;
    if (ev.flags & proto.ctx_flag_link != 0 and ev.link_url.len != 0)
        ctx.link = self.allocator.dupe(u8, ev.link_url) catch null;
    if (ev.flags & proto.ctx_flag_image != 0 and ev.src_url.len != 0)
        ctx.image = self.allocator.dupe(u8, ev.src_url) catch null;
    if (ev.flags & proto.ctx_flag_selection != 0 and ev.selection_text.len != 0)
        ctx.sel = self.allocator.dupe(u8, ev.selection_text) catch null;
    root.own(freeMenuCtx, ctx);

    const m = root.top();
    const targeted = ctx.link != null or ctx.image != null or ctx.sel != null;
    if (!targeted) {
        // Plain page: Firefox's icon-only navigation strip up top.
        // A targeted menu (link / image / selection) instead LEADS
        // with what was clicked, exactly like Firefox.
        m.custom(self.buildNavStrip(ctx));
    }
    if (ctx.link != null) {
        const links = m.section();
        links.itemIcon("Open Link in New Tab", .{ .name = "tab-new-symbolic" }, &onMenuOpenLink, ctx);
        links.itemIcon("Copy Link URL", .{ .name = "edit-copy-symbolic" }, &onMenuCopyLink, ctx);
    }
    if (ctx.image != null) {
        const imgs = m.section();
        imgs.itemIcon("Open Image in New Tab", .{ .name = "image-x-generic-symbolic" }, &onMenuOpenImage, ctx);
        imgs.itemIcon("Copy Image URL", .{ .name = "edit-copy-symbolic" }, &onMenuCopyImage, ctx);
    }
    if (ctx.sel) |sel| {
        const seln = m.section();
        seln.itemIcon("Copy", .{ .name = "edit-copy-symbolic" }, &onMenuCopySelection, ctx);
        // `Search the Web for "…"`, quoting a short prefix of the
        // selection the way Firefox does.
        var lbuf: [96]u8 = undefined;
        var short = sel;
        if (short.len > 32) {
            var end: usize = 32;
            while (end > 0 and (short[end] & 0xC0) == 0x80) end -= 1;
            short = short[0..end];
        }
        const label: [*:0]const u8 = if (std.fmt.bufPrintZ(
            &lbuf,
            "Search the Web for \"{s}{s}\"",
            .{ short, if (short.len < sel.len) "\u{2026}" else "" },
        )) |l| l.ptr else |_| "Search the Web for Selection";
        seln.itemIcon(label, .{ .name = "edit-find-symbolic" }, &onMenuSearchSelection, ctx);
    }
    const page = m.section();
    page.check("Reader View", self.reader_active, &onMenuReader, ctx);
    page.itemIconEnabled("Copy Page URL", .none, ctx.page != null, &onMenuCopyUrl, ctx);
    page.checkEnabled(
        "Bookmark This Page",
        self.bookmark_id != 0,
        ctx.page != null,
        &onMenuBookmark,
        ctx,
    );
    // Per-site popup override. Only offered once the page has an
    // origin to attach it to (about:blank has none).
    page.checkEnabled(
        "Allow Popups on This Site",
        self.site_popup == .allow,
        self.nav_origin != null,
        &onMenuAllowPopups,
        ctx,
    );

    const store_section = m.section();
    store_section.itemIcon("History", .{ .name = "document-open-recent-symbolic" }, &onMenuHistory, ctx);
    store_section.itemIcon("Bookmarks", .{ .name = "sketerm-starred-symbolic" }, &onMenuBookmarks, ctx);
    store_section.itemIcon("Userscripts…", .{ .name = "application-x-addon-symbolic" }, &onMenuUserscripts, ctx);
    store_section.itemIcon("Filter Lists…", .{ .name = "security-high-symbolic" }, &onMenuFilterLists, ctx);
    // A style needs a site to be scoped to; about:blank has none.
    store_section.itemIconEnabled(
        "Edit Site Style…",
        .{ .name = "applications-graphics-symbolic" },
        self.nav_origin != null,
        &onMenuSiteStyle,
        ctx,
    );
    self.appendToolRows(m, ctx);

    // Container / identity actions.
    const tabs = m.section();
    tabs.itemIcon("New Incognito Web Tab", .{ .name = "view-private-symbolic" }, &onMenuIncognito, ctx);
    const cl = self.cl;
    tabs.itemIconEnabled(
        if (cl.isRemote()) "Extensions (local browsers only)" else "Extensions...",
        .{ .name = "application-x-addon-symbolic" },
        cl.has(.webext) and !cl.isRemote(),
        &onMenuExtensions,
        ctx,
    );
    self.appendContainerRows(root, tabs, ctx);

    const x: f64 = @floatFromInt(ev.x + @as(i32, self.snap_dx));
    const y: f64 = @floatFromInt(ev.y + @as(i32, self.snap_dy));
    _ = root.popup(self.view_area, x, y);
}

pub const ContainerRowCtx = struct {
    allocator: std.mem.Allocator,
    face: *WebFace,
    container: u32,
};

pub fn freeContainerRowCtx(user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(ContainerRowCtx, user);
    ctx.allocator.destroy(ctx);
}

/// The tools section both menus share, judged against the tab's OWN
/// helper. A helper too old for a verb greys the row out rather than
/// hiding it: what a browser pane CAN do stays visible.
pub fn appendToolRows(self: *WebFace, m: classicmenu.Menu, ctx: *MenuCtx) void {
    const tools = m.section();
    tools.itemIconEnabled("Print to PDF…", .{ .name = "document-print-symbolic" }, self.canPrintPdf(), &onMenuPrintPdf, ctx);
    tools.itemIconEnabled(
        "Open DevTools",
        .{ .name = "applications-engineering-symbolic" },
        self.devToolsRefusal() == null,
        &onMenuDevTools,
        ctx,
    );
    tools.itemIconEnabled(
        "Fill Password…",
        .{ .name = "dialog-password-symbolic" },
        self.view_live and ctx.page != null,
        &onMenuFillPassword,
        ctx,
    );
}

/// The container rows both menus share: a new tab in a container,
/// the manager, and "always open this site in X" for the page in
/// front of the user. The site rule is keyed on the HOST, re-derived
/// at click time from the face's current address, so no row owns a
/// string.
pub fn appendContainerRows(self: *WebFace, root: *classicmenu.Root, tabs: classicmenu.Menu, ctx: *MenuCtx) void {
    if (containers().len != 0) {
        const cont = tabs.submenu("New Tab in Container");
        for (containers()) |*ctn| {
            const rc = self.allocator.create(ContainerRowCtx) catch continue;
            rc.* = .{ .allocator = self.allocator, .face = self, .container = ctn.id };
            root.own(freeContainerRowCtx, rc);
            var lbuf: [128]u8 = undefined;
            cont.item(classicmenu.escapeLabel(ctn.name, &lbuf), &onMenuOpenInContainer, rc);
        }
    }
    tabs.itemIcon("Containers…", .{ .name = "system-users-symbolic" }, &onMenuContainers, ctx);
    if (self.url == null or containers().len == 0) return;
    const asg = tabs.submenu("Always Open This Site In");
    if (self.allocator.create(ContainerRowCtx) catch null) |rc| {
        rc.* = .{ .allocator = self.allocator, .face = self, .container = 0 };
        root.own(freeContainerRowCtx, rc);
        asg.item("No container", &onMenuAssignSite, rc);
    }
    for (containers()) |*ctn| {
        if (ctn.ephemeral) continue;
        const rc = self.allocator.create(ContainerRowCtx) catch continue;
        rc.* = .{ .allocator = self.allocator, .face = self, .container = ctn.id };
        root.own(freeContainerRowCtx, rc);
        var abuf: [128]u8 = undefined;
        asg.item(classicmenu.escapeLabel(ctn.name, &abuf), &onMenuAssignSite, rc);
    }
}

pub fn onMenuIncognito(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const win = cast.userData(MenuCtx, user).face.ownerWindow() orelse return;
    win.newIncognitoWebTab() catch {};
}

pub fn onMenuContainers(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const win = cast.userData(MenuCtx, user).face.ownerWindow() orelse return;
    @import("../webcontainers.zig").openManager(win);
}

/// Bind (or with container 0, unbind) this page's HOST to a
/// container. Existing tabs are left where they are; the rule
/// governs what opens next — see `containerForUrl`.
pub fn onMenuAssignSite(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const rc = cast.userData(ContainerRowCtx, user);
    const u = rc.face.url orelse return;
    const host = hostOfUrl(u) orelse return;
    setSiteContainer(rc.face.allocator, host, rc.container);
}

pub fn onMenuExtensions(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const face = cast.userData(MenuCtx, user).face;
    const win = face.ownerWindow() orelse return;
    @import("../window.zig").dispatchAction(win, .web_extensions);
}

pub fn onMenuOpenInContainer(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const rc = cast.userData(ContainerRowCtx, user);
    const win = rc.face.ownerWindow() orelse return;
    win.newWebTabInContainer(rc.container, null) catch {};
}

pub fn copyText(self: *WebFace, text: []const u8) void {
    if (self.widgets_dead) return;
    clipboard.copyText(self.allocator, self.root_box, text);
}

/// Read the system clipboard and push the TEXT to the helper.
///
/// The engine cannot read the session selection itself (see
/// `CAP_CLIPBOARD`), so the client is the only one who can. The
/// read is async, and this face may be gone a main-loop turn later:
/// the context therefore carries `(*Client, view id)` and NEVER a
/// `*WebFace`, resolved through `faceByViewOn` when the text lands.
/// The client is the fence — it is never freed.
/// @return false when no helper can take it, so the pane binding
/// falls through to the terminal exactly as before.
pub fn pasteFromClipboard(self: *WebFace) bool {
    if (!self.view_live or !self.cl.has(.clipboard)) return false;
    const ctx = self.allocator.create(PasteCtx) catch return false;
    ctx.* = .{ .allocator = self.allocator, .cl = self.cl, .view = self.view };
    if (!clipboard.readFrom(
        self.allocator,
        clipboard.clipboardFor(self.root_box, .clipboard),
        onWebPasteRead,
        @ptrCast(ctx),
    )) {
        // readFrom's contract: a false return means the callback
        // never runs, so the context is ours to undo.
        self.allocator.destroy(ctx);
        return false;
    }
    return true;
}

/// Ask the helper for the page selection; the answer arrives as
/// `ev_clipboard_text` and is written to the system clipboard there.
/// `cut` also deletes the selection, helper-side and after the
/// answer, so the text cannot be lost to a racing delete.
pub fn copyToClipboard(self: *WebFace, cut: bool) bool {
    if (!self.view_live or !self.cl.has(.clipboard)) return false;
    self.clip_seq +%= 1;
    self.cl.post(proto.ClipboardRead{
        .view = self.view,
        .seq = self.clip_seq,
        .mode = @intFromEnum(@as(proto.ClipboardMode, if (cut) .cut else .copy)),
    });
    return true;
}

/// Firefox's icon-only Back / Forward / Reload strip: the plain
/// page menu's first row. Custom widget (classicmenu rows are
/// label rows), so its buttons pop the menu down themselves.
pub fn buildNavStrip(self: *WebFace, ctx: *MenuCtx) *c.GtkWidget {
    const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    c.gtk_box_set_homogeneous(@ptrCast(row), 1);
    c.gtk_widget_set_margin_top(row, 2);
    c.gtk_widget_set_margin_bottom(row, 2);
    const specs = [_]struct {
        icon: [*:0]const u8,
        tip: [*:0]const u8,
        enabled: bool,
        cb: *const fn (?*c.GtkButton, ?*anyopaque) callconv(.c) void,
    }{
        .{ .icon = "go-previous-symbolic", .tip = "Back", .enabled = self.can_back, .cb = &onNavStripBack },
        .{ .icon = "go-next-symbolic", .tip = "Forward", .enabled = self.can_fwd, .cb = &onNavStripForward },
        .{ .icon = "view-refresh-symbolic", .tip = "Reload", .enabled = true, .cb = &onNavStripReload },
    };
    for (specs) |s| {
        const btn = c.gtk_button_new_from_icon_name(s.icon);
        c.gtk_button_set_has_frame(@ptrCast(btn), 0);
        c.gtk_widget_add_css_class(btn, "flat");
        c.gtk_widget_set_hexpand(btn, 1);
        c.gtk_widget_set_tooltip_text(btn, s.tip);
        c.gtk_widget_set_sensitive(btn, @intFromBool(s.enabled));
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(s.cb), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row), btn);
    }
    return row.?;
}

pub fn navStripFire(user: ?*anyopaque, action: proto.NavAct) void {
    const ctx = cast.userData(MenuCtx, user);
    // Close first, like every classicmenu row does.
    if (ctx.root) |r| {
        if (r.pop) |pop| c.gtk_popover_popdown(@ptrCast(pop));
    }
    ctx.face.navAction(action);
}

pub fn onNavStripBack(_: ?*c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    navStripFire(user, .back);
}

pub fn onNavStripForward(_: ?*c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    navStripFire(user, .forward);
}

pub fn onNavStripReload(_: ?*c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    navStripFire(user, .reload);
}

pub fn onMenuOpenImage(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    if (ctx.image) |u| ctx.face.openInNewTab(u);
}

pub fn onMenuCopyImage(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    if (ctx.image) |u| ctx.face.copyText(u);
}

pub fn onMenuCopySelection(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    if (ctx.sel) |s| ctx.face.copyText(s);
}

pub fn onMenuSearchSelection(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    const sel = ctx.sel orelse return;
    var buf: [2048]u8 = undefined;
    const url = suggest.searchUrl(&buf, searchTemplate(), sel) orelse return;
    ctx.face.openInNewTab(url);
}

pub fn onMenuBack(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    cast.userData(MenuCtx, user).face.navAction(.back);
}

pub fn onMenuForward(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    cast.userData(MenuCtx, user).face.navAction(.forward);
}

pub fn onMenuReload(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    cast.userData(MenuCtx, user).face.navAction(.reload);
}

pub fn onMenuCopyUrl(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    if (ctx.page) |p| ctx.face.copyText(p);
}

pub fn onMenuCopyLink(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    if (ctx.link) |l| ctx.face.copyText(l);
}

pub fn onMenuOpenLink(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    const link = ctx.link orelse return;
    ctx.face.openInNewTab(link);
}

pub fn onMenuBookmark(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    cast.userData(MenuCtx, user).face.toggleBookmark();
}

/// Store (or clear) this origin's popup override and apply it at
/// once, so the next popup from the page obeys without a reload.
pub fn onMenuAllowPopups(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const face = cast.userData(MenuCtx, user).face;
    if (face.nav_origin == null) return;
    face.site_popup = if (face.site_popup == .allow) .inherit else .allow;
    face.pushPopupPolicy();
    if (face.storeOrigin()) |origin|
        webstore.siteSetPopup(face.allocator, origin, if (face.site_popup == .allow) "allow" else "");
}

pub fn onMenuHistory(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const face = cast.userData(MenuCtx, user).face;
    const win = face.ownerWindow() orelse return;
    webhistory.openHistory(win, face.pane);
}

pub fn onMenuBookmarks(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const face = cast.userData(MenuCtx, user).face;
    const win = face.ownerWindow() orelse return;
    webhistory.openBookmarks(win, face.pane);
}

pub fn onMenuUserscripts(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const face = cast.userData(MenuCtx, user).face;
    const win = face.ownerWindow() orelse return;
    @import("../window.zig").dispatchAction(win, .web_userscripts);
}

pub fn onMenuFilterLists(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const face = cast.userData(MenuCtx, user).face;
    const win = face.ownerWindow() orelse return;
    @import("../window.zig").dispatchAction(win, .web_filter_lists);
}

pub fn onMenuSiteStyle(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const face = cast.userData(MenuCtx, user).face;
    const win = face.ownerWindow() orelse return;
    const origin = face.nav_origin orelse return;
    // The style is keyed by HOST: strip the origin's scheme and
    // any port, so http/https share one style per site.
    var host = origin;
    if (std.mem.indexOf(u8, host, "://")) |i| host = host[i + 3 ..];
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |ci| host = host[0..ci];
    if (host.len == 0) return;
    webuserscripts.openSiteStyle(win, host);
}

pub fn onMenuDevTools(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    cast.userData(MenuCtx, user).face.openDevTools();
}

pub fn onMenuPrintPdf(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    cast.userData(MenuCtx, user).face.printToPdf();
}

pub fn onMenuFillPassword(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    cast.userData(MenuCtx, user).face.fillPassword();
}

// ---- toolbar hamburger -------------------------------------------

pub fn onBurger(btn: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    cast.userData(WebFace, user).showBurgerMenu(btn);
}

/// The toolbar's primary menu: every verb this face already has,
/// gathered in one place.
///
/// It shares the page context menu's handlers (and its `MenuCtx`)
/// rather than repeating them — the difference between the two
/// menus is which rows they list, never what a row does. Link rows
/// are absent here: a toolbar click has no hit test behind it.
pub fn showBurgerMenu(self: *WebFace, anchor: *c.GtkWidget) void {
    if (self.widgets_dead) return;
    const root = classicmenu.Root.create(self.allocator) orelse return;
    const ctx = self.allocator.create(MenuCtx) catch {
        root.destroy();
        return;
    };
    ctx.* = .{ .allocator = self.allocator, .face = self };
    if (self.url) |u| ctx.page = self.allocator.dupe(u8, u) catch null;
    root.own(freeMenuCtx, ctx);

    const m = root.top();
    m.itemIconEnabled("Back", .{ .name = "go-previous-symbolic" }, self.can_back, &onMenuBack, ctx);
    m.itemIconEnabled("Forward", .{ .name = "go-next-symbolic" }, self.can_fwd, &onMenuForward, ctx);
    m.itemIcon("Reload", .{ .name = "view-refresh-symbolic" }, &onMenuReload, ctx);

    const view = m.section();
    view.itemIcon("Find in Page…", .{ .name = "edit-find-symbolic" }, &onMenuFind, ctx);
    view.itemIcon("Zoom In", .{ .name = "zoom-in-symbolic" }, &onMenuZoomIn, ctx);
    view.itemIcon("Zoom Out", .{ .name = "zoom-out-symbolic" }, &onMenuZoomOut, ctx);
    view.itemIconEnabled("Reset Zoom", .{ .name = "zoom-original-symbolic" }, self.zoom_x100 != 0, &onMenuZoomReset, ctx);
    view.check("Reader View", self.reader_active, &onMenuReader, ctx);

    const page = m.section();
    page.itemIconEnabled("Copy Page URL", .none, ctx.page != null, &onMenuCopyUrl, ctx);
    page.checkEnabled("Bookmark This Page", self.bookmark_id != 0, ctx.page != null, &onMenuBookmark, ctx);
    page.checkEnabled(
        "Allow Popups on This Site",
        self.site_popup == .allow,
        self.nav_origin != null,
        &onMenuAllowPopups,
        ctx,
    );

    const store_section = m.section();
    store_section.itemIcon("History", .{ .name = "document-open-recent-symbolic" }, &onMenuHistory, ctx);
    store_section.itemIcon("Bookmarks", .{ .name = "sketerm-starred-symbolic" }, &onMenuBookmarks, ctx);
    // The strip shows itself when a download starts; this row is
    // how it comes BACK after being dismissed, so it is dead
    // weight while this face has downloaded nothing.
    store_section.checkEnabled(
        "Downloads",
        self.downloads.items.len != 0 and c.gtk_widget_get_visible(self.dl_strip) != 0,
        self.downloads.items.len != 0,
        &onMenuDownloads,
        ctx,
    );

    self.appendToolRows(m, ctx);

    const tabs = m.section();
    tabs.itemIcon("New Incognito Web Tab", .{ .name = "view-private-symbolic" }, &onMenuIncognito, ctx);
    tabs.itemIcon("New Tor Web Tab", .{ .name = webroute.Choice.tor.icon() }, &onMenuTorTab, ctx);
    // The current tab's route, as a submenu of the same rows the
    // toolbar's route button offers.
    {
        const current = webroute.Choice.fromKind(self.routeSpec().kind);
        var rbuf: [64]u8 = undefined;
        var sbuf: [webroute.HOST_LABEL_MAX + 8]u8 = undefined;
        const rlabel = std.fmt.bufPrintZ(&rbuf, "Route: {s}", .{self.routeSpec().shortLabel(&sbuf)}) catch "Route";
        const rm = tabs.submenuIcon(rlabel.ptr, .{ .name = current.icon() });
        self.appendRouteRows(root, rm, current);
    }
    self.appendContainerRows(root, tabs, ctx);
    var shell_buf: [96]u8 = undefined;
    tabs.itemIconEnabled(
        self.shellRowLabel(&shell_buf),
        .{ .name = "sketerm-terminal-symbolic" },
        self.pane != null,
        &onMenuShell,
        ctx,
    );

    appmenu.appendHelp(
        m,
        self.allocator,
        if (self.ownerWindow()) |w| @ptrCast(@alignCast(w.app_window)) else null,
        .web,
    );

    _ = root.popup(
        anchor,
        @floatFromInt(@divTrunc(c.gtk_widget_get_width(anchor), 2)),
        @floatFromInt(c.gtk_widget_get_height(anchor)),
    );
}

pub fn onMenuFind(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    cast.userData(MenuCtx, user).face.openFind();
}

pub fn onMenuZoomIn(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    cast.userData(MenuCtx, user).face.zoomStep(1);
}

pub fn onMenuZoomOut(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    cast.userData(MenuCtx, user).face.zoomStep(-1);
}

pub fn onMenuZoomReset(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    cast.userData(MenuCtx, user).face.zoomReset();
}

pub fn onMenuDownloads(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const face = cast.userData(MenuCtx, user).face;
    if (face.widgets_dead) return;
    const on = c.gtk_widget_get_visible(face.dl_strip) != 0;
    c.gtk_widget_set_visible(face.dl_strip, if (on) 0 else 1);
}

pub fn onMenuShell(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    cast.userData(MenuCtx, user).face.showShell();
}

/// The menu row's text for "show the shell", carrying the chord the
/// pane's binding table has for `toggle_web_face` when one is bound
/// (there is no default), so the row teaches the shortcut.
pub fn shellRowLabel(self: *WebFace, buf: []u8) [*:0]const u8 {
    const base = "Show This Pane's Shell";
    const pane = self.pane orelse return base;
    const ictx = pane.input_ctx orelse return base;
    for (ictx.bindings) |b| {
        if (b.action != .toggle_web_face or b.keyval == 0) continue;
        const raw = c.gtk_accelerator_get_label(b.keyval, b.mods) orelse return base;
        defer c.g_free(raw);
        const label = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        return (std.fmt.bufPrintZ(buf, "{s} ({s})", .{ base, label }) catch return base).ptr;
    }
    return base;
}
