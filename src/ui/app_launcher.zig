//! Remote app launcher — lists the installed GUI apps on a session's
//! host (via the daemon's `app_list`) so the user can pick one to run
//! as a forwarded app, instead of typing its command. The picked
//! app's Exec is spawned as a new `app=true` session on the same host
//! and rendered locally.
//!
//! Lifetime: heap-allocated `Launcher`, freed on the window "destroy".
//! Holds Window + Pane (not Terminal), re-fetching the live Terminal
//! through the Window's pane list so a pane closing under it can't
//! dangle.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const Window = @import("window.zig").Window;
const Pane = @import("pane.zig").Pane;
const Terminal = @import("../terminal.zig").Terminal;

const Launcher = struct {
    allocator: std.mem.Allocator,
    win: *Window,
    pane: *Pane,
    window: *c.GtkWidget,
    listbox: *c.GtkWidget,
    search: *c.GtkWidget,
    status: *c.GtkWidget,
    /// Owned host string for spawning ("" = local).
    host: []u8,

    fn liveTerminal(self: *Launcher) ?*Terminal {
        for (self.win.panes.items) |p| {
            if (p == self.pane) return self.pane.terminal;
        }
        return null;
    }
};

/// Open the launcher for `pane` (a remote/durable session pane).
pub fn open(win: *Window, pane: *Pane) void {
    if (pane.terminal.remote == null) return;
    const allocator = win.allocator;
    const host_str: []const u8 = if (pane.terminal.remote.?.host) |h| h else "";

    const self = allocator.create(Launcher) catch return;
    const window = c.gtk_window_new();
    const list = c.gtk_list_box_new();
    const search = c.gtk_search_entry_new();
    const status = c.gtk_label_new("Loading apps…");
    self.* = .{
        .allocator = allocator,
        .win = win,
        .pane = pane,
        .window = window,
        .listbox = list,
        .search = search,
        .status = status,
        .host = allocator.dupe(u8, host_str) catch {
            allocator.destroy(self);
            c.gtk_window_destroy(@ptrCast(window));
            return;
        },
    };

    var title_buf: [256]u8 = undefined;
    const disp = if (host_str.len > 0) host_str else "this machine";
    const title = std.fmt.bufPrintZ(&title_buf, "Launch App on {s}", .{disp}) catch "Launch App";
    c.gtk_window_set_title(@ptrCast(window), title.ptr);
    c.gtk_window_set_default_size(@ptrCast(window), 480, 620);
    c.gtk_window_set_transient_for(@ptrCast(window), @ptrCast(win.app_window));

    const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_margin_start(search, 8);
    c.gtk_widget_set_margin_end(search, 8);
    c.gtk_widget_set_margin_top(search, 8);
    c.gtk_widget_set_margin_bottom(search, 4);
    _ = c.g_signal_connect_data(search, "search-changed", @ptrCast(&onSearchChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(root), search);

    const scroller = c.gtk_scrolled_window_new();
    c.gtk_widget_set_vexpand(scroller, 1);
    c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), list);
    c.gtk_list_box_set_filter_func(@ptrCast(list), @ptrCast(&filterRow), @ptrCast(self), null);
    _ = c.g_signal_connect_data(list, "row-activated", @ptrCast(&onRowActivated), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(root), scroller);

    c.gtk_label_set_xalign(@ptrCast(status), 0.0);
    c.gtk_widget_set_margin_start(status, 10);
    c.gtk_widget_set_margin_end(status, 10);
    c.gtk_widget_set_margin_top(status, 2);
    c.gtk_widget_set_margin_bottom(status, 6);
    c.gtk_widget_add_css_class(status, "dim-label");
    c.gtk_box_append(@ptrCast(root), status);

    c.gtk_window_set_child(@ptrCast(window), root);
    _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&onDestroy), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

    pane.terminal.apps_ctx = @ptrCast(self);
    pane.terminal.on_apps = onApps;
    c.gtk_window_present(@ptrCast(window));
    pane.terminal.requestApps();
}

fn onDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Launcher, user);
    if (self.liveTerminal()) |term| {
        if (term.apps_ctx == @as(?*anyopaque, @ptrCast(self))) {
            term.on_apps = null;
            term.apps_ctx = null;
        }
    }
    self.allocator.free(self.host);
    self.allocator.destroy(self);
}

