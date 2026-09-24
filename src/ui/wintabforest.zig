//! Tree-style tabs, split out of window.zig: the window-level tab
//! forest (model: src/ui/tabforest.zig) and the vertical tree sidebar
//! that views it (src/ui/tabsidebar.zig), plus the web-group chrome
//! and the web tabs that nest under an opener. Every forest mutation
//! goes through `forestChanged`. Functions keep the owning *Window
//! receiver and are aliased back into Window.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const winmod = @import("window.zig");
const Window = winmod.Window;
const Pane = @import("pane.zig").Pane;
const Terminal = @import("../terminal.zig").Terminal;
const tabforest_mod = @import("tabforest.zig");
const tabsidebar_mod = @import("tabsidebar.zig");
const webgroup = @import("webgroup.zig");
const logActionError = winmod.logActionError;
const showToast = winmod.showToast;
const tabPageForPane = winmod.tabPageForPane;
const widgetIsAncestor = winmod.widgetIsAncestor;

pub fn childInsertPos(self: *const Window) tabforest_mod.InsertPos {
    return switch (self.config.tab_child_insert) {
        .last => .last,
        .first => .first,
    };
}

/// Refresh every view of the tab forest after a mutation: the
/// strip's hidden state, the sidebar rows, and (under
/// SKETERM_VERIFY_TREE) the model/view cross-check.
pub fn forestChanged(self: *Window) void {
    if (self.destroying) return;
    self.tabbar.refreshHidden();
    if (self.tab_sidebar) |sb| {
        if (c.gtk_widget_get_visible(sb.root) != 0) sb.rebuild();
    }
    // Forest-only verify: forestChanged fires from page-attached,
    // BEFORE appendOrInsertTab has attached the new page's
    // PaneTree — the pane-tree check would warn spuriously there.
    self.verifyTabForest();
}

/// Collapse / expand a tab's subtree. Collapsing pulls the
/// selection up to the collapsed tab if it sat inside the hidden
/// subtree (TST behaviour), and offers the newly hidden WEB panes
/// to the discard path — a collapsed subtree is the natural
/// unload candidate.
pub fn setTabCollapsed(self: *Window, page: *c.AdwTabPage, collapsed: bool) void {
    self.tab_forest.setCollapsed(page, collapsed);
    if (collapsed) {
        if (c.adw_tab_view_get_selected_page(self.tab_view)) |sel| {
            if (self.tab_forest.isHidden(sel))
                c.adw_tab_view_set_selected_page(self.tab_view, page);
        }
        discardCollapsedWebPanes(self, page);
    }
    self.forestChanged();
}

/// Close a tab and its whole subtree, regardless of the
/// `tab_close_parent` setting (the context menu's explicit verb).
/// Deepest-first so each close only ever promotes an empty child
/// list; every member still gets its own dirty-editor veto.
pub fn closeTabSubtree(self: *Window, page: *c.AdwTabPage) void {
    var subtree: std.ArrayList(*c.AdwTabPage) = .empty;
    defer subtree.deinit(self.allocator);
    self.tab_forest.appendSubtree(self.allocator, page, &subtree) catch return;
    self.closing_subtree = true;
    defer self.closing_subtree = false;
    var i = subtree.items.len;
    while (i > 0) {
        i -= 1;
        _ = c.adw_tab_view_close_page(self.tab_view, subtree.items[i]);
    }
}

/// Move one tab into a fresh window (the strip drag-out, as a
/// menu verb). The PaneTree travels with the page as qdata.
pub fn moveTabToNewWindow(self: *Window, page: *c.AdwTabPage) void {
    if (c.adw_tab_view_get_n_pages(self.tab_view) <= 1) return;
    const win = self.spawnSecondaryWindow() orelse return;
    if (!win.transferPageFrom(self.tab_view, page, 0))
        win.destroyToplevel();
}

