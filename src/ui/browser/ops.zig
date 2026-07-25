//! File operations: clipboard copy/cut/paste with its conflict flow,
//! new folder / rename / batch rename, delete, trash and restore, the
//! undo/redo stacks, tags, and archive browsing.

const std = @import("std");
const c = @import("../../c.zig").c;
const wire = @import("../../mux/wire.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const Dir = @import("types.zig").Dir;
const HistoryDirection = @import("types.zig").HistoryDirection;
const HostConn = @import("types.zig").HostConn;
const MenuCtx = @import("menu.zig").MenuCtx;
const PendingJob = @import("types.zig").PendingJob;
const RowCtx = @import("render.zig").RowCtx;
const UndoOp = @import("types.zig").UndoOp;
const WireJobEv = @import("types.zig").WireJobEv;
const WireReply = @import("types.zig").WireReply;
const appendQuoted = @import("../../filebrowser/desktop.zig").appendQuoted;
const conflict = @import("conflict.zig");
const connectPopoverAutoUnparent = @import("menu.zig").connectPopoverAutoUnparent;
const hostEq = @import("../../filebrowser/paths.zig").hostEq;
const menuDone = @import("menu.zig").menuDone;
const parseSpec = @import("../../filebrowser/paths.zig").parseSpec;
const uniqueName = @import("../../filebrowser/paths.zig").uniqueName;
const urlUnescape = @import("../../filebrowser/paths.zig").urlUnescape;

/// One in-flight .trashinfo fetch for Restore from Trash.
pub const RestoreRead = struct {
    req: u32,
    hc: *HostConn,
    /// The trashed entry (…/Trash/files/<name>).
    trashed: []u8,
    /// Its metadata file (…/Trash/info/<name>.trashinfo).
    info: []u8,
    buf: std.ArrayList(u8) = .empty,

    pub fn destroy(self: *RestoreRead, allocator: std.mem.Allocator) void {
        allocator.free(self.trashed);
        allocator.free(self.info);
        self.buf.deinit(allocator);
        allocator.destroy(self);
    }
};

pub fn copyToClip(ctx: *MenuCtx, cut: bool) void {
    const self = ctx.view;
    const path = ctx.path orelse return menuDone(ctx);
    self.clip_cut = cut;
    if (self.clip_host) |s| self.allocator.free(s);
    self.clip_host = null;
    if (ctx.tab.hc.host) |h| self.clip_host = self.allocator.dupe(u8, h) catch null;
    // The source directory's filesystem: what decides later whether a
    // hard link into another directory could work at all.
    self.clip_dev = ctx.tab.root.dev;
    if (self.clip_path) |s| self.allocator.free(s);
    self.clip_path = null;
    for (self.clip_paths.items) |p| self.allocator.free(p);
    self.clip_paths.clearRetainingCapacity();
    // A multi-selection that includes the clicked row copies the
    // whole selection; otherwise just the clicked entry.
    const in_selection = for (ctx.tab.selected.items) |sp| {
        if (std.mem.eql(u8, sp, path)) break true;
    } else false;
    if (in_selection and ctx.tab.selected.items.len > 1) {
        for (ctx.tab.selected.items) |sp| {
            const owned = self.allocator.dupe(u8, sp) catch continue;
            self.clip_paths.append(self.allocator, owned) catch self.allocator.free(owned);
        }
    } else {
        if (self.allocator.dupe(u8, path)) |owned| {
            self.clip_paths.append(self.allocator, owned) catch self.allocator.free(owned);
        } else |_| {}
    }
    if (self.clip_paths.items.len > 0)
        self.clip_path = self.allocator.dupe(u8, self.clip_paths.items[0]) catch null;
    const verb: []const u8 = if (cut) "cut" else "copied";
    if (self.clip_paths.items.len > 1) {
        self.setStatusFmt("{s} {d} items", .{ verb, self.clip_paths.items.len });
    } else {
        self.setStatusFmt("{s}: {s}", .{ verb, path });
    }
    menuDone(ctx);
}

/// Is `tab` still one of this view's tabs? Anything that parks work
/// against a tab and acts on it LATER (the conflict queue, the
/// template menu) must ask, because the user can close the tab in
/// between and the pointer would be stale.
pub fn tabAlive(self: *BrowserView, tab: *BTab) bool {
    for (self.tabs.items) |t| {
        if (t == tab) return true;
    }
    return false;
}

/// Pick a destination name that does not collide with the live
/// target listing: "name-copy", then "name-copy2"…
pub fn uniqueDstName(tab: *BTab, base: []const u8, buf: []u8) ?[]const u8 {
    const Listing = struct {
        tab: *BTab,
        pub fn contains(self: @This(), name: []const u8) bool {
            return self.tab.root.find(name) != null;
        }
    };
    return uniqueName(base, buf, Listing{ .tab = tab });
}

/// Per-item paste modifiers. `dir_mode` reaches the daemon copy verb
/// verbatim; `undoable` is false for merge and replace, which cannot
/// be reversed by deleting what was created (a merge leaves the
/// destination's own files in place, a replace destroyed them).
pub const PasteOpts = struct {
    dir_mode: []const u8 = "",
    undoable: bool = true,
};

/// Copy/move `sources` (living on `src_host`) into `tab`'s directory.
/// Names that are free start IMMEDIATELY; names that collide are
/// parked in conflict.zig's queue and decided while the rest of the
/// batch is already copying. The clipboard is only consulted by the
/// caller, so a dual-pane send uses the same path as Paste Here.
pub fn beginPaste(
    self: *BrowserView,
    tab: *BTab,
    src_host: ?[]const u8,
    srcs: []const []u8,
    cut: bool,
    clear_clipboard: bool,
) void {
    const src_hc = self.hostConnFor(src_host) orelse return;
    const dir = tab.root.path;
    var started: usize = 0;
    var conflicts: usize = 0;
    for (srcs) |src| {
        const base = std.fs.path.basename(src);
        var dst_buf: [4096]u8 = undefined;
        const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{
            if (dir.len == 1) "" else dir, base,
        }) catch continue;
        // Pasting onto itself is a no-op, not a copy/move.
        if (hostEq(src_host, tab.hc.host) and std.mem.eql(u8, src, dst)) continue;
        if (tab.root.find(base)) |i| {
            conflict.enqueue(self, tab, src_hc, src_host, src, dst, tab.root.entries.items[i].tdir, cut);
            conflicts += 1;
            continue;
        }
        pasteOne(self, tab, src_host, src, dst, cut, .{});
        started += 1;
    }
    if (conflicts > 0) {
        self.setStatusFmt("{d} item(s) started; {d} name conflict(s) waiting for a decision", .{ started, conflicts });
    } else if (started == 0) {
        self.setStatus("nothing to paste here");
    }
    if (cut and clear_clipboard) {
        // Cut is one-shot: the sources are moving away. Parked
        // conflicts own their own copy of the paths.
        if (self.clip_path) |s| self.allocator.free(s);
        self.clip_path = null;
        for (self.clip_paths.items) |p| self.allocator.free(p);
        self.clip_paths.clearRetainingCapacity();
        self.clip_cut = false;
    }
}