/// Terminal.on_apps: populate the list.
fn onApps(ctx: ?*anyopaque, apps: []const Terminal.AppEntry) void {
    const self = cast.userData(Launcher, ctx);
    clearList(self.listbox);
    for (apps) |app| addRow(self, app);
    var sbuf: [64]u8 = undefined;
    const msg = if (apps.len == 0)
        std.fmt.bufPrintZ(&sbuf, "No apps found on the host", .{}) catch ""
    else
        std.fmt.bufPrintZ(&sbuf, "{d} apps — type to filter", .{apps.len}) catch "";
    c.gtk_label_set_text(@ptrCast(self.status), msg.ptr);
}

fn addRow(self: *Launcher, app: Terminal.AppEntry) void {
    if (app.name.len == 0 or app.exec.len == 0) return;
    var name_buf: [512]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{app.name}) catch return;

    const row = c.gtk_list_box_row_new();
    const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 10);
    c.gtk_widget_set_margin_start(box, 8);
    c.gtk_widget_set_margin_end(box, 8);
    c.gtk_widget_set_margin_top(box, 5);
    c.gtk_widget_set_margin_bottom(box, 5);

    // Icon by name (themed); falls back to a generic app icon.
    const icon = if (app.icon.len > 0) blk: {
        var icon_buf: [256]u8 = undefined;
        const iz = std.fmt.bufPrintZ(&icon_buf, "{s}", .{app.icon}) catch break :blk c.gtk_image_new_from_icon_name("application-x-executable-symbolic");
        break :blk c.gtk_image_new_from_icon_name(iz.ptr);
    } else c.gtk_image_new_from_icon_name("application-x-executable-symbolic");
    c.gtk_image_set_icon_size(@ptrCast(icon), c.GTK_ICON_SIZE_LARGE);
    const label = c.gtk_label_new(name_z.ptr);
    c.gtk_label_set_xalign(@ptrCast(label), 0.0);
    c.gtk_widget_set_hexpand(label, 1);
    c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(@ptrCast(box), icon);
    c.gtk_box_append(@ptrCast(box), label);
    c.gtk_list_box_row_set_child(@ptrCast(row), box);

    // Stash exec + name (GLib-owned copies) for filtering/activation.
    var exec_buf: [4096]u8 = undefined;
    if (std.fmt.bufPrintZ(&exec_buf, "{s}", .{app.exec})) |ez| {
        c.g_object_set_data_full(@ptrCast(@alignCast(row)), "al-exec", c.g_strdup(ez.ptr), c.g_free);
    } else |_| return;
    c.g_object_set_data_full(@ptrCast(@alignCast(row)), "al-name", c.g_strdup(name_z.ptr), c.g_free);
    c.gtk_list_box_append(@ptrCast(self.listbox), row);
}

fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Launcher, user);
    const exec_c = c.g_object_get_data(@ptrCast(@alignCast(row)), "al-exec") orelse return;
    const exec = std.mem.span(@as([*:0]const u8, @ptrCast(exec_c)));
    if (exec.len == 0) return;

    // Spawn via the host's shell so full Exec strings work.
    const host_opt: ?[]const u8 = if (self.host.len > 0) self.host else null;
    const argv = [_][]const u8{ "/bin/sh", "-c", exec };
    self.win.launchRemoteAppSession(host_opt, &argv) catch {
        c.gtk_label_set_text(@ptrCast(self.status), "Launch failed (daemon refused the app session)");
        return;
    };
    c.gtk_window_destroy(@ptrCast(self.window));
}

fn onSearchChanged(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Launcher, user);
    c.gtk_list_box_invalidate_filter(@ptrCast(self.listbox));
}

fn filterRow(row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Launcher, user);
    const query_c = c.gtk_editable_get_text(@ptrCast(self.search));
    const query = std.mem.span(query_c);
    if (query.len == 0) return 1;
    const name_c = c.g_object_get_data(@ptrCast(@alignCast(row)), "al-name") orelse return 1;
    const name = std.mem.span(@as([*:0]const u8, @ptrCast(name_c)));
    var qbuf: [256]u8 = undefined;
    var nbuf: [512]u8 = undefined;
    if (query.len >= qbuf.len or name.len >= nbuf.len) return 1;
    const ql = std.ascii.lowerString(qbuf[0..query.len], query);
    const nl = std.ascii.lowerString(nbuf[0..name.len], name);
    return if (std.mem.indexOf(u8, nl, ql) != null) 1 else 0;
}

fn clearList(list: *c.GtkWidget) void {
    while (c.gtk_widget_get_first_child(list)) |child| {
        c.gtk_list_box_remove(@ptrCast(list), child);
    }
}