/// Discard the web pages of every pane hidden by collapsing
/// `page`'s subtree (the descendants, not the collapsed tab
/// itself). Panes without a web face are untouched; discard keeps
/// the last frame and revives on next look, so this is free.
fn discardCollapsedWebPanes(self: *Window, page: *c.AdwTabPage) void {
    const webface = @import("webface.zig");
    if (!webface.discardSupported()) return;
    var subtree: std.ArrayList(*c.AdwTabPage) = .empty;
    defer subtree.deinit(self.allocator);
    self.tab_forest.appendSubtree(self.allocator, page, &subtree) catch return;
    if (subtree.items.len <= 1) return;
    for (subtree.items[1..]) |desc| {
        const t = Window.tabTreeOf(desc) orelse continue;
        var leaves: std.ArrayList(*Pane) = .empty;
        defer leaves.deinit(self.allocator);
        t.appendLeaves(self.allocator, &leaves) catch continue;
        for (leaves.items) |pane| {
            if (webface.WebFace.fromPane(pane)) |face| _ = face.discardNow();
        }
    }
}

/// Reparent `page` (subtree and all) under `new_parent`, or to
/// the root level when null — the sidebar drag-drop entry point.
pub fn tabForestReparent(self: *Window, page: *c.AdwTabPage, new_parent: ?*c.AdwTabPage) void {
    self.tab_forest.reparent(page, new_parent, self.childInsertPos()) catch |err| {
        if (err == error.WouldCycle)
            showToast(self, "Cannot drop a tab into its own subtree.");
        return;
    };
    self.forestChanged();
}

/// Move `page` next to `anchor` among the anchor's siblings — the
/// sidebar's drop-between-rows gesture. Only the FOREST order moves;
/// the AdwTabView strip keeps its own flat order (see tabforest.zig).
pub fn tabForestMoveNextTo(self: *Window, page: *c.AdwTabPage, anchor: *c.AdwTabPage, after: bool) void {
    self.tab_forest.moveNextTo(page, anchor, after) catch |err| {
        if (err == error.WouldCycle)
            showToast(self, "Cannot drop a tab into its own subtree.");
        return;
    };
    self.forestChanged();
}

/// Show / hide the vertical tree-style tab sidebar
/// (toggle_tab_sidebar action; startup state = show_tab_sidebar).
pub fn toggleTabSidebarVisibility(self: *Window) void {
    const sb = self.tab_sidebar orelse return;
    const visible = c.gtk_widget_get_visible(sb.root) != 0;
    self.sidebar_user_set = true;
    applyTabSidebarVisible(self, !visible);
}

/// The sidebar's visibility is also its MODE switch: while it is
/// showing, a browser's pages live in it and new tabs go there;
/// while it is hidden, a browser falls back to its own in-pane tab
/// strip and new tabs are window tabs. So every show/hide has to
/// re-ask each browser to redraw its chrome.
/// Follow the configured default. A window whose sidebar the user
/// set by hand keeps its own state, so editing the preference (or
/// any other config write triggering a reload) never overrides a
/// deliberate per-window choice.
pub fn setTabSidebarVisible(self: *Window, show: bool) void {
    if (self.sidebar_user_set) return;
    applyTabSidebarVisible(self, show);
}

/// Apply visibility to THIS window only. Never writes
/// `show_tab_sidebar` back to config: that key is the new-window
/// default, and persisting a runtime toggle into it is what used to
/// flip the sidebar in every other window on the next reload.
fn applyTabSidebarVisible(self: *Window, show: bool) void {
    const sb = self.tab_sidebar orelse return;
    c.gtk_widget_set_visible(sb.root, @intFromBool(show));
    if (show) {
        // A GtkPaned forgets a position set while its start child
        // was hidden (the file browser's places sidebar hit this
        // too) — re-assert the saved width as it comes back.
        c.gtk_paned_set_position(@ptrCast(self.content_box), self.config.tab_sidebar_width);
        // Rows are not rebuilt while hidden; catch up on reveal.
        sb.rebuild();
    }
    refreshWebGroupChrome(self);
    @import("prefs.zig").noteTabSidebarVisibility(@ptrCast(self), show);
}