/// Start ONE source's copy (or move) to an exact destination path.
/// Every paste path funnels through here, so same-host vs cross-host
/// and the undo bookkeeping are decided in one place.
pub fn pasteOne(
    self: *BrowserView,
    tab: *BTab,
    src_host: ?[]const u8,
    src: []const u8,
    dst: []const u8,
    cut: bool,
    opts: PasteOpts,
) void {
    const base = std.fs.path.basename(src);
    if (hostEq(src_host, tab.hc.host)) {
        if (cut) {
            // Same-host move = one rename, undoable.
            const req = self.nextReq();
            self.deferUndo(req, self.makeUndo(tab.hc.host, .rename_back, dst, src, ""));
            self.sendOp(tab.hc, .{ .req = req, .op = "rename", .path = src, .to = dst });
            return;
        }
        var lbl: [128]u8 = undefined;
        const label = std.fmt.bufPrint(&lbl, "copy {s}", .{base}) catch base;
        const undo = if (opts.undoable)
            self.makeUndo(tab.hc.host, .delete_created, dst, src, "")
        else
            null;
        self.startDaemonJobUndo(tab.hc, "copy", src, dst, label, undo, .{ .dir_mode = opts.dir_mode });
        return;
    }
    const src_hc = self.hostConnFor(src_host) orelse return;
    self.startTransfer(src_hc, src, tab.hc, dst, .{ .delete_src_after = cut });
}

/// Copy an entry beside itself under a free name ("x" -> "x-copy").
/// Undoable like any other copy: the created path is what undo drops.
pub fn duplicateEntry(self: *BrowserView, tab: *BTab, path: []const u8) void {
    const base = std.fs.path.basename(path);
    var name_buf: [512]u8 = undefined;
    const unique = uniqueDstName(tab, base, &name_buf) orelse {
        self.setStatusFmt("no free name beside {s}", .{base});
        return;
    };
    const dir = std.fs.path.dirname(path) orelse "/";
    var dst_buf: [4096]u8 = undefined;
    const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{
        if (dir.len == 1) "" else dir, unique,
    }) catch return;
    var lbl: [128]u8 = undefined;
    const label = std.fmt.bufPrint(&lbl, "duplicate {s}", .{base}) catch "duplicate";
    self.startDaemonJobUndo(tab.hc, "copy", path, dst, label, self.makeUndo(tab.hc.host, .delete_created, dst, path, ""), .{});
    self.setStatusFmt("duplicating {s} -> {s}", .{ base, unique });
}

/// Create a link to `target` in `tab`'s directory. Both kinds go
/// through one path: only the wire verb and the undo payload differ.
pub fn linkHere(self: *BrowserView, tab: *BTab, target: []const u8, hard: bool) void {
    const base = std.fs.path.basename(target);
    var name_buf: [512]u8 = undefined;
    // A link beside its own target needs a free name; a link in
    // another directory keeps the original one.
    const dir = tab.root.path;
    var name: []const u8 = base;
    if (tab.root.find(base) != null) {
        name = uniqueDstName(tab, base, &name_buf) orelse {
            self.setStatusFmt("no free name for a link to {s}", .{base});
            return;
        };
    }
    var link_buf: [4096]u8 = undefined;
    const link = std.fmt.bufPrint(&link_buf, "{s}/{s}", .{
        if (dir.len == 1) "" else dir, name,
    }) catch return;
    const req = self.nextReq();
    self.deferUndo(req, self.makeUndo(
        tab.hc.host,
        .link_created,
        link,
        target,
        if (hard) "hardlink" else "symlink",
    ));
    self.sendOp(tab.hc, .{
        .req = req,
        .op = if (hard) "hardlink" else "symlink",
        .path = link,
        .to = target,
    });
    self.setStatusFmt("{s} link: {s} -> {s}", .{ if (hard) "hard" else "symbolic", name, target });
}

/// Can a hard link from `tab`'s directory to the clipboard source
/// possibly work? Same host and same filesystem, decided from the
/// device id the daemon ships with each listing -- the verb is only
/// offered where it can succeed, never offered and then failed.
pub fn hardlinkPossible(self: *BrowserView, tab: *BTab) bool {
    if (self.clip_path == null) return false;
    if (!hostEq(if (self.clip_host) |h| @as(?[]const u8, h) else null, tab.hc.host)) return false;
    return self.clip_dev != 0 and self.clip_dev == tab.root.dev;
}

pub fn findEntryTags(tab: *BTab, path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const parent = std.fs.path.dirname(path) orelse return "";
    const dir: *Dir = if (std.mem.eql(u8, tab.root.path, parent))
        tab.root
    else
        tab.subdirByPath(parent) orelse return "";
    const i = dir.find(base) orelse return "";
    return dir.entries.items[i].tags;
}

pub fn onMenuTags(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const path = ctx.path orelse return menuDone(ctx);
    const popover = c.gtk_popover_new();
    const entry = c.gtk_entry_new();
    c.gtk_entry_set_placeholder_text(@ptrCast(entry), "comma,separated,tags (empty clears)");
    const cur = findEntryTags(ctx.tab, path);
    if (cur.len > 0) {
        var z: [256:0]u8 = undefined;
        const n = @min(cur.len, z.len - 1);
        @memcpy(z[0..n], cur[0..n]);
        z[n] = 0;
        c.gtk_editable_set_text(@ptrCast(entry), &z);
    }
    const tctx = self.allocator.create(MenuCtx) catch return menuDone(ctx);
    tctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .tab = ctx.tab,
        .path = self.allocator.dupe(u8, path) catch null,
        .name = null,
        .is_dir = ctx.is_dir,
        .popover = popover,
        .mode = .tags,
        .entry = entry,
    };
    c.g_object_set_data_full(@ptrCast(popover), "sketerm-menu", @ptrCast(tctx), @ptrCast(&MenuCtx.free));
    _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onTagsActivate), @ptrCast(tctx), null, c.G_CONNECT_DEFAULT);
    c.gtk_popover_set_child(@ptrCast(popover), entry);
    c.gtk_widget_set_parent(popover, ctx.tab.page);
    connectPopoverAutoUnparent(popover);
    c.gtk_popover_popup(@ptrCast(popover));
    _ = c.gtk_widget_grab_focus(entry);
    menuDone(ctx);
}

