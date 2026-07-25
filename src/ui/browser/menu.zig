//! The entry context menu: its popover construction, the declarative
//! .action buttons, and the handlers that dispatch a menu item into
//! the module that owns the behavior.

const std = @import("std");
const c = @import("../../c.zig").c;

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const RowCtx = @import("render.zig").RowCtx;
const copyToClip = @import("ops.zig").copyToClip;
const countSelected = @import("nav.zig").countSelected;
const hostEq = @import("../../filebrowser/paths.zig").hostEq;
const isArchivePath = @import("../../filebrowser/paths.zig").isArchivePath;
const isSketermMount = @import("../../filebrowser/paths.zig").isSketermMount;
const isTrashPath = @import("../../filebrowser/paths.zig").isTrashPath;
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
    mode: enum { none, rename, mkdir, tags } = .none,
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
    _ = gesture;
    _ = n_press;
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    const self = tab.view;

    var path: ?[]u8 = null;
    var name: ?[]u8 = null;
    var is_dir = false;
    if (c.gtk_list_box_get_row_at_y(tab.listbox, @intFromFloat(y))) |row| {
        if (c.g_object_get_data(@ptrCast(row), "sketerm-row")) |data| {
            const rctx: *RowCtx = @ptrCast(@alignCast(data));
            path = self.allocator.dupe(u8, rctx.path) catch null;
            name = self.allocator.dupe(u8, std.fs.path.basename(rctx.path)) catch null;
            is_dir = rctx.is_dir;
            c.gtk_list_box_select_row(tab.listbox, row);
        }
    }
    self.showEntryMenu(tab, @ptrCast(@alignCast(tab.listbox)), x, y, path, name, is_dir);
}

/// Build and pop the entry context menu. Takes ownership of
/// `path`/`name`; `parent` is the visible widget the click hit.
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
    const popover = c.gtk_popover_new();
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
        .popover = popover,
    };
    c.g_object_set_data_full(@ptrCast(popover), "sketerm-menu", @ptrCast(ctx), @ptrCast(&MenuCtx.free));

    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    const is_local = tab.hc.host == null;
    if (tab.root.archive.len > 0) {
        // Archive members: extract-and-open is the only verb
        // (path ops would misparse member names).
        if (ctx.path != null and !is_dir)
            menuButton(box, "Extract and Open", &onMenuExtractMember, ctx, false);
    } else if (tab.root.collection) {
        // Register rows: specs spanning hosts: navigation +
        // membership only (path verbs would misparse specs).
        if (ctx.path != null) {
            menuButton(box, "Open in New Browser Tab", &onMenuCollectionOpen, ctx, false);
            menuButton(box, "Unmark (remove from this register)", &onMenuRegisterRemove, ctx, false);
        }
    } else {
    if (ctx.path != null) {
        if (is_dir) {
            if (is_local)
                menuButton(box, "Open Terminal Here", &onMenuTerminalHere, ctx, false);
            if (self.on_host_term != null)
                menuButton(box, "Open Terminal Tab Here", &onMenuTermTab, ctx, false);
            menuButton(box, "Open in New Browser Tab", &onMenuOpenTab, ctx, false);
            menuButton(box, "Calculate Size", &onMenuCalcSize, ctx, false);
            menuButton(box, "Find Duplicates Here", &onMenuFindDups, ctx, false);
            menuButton(box, "Add Bookmark", &onMenuBookmark, ctx, false);
        } else if (!is_local and self.on_host_open != null) {
            menuButton(box, "Open on Host (app forward)", &onMenuHostOpen, ctx, false);
        }
        if (!is_dir)
            menuButton(box, "Open With…", &onMenuOpenWith, ctx, false);
        if (isTrashPath(ctx.path.?))
            menuButton(box, "Restore from Trash", &onMenuTrashRestoreItem, ctx, false);
        if (is_local and !is_dir and isSketermMount(ctx.path.?)) {
            menuButton(box, "Pin (keep hydrated)", &onMenuPin, ctx, false);
            menuButton(box, "Evict Cached Data", &onMenuEvict, ctx, false);
        }
        menuButton(box, "Copy", &onMenuCopy, ctx, false);
        menuButton(box, "Cut", &onMenuCut, ctx, false);
        if (self.peerView()) |peer| {
            if (peer.currentTab()) |pt| {
                var pbuf: [4300]u8 = undefined;
                var lbuf: [4400:0]u8 = undefined;
                const dest = pt.spec(&pbuf);
                if (std.fmt.bufPrintZ(&lbuf, "Copy to Other Pane ({s})  F5", .{dest})) |t| {
                    menuButton(box, t.ptr, &onMenuCopyToPeer, ctx, false);
                } else |_| {}
                if (std.fmt.bufPrintZ(&lbuf, "Move to Other Pane ({s})  F6", .{dest})) |t| {
                    menuButton(box, t.ptr, &onMenuMoveToPeer, ctx, false);
                } else |_| {}
            }
        }
        menuButton(box, "Copy Path", &onMenuCopyPath, ctx, false);
        menuButton(box, "Duplicate", &onMenuDuplicate, ctx, false);
        menuButton(box, "Rename…", &onMenuRename, ctx, false);
        menuButton(box, "Properties…", &onMenuProperties, ctx, false);
        menuButton(box, "Tags…", &onMenuTags, ctx, false);
        if (!is_dir and isArchivePath(ctx.path.?)) {
            menuButton(box, "Browse Archive", &onMenuBrowseArchive, ctx, false);
            menuButton(box, "Extract Here", &onMenuExtractHere, ctx, false);
        }
        menuButton(box, "Compress to .tar.gz", &onMenuArchiveCreate, ctx, false);
        menuButton(box, "Add to Collection", &onMenuRegisterAdd, ctx, false);
        menuButton(box, "Mark in Register...", &onMenuRegisterAddNamed, ctx, false);
        menuButton(box, "Export Selection to Shell ($SK_SEL)", &onMenuExportSel, ctx, false);
        if (countSelected(tab) > 1) {
            menuButton(box, "Batch Rename Selected…", &onMenuBatchRename, ctx, false);
            menuButton(box, "Batch Rename in $EDITOR…", &onMenuEditorRename, ctx, false);
        }
        menuButton(box, "Move to Trash", &onMenuTrash, ctx, false);
        menuButton(box, "Delete Permanently…", &onMenuDelete, ctx, true);
    }
    if (self.clip_path != null) {
        menuButton(box, "Paste Here", &onMenuPaste, ctx, false);
        menuButton(box, "Paste as Symbolic Link", &onMenuPasteSymlink, ctx, false);
        // A hard link is offered only where it can succeed: same host,
        // same filesystem. Everywhere else the verb is simply absent.
        if (self.hardlinkPossible(tab))
            menuButton(box, "Paste as Hard Link", &onMenuPasteHardlink, ctx, false);
        menuButton(box, "Sync Here (mirror copy, resumable)", &onMenuSyncHere, ctx, false);
        menuButton(box, "Compare / Sync with Copied…", &onMenuCompare, ctx, false);
    }
    menuButton(box, "New Folder…", &onMenuNewFolder, ctx, false);
    menuButton(box, "New from Template…", &onMenuNewFromTemplate, ctx, false);
    if (self.undo_stack.items.len > 0) {
        var uz: [96:0]u8 = undefined;
        const last = self.undo_stack.items[self.undo_stack.items.len - 1];
        const utxt = std.fmt.bufPrintZ(&uz, "Undo ({s})", .{last.describe()}) catch "Undo";
        menuButton(box, utxt.ptr, &onMenuUndo, ctx, false);
    }
    if (ctx.path != null) self.appendActionButtons(box, ctx);
    }

    c.gtk_popover_set_child(@ptrCast(popover), box);
    c.gtk_widget_set_parent(popover, parent);
    connectPopoverAutoUnparent(popover);
    const rect = c.GdkRectangle{ .x = @intFromFloat(x), .y = @intFromFloat(y), .width = 1, .height = 1 };
    c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
    c.gtk_popover_popup(@ptrCast(popover));
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

