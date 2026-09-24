//! The browser's small popover prompts: the one-entry name dialog
//! (New Folder / New File / Rename), the Tags entry and the Batch
//! Rename find/replace pair.
//!
//! Only the widgets live here. What a prompt DOES when submitted is an
//! operation in ops.zig (`createEntry`, `commitRename`, `setTags`,
//! `batchRenameSelected`), so the same verb can be driven from a
//! chord, a menu row or a test without a popover in the way.

const std = @import("std");
const c = @import("../../c.zig").c;

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const MenuCtx = @import("menu.zig").MenuCtx;
const connectPopoverAutoUnparent = @import("menu.zig").connectPopoverAutoUnparent;
const menuDone = @import("menu.zig").menuDone;
const ops = @import("ops.zig");
const cast = @import("../../util/cast.zig");

/// The prompt's context is a `MenuCtx` owned by the popover: freed
/// with it through the qdata notify, so a prompt abandoned by a click
/// elsewhere cleans up like one that was submitted.
fn popup(self: *BrowserView, tab: *BTab, popover: *c.GtkWidget, ctx: *MenuCtx, child: *c.GtkWidget, focus: ?*c.GtkWidget) void {
    _ = self;
    c.g_object_set_data_full(@ptrCast(popover), "sketerm-menu", @ptrCast(ctx), @ptrCast(&MenuCtx.free));
    c.gtk_popover_set_child(@ptrCast(popover), child);
    c.gtk_widget_set_parent(popover, tab.page);
    connectPopoverAutoUnparent(popover);
    c.gtk_popover_popup(@ptrCast(popover));
    if (focus) |w| _ = c.gtk_widget_grab_focus(w);
}

/// Preset an entry's text from a bounded slice.
fn presetEntry(entry: *c.GtkWidget, text: []const u8, select_all: bool) void {
    var z: [512:0]u8 = undefined;
    const n = @min(text.len, z.len - 1);
    @memcpy(z[0..n], text[0..n]);
    z[n] = 0;
    c.gtk_editable_set_text(@ptrCast(entry), &z);
    if (select_all) c.gtk_editable_select_region(@ptrCast(entry), 0, -1);
}

fn entryText(entry: *c.GtkEntry) []const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(entry)))));
}

/// One-entry popover shared by Rename (target = old full path)
/// and New Folder / New File (target = null, the current dir).
pub fn entryDialog(self: *BrowserView, tab: *BTab, mode: @TypeOf(@as(MenuCtx, undefined).mode), rename_path: ?[]const u8) void {
    const popover = c.gtk_popover_new();
    const entry = c.gtk_entry_new();
    c.gtk_entry_set_placeholder_text(@ptrCast(entry), switch (mode) {
        .mkdir => "folder name",
        .newfile => "file name",
        else => "new name",
    });
    if (rename_path) |rp| presetEntry(entry, std.fs.path.basename(rp), true);
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
    _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onEntryDialogActivate), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    popup(self, tab, popover, ctx, entry, entry);
}

pub fn onEntryDialogActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    const self = ctx.view;
    const name = entryText(entry);
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) {
        self.setStatus("invalid name");
        return menuDone(ctx);
    }
    switch (ctx.mode) {
        .mkdir => ops.createEntry(self, ctx.tab, .directory, name),
        .newfile => ops.createEntry(self, ctx.tab, .file, name),
        .rename => if (ctx.path) |old| ops.commitRename(self, ctx.tab, old, name),
        .none, .tags => {},
    }
    menuDone(ctx);
}

pub fn onMenuTags(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    const self = ctx.view;
    const path = ctx.path orelse return menuDone(ctx);
    const popover = c.gtk_popover_new();
    const entry = c.gtk_entry_new();
    c.gtk_entry_set_placeholder_text(@ptrCast(entry), "comma,separated,tags (empty clears)");
    const cur = ops.findEntryTags(ctx.tab, path);
    if (cur.len > 0) presetEntry(entry, cur, false);
    const tctx = self.allocator.create(MenuCtx) catch return menuDone(ctx);
    // What is already in use on this host (its daemon's tag index),
    // and how to find it: `#tag` in the search bar.
    ops.refreshKnownTags(self, ctx.tab.hc);
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
    c.gtk_box_append(@ptrCast(box), entry);
    var kb: [600:0]u8 = undefined;
    const known_list: []const u8 = if (ctx.tab.hc.known_tags) |k| (if (k.len > 0) k[0..@min(k.len, 500)] else "none yet") else "none yet";
    const known = std.fmt.bufPrintZ(&kb, "In use: {s}\nSearch with #tag", .{known_list}) catch "Search with #tag";
    const hint = c.gtk_label_new(known.ptr);
    c.gtk_label_set_xalign(@ptrCast(hint), 0);
    c.gtk_label_set_wrap(@ptrCast(hint), 1);
    c.gtk_label_set_max_width_chars(@ptrCast(hint), 48);
    c.gtk_widget_add_css_class(hint, "dim-label");
    c.gtk_box_append(@ptrCast(box), hint);
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
    _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onTagsActivate), @ptrCast(tctx), null, c.G_CONNECT_DEFAULT);
    popup(self, ctx.tab, popover, tctx, box, entry);
    menuDone(ctx);
}

pub fn onTagsActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    const path = ctx.path orelse return menuDone(ctx);
    ops.setTags(ctx.view, ctx.tab.hc, path, entryText(entry));
    menuDone(ctx);
}

pub fn onMenuBatchRename(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
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
    _ = c.g_signal_connect_data(apply, "clicked", @ptrCast(&onBatchRenameApply), @ptrCast(bctx), null, c.G_CONNECT_DEFAULT);
    popup(self, tab, popover, bctx, box, null);
    menuDone(ctx);
}

pub fn onBatchRenameApply(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    const find_txt = entryText(@ptrCast(ctx.entry.?));
    const repl_txt = entryText(@ptrCast(ctx.entry2.?));
    ops.batchRenameSelected(ctx.view, ctx.tab, find_txt, repl_txt);
    menuDone(ctx);
}