pub fn onTagsActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const path = ctx.path orelse return menuDone(ctx);
    const txt = c.gtk_editable_get_text(@ptrCast(entry));
    const tags = std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
    self.sendOp(ctx.tab.hc, .{ .req = self.nextReq(), .op = "tag_set", .path = path, .to = tags });
    menuDone(ctx);
}

pub fn onMenuExportSel(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const tab = ctx.tab;
    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(self.allocator);
    const paths: []const []u8 = if (tab.selected.items.len > 0)
        tab.selected.items
    else if (ctx.path) |pp|
        (&[_][]u8{pp})[0..]
    else
        return menuDone(ctx);
    cmd.appendSlice(self.allocator, "SK_SEL=") catch return menuDone(ctx);
    appendQuoted(&cmd, self.allocator, paths[0]) catch return menuDone(ctx);
    cmd.appendSlice(self.allocator, "; SK_SEL_ALL='") catch return menuDone(ctx);
    for (paths, 0..) |sp, i| {
        if (i > 0) cmd.append(self.allocator, ' ') catch return menuDone(ctx);
        for (sp) |ch| {
            if (ch == '\'') {
                cmd.appendSlice(self.allocator, "'\\''") catch return menuDone(ctx);
            } else cmd.append(self.allocator, ch) catch return menuDone(ctx);
        }
    }
    cmd.appendSlice(self.allocator, "'\n") catch return menuDone(ctx);
    self.pane.terminal.writeRaw(cmd.items);
    self.pane.setBrowserVisible(false);
    self.setStatusFmt("exported {d} path(s) as $SK_SEL / $SK_SEL_ALL", .{paths.len});
    menuDone(ctx);
}

/// Editor-buffer rename: selection names go to a temp file, the
/// pane's SHELL runs $EDITOR on it, and a sentinel "done" file
/// (watched with GFileMonitor) triggers applying the renames.
pub const EditorRename = struct {
    view: *BrowserView,
    host: ?[]u8,
    paths: std.ArrayList([]u8) = .empty,
    tmp: []u8,
    done: []u8,
    monitor: ?*c.GFileMonitor = null,

    pub fn destroy(self: *EditorRename, allocator: std.mem.Allocator) void {
        if (self.monitor) |m| {
            _ = c.g_file_monitor_cancel(m);
            c.g_object_unref(m);
        }
        var zb: [4300]u8 = undefined;
        if (std.fmt.bufPrintZ(&zb, "{s}", .{self.tmp})) |z| {
            _ = c.unlink(z.ptr);
        } else |_| {}
        if (std.fmt.bufPrintZ(&zb, "{s}", .{self.done})) |z| {
            _ = c.unlink(z.ptr);
        } else |_| {}
        for (self.paths.items) |sp| allocator.free(sp);
        self.paths.deinit(allocator);
        if (self.host) |h| allocator.free(h);
        allocator.free(self.tmp);
        allocator.free(self.done);
        allocator.destroy(self);
    }
};

pub fn onMenuEditorRename(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const tab = ctx.tab;
    if (tab.selected.items.len < 2) return menuDone(ctx);
    if (self.editor_rename) |er| {
        er.destroy(self.allocator);
        self.editor_rename = null;
    }
    var stamp: [32]u8 = undefined;
    var t: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &t);
    const tag = std.fmt.bufPrint(&stamp, "{d}", .{@as(u64, @intCast(t.tv_nsec)) ^ @as(u64, @intCast(t.tv_sec))}) catch return menuDone(ctx);
    const cache_root = c.g_get_user_cache_dir();
    var tb: [4200]u8 = undefined;
    var db: [4200]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tb, "{s}/sketerm-rename-{s}.txt", .{ cache_root, tag }) catch return menuDone(ctx);
    const done = std.fmt.bufPrint(&db, "{s}/sketerm-rename-{s}.done", .{ cache_root, tag }) catch return menuDone(ctx);

    const er = self.allocator.create(EditorRename) catch return menuDone(ctx);
    er.* = .{
        .view = self,
        .host = if (tab.hc.host) |h| (self.allocator.dupe(u8, h) catch null) else null,
        .tmp = self.allocator.dupe(u8, tmp) catch {
            self.allocator.destroy(er);
            return menuDone(ctx);
        },
        .done = self.allocator.dupe(u8, done) catch {
            self.allocator.free(er.tmp);
            self.allocator.destroy(er);
            return menuDone(ctx);
        },
    };
    // Write one basename per line; remember the full paths.
    var zb: [4300:0]u8 = undefined;
    const tz = std.fmt.bufPrintZ(&zb, "{s}", .{tmp}) catch {
        er.destroy(self.allocator);
        return menuDone(ctx);
    };
    const f = c.fopen(tz.ptr, "wb") orelse {
        er.destroy(self.allocator);
        return menuDone(ctx);
    };
    for (tab.selected.items) |sp| {
        const owned = self.allocator.dupe(u8, sp) catch continue;
        er.paths.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            continue;
        };
        const base = std.fs.path.basename(sp);
        _ = c.fwrite(base.ptr, 1, base.len, f);
        _ = c.fwrite("\n", 1, 1, f);
    }
    _ = c.fclose(f);

    var dzb: [4300:0]u8 = undefined;
    const dz = std.fmt.bufPrintZ(&dzb, "{s}", .{done}) catch {
        er.destroy(self.allocator);
        return menuDone(ctx);
    };
    const gfile = c.g_file_new_for_path(dz.ptr);
    er.monitor = c.g_file_monitor_file(gfile, c.G_FILE_MONITOR_NONE, null, null);
    c.g_object_unref(gfile);
    if (er.monitor == null) {
        er.destroy(self.allocator);
        return menuDone(ctx);
    }
    _ = c.g_signal_connect_data(er.monitor, "changed", @ptrCast(&onEditorRenameDone), @ptrCast(er), null, c.G_CONNECT_DEFAULT);
    self.editor_rename = er;

    // Run $EDITOR in the pane's shell; touching the done file
    // fires the monitor.
    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(self.allocator);
    cmd.appendSlice(self.allocator, "\"${EDITOR:-vi}\" ") catch return menuDone(ctx);
    appendQuoted(&cmd, self.allocator, tmp) catch return menuDone(ctx);
    cmd.appendSlice(self.allocator, " && touch ") catch return menuDone(ctx);
    appendQuoted(&cmd, self.allocator, done) catch return menuDone(ctx);
    cmd.append(self.allocator, '\n') catch return menuDone(ctx);
    self.pane.terminal.writeRaw(cmd.items);
    self.pane.setBrowserVisible(false);
    self.setStatus("edit the names, save, and quit the editor to apply");
    menuDone(ctx);
}

