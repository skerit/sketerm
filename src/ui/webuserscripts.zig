//! Userscript manager and per-site userstyle editor — the human face
//! of the web store's userscript/userstyle records.
//!
//! Both are ordinary transient toplevels over the window that opened
//! them (the webhistory.zig shape): one heap context per window, freed
//! on "destroy" (mechanism 1 — the widget owns the data), and that
//! same "destroy" is the `webstore.cancelFor` choke point the async
//! store replies require.
//!
//! Every mutation ends in `webface.client().refreshUserContent()`, so
//! the daemon store and the live helper never disagree for longer
//! than one store round trip.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const webstore = @import("webstore.zig");
const webface = @import("webface.zig");
const userscript = @import("../web/userscript.zig");
const pickwin = @import("picker.zig");
const fpicker = @import("../filebrowser/picker.zig");
const Window = @import("window.zig").Window;

/// Largest userscript file the ADD path will read; mirrors the store's
/// own cap so nothing is read that the daemon would refuse anyway.
const MAX_SCRIPT = 2 << 20;

// ── userscript manager ──────────────────────────────────────────

const Manager = struct {
    allocator: std.mem.Allocator,
    win: *Window,
    window: *c.GtkWidget,
    listbox: *c.GtkWidget,
    status: *c.GtkWidget,
};

/// Per-row signal context, owned by its closure via `cast.destroyCtx`
/// (it owns nothing but itself). The manager back-pointer stays valid
/// because rows are children of the manager window: their closures die
/// with it, before `onManagerDestroy` frees the manager.
const RowCtx = struct {
    allocator: std.mem.Allocator,
    mgr: *Manager,
    id: u64,
};

pub fn openManager(win: *Window) void {
    const allocator = win.allocator;
    const self = allocator.create(Manager) catch return;
    const window = c.gtk_window_new();
    self.* = .{
        .allocator = allocator,
        .win = win,
        .window = window,
        .listbox = c.gtk_list_box_new(),
        .status = c.gtk_label_new("Loading…"),
    };

    c.gtk_window_set_title(@ptrCast(window), "Userscripts");
    c.gtk_window_set_default_size(@ptrCast(window), 560, 480);
    c.gtk_window_set_transient_for(@ptrCast(window), @ptrCast(win.app_window));

    const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);

    const scroller = c.gtk_scrolled_window_new();
    c.gtk_widget_set_vexpand(scroller, 1);
    c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_list_box_set_selection_mode(@ptrCast(self.listbox), c.GTK_SELECTION_NONE);
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), self.listbox);
    c.gtk_box_append(@ptrCast(root), scroller);

    const footer = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_widget_set_margin_start(footer, 10);
    c.gtk_widget_set_margin_end(footer, 10);
    c.gtk_widget_set_margin_top(footer, 6);
    c.gtk_widget_set_margin_bottom(footer, 8);
    c.gtk_label_set_xalign(@ptrCast(self.status), 0.0);
    c.gtk_widget_set_hexpand(self.status, 1);
    c.gtk_widget_add_css_class(self.status, "dim-label");
    c.gtk_box_append(@ptrCast(footer), self.status);
    const add = c.gtk_button_new_with_label("Add from File…");
    _ = c.g_signal_connect_data(add, "clicked", @ptrCast(&onAddClicked), self, null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(footer), add);
    c.gtk_box_append(@ptrCast(root), footer);

    c.gtk_window_set_child(@ptrCast(window), root);
    _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&onManagerDestroy), self, null, c.G_CONNECT_DEFAULT);
    c.gtk_window_present(@ptrCast(window));
    refreshManager(self);
}

fn onManagerDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Manager, user);
    webstore.cancelFor(@ptrCast(self));
    self.allocator.destroy(self);
}

fn refreshManager(self: *Manager) void {
    if (!webstore.userscriptList(self.allocator, @ptrCast(self), &onListReply))
        c.gtk_label_set_text(@ptrCast(self.status), "Store unavailable.");
}

