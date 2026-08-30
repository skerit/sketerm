//! WebGroup — several browser PAGES inside one pane, one visible.
//!
//! The window tab is "the browser"; the pages inside it are what the
//! tree-style tab sidebar lists (`src/ui/tabsidebar.zig` in `.browser`
//! mode), exactly as the editor face owns its own document tabs.
//!
//! ## Why N whole `WebFace`s and not one face owning N views
//!
//! Everything that binds a helper-side view to its widgets is ALREADY
//! per-face and already correct: the refcounted frame mapping, the
//! dmabuf import cache, the pacer and its frame-clock tick, the discard
//! countdown, the held certificate/permission decisions, link hints,
//! the a11y mirror, and the fixed `signal_objs` tracking array whose
//! docblock warns that overflowing it silently drops a disconnect.
//! Splitting `WebFace` into face-level chrome plus per-view page state
//! would have had to re-implement all of it, and re-derive every
//! invariant those pieces encode.
//!
//! A `GtkNotebook` instead UNMAPS the pages it is not showing, and the
//! web face already turns `view_area` map/unmap into `view_show` /
//! `view_hide` + the discard timer (`WebFace.setOnScreen`). So a
//! background page stops painting, stops costing the engine anything,
//! and eventually discards itself — with no new code and no new state
//! machine. Page geometry follows for the same reason: the sensor gets
//! its allocation when the page maps, so a page is resized when it is
//! shown rather than N times per pane resize.
//!
//! ## The strip is the fallback, the sidebar is the point
//!
//! `TabHost` (the shared GtkNotebook strip mechanics the file browser
//! and the editor use) draws the in-pane tab strip. It is shown only
//! when the sidebar is NOT listing this group and there is more than
//! one page — otherwise a user who hides the sidebar would have pages
//! with no way to reach them.
//!
//! ## Lifetime
//!
//! The group is what the Pane holds (`Pane.web_ctx`), so it owns the
//! pane's five-pointer face contract and fans prepare-destroy / deinit
//! out to its pages. `WebFace.fromPane` answers with the ACTIVE page,
//! which is what every existing caller means by "the browser on this
//! pane".

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const facehost = @import("facehost.zig");
const classicmenu = @import("browser/classicmenu.zig");
const clipboard = @import("clipboard.zig");
const tabhost = @import("tabhost.zig");
const tabforest = @import("tabforest.zig");
const Pane = @import("pane.zig").Pane;
const urlhost = @import("../web/urlhost.zig");
const web_model = @import("../web/model.zig");
const webface = @import("webface.zig");
const WebFace = webface.WebFace;

pub const Forest = tabforest.Forest(*WebFace);

/// One page: its face plus the strip label that fronts it. The label
/// is owned by its widgets (freed by the label box's qdata notify), so
/// it is only ever borrowed here and dropped on removal.
pub const Page = struct {
    face: *WebFace,
    label: ?*tabhost.TabLabel = null,
};