pub fn onEditorRenameDone(
    _: *c.GFileMonitor,
    _: ?*c.GFile,
    _: ?*c.GFile,
    event: c.GFileMonitorEvent,
    user: ?*anyopaque,
) callconv(.c) void {
    if (event != c.G_FILE_MONITOR_EVENT_CREATED and event != c.G_FILE_MONITOR_EVENT_CHANGES_DONE_HINT) return;
    const er: *EditorRename = @ptrCast(@alignCast(user.?));
    const self = er.view;
    if (self.editor_rename != er) return;
    defer {
        self.editor_rename = null;
        er.destroy(self.allocator);
    }
    var zb: [4300:0]u8 = undefined;
    const tz = std.fmt.bufPrintZ(&zb, "{s}", .{er.tmp}) catch return;
    const f = c.fopen(tz.ptr, "rb") orelse return;
    var content: [64 * 1024]u8 = undefined;
    const n = c.fread(&content, 1, content.len, f);
    _ = c.fclose(f);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.allocator);
    var it = std.mem.splitScalar(u8, content[0..n], '\n');
    while (it.next()) |line| {
        const nm = std.mem.trim(u8, line, " \t\r");
        if (nm.len > 0) names.append(self.allocator, nm) catch return;
    }
    if (names.items.len != er.paths.items.len) {
        self.setStatusFmt("rename aborted: {d} line(s) for {d} file(s) — line count must match", .{
            names.items.len, er.paths.items.len,
        });
        return;
    }
    const hc = self.hostConnFor(if (er.host) |h| @as(?[]const u8, h) else null) orelse return;
    var renamed: usize = 0;
    for (er.paths.items, names.items) |old, new_name| {
        const base = std.fs.path.basename(old);
        if (std.mem.eql(u8, base, new_name)) continue;
        if (std.mem.indexOfScalar(u8, new_name, '/') != null) continue;
        const dir = std.fs.path.dirname(old) orelse continue;
        var nb: [4300]u8 = undefined;
        const np = std.fmt.bufPrint(&nb, "{s}/{s}", .{ if (dir.len == 1) "" else dir, new_name }) catch continue;
        const req = self.nextReq();
        self.deferUndo(req, self.makeUndo(hc.host, .rename_back, np, old, ""));
        self.sendOp(hc, .{ .req = req, .op = "rename", .path = old, .to = np });
        renamed += 1;
    }
    self.setStatusFmt("editor rename: {d} file(s) renamed", .{renamed});
}

pub fn onMenuBatchRename(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const tab = ctx.tab;
    const popover = c.gtk_popover_new();
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
    const find_e = c.gtk_entry_new();
    c.gtk_entry_set_placeholder_text(@ptrCast(find_e), "find (substring)");
    const repl_e = c.gtk_entry_new();
    c.gtk_entry_set_placeholder_text(@ptrCast(repl_e), "replace with");
    const apply = c.gtk_button_new_with_label("Rename selected");
    c.gtk_box_append(@ptrCast(box), find_e);
    c.gtk_box_append(@ptrCast(box), repl_e);
    c.gtk_box_append(@ptrCast(box), apply);
    const bctx = self.allocator.create(MenuCtx) catch return menuDone(ctx);
    bctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .tab = tab,
        .path = null,
        .name = null,
        .is_dir = false,
        .popover = popover,
        .entry = find_e,
        .entry2 = repl_e,
    };
    c.g_object_set_data_full(@ptrCast(popover), "sketerm-menu", @ptrCast(bctx), @ptrCast(&MenuCtx.free));
    _ = c.g_signal_connect_data(apply, "clicked", @ptrCast(&onBatchRenameApply), @ptrCast(bctx), null, c.G_CONNECT_DEFAULT);
    c.gtk_popover_set_child(@ptrCast(popover), box);
    c.gtk_widget_set_parent(popover, tab.page);
    connectPopoverAutoUnparent(popover);
    c.gtk_popover_popup(@ptrCast(popover));
    menuDone(ctx);
}

pub fn onBatchRenameApply(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const tab = ctx.tab;
    const find_txt = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(ctx.entry.?)))));
    const repl_txt = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(ctx.entry2.?)))));
    if (find_txt.len == 0 or std.mem.indexOfScalar(u8, repl_txt, '/') != null) {
        self.setStatus("batch rename: bad pattern");
        return menuDone(ctx);
    }
    var renamed: usize = 0;
    var rows = c.gtk_list_box_get_selected_rows(tab.listbox);
    const head = rows;
    while (rows != null) : (rows = rows.*.next) {
        const row: *c.GtkListBoxRow = @ptrCast(@alignCast(rows.*.data));
        const data = c.g_object_get_data(@ptrCast(row), "sketerm-row") orelse continue;
        const rctx: *RowCtx = @ptrCast(@alignCast(data));
        const base = std.fs.path.basename(rctx.path);
        const parent = std.fs.path.dirname(rctx.path) orelse continue;
        // Replace ALL occurrences of `find` in the basename.
        var nb: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&nb);
        var rest = base;
        var changed = false;
        while (std.mem.indexOf(u8, rest, find_txt)) |i| {
            w.writeAll(rest[0..i]) catch break;
            w.writeAll(repl_txt) catch break;
            rest = rest[i + find_txt.len ..];
            changed = true;
        }
        w.writeAll(rest) catch continue;
        if (!changed or w.buffered().len == 0) continue;
        var full: [4096]u8 = undefined;
        const to = std.fmt.bufPrint(&full, "{s}/{s}", .{
            if (parent.len == 1) "" else parent, w.buffered(),
        }) catch continue;
        self.sendOp(tab.hc, .{ .req = self.nextReq(), .op = "rename", .path = rctx.path, .to = to });
        renamed += 1;
    }
    if (head != null) c.g_list_free(head);
    self.setStatusFmt("batch rename: {d} rename(s) sent", .{renamed});
    menuDone(ctx);
}