fn onListReply(ctx: ?*anyopaque, ok: bool, payload: []const u8) void {
    const self = cast.userData(Manager, ctx);
    if (!ok) {
        c.gtk_label_set_text(@ptrCast(self.status), "Store unavailable.");
        return;
    }
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const scripts = webstore.parseUserscripts(arena.allocator(), payload);

    while (c.gtk_list_box_get_row_at_index(@ptrCast(self.listbox), 0)) |row|
        c.gtk_list_box_remove(@ptrCast(self.listbox), @ptrCast(row));

    for (scripts) |s| {
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
        c.gtk_widget_set_margin_start(row, 10);
        c.gtk_widget_set_margin_end(row, 10);
        c.gtk_widget_set_margin_top(row, 4);
        c.gtk_widget_set_margin_bottom(row, 4);

        var name_z: [280]u8 = undefined;
        const shown = if (s.name.len > 0) s.name else "(unnamed script)";
        const nz = std.fmt.bufPrintZ(&name_z, "{s}", .{shown[0..@min(shown.len, 256)]}) catch "script";
        const label = c.gtk_label_new(nz.ptr);
        c.gtk_label_set_xalign(@ptrCast(label), 0.0);
        c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
        c.gtk_widget_set_hexpand(label, 1);
        c.gtk_box_append(@ptrCast(row), label);

        const sw = c.gtk_switch_new();
        c.gtk_switch_set_active(@ptrCast(sw), if (s.enabled) 1 else 0);
        c.gtk_widget_set_valign(sw, c.GTK_ALIGN_CENTER);
        const swctx = self.allocator.create(RowCtx) catch continue;
        swctx.* = .{ .allocator = self.allocator, .mgr = self, .id = s.id };
        _ = c.g_signal_connect_data(sw, "state-set", @ptrCast(&onRowToggled), swctx, @ptrCast(cast.destroyCtx(RowCtx)), c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row), sw);

        const rm = c.gtk_button_new_from_icon_name("user-trash-symbolic");
        c.gtk_widget_set_tooltip_text(rm, "Remove userscript");
        c.gtk_widget_add_css_class(rm, "flat");
        const rmctx = self.allocator.create(RowCtx) catch continue;
        rmctx.* = .{ .allocator = self.allocator, .mgr = self, .id = s.id };
        _ = c.g_signal_connect_data(rm, "clicked", @ptrCast(&onRowRemove), rmctx, @ptrCast(cast.destroyCtx(RowCtx)), c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row), rm);

        c.gtk_list_box_append(@ptrCast(self.listbox), row);
    }
    var buf: [64]u8 = undefined;
    const txt = std.fmt.bufPrintZ(&buf, "{d} userscript{s}", .{
        scripts.len,
        if (scripts.len == 1) "" else "s",
    }) catch "";
    c.gtk_label_set_text(@ptrCast(self.status), txt.ptr);
}

fn onRowToggled(_: *c.GtkWidget, state: c.gboolean, user: ?*anyopaque) callconv(.c) c.gboolean {
    const ctx = cast.userData(RowCtx, user);
    _ = webstore.userscriptEnable(ctx.allocator, ctx.id, state != 0, @ptrCast(ctx.mgr), &onMutated);
    return 0; // let the switch settle visually
}

fn onRowRemove(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RowCtx, user);
    _ = webstore.userscriptRemove(ctx.allocator, ctx.id, @ptrCast(ctx.mgr), &onMutated);
}

/// Any store mutation answered: re-list and re-push to the helper.
fn onMutated(ctx: ?*anyopaque, ok: bool, _: []const u8) void {
    const self = cast.userData(Manager, ctx);
    if (!ok) return;
    refreshManager(self);
    webface.client().refreshUserContent();
}