pub const Group = struct {
    allocator: std.mem.Allocator,
    pane: *Pane,
    host: tabhost.TabHost,
    pages: std.ArrayList(Page) = .empty,
    /// Opener nesting across the pages, the same model the window-level
    /// tab tree uses.
    forest: Forest,
    /// Set once the pane's widgets are gone; every widget touch is
    /// skipped past that point (the face contract's `widgets_dead`).
    widgets_dead: bool = false,
    /// True while `deinit` is unwinding, so a page closing itself
    /// during teardown does not re-enter the list.
    tearing_down: bool = false,
    /// The `webwatch.Watch` whose pages this group shows, if this
    /// browser is a watch on an assistant's browser. Opaque here: the
    /// pane's lease chip resolves it through `webwatch.chipText`.
    watch: ?*anyopaque = null,
    /// The face the notebook is switching to (or settled on). Tracked
    /// here because GtkNotebook emits "switch-page" BEFORE updating its
    /// current-page property, so anything reading `active()` from that
    /// handler (the sidebar's selection refresh) would get the OLD page
    /// and paint the previously active row as current.
    current: ?*WebFace = null,

    /// The group on `pane`, if it wears a web face at all.
    pub fn fromPane(pane: *Pane) ?*Group {
        const ctx = pane.web_ctx orelse return null;
        return @ptrCast(@alignCast(ctx));
    }

    /// The group on `pane`, creating and attaching one if the pane has
    /// no web face yet.
    pub fn ensure(allocator: std.mem.Allocator, pane: *Pane) !*Group {
        if (fromPane(pane)) |g| return g;
        const self = try allocator.create(Group);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .pane = pane,
            .host = tabhost.TabHost.init(allocator),
            .forest = Forest.init(allocator),
        };
        const nb = self.host.widget();
        // The strip is hidden until a second page exists; a lone page
        // must look exactly like the single-view face always did.
        c.gtk_notebook_set_show_tabs(self.host.notebook, 0);
        c.gtk_notebook_set_show_border(self.host.notebook, 0);
        self.host.ctx = @ptrCast(self);
        self.host.on_close = &hostCloseCb;
        self.host.on_new = &hostNewCb;
        self.host.on_reordered = &hostReorderedCb;
        self.host.tab_menu = .{
            .extra = &tabMenuExtra,
            .duplicate = &tabMenuDuplicate,
        };
        _ = c.g_signal_connect_data(nb, "switch-page", @ptrCast(&onSwitchPage), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        self.host.installStripGestures();

        if (!pane.attachWeb(nb, @ptrCast(self), prepareDestroyCb, destroyCb, focusCb)) {
            // The notebook never reached a parent, so its floating
            // reference is still the only one.
            _ = c.g_object_ref_sink(@ptrCast(nb));
            c.g_object_unref(@ptrCast(nb));
            self.forest.deinit();
            allocator.destroy(self);
            return error.PaneHasNoWrapper;
        }
        return self;
    }

    /// Adopt a freshly built face as a page. `opener` nests it under an
    /// existing page (the tree-style relationship); null makes it a
    /// root. The new page is made current.
    /// Every fallible step runs BEFORE the widget gets a parent, so a
    /// failure leaves `face.root_box` still floating and the caller's
    /// ref_sink/unref is the correct disposal. Rolling the notebook
    /// page back instead would destroy the box and turn that disposal
    /// into a double free.
    pub fn adopt(self: *Group, face: *WebFace, opener: ?*WebFace, pos: tabforest.InsertPos) !void {
        try self.pages.ensureUnusedCapacity(self.allocator, 1);
        if (opener) |op| {
            if (self.forest.find(op) != null) {
                _ = self.forest.addChild(face, op, pos) catch try self.forest.add(face);
            } else {
                _ = try self.forest.add(face);
            }
        } else {
            _ = try self.forest.add(face);
        }
        errdefer self.forest.remove(face) catch {};
        const label = self.host.addPage(face.root_box, pageTitle(face)) orelse
            return error.OutOfMemory;
        self.pages.appendAssumeCapacity(.{ .face = face, .label = label });
        self.host.setCurrentPage(face.root_box);
        self.refreshChrome();
        self.notifyWindow();
    }

    pub fn count(self: *const Group) usize {
        return self.pages.items.len;
    }

    /// The page the notebook is showing — what `WebFace.fromPane`
    /// answers with, and what every pane-scoped web verb acts on.
    pub fn active(self: *Group) ?*WebFace {
        // The switch-page tracker wins while it names a live page: it
        // is ahead of the notebook's current-page property during the
        // switch itself (see `current`'s docblock).
        if (self.current) |face| {
            if (self.indexOf(face) != null) return face;
        }
        const cur = self.host.currentPage() orelse {
            // Before the notebook has settled (during the very first
            // adopt) the list order is the honest answer.
            return if (self.pages.items.len > 0) self.pages.items[0].face else null;
        };
        return self.faceForWidget(cur);
    }

    fn faceForWidget(self: *Group, w: *c.GtkWidget) ?*WebFace {
        for (self.pages.items) |p| {
            if (p.face.root_box == w) return p.face;
        }
        return null;
    }

    fn indexOf(self: *Group, face: *WebFace) ?usize {
        for (self.pages.items, 0..) |p, i| {
            if (p.face == face) return i;
        }
        return null;
    }

    pub fn has(self: *Group, face: *WebFace) bool {
        return self.indexOf(face) != null;
    }

    /// Raise `face` (and the pane's web face with it).
    pub fn setActive(self: *Group, face: *WebFace) void {
        if (self.widgets_dead) return;
        if (self.indexOf(face) == null) return;
        self.host.setCurrentPage(face.root_box);
    }

    /// Close one page. The last page closing takes the whole face down
    /// (the pane returns to whatever was underneath), which is what
    /// closing the only page of a browser has always done.
    pub fn closePage(self: *Group, face: *WebFace, policy: tabforest.ClosePolicy) void {
        if (self.tearing_down) return;
        if (self.indexOf(face) == null) return;
        if (self.pages.items.len <= 1) return self.detachAll();
        switch (policy) {
            .close_subtree => {
                var subtree: std.ArrayList(*WebFace) = .empty;
                defer subtree.deinit(self.allocator);
                self.forest.appendSubtree(self.allocator, face, &subtree) catch {
                    self.dropPage(face);
                    self.refreshChrome();
                    self.notifyWindow();
                    return;
                };
                // Closing a subtree that IS the whole browser is the
                // same request as closing its last page.
                if (subtree.items.len >= self.pages.items.len) return self.detachAll();
                // Deepest first, so each removal only ever promotes an
                // empty child list.
                var i = subtree.items.len;
                while (i > 0) {
                    i -= 1;
                    self.dropPage(subtree.items[i]);
                }
            },
            .promote => self.dropPage(face),
        }
        self.refreshChrome();
        self.notifyWindow();
    }

    /// Take the whole web face off the pane: the pane goes back to
    /// whatever was underneath, which is what closing the only page of
    /// a browser has always done.
    ///
    /// `detachWeb` FREES this group (it runs the face contract's
    /// deinit), so the window is resolved first and nothing touches
    /// `self` afterwards. The sidebar is told because it may have been
    /// listing rows for pages that no longer exist.
    fn detachAll(self: *Group) void {
        const win = self.ownerWindow();
        const pane = self.pane;
        pane.detachWeb();
        if (win) |w| w.sidebarRefresh();
    }

    /// Remove one page's widgets and free its face. `remove` on the
    /// forest promotes the children, matching the window-level tree.
    fn dropPage(self: *Group, face: *WebFace) void {
        const idx = self.indexOf(face) orelse return;
        if (self.current == face) self.current = null;
        _ = self.pages.orderedRemove(idx);
        self.forest.remove(face) catch {};
        // Same two-phase order the Pane face contract uses: disconnect
        // while the widgets are alive, then destroy them, then free.
        face.prepareDestroy(self.widgets_dead);
        if (!self.widgets_dead) self.host.removePage(face.root_box);
        face.deinit();
    }

    /// A new page in this group, nested under `opener`.
    pub fn newPage(self: *Group, url: ?[]const u8, opener: ?*WebFace) !*WebFace {
        return webface.WebFace.attachPage(self.allocator, self, url, opener);
    }

    /// Page in an EXPLICIT container (restore, and "open this site in
    /// container X"), rather than inheriting the opener's.
    pub fn newPageIn(self: *Group, url: ?[]const u8, opener: ?*WebFace, container: u32) !*WebFace {
        return webface.WebFace.attachPageIn(self.allocator, self, url, opener, container);
    }

    /// Show the in-pane strip only when the sidebar is not listing this
    /// group's pages and there is more than one of them.
    pub fn refreshChrome(self: *Group) void {
        if (self.widgets_dead) return;
        const listed = if (self.ownerWindow()) |win| win.sidebarListsGroup(self) else false;
        const show = self.pages.items.len > 1 and !listed;
        c.gtk_notebook_set_show_tabs(self.host.notebook, @intFromBool(show));
    }

    /// A page's title changed: the strip label follows, and so does the
    /// sidebar row when it is the one listing us.
    pub fn noteTitle(self: *Group, face: *WebFace) void {
        if (self.widgets_dead) return;
        const idx = self.indexOf(face) orelse return;
        if (self.pages.items[idx].label) |lbl| lbl.setTitle(pageTitle(face));
        if (self.ownerWindow()) |win| win.sidebarNoteWebTitle(face);
    }

    /// Snapshot every page for layout persistence, with the nesting
    /// expressed as parent INDICES into the same array (a pointer means
    /// nothing to the next process). Pages that present a view they did
    /// not create — a DevTools inspector — are skipped: a fresh helper
    /// knows nothing about the old view id, so restoring one would give
    /// back a blank pane.
    pub fn paneState(self: *Group, arena: std.mem.Allocator) !web_model.PaneState {
        var out: std.ArrayList(web_model.PageState) = .empty;
        var kept: std.ArrayList(*WebFace) = .empty;
        defer kept.deinit(arena);
        const cur = self.active();
        var active_idx: u32 = 0;
        for (self.pages.items) |p| {
            if (p.face.attached) continue;
            const st = try p.face.paneState(arena);
            if (cur == p.face) active_idx = @intCast(out.items.len);
            try out.append(arena, .{
                .url = st.url,
                .zoom_level_x100 = st.zoom_level_x100,
                .container = p.face.container,
                .scroll_x = p.face.scroll_x,
                .scroll_y = p.face.scroll_y,
            });
            try kept.append(arena, p.face);
        }
        // Second pass: a parent is only referable once every kept page
        // has an index (Forest.parentIndices, shared with the window
        // tab tree's own serialization and unit-tested there).
        const parents = try arena.alloc(?u32, kept.items.len);
        self.forest.parentIndices(kept.items, parents);
        for (parents, 0..) |p, i| out.items[i].parent = if (p) |v| @intCast(v) else -1;
        if (out.items.len == 0) return .{};
        return .{
            .url = out.items[active_idx].url,
            .zoom_level_x100 = out.items[active_idx].zoom_level_x100,
            .pages = out.items,
            .active_page = active_idx,
            .container = out.items[active_idx].container,
        };
    }

    /// Rebuild a saved page list onto a group that already holds the
    /// FIRST page (the restore path attaches one face the ordinary way,
    /// then hands the rest here).
    pub fn restorePages(self: *Group, state: web_model.PaneState) void {
        if (state.pages.len <= 1) return;
        var built: std.ArrayList(*WebFace) = .empty;
        defer built.deinit(self.allocator);
        // Page 0 is the one already attached.
        built.append(self.allocator, self.pages.items[0].face) catch return;
        for (state.pages[1..]) |ps| {
            const parent: ?*WebFace = blk: {
                if (ps.parent < 0) break :blk null;
                const pi: usize = @intCast(ps.parent);
                if (pi >= built.items.len) break :blk null;
                break :blk built.items[pi];
            };
            const url: ?[]const u8 = if (ps.url.len > 0) ps.url else null;
            // The SAVED container, not the opener's: a restored tree can
            // mix identities, and inheriting would quietly move a page
            // into whichever container its parent happened to be in.
            const face = self.newPageIn(url, parent, ps.container) catch break;
            face.applyRestoredZoom(ps.zoom_level_x100);
            face.applyRestoredScroll(ps.scroll_x, ps.scroll_y);
            built.append(self.allocator, face) catch break;
        }
        const want: usize = @intCast(state.active_page);
        if (want < built.items.len) self.setActive(built.items[want]);
    }

    pub fn ownerWindow(self: *Group) ?*@import("window.zig").Window {
        if (self.widgets_dead) return null;
        return facehost.windowOf(self.host.widget());
    }

    fn notifyWindow(self: *Group) void {
        const win = self.ownerWindow() orelse return;
        win.webGroupChanged(self);
    }

    /// Title for a page row / strip label: the page title, else its
    /// host, else a placeholder — never an empty label.
    ///
    /// `about:blank` counts as blank, both as a title and as an
    /// address: it is what a fresh page reports before the user has
    /// typed anything, and the address bar already blanks it for the
    /// same reason.
    pub fn pageTitle(face: *WebFace) []const u8 {
        if (face.title) |t| {
            if (t.len > 0 and !std.mem.eql(u8, t, BLANK)) return t;
        }
        const addr = face.url orelse face.pending_url orelse return "New Tab";
        if (addr.len == 0 or std.mem.eql(u8, addr, BLANK)) return "New Tab";
        const h = urlhost.hostOf(addr, urlhost.site);
        return if (h.len > 0) h else addr;
    }

    const BLANK = "about:blank";

    // ---- Pane face contract ------------------------------------------

    fn prepareDestroyCb(ctx: *anyopaque, widgets_dead: bool) void {
        const self: *Group = @ptrCast(@alignCast(ctx));
        self.widgets_dead = self.widgets_dead or widgets_dead;
        for (self.pages.items) |p| p.face.prepareDestroy(self.widgets_dead);
        self.widgets_dead = true;
    }

    fn destroyCb(ctx: *anyopaque) void {
        const self: *Group = @ptrCast(@alignCast(ctx));
        self.tearing_down = true;
        for (self.pages.items) |p| p.face.deinit();
        self.pages.deinit(self.allocator);
        self.forest.deinit();
        self.allocator.destroy(self);
    }

    fn focusCb(ctx: *anyopaque) void {
        const self: *Group = @ptrCast(@alignCast(ctx));
        const face = self.active() orelse return;
        face.focusFace();
    }

    // ---- TabHost callbacks -------------------------------------------

    fn hostCloseCb(ctx: ?*anyopaque, page: *c.GtkWidget) void {
        const self = cast.userData(Group, ctx);
        const face = self.faceForWidget(page) orelse return;
        self.closePage(face, self.closePolicy());
    }

    fn hostNewCb(ctx: ?*anyopaque) void {
        const self = cast.userData(Group, ctx);
        _ = self.newPage(null, null) catch {};
    }

    /// A strip drag reordered the pages: keep the model list in the
    /// notebook's order so persistence and index arithmetic hold. The
    /// forest is deliberately NOT reordered — the strip is the flat
    /// view and the sidebar the tree view, the same divergence the
    /// window-level tab strip and sidebar already allow.
    fn hostReorderedCb(ctx: ?*anyopaque, page: *c.GtkWidget, new_index: usize) void {
        const self = cast.userData(Group, ctx);
        const face = self.faceForWidget(page) orelse return;
        const from = self.indexOf(face) orelse return;
        if (new_index >= self.pages.items.len) return;
        const moved = self.pages.orderedRemove(from);
        self.pages.insert(self.allocator, new_index, moved) catch {
            self.pages.append(self.allocator, moved) catch {};
        };
    }

    fn onSwitchPage(_: *c.GtkNotebook, page: *c.GtkWidget, _: c.guint, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Group, user);
        if (self.widgets_dead) return;
        const face = self.faceForWidget(page) orelse return;
        self.current = face;
        // The pane titlebar and the window tab wear the ACTIVE page's
        // title; the page coming forward re-asserts both.
        face.onRaised();
        // The helper publishes action snapshots only for the active
        // mirrored page. A notebook switch changes that active bit even
        // though no face was created or destroyed.
        webface.tabsChanged();
        if (self.ownerWindow()) |win| win.sidebarRefreshSelection();
    }

    /// The window's tab_close_parent setting as a forest ClosePolicy.
    pub fn closePolicy(self: *Group) tabforest.ClosePolicy {
        const win = self.ownerWindow() orelse return .promote;
        return switch (win.config.tab_close_parent) {
            .promote => .promote,
            .close_subtree => .close_subtree,
        };
    }

    pub fn childInsertPos(self: *Group) tabforest.InsertPos {
        const win = self.ownerWindow() orelse return .last;
        return switch (win.config.tab_child_insert) {
            .last => .last,
            .first => .first,
        };
    }

    // ── per-page context menu (shared with the sidebar rows) ─────

    /// Heap context for one popped page-menu row; owned by the menu
    /// Root, so it dies with the popover.
    const PageMenuCtx = struct {
        allocator: std.mem.Allocator,
        group: *Group,
        face: *WebFace,
    };

    fn pageMenuCtx(self: *Group, root: *classicmenu.Root, face: *WebFace) ?*PageMenuCtx {
        const ctx = self.allocator.create(PageMenuCtx) catch return null;
        ctx.* = .{ .allocator = self.allocator, .group = self, .face = face };
        root.own(cast.destroyCtx(PageMenuCtx), @ptrCast(ctx));
        return ctx;
    }

    /// The group's domain rows for TabHost's shared per-tab menu.
    fn tabMenuExtra(ctx: ?*anyopaque, page: *c.GtkWidget, root: *classicmenu.Root, m: classicmenu.Menu) void {
        const self = cast.userData(Group, ctx);
        const face = self.faceForWidget(page) orelse return;
        const cx = self.pageMenuCtx(root, face) orelse return;

        m.itemIcon("New Tab", .{ .name = "tab-new-symbolic" }, &onPageMenuNewTab, @ptrCast(cx));

        const nav = m.section();
        nav.itemIcon("Reload", .{ .name = "view-refresh-symbolic" }, &onPageMenuReload, @ptrCast(cx));
        nav.itemIconEnabled(
            "Copy Page URL",
            .{ .name = "edit-copy-symbolic" },
            face.url != null or face.pending_url != null,
            &onPageMenuCopyUrl,
            @ptrCast(cx),
        );

        if (self.forest.hasChildren(face)) {
            const tree = m.section();
            const collapse_label: [*:0]const u8 =
                if (self.forest.isCollapsed(face)) "Expand Subtree" else "Collapse Subtree";
            tree.itemIcon(collapse_label, .{ .name = "view-list-symbolic" }, &onPageMenuCollapse, @ptrCast(cx));
            tree.itemIcon("Close Subtree", .{ .name = "edit-delete-symbolic" }, &onPageMenuCloseSubtree, @ptrCast(cx));
        }
    }

    /// "Duplicate Tab": same URL, nested under the original (TST's
    /// duplicate-as-child).
    fn tabMenuDuplicate(ctx: ?*anyopaque, page: *c.GtkWidget) void {
        const self = cast.userData(Group, ctx);
        const face = self.faceForWidget(page) orelse return;
        const url = face.url orelse face.pending_url;
        _ = self.newPage(url, face) catch {};
    }

    fn onPageMenuNewTab(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const cx = cast.userData(PageMenuCtx, user);
        _ = cx.group.newPage(null, null) catch {};
    }

    fn onPageMenuReload(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const cx = cast.userData(PageMenuCtx, user);
        if (!cx.group.has(cx.face)) return;
        cx.face.navAction(.reload);
    }

    fn onPageMenuCopyUrl(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const cx = cast.userData(PageMenuCtx, user);
        if (!cx.group.has(cx.face)) return;
        const url = cx.face.url orelse cx.face.pending_url orelse return;
        clipboard.copyText(cx.group.allocator, cx.face.root_box, url);
    }

    fn onPageMenuCollapse(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const cx = cast.userData(PageMenuCtx, user);
        const g = cx.group;
        if (!g.has(cx.face)) return;
        const collapse = !g.forest.isCollapsed(cx.face);
        g.forest.setCollapsed(cx.face, collapse);
        // TST behaviour: a selection hidden by the collapse is pulled
        // up to the collapsed head, so it never points at an
        // invisible row.
        if (collapse) {
            if (g.active()) |cur| {
                if (g.forest.isHidden(cur)) g.setActive(cx.face);
            }
        }
        g.notifyWindow();
    }

    fn onPageMenuCloseSubtree(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const cx = cast.userData(PageMenuCtx, user);
        if (!cx.group.has(cx.face)) return;
        cx.group.closePage(cx.face, .close_subtree);
    }
};