pub fn setMountXattr(ctx: *MenuCtx, comptime attr: [:0]const u8, comptime okmsg: []const u8) void {
    const self = ctx.view;
    const path = ctx.path orelse return menuDone(ctx);
    var z: [4300:0]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return menuDone(ctx);
    if (c.setxattr(pz.ptr, attr.ptr, "1", 1, 0) != 0) {
        self.setStatusFmt("{s} failed (is this really a sketerm mount?)", .{attr});
    } else {
        self.setStatusFmt("{s}: {s}", .{ std.fs.path.basename(path), okmsg });
    }
    menuDone(ctx);
}

pub fn onMenuTrash(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const path = ctx.path orelse return menuDone(ctx);
    const hc = ctx.tab.hc;
    if (hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{hc.label()});
        return menuDone(ctx);
    }
    const req = self.nextReq();
    const pj = self.allocator.create(PendingJob) catch return menuDone(ctx);
    pj.* = .{
        .req = req,
        .hc = hc,
        .label = self.allocator.dupe(u8, "move to trash") catch {
            self.allocator.destroy(pj);
            return menuDone(ctx);
        },
        .undo_trash_orig = self.allocator.dupe(u8, path) catch null,
    };
    self.pending_jobs.append(self.allocator, pj) catch {
        if (pj.undo_trash_orig) |o| self.allocator.free(o);
        self.allocator.free(pj.label);
        self.allocator.destroy(pj);
        return menuDone(ctx);
    };
    self.sendOp(hc, .{ .req = req, .op = "trash", .path = path });
    menuDone(ctx);
}

pub fn onMenuDelete(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const path = ctx.path orelse return menuDone(ctx);
    // Confirm popover with one destructive button.
    const popover = c.gtk_popover_new();
    const cctx = self.allocator.create(MenuCtx) catch return menuDone(ctx);
    cctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .tab = ctx.tab,
        .path = self.allocator.dupe(u8, path) catch null,
        .name = null,
        .is_dir = ctx.is_dir,
        .popover = popover,
    };
    c.g_object_set_data_full(@ptrCast(popover), "sketerm-menu", @ptrCast(cctx), @ptrCast(&MenuCtx.free));
    var lbl: [300:0]u8 = undefined;
    const base = std.fs.path.basename(path);
    const txt = std.fmt.bufPrintZ(&lbl, "Delete {s}{s}", .{ base, if (ctx.is_dir) " (recursively)" else "" }) catch "Delete";
    const btn = c.gtk_button_new_with_label(txt.ptr);
    c.gtk_widget_add_css_class(btn, "destructive-action");
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onDeleteConfirmed), @ptrCast(cctx), null, c.G_CONNECT_DEFAULT);
    c.gtk_popover_set_child(@ptrCast(popover), btn);
    c.gtk_widget_set_parent(popover, ctx.tab.page);
    connectPopoverAutoUnparent(popover);
    c.gtk_popover_popup(@ptrCast(popover));
    menuDone(ctx);
}

pub fn onDeleteConfirmed(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const path = ctx.path orelse return menuDone(ctx);
    if (ctx.is_dir) {
        var lbl: [128]u8 = undefined;
        const label = std.fmt.bufPrint(&lbl, "delete {s}", .{std.fs.path.basename(path)}) catch "delete";
        self.startDaemonJob(ctx.tab.hc, "delete_tree", path, "", label);
    } else {
        self.sendOp(ctx.tab.hc, .{ .req = self.nextReq(), .op = "delete", .path = path });
    }
    menuDone(ctx);
}

/// One-entry popover shared by Rename (target = old full path)
/// and New Folder (target = null → current dir).
pub fn entryDialog(self: *BrowserView, tab: *BTab, mode: @TypeOf(@as(MenuCtx, undefined).mode), rename_path: ?[]const u8) void {
    const popover = c.gtk_popover_new();
    const entry = c.gtk_entry_new();
    c.gtk_entry_set_placeholder_text(@ptrCast(entry), if (mode == .mkdir) "folder name" else "new name");
    if (rename_path) |rp| {
        var z: [512:0]u8 = undefined;
        const base = std.fs.path.basename(rp);
        const n = @min(base.len, z.len - 1);
        @memcpy(z[0..n], base[0..n]);
        z[n] = 0;
        c.gtk_editable_set_text(@ptrCast(entry), &z);
        c.gtk_editable_select_region(@ptrCast(entry), 0, -1);
    }
    const ctx = self.allocator.create(MenuCtx) catch return;
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .tab = tab,
        .path = if (rename_path) |rp| (self.allocator.dupe(u8, rp) catch null) else null,
        .name = null,
        .is_dir = false,
        .popover = popover,
        .mode = mode,
        .entry = entry,
    };
    c.g_object_set_data_full(@ptrCast(popover), "sketerm-menu", @ptrCast(ctx), @ptrCast(&MenuCtx.free));
    _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onEntryDialogActivate), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.gtk_popover_set_child(@ptrCast(popover), entry);
    c.gtk_widget_set_parent(popover, tab.page);
    connectPopoverAutoUnparent(popover);
    c.gtk_popover_popup(@ptrCast(popover));
    _ = c.gtk_widget_grab_focus(entry);
}