/// User-data for the add-file picker. The picker can outlive the
/// manager window, so this carries NO manager pointer: the add's
/// store reply resolves through a null context and only re-pushes the
/// helper set. An open manager simply shows the new script on its
/// next relist (toggle, remove, or reopen) — a stale list beats a
/// freed pointer.
const AddCtx = struct {
    allocator: std.mem.Allocator,
};

fn onAddClicked(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Manager, user);
    const ctx = self.allocator.create(AddCtx) catch return;
    ctx.* = .{ .allocator = self.allocator };
    _ = pickwin.PickerWindow.open(self.allocator, @ptrCast(self.window), .{
        .mode = .open_file,
        .title = "Add Userscript",
        .local_only = true,
    }, &onScriptPicked, @ptrCast(ctx)) catch {
        self.allocator.destroy(ctx);
    };
}

fn onScriptPicked(user: ?*anyopaque, result: ?fpicker.Result) void {
    const ctx: *AddCtx = @ptrCast(@alignCast(user.?));
    defer ctx.allocator.destroy(ctx);
    const res = result orelse return;
    if (res.specs.len == 0) return;
    const path = pickwin.localPathOrRefuse(
        null,
        res.specs[0],
        "Userscripts are read by this GUI — pick a local file.",
    ) orelse return;

    const source = readFileBounded(ctx.allocator, path) orelse return;
    defer ctx.allocator.free(source);
    // The name comes from the metadata block; a file without one is
    // not a userscript and is refused here rather than stored dead.
    const meta = (userscript.parseMeta(ctx.allocator, source) catch null) orelse return;
    defer userscript.freeMeta(ctx.allocator, &meta);
    const name = if (meta.name.len > 0) meta.name else basename(path);
    _ = webstore.userscriptAdd(ctx.allocator, name, source, null, &onAdded);
}

fn onAdded(_: ?*anyopaque, ok: bool, _: []const u8) void {
    if (!ok) return;
    webface.client().refreshUserContent();
}

fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn readFileBounded(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    var z: [4096:0]u8 = undefined;
    const p = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return null;
    const fp = c.fopen(p.ptr, "rb") orelse return null;
    defer _ = c.fclose(fp);
    var list: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, fp);
        if (n == 0) break;
        list.appendSlice(gpa, buf[0..n]) catch {
            list.deinit(gpa);
            return null;
        };
        if (list.items.len > MAX_SCRIPT) {
            list.deinit(gpa);
            return null;
        }
    }
    return list.toOwnedSlice(gpa) catch {
        list.deinit(gpa);
        return null;
    };
}

// ── per-site userstyle editor ───────────────────────────────────

const StyleEd = struct {
    allocator: std.mem.Allocator,
    window: *c.GtkWidget,
    text: *c.GtkWidget,
    enabled: *c.GtkWidget,
    status: *c.GtkWidget,
    /// Owned, lowercased host key the style is stored under.
    host: []u8,
};