pub fn onMenuTerminalHere(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const path = ctx.path orelse return menuDone(ctx);
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
    const clip = c.gtk_widget_get_clipboard(@ptrCast(@alignCast(ctx.tab.listbox)));
    c.gdk_clipboard_set_text(clip, &z);
    menuDone(ctx);
}

pub fn onMenuPaste(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    if (self.clip_paths.items.len == 0 and self.clip_path == null) return menuDone(ctx);
    const srcs: []const []u8 = if (self.clip_paths.items.len > 0)
        self.clip_paths.items
    else
        (&[_][]u8{self.clip_path.?})[0..];
    self.beginPaste(ctx.tab, self.clip_host, srcs, self.clip_cut, true);
    menuDone(ctx);
}

pub fn onMenuTermTab(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const path = ctx.path orelse return menuDone(ctx);
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
    ctx.view.startDaemonJobKind(ctx.tab.hc, "find", path, "", "*", "calculate size", .calc_size);
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
    if (!hostEq(if (self.clip_host) |h| @as(?[]const u8, h) else null, tab.hc.host)) {
        self.setStatus("a link can only point at a path on the same host");
        return;
    }
    const srcs: []const []u8 = if (self.clip_paths.items.len > 0)
        self.clip_paths.items
    else if (self.clip_path) |p|
        (&[_][]u8{p})[0..]
    else
        return;
    for (srcs) |src| self.linkHere(tab, src, hard);
}

pub fn onMenuRename(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const path = ctx.path orelse return menuDone(ctx);
    ctx.view.entryDialog(ctx.tab, .rename, path);
    menuDone(ctx);
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

pub fn onMenuArchiveCreate(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const path = ctx.path orelse return menuDone(ctx);
    var out: [4096]u8 = undefined;
    const archive = std.fmt.bufPrint(&out, "{s}.tar.gz", .{path}) catch return menuDone(ctx);
    ctx.view.startDaemonJob(ctx.tab.hc, "archive_create", path, archive, "create archive");
    menuDone(ctx);
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
pub fn appendActionButtons(self: *BrowserView, box: *c.GtkWidget, ctx: *MenuCtx) void {
    const path = ctx.path orelse return;
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
        // %f → single-quoted path, substituted now.
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
        var lbl: [128:0]u8 = undefined;
        const ltxt = std.fmt.bufPrintZ(&lbl, "{s}{s}", .{
            name, if (on_host) " (on host)" else "",
        }) catch continue;
        const btn = c.gtk_button_new_with_label(ltxt.ptr);
        c.gtk_button_set_has_frame(@ptrCast(btn), 0);
        c.gtk_widget_set_halign(c.gtk_button_get_child(@ptrCast(btn)), c.GTK_ALIGN_START);
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onActionClicked), @ptrCast(actx), @ptrCast(&ActionCtx.free), c.G_CONNECT_DEFAULT);
        // Popdown when an action fires: reuse the menu ctx's popover.
        c.g_object_set_data(@ptrCast(btn), "sketerm-popover", @ptrCast(ctx.popover));
        c.gtk_box_append(@ptrCast(box), btn);
    }
}

pub fn onActionClicked(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
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
    if (c.g_object_get_data(@ptrCast(btn), "sketerm-popover")) |pop| {
        c.gtk_popover_popdown(@ptrCast(@alignCast(pop)));
    }
}