pub fn onEntryDialogActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const txt = c.gtk_editable_get_text(@ptrCast(entry));
    const name = std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) {
        self.setStatus("invalid name");
        return menuDone(ctx);
    }
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const req = self.nextReq();
    switch (ctx.mode) {
        .mkdir => {
            const dir = ctx.tab.root.path;
            w.print("{s}/{s}", .{ if (dir.len == 1) "" else dir, name }) catch return menuDone(ctx);
            self.deferUndo(req, self.makeUndo(ctx.tab.hc.host, .rmdir_created, w.buffered(), "", ""));
            self.sendOp(ctx.tab.hc, .{ .req = req, .op = "mkdir", .path = w.buffered() });
        },
        .rename => {
            const old = ctx.path orelse return menuDone(ctx);
            const dir = std.fs.path.dirname(old) orelse return menuDone(ctx);
            w.print("{s}/{s}", .{ if (dir.len == 1) "" else dir, name }) catch return menuDone(ctx);
            self.deferUndo(req, self.makeUndo(ctx.tab.hc.host, .rename_back, w.buffered(), old, ""));
            self.sendOp(ctx.tab.hc, .{ .req = req, .op = "rename", .path = old, .to = w.buffered() });
        },
        .none, .tags => {},
    }
    menuDone(ctx);
}

/// Fetch the .trashinfo for a trashed entry, then restore it to
/// the Path= recorded inside.
pub fn startTrashRestore(self: *BrowserView, tab: *BTab, trashed: []const u8) void {
    if (self.restore_read) |rr| {
        rr.destroy(self.allocator);
        self.restore_read = null;
    }
    const name = std.fs.path.basename(trashed);
    const files_dir = std.fs.path.dirname(trashed) orelse return;
    const trash_root = std.fs.path.dirname(files_dir) orelse return;
    var info_buf: [4300]u8 = undefined;
    const info = std.fmt.bufPrint(&info_buf, "{s}/info/{s}.trashinfo", .{ trash_root, name }) catch return;
    const rr = self.allocator.create(RestoreRead) catch return;
    rr.* = .{
        .req = self.nextReq(),
        .hc = tab.hc,
        .trashed = self.allocator.dupe(u8, trashed) catch {
            self.allocator.destroy(rr);
            return;
        },
        .info = self.allocator.dupe(u8, info) catch {
            self.allocator.free(rr.trashed);
            self.allocator.destroy(rr);
            return;
        },
    };
    self.restore_read = rr;
    self.sendOp(tab.hc, .{ .req = rr.req, .op = "read", .path = rr.info, .off = @as(u64, 0), .len = @as(u64, 8192) });
}

pub fn feedRestore(self: *BrowserView, hc: *HostConn, ftype: wire.FrameType, payload: []const u8) bool {
    const rr = self.restore_read orelse return false;
    if (rr.hc != hc) return false;
    switch (ftype) {
        .fs_data => {
            if (payload.len < 12) return false;
            if (std.mem.readInt(u32, payload[0..4], .little) != rr.req) return false;
            rr.buf.appendSlice(self.allocator, payload[12..]) catch {};
            return true;
        },
        .fs_reply => {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const rep = std.json.parseFromSliceLeaky(WireReply, arena.allocator(), payload, .{
                .ignore_unknown_fields = true,
            }) catch return false;
            if (rep.req != rr.req) return false;
            defer {
                rr.destroy(self.allocator);
                self.restore_read = null;
            }
            if (!rep.ok) {
                self.setStatus("cannot read trash metadata");
                return true;
            }
            // Parse Path= (URL-escaped) from the .trashinfo.
            var orig_buf: [4096]u8 = undefined;
            var orig: ?[]const u8 = null;
            var it = std.mem.tokenizeScalar(u8, rr.buf.items, '\n');
            while (it.next()) |line_raw| {
                const line = std.mem.trim(u8, line_raw, " \t\r");
                if (std.mem.startsWith(u8, line, "Path=")) {
                    orig = urlUnescape(line[5..], &orig_buf);
                    break;
                }
            }
            const dst = orig orelse {
                self.setStatus("trash metadata has no Path entry");
                return true;
            };
            var lbl: [128]u8 = undefined;
            const label = std.fmt.bufPrint(&lbl, "restore {s}", .{std.fs.path.basename(dst)}) catch "restore";
            self.startDaemonJobTo(rr.hc, "trash_restore", rr.trashed, dst, rr.info, label);
            return true;
        },
        else => return false,
    }
}

pub const UNDO_CAP = 20;

pub fn clearRedo(self: *BrowserView) void {
    for (self.redo_stack.items) |op| op.destroy(self.allocator);
    self.redo_stack.clearRetainingCapacity();
}

pub fn pushUndo(self: *BrowserView, op: *UndoOp) void {
    self.clearRedo();
    self.pushHistoryStack(&self.undo_stack, op);
}

pub fn pushHistoryStack(self: *BrowserView, stack: *std.ArrayList(*UndoOp), op: *UndoOp) void {
    stack.append(self.allocator, op) catch {
        op.destroy(self.allocator);
        return;
    };
    while (stack.items.len > UNDO_CAP) {
        const old = stack.orderedRemove(0);
        old.destroy(self.allocator);
    }
}

pub fn makeUndo(
    self: *BrowserView,
    host: ?[]const u8,
    kind: @FieldType(UndoOp, "kind"),
    a: []const u8,
    b: []const u8,
    p: []const u8,
) ?*UndoOp {
    const op = self.allocator.create(UndoOp) catch return null;
    const host_owned = if (host) |h| self.allocator.dupe(u8, h) catch { self.allocator.destroy(op); return null; } else null;
    const a_owned = self.allocator.dupe(u8, a) catch { self.allocator.destroy(op); return null; };
    const b_owned: []u8 = if (b.len > 0) self.allocator.dupe(u8, b) catch { self.allocator.free(a_owned); if (host_owned) |h| self.allocator.free(h); self.allocator.destroy(op); return null; } else @constCast(&[_]u8{});
    const p_owned: []u8 = if (p.len > 0) self.allocator.dupe(u8, p) catch { if (b_owned.len > 0) self.allocator.free(b_owned); self.allocator.free(a_owned); if (host_owned) |h| self.allocator.free(h); self.allocator.destroy(op); return null; } else @constCast(&[_]u8{});
    op.* = .{ .host = host_owned, .kind = kind, .a = a_owned, .b = b_owned, .p = p_owned };
    return op;
}

/// Register an undo that becomes real when req's reply is ok.
pub fn deferUndo(self: *BrowserView, req: u32, op: ?*UndoOp) void {
    const u = op orelse return;
    self.pending_undo.append(self.allocator, .{ .req = req, .op = u }) catch u.destroy(self.allocator);
}

pub fn recordTrashUndo(self: *BrowserView, hc: *HostConn, orig: []const u8, trashed: []const u8, info: []const u8) void {
    if (self.makeUndo(hc.host, .trash_restore, trashed, orig, info)) |op| self.pushUndo(op);
}