/// True while the tree sidebar is the tab surface for browsers:
/// pages of a browser are listed there, and "new tab" inside a
/// browser means a new page rather than a new window tab.
pub fn browserPagesInSidebar(self: *Window) bool {
    // A popup window has no tab surface at all: its one page is
    // the whole window.
    if (self.popup_window) return false;
    const sb = self.tab_sidebar orelse return false;
    return c.gtk_widget_get_visible(sb.root) != 0;
}

/// The pane the selected tab is focused on — which face the sidebar
/// and the new-tab action are talking about. `last_focused` is
/// validated the way tabchrome does it: a closed pane's address can
/// be reused, so the pointer must still be a live pane of THIS tab.
pub fn selectedTabPane(self: *Window) ?*Pane {
    const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return null;
    const child = c.adw_tab_page_get_child(page) orelse return null;
    if (Window.tabTreeOf(page)) |t| {
        if (t.last_focused) |lf| {
            for (self.panes.items) |p| {
                if (p == lf and widgetIsAncestor(@ptrCast(child), p.widget())) return p;
            }
        }
    }
    for (self.panes.items) |p| {
        if (widgetIsAncestor(@ptrCast(child), p.widget())) return p;
    }
    return null;
}

/// The browser whose pages the sidebar should be listing, or null
/// when the selected tab is not a browser (then the sidebar shows
/// the window's own tab tree, as before).
pub fn sidebarGroup(self: *Window) ?*webgroup.Group {
    if (self.destroying) return null;
    if (!self.browserPagesInSidebar()) return null;
    const pane = self.selectedTabPane() orelse return null;
    if (!pane.webFaceVisible()) return null;
    return webgroup.Group.fromPane(pane);
}

/// Is `g` the group the sidebar is currently listing? A group that
/// is answers with rows in the sidebar and hides its own strip.
pub fn sidebarListsGroup(self: *Window, g: *webgroup.Group) bool {
    if (!self.browserPagesInSidebar()) return false;
    const cur = self.sidebarGroup() orelse return false;
    return cur == g;
}

/// A browser's page list changed (page opened, closed, reordered).
pub fn webGroupChanged(self: *Window, g: *webgroup.Group) void {
    if (self.destroying) return;
    if (self.sidebarListsGroup(g)) {
        if (self.tab_sidebar) |sb| sb.rebuild();
    }
    g.refreshChrome();
}

/// Re-resolve what the sidebar should be showing. Called when the
/// selected tab or the focused pane changes — either can swap the
/// sidebar between the window tree and a browser's pages.
pub fn sidebarRefresh(self: *Window) void {
    if (self.destroying) return;
    const sb = self.tab_sidebar orelse return;
    if (c.gtk_widget_get_visible(sb.root) == 0) return;
    sb.rebuild();
    refreshWebGroupChrome(self);
}

pub fn sidebarRefreshSelection(self: *Window) void {
    if (self.destroying) return;
    const sb = self.tab_sidebar orelse return;
    if (c.gtk_widget_get_visible(sb.root) == 0) return;
    sb.refreshSelection();
}

/// One page's title changed: update just its row rather than
/// rebuilding the list under the user's pointer.
pub fn sidebarNoteWebTitle(self: *Window, face: *@import("webface.zig").WebFace) void {
    if (self.destroying) return;
    const sb = self.tab_sidebar orelse return;
    if (c.gtk_widget_get_visible(sb.root) == 0) return;
    sb.noteWebTitle(face);
}

/// Every browser in this window re-decides whether to draw its own
/// tab strip (it does when the sidebar is not listing it).
fn refreshWebGroupChrome(self: *Window) void {
    for (self.panes.items) |p| {
        if (webgroup.Group.fromPane(p)) |g| g.refreshChrome();
    }
}