/// Open the style editor for one site (`host` is copied).
pub fn openSiteStyle(win: *Window, host: []const u8) void {
    const allocator = win.allocator;
    const self = allocator.create(StyleEd) catch return;
    const owned = allocator.dupe(u8, host) catch {
        allocator.destroy(self);
        return;
    };
    for (owned) |*ch| ch.* = std.ascii.toLower(ch.*);
    const window = c.gtk_window_new();
    self.* = .{
        .allocator = allocator,
        .window = window,
        .text = c.gtk_text_view_new(),
        .enabled = c.gtk_check_button_new_with_label("Enabled"),
        .status = c.gtk_label_new("Loading…"),
        .host = owned,
    };

    var title: [560]u8 = undefined;
    const tz = std.fmt.bufPrintZ(&title, "Style for {s}", .{self.host}) catch "Site Style";
    c.gtk_window_set_title(@ptrCast(window), tz.ptr);
    c.gtk_window_set_default_size(@ptrCast(window), 560, 480);
    c.gtk_window_set_transient_for(@ptrCast(window), @ptrCast(win.app_window));

    const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    const scroller = c.gtk_scrolled_window_new();
    c.gtk_widget_set_vexpand(scroller, 1);
    c.gtk_text_view_set_monospace(@ptrCast(self.text), 1);
    c.gtk_text_view_set_left_margin(@ptrCast(self.text), 8);
    c.gtk_text_view_set_top_margin(@ptrCast(self.text), 8);
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), self.text);
    c.gtk_box_append(@ptrCast(root), scroller);

    const footer = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_widget_set_margin_start(footer, 10);
    c.gtk_widget_set_margin_end(footer, 10);
    c.gtk_widget_set_margin_top(footer, 6);
    c.gtk_widget_set_margin_bottom(footer, 8);
    c.gtk_check_button_set_active(@ptrCast(self.enabled), 1);
    c.gtk_box_append(@ptrCast(footer), self.enabled);
    c.gtk_label_set_xalign(@ptrCast(self.status), 0.0);
    c.gtk_widget_set_hexpand(self.status, 1);
    c.gtk_widget_add_css_class(self.status, "dim-label");
    c.gtk_box_append(@ptrCast(footer), self.status);
    const save = c.gtk_button_new_with_label("Save");
    c.gtk_widget_add_css_class(save, "suggested-action");
    _ = c.g_signal_connect_data(save, "clicked", @ptrCast(&onStyleSave), self, null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(footer), save);
    c.gtk_box_append(@ptrCast(root), footer);

    c.gtk_window_set_child(@ptrCast(window), root);
    _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&onStyleDestroy), self, null, c.G_CONNECT_DEFAULT);
    c.gtk_window_present(@ptrCast(window));

    if (!webstore.userstyleGet(allocator, self.host, @ptrCast(self), &onStyleReply))
        c.gtk_label_set_text(@ptrCast(self.status), "Store unavailable.");
}

fn onStyleDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(StyleEd, user);
    webstore.cancelFor(@ptrCast(self));
    self.allocator.free(self.host);
    self.allocator.destroy(self);
}

fn onStyleReply(ctx: ?*anyopaque, ok: bool, payload: []const u8) void {
    const self = cast.userData(StyleEd, ctx);
    if (!ok) {
        c.gtk_label_set_text(@ptrCast(self.status), "Store unavailable.");
        return;
    }
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const buffer = c.gtk_text_view_get_buffer(@ptrCast(self.text));
    if (webstore.parseUserstyle(arena.allocator(), payload)) |style| {
        c.gtk_text_buffer_set_text(buffer, style.css.ptr, @intCast(style.css.len));
        c.gtk_check_button_set_active(@ptrCast(self.enabled), if (style.enabled) 1 else 0);
        c.gtk_label_set_text(@ptrCast(self.status), "Stored style loaded.");
    } else {
        c.gtk_label_set_text(@ptrCast(self.status), "No style stored yet. Empty CSS deletes.");
    }
}

fn onStyleSave(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(StyleEd, user);
    const buffer = c.gtk_text_view_get_buffer(@ptrCast(self.text));
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_bounds(buffer, &start, &end);
    const raw = c.gtk_text_buffer_get_text(buffer, &start, &end, 0);
    defer c.g_free(raw);
    const css = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
    const enabled = c.gtk_check_button_get_active(@ptrCast(self.enabled)) != 0;
    if (!webstore.userstyleSet(self.allocator, self.host, css, enabled, @ptrCast(self), &onStyleSaved)) {
        c.gtk_label_set_text(@ptrCast(self.status), "Store unavailable.");
    }
}

fn onStyleSaved(ctx: ?*anyopaque, ok: bool, _: []const u8) void {
    const self = cast.userData(StyleEd, ctx);
    if (!ok) {
        c.gtk_label_set_text(@ptrCast(self.status), "Save failed.");
        return;
    }
    c.gtk_label_set_text(@ptrCast(self.status), "Saved.");
    // Instant apply: the helper swaps live style elements on this set.
    webface.client().refreshUserContent();
}