pub fn performUndo(self: *BrowserView) void {
    self.beginHistory(.undo);
}

pub fn performRedo(self: *BrowserView) void {
    self.beginHistory(.redo);
}

pub fn beginHistory(self: *BrowserView, direction: HistoryDirection) void {
    if (self.history_busy) {
        self.setStatus("a history operation is still running");
        return;
    }
    const source = if (direction == .undo) &self.undo_stack else &self.redo_stack;
    const op = source.pop() orelse {
        self.setStatus(if (direction == .undo) "nothing to undo" else "nothing to redo");
        return;
    };
    const hc = self.hostConnFor(if (op.host) |h| @as(?[]const u8, h) else null) orelse {
        self.pushHistoryStack(source, op);
        return;
    };
    if (hc.state != .ready) {
        self.setStatus("host not connected; history operation retained");
        self.pushHistoryStack(source, op);
        return;
    }
    self.history_busy = true;
    switch (op.kind) {
        .rename_back => {
            const req = self.nextReq();
            if (!self.deferHistory(req, hc, op, direction)) return;
            self.sendOp(hc, .{ .req = req, .op = "rename", .path = if (direction == .undo) op.a else op.b, .to = if (direction == .undo) op.b else op.a });
        },
        .delete_created => {
            var lbl: [128]u8 = undefined;
            const label = std.fmt.bufPrint(&lbl, "{s} copy {s}", .{ @tagName(direction), std.fs.path.basename(op.a) }) catch "copy history";
            if (direction == .undo)
                self.startHistoryJob(hc, "delete_tree", op.a, "", "", label, op, direction)
            else if (op.b.len > 0)
                self.startHistoryJob(hc, "copy", op.b, op.a, "", label, op, direction)
            else
                self.restoreHistory(op, direction);
        },
        .trash_restore => {
            var lbl: [128]u8 = undefined;
            const label = std.fmt.bufPrint(&lbl, "{s} trash {s}", .{ @tagName(direction), std.fs.path.basename(op.b) }) catch "trash history";
            if (direction == .undo)
                self.startHistoryJob(hc, "trash_restore", op.a, op.b, op.p, label, op, direction)
            else
                self.startHistoryJob(hc, "trash", op.b, "", "", label, op, direction);
        },
        .rmdir_created => {
            const req = self.nextReq();
            if (!self.deferHistory(req, hc, op, direction)) return;
            self.sendOp(hc, .{ .req = req, .op = if (direction == .undo) "delete" else "mkdir", .path = op.a });
        },
        .link_created => {
            // Undo unlinks the link (never its target); redo recreates
            // it with the verb recorded in `p`.
            const req = self.nextReq();
            if (!self.deferHistory(req, hc, op, direction)) return;
            if (direction == .undo) {
                self.sendOp(hc, .{ .req = req, .op = "delete", .path = op.a });
            } else {
                self.sendOp(hc, .{ .req = req, .op = op.p, .path = op.a, .to = op.b });
            }
        },
    }
}

pub fn deferHistory(self: *BrowserView, req: u32, hc: *HostConn, op: *UndoOp, direction: HistoryDirection) bool {
    self.pending_history.append(self.allocator, .{ .req = req, .hc = hc, .op = op, .direction = direction }) catch {
        self.restoreHistory(op, direction);
        return false;
    };
    return true;
}

pub fn finishHistory(self: *BrowserView, op: *UndoOp, direction: HistoryDirection) void {
    self.history_busy = false;
    self.pushHistoryStack(if (direction == .undo) &self.redo_stack else &self.undo_stack, op);
    self.setStatus(if (direction == .undo) "undo complete" else "redo complete");
}

pub fn restoreHistory(self: *BrowserView, op: *UndoOp, direction: HistoryDirection) void {
    self.history_busy = false;
    self.pushHistoryStack(if (direction == .undo) &self.undo_stack else &self.redo_stack, op);
}

pub fn updateTrashResult(self: *BrowserView, op: *UndoOp, trashed: []const u8, info: []const u8) void {
    const a = self.allocator.dupe(u8, trashed) catch return;
    const p = self.allocator.dupe(u8, info) catch { self.allocator.free(a); return; };
    self.allocator.free(op.a);
    if (op.p.len > 0) self.allocator.free(op.p);
    op.a = a;
    op.p = p;
}

/// Open a flat results tab listing an archive's members (host-
/// side bsdtar; only the member table crosses the wire).
pub fn startArchiveBrowse(self: *BrowserView, tab: *BTab, archive: []const u8) void {
    var rbuf: [4096]u8 = undefined;
    const parent = std.fs.path.dirname(archive) orelse "/";
    if (parent.len >= rbuf.len) return;
    @memcpy(rbuf[0..parent.len], parent);
    var hbuf: [256]u8 = undefined;
    var host: ?[]const u8 = null;
    if (tab.hc.host) |h| {
        if (h.len >= hbuf.len) return;
        @memcpy(hbuf[0..h.len], h);
        host = hbuf[0..h.len];
    }
    const rtab = self.newTab(host, rbuf[0..parent.len]) orelse return;
    self.closeViewOf(rtab.hc, rtab.root);
    var i: usize = 0;
    while (i < self.pending.items.len) {
        if (self.pending.items[i].tab == rtab) self.dropPending(i) else i += 1;
    }
    rtab.root.flat = true;
    rtab.root.loaded = true;
    rtab.root.view_id = 0;
    rtab.root.archive = self.allocator.dupe(u8, archive) catch &.{};
    var lbl: [96:0]u8 = undefined;
    const l = std.fmt.bufPrintZ(&lbl, "{s}", .{std.fs.path.basename(archive)}) catch "archive";
    c.gtk_label_set_text(rtab.tab_label, l.ptr);
    self.arch_tab = rtab;
    self.startDaemonJobKind(rtab.hc, "archive_list", archive, "", "", "list archive", .{ .kind = .archive_list });
}