/// "New tab" while a browser owns the sidebar means a new PAGE in
/// that browser. Answers true when it handled the request.
pub fn newTabInBrowser(self: *Window) bool {
    if (!self.browserPagesInSidebar()) return false;
    const g = self.sidebarGroup() orelse return false;
    _ = g.newPage(null, g.active()) catch return false;
    return true;
}

/// tab_collapse / tab_expand on the selected tab. Collapsing a
/// tab without children is a no-op rather than a surprise.
pub fn collapseCurrentTab(self: *Window, collapse: bool) void {
    // Act on the tree the user can SEE. While the sidebar lists a
    // browser's pages, folding the window's tab tree instead would
    // move something invisible.
    if (self.sidebarGroup()) |g| {
        const face = g.active() orelse return;
        if (g.forest.find(face) == null) return;
        if (collapse and !g.forest.hasChildren(face)) return;
        g.forest.setCollapsed(face, collapse);
        if (self.tab_sidebar) |sb| sb.rebuild();
        return;
    }
    const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return;
    if (collapse and !self.tab_forest.hasChildren(page)) return;
    self.setTabCollapsed(page, collapse);
}

/// tab_tree_next / tab_tree_prev: walk the VISIBLE tree order
/// (collapsed subtrees skipped), wrapping at the ends.
pub fn tabTreeStep(self: *Window, forward: bool) void {
    // Same rule as collapseCurrentTab: step through whichever tree
    // the sidebar is showing.
    if (self.sidebarGroup()) |g| {
        const face = g.active() orelse return;
        const next = (g.forest.stepVisible(self.allocator, face, forward) catch return) orelse return;
        g.setActive(next);
        return;
    }
    const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return;
    const next = (self.tab_forest.stepVisible(self.allocator, page, forward) catch return) orelse return;
    c.adw_tab_view_set_selected_page(self.tab_view, next);
}

/// Web tab nested under `opener` in the tab tree (a page popup or
/// an open-link-in-new-tab from that tab). The pending parent is
/// consumed by the page-attached handler minting the forest node.
pub fn newWebTabFrom(self: *Window, url: ?[]const u8, opener: ?*c.AdwTabPage) !void {
    self.forest_pending_parent = opener;
    defer self.forest_pending_parent = null;
    try self.newWebTabAt(url);
}

/// Web tab PRESENTING an assistant's page (`webwatch.zig`): the
/// first page of a watch, its face observing alias `view` on the
/// watch's client. Returns the pane the tab was built around.
pub fn newWebTabObserving(self: *Window, watch: *@import("webwatch.zig").Watch, view: u32) !*Pane {
    const before = self.panes.items.len;
    try self.newShellTab("Web");
    if (self.panes.items.len <= before) return error.TabSpawnFailed;
    const pane = self.panes.items[self.panes.items.len - 1];
    _ = @import("webface.zig").WebFace.attachObserved(self.allocator, pane, view, watch.cl, @ptrCast(watch)) catch |err| {
        logActionError("watch attach", err);
        return err;
    };
    if (@import("webgroup.zig").Group.fromPane(pane)) |g| g.watch = @ptrCast(watch);
    pane.refreshLeaseChip();
    return pane;
}

/// Web tab PRESENTING a view the helper already created -- a real
/// popup, whose page is already loading with its opener intact.
/// Nothing is navigated here: navigating would replace the document
/// the engine opened and, with it, the relationship it exists for.
pub fn newWebTabForView(
    self: *Window,
    view: u32,
    on: *@import("webface.zig").Client,
    opener: ?*c.AdwTabPage,
    how: @import("webface.zig").WebFace.PopupPresentation,
) !void {
    self.forest_pending_parent = opener;
    defer self.forest_pending_parent = null;
    const before = self.panes.items.len;
    try self.newShellTab("Web");
    if (self.panes.items.len <= before) return error.TabSpawnFailed;
    const pane = self.panes.items[self.panes.items.len - 1];
    _ = @import("webface.zig").WebFace.attachPopupView(self.allocator, pane, view, on, how) catch |err| {
        logActionError("popup attach", err);
        return err;
    };
}