pub fn onArchiveMember(self: *BrowserView, e: WireJobEv) void {
    const rtab = self.arch_tab orelse return;
    if (e.path.len == 0) return;
    const dir = rtab.root;
    if (dir.find(e.path) != null) return;
    const a = self.allocator;
    const name = a.dupe(u8, e.path) catch return;
    const kind = a.dupe(u8, if (e.kind.len > 0) e.kind else "file") catch {
        a.free(name);
        return;
    };
    const tgt = a.dupe(u8, e.path) catch {
        a.free(name);
        a.free(kind);
        return;
    };
    dir.entries.append(a, .{
        .name = name,
        .kind = kind,
        .size = e.size,
        .mode = 0,
        .mtime_ms = 0,
        .target = tgt,
        .tdir = false,
    }) catch {
        a.free(name);
        a.free(kind);
        a.free(tgt);
        return;
    };
    if (self.currentTab() == rtab) self.renderTab(rtab);
}

/// Extract one member on the archive's host, then open it.
pub fn extractAndOpenMember(self: *BrowserView, tab: *BTab, member: []const u8) void {
    const archive = tab.root.archive;
    if (archive.len == 0) return;
    const hc = tab.hc;
    if (hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{hc.label()});
        return;
    }
    const req = self.nextReq();
    const pj = self.allocator.create(PendingJob) catch return;
    var lbl: [128]u8 = undefined;
    const label = std.fmt.bufPrint(&lbl, "extract {s}", .{std.fs.path.basename(member)}) catch "extract member";
    pj.* = .{
        .req = req,
        .hc = hc,
        .label = self.allocator.dupe(u8, label) catch {
            self.allocator.destroy(pj);
            return;
        },
        .open_on_done = true,
    };
    self.pending_jobs.append(self.allocator, pj) catch {
        self.allocator.free(pj.label);
        self.allocator.destroy(pj);
        return;
    };
    self.sendOp(hc, .{ .req = req, .op = "archive_extract", .path = archive, .pattern = member });
    self.setStatusFmt("extracting {s} on {s}…", .{ member, hc.label() });
}

/// Drop of an entry spec onto the listing: target dir = the row
/// under the pointer when it's a directory, else the tab root.
pub fn onListDrop(
    target: *c.GtkDropTarget,
    value: *c.GValue,
    x: f64,
    y: f64,
    user: ?*anyopaque,
) callconv(.c) c.gboolean {
    _ = target;
    _ = x;
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    const self = tab.view;
    const cstr = c.g_value_get_string(value) orelse return 0;
    const spec = std.mem.span(@as([*:0]const u8, @ptrCast(cstr)));

    var dst_dir: []const u8 = tab.root.path;
    var dbuf: [4096]u8 = undefined;
    if (c.gtk_list_box_get_row_at_y(tab.listbox, @intFromFloat(y))) |row| {
        if (c.g_object_get_data(@ptrCast(row), "sketerm-row")) |data| {
            const rctx: *RowCtx = @ptrCast(@alignCast(data));
            if (rctx.is_dir) {
                if (rctx.path.len < dbuf.len) {
                    @memcpy(dbuf[0..rctx.path.len], rctx.path);
                    dst_dir = dbuf[0..rctx.path.len];
                }
            }
        }
    }
    return @intFromBool(dropSpecInto(self, tab, spec, dst_dir));
}

/// Land a dragged entry spec in `dst_dir` on `tab`'s host: same host
/// = MOVE (rename, undoable), cross-host = copy. Shared by the
/// listing, the breadcrumb segments and the tab labels.
/// @return false when the spec is unusable or the drop is a no-op.
pub fn dropSpecInto(self: *BrowserView, tab: *BTab, spec: []const u8, dst_dir: []const u8) bool {
    if (spec.len == 0) return false;
    const loc = parseSpec(spec);
    const src_host: ?[]const u8 = if (loc.current_host) null else loc.host;
    const src = loc.path;
    if (src.len == 0 or src[0] != '/') return false;
    const base = std.fs.path.basename(src);
    var dst_buf: [4200]u8 = undefined;
    const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{
        if (dst_dir.len == 1) "" else dst_dir, base,
    }) catch return false;

    if (hostEq(src_host, tab.hc.host)) {
        if (std.mem.eql(u8, src, dst)) return false; // dropped in place
        const req = self.nextReq();
        self.deferUndo(req, self.makeUndo(tab.hc.host, .rename_back, dst, src, ""));
        self.sendOp(tab.hc, .{ .req = req, .op = "rename", .path = src, .to = dst });
        self.setStatusFmt("moved {s} -> {s}", .{ base, dst_dir });
    } else {
        const src_hc = self.hostConnFor(src_host) orelse return false;
        self.startTransfer(src_hc, src, tab.hc, dst, .{});
        self.setStatusFmt("copying {s} -> {s}", .{ base, dst_dir });
    }
    return true;
}

/// The other browser face in this sketerm tab, if any: the
/// orthodox implicit destination.
pub fn peerView(self: *BrowserView) ?*BrowserView {
    const lookup = self.on_peer orelse return null;
    const ctx = self.hooks_ctx orelse return null;
    const peer = lookup(ctx, self.pane) orelse return null;
    return if (peer == self) null else peer;
}

/// Copy (or move) the current selection into the other pane's
/// current directory, conflict dialog included.
pub fn sendToPeer(self: *BrowserView, move: bool, clicked: ?[]const u8) void {
    const tab = self.currentTab() orelse return;
    const peer = self.peerView() orelse {
        self.setStatus("no second browser pane in this tab");
        return;
    };
    const peer_tab = peer.currentTab() orelse return;
    // Same rule as Copy: a clicked row outside the selection acts
    // on itself, not on the selection.
    var one: [1][]u8 = undefined;
    var sources: []const []u8 = tab.selected.items;
    if (clicked) |path| {
        const in_selection = for (tab.selected.items) |sp| {
            if (std.mem.eql(u8, sp, path)) break true;
        } else false;
        if (!in_selection or tab.selected.items.len <= 1) {
            one[0] = @constCast(path);
            sources = one[0..];
        }
    }
    if (sources.len == 0) {
        self.setStatus("select something to send to the other pane");
        return;
    }
    if (hostEq(tab.hc.host, peer_tab.hc.host) and std.mem.eql(u8, tab.root.path, peer_tab.root.path)) {
        self.setStatus("both panes show the same directory");
        return;
    }
    peer.beginPaste(peer_tab, tab.hc.host, sources, move, false);
    var buf: [4300]u8 = undefined;
    self.setStatusFmt("{s} {d} item(s) to {s}", .{
        if (move) "moving" else "copying",
        sources.len,
        peer_tab.spec(&buf),
    });
}
