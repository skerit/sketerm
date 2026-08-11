//! Remote file picker — a small window that browses the session's
//! filesystem (via the daemon's `file_list`) so the user can navigate
//! to a file and download it, instead of typing a path. Read-only.
//!
//! Lifetime: heap-allocated `Browser`, freed on the window's "destroy".
//! It holds Window + Pane (not the Terminal) and re-fetches the live
//! Terminal through the Window's pane list before every action, so a
//! pane closing under it can't dangle.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const fmtSize = @import("../filebrowser/format.zig").fmtSize;
const Window = @import("window.zig").Window;
const Pane = @import("pane.zig").Pane;
const Terminal = @import("../terminal.zig").Terminal;

const Browser = struct {
    allocator: std.mem.Allocator,
    win: *Window,
    pane: *Pane,
    window: *c.GtkWidget,
    listbox: *c.GtkWidget,
    addr: *c.GtkWidget,
    status: *c.GtkWidget,
    /// Current directory (resolved/canonical), owned. "" until the first
    /// listing arrives.
    cur_path: []u8,

    /// The Terminal IF the pane is still alive — else null (pane closed
    /// while the browser was open).
    fn liveTerminal(self: *Browser) ?*Terminal {
        for (self.win.panes.items) |p| {
            if (p == self.pane) return self.pane.terminal;
        }
        return null;
    }
};

/// Open the remote file browser for `pane` (must be a remote pane).
pub fn open(win: *Window, pane: *Pane) void {
    if (pane.terminal.remote == null) return;
    const allocator = win.allocator;

    const self = allocator.create(Browser) catch return;
    const window = c.gtk_window_new();
    const list = c.gtk_list_box_new();
    const addr = c.gtk_entry_new();
    const status = c.gtk_label_new("");
    self.* = .{
        .allocator = allocator,
        .win = win,
        .pane = pane,
        .window = window,
        .listbox = list,
        .addr = addr,
        .status = status,
        .cur_path = allocator.dupe(u8, "") catch {
            allocator.destroy(self);
            c.gtk_window_destroy(@ptrCast(window));
            return;
        },
    };

    var title_buf: [256]u8 = undefined;
    const host = if (pane.terminal.remote) |r| (if (r.host) |h| h else "local") else "remote";
    const title = std.fmt.bufPrintZ(&title_buf, "Download from {s}", .{host}) catch "Download";
    c.gtk_window_set_title(@ptrCast(window), title.ptr);
    c.gtk_window_set_default_size(@ptrCast(window), 560, 600);
    c.gtk_window_set_transient_for(@ptrCast(window), @ptrCast(win.app_window));

    const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);

    // Address bar: Up button + editable path entry.
    const bar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    c.gtk_widget_set_margin_start(bar, 8);
    c.gtk_widget_set_margin_end(bar, 8);
    c.gtk_widget_set_margin_top(bar, 8);
    c.gtk_widget_set_margin_bottom(bar, 4);
    const up = c.gtk_button_new_from_icon_name("go-up-symbolic");
    c.gtk_widget_set_tooltip_text(up, "Parent directory");
    _ = c.g_signal_connect_data(up, "clicked", @ptrCast(&onUpClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_entry_set_placeholder_text(@ptrCast(addr), "Path");
    c.gtk_widget_set_hexpand(addr, 1);
    _ = c.g_signal_connect_data(addr, "activate", @ptrCast(&onAddrActivate), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(bar), up);
    c.gtk_box_append(@ptrCast(bar), addr);
    c.gtk_box_append(@ptrCast(root), bar);

    // Scrollable directory list.
    const scroller = c.gtk_scrolled_window_new();
    c.gtk_widget_set_vexpand(scroller, 1);
    c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), list);
    _ = c.g_signal_connect_data(list, "row-activated", @ptrCast(&onRowActivated), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(root), scroller);

    // Status line (item count / errors).
    c.gtk_label_set_xalign(@ptrCast(status), 0.0);
    c.gtk_widget_set_margin_start(status, 10);
    c.gtk_widget_set_margin_end(status, 10);
    c.gtk_widget_set_margin_top(status, 2);
    c.gtk_widget_set_margin_bottom(status, 6);
    c.gtk_widget_add_css_class(status, "dim-label");
    c.gtk_box_append(@ptrCast(root), status);

    c.gtk_window_set_child(@ptrCast(window), root);
    _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&onDestroy), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

    // Wire the listing callback and load the cwd.
    pane.terminal.listing_ctx = @ptrCast(self);
    pane.terminal.on_listing = onListing;
    c.gtk_window_present(@ptrCast(window));
    pane.terminal.requestList("");
}

fn onDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Browser, user);
    // Detach our listing callback if the terminal is still around.
    if (self.liveTerminal()) |term| {
        if (term.listing_ctx == @as(?*anyopaque, @ptrCast(self))) {
            term.on_listing = null;
            term.listing_ctx = null;
        }
    }
    self.allocator.free(self.cur_path);
    self.allocator.destroy(self);
}

/// Terminal.on_listing: rebuild the row list for the just-listed dir.
fn onListing(ctx: ?*anyopaque, listing: Terminal.Listing) void {
    const self = cast.userData(Browser, ctx);

    if (listing.err.len > 0) {
        // Navigation failed (e.g. permission denied): keep the current
        // view, surface the reason.
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "Cannot open: {s}", .{listing.err}) catch "Cannot open directory";
        c.gtk_label_set_text(@ptrCast(self.status), msg.ptr);
        return;
    }

    // Adopt the resolved path.
    const newp = self.allocator.dupe(u8, listing.path) catch return;
    self.allocator.free(self.cur_path);
    self.cur_path = newp;
    var addr_buf: [4096]u8 = undefined;
    if (std.fmt.bufPrintZ(&addr_buf, "{s}", .{listing.path})) |z| {
        c.gtk_editable_set_text(@ptrCast(self.addr), z.ptr);
    } else |_| {}

    clearList(self.listbox);
    for (listing.entries) |e| addRow(self, e);

    var sbuf: [128]u8 = undefined;
    const status = if (listing.truncated)
        std.fmt.bufPrintZ(&sbuf, "{d} items (truncated)", .{listing.entries.len}) catch ""
    else
        std.fmt.bufPrintZ(&sbuf, "{d} items", .{listing.entries.len}) catch "";
    c.gtk_label_set_text(@ptrCast(self.status), status.ptr);
}

fn addRow(self: *Browser, e: Terminal.DirEntry) void {
    var name_buf: [1024]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{e.name}) catch return;

    const row = c.gtk_list_box_row_new();
    const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_widget_set_margin_start(box, 6);
    c.gtk_widget_set_margin_end(box, 6);
    c.gtk_widget_set_margin_top(box, 3);
    c.gtk_widget_set_margin_bottom(box, 3);

    const icon = c.gtk_image_new_from_icon_name(if (e.is_dir) "folder-symbolic" else "text-x-generic-symbolic");
    const label = c.gtk_label_new(name_z.ptr);
    c.gtk_label_set_xalign(@ptrCast(label), 0.0);
    c.gtk_widget_set_hexpand(label, 1);
    c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_MIDDLE);
    c.gtk_box_append(@ptrCast(box), icon);
    c.gtk_box_append(@ptrCast(box), label);

    if (!e.is_dir) {
        var size_buf: [48:0]u8 = undefined;
        const size_z = fmtSize(&size_buf, e.size);
        const slabel = c.gtk_label_new(size_z.ptr);
        c.gtk_widget_add_css_class(slabel, "dim-label");
        c.gtk_box_append(@ptrCast(box), slabel);
    }

    c.gtk_list_box_row_set_child(@ptrCast(row), box);
    // Stash the entry's identity on the row for row-activated.
    c.g_object_set_data(@ptrCast(@alignCast(row)), "rb-isdir", @ptrFromInt(@as(usize, @intFromBool(e.is_dir))));
    const dup = c.g_strdup(name_z.ptr);
    c.g_object_set_data_full(@ptrCast(@alignCast(row)), "rb-name", dup, c.g_free);
    c.gtk_list_box_append(@ptrCast(self.listbox), row);
}

fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Browser, user);
    const name_c = c.g_object_get_data(@ptrCast(@alignCast(row)), "rb-name") orelse return;
    const name = std.mem.span(@as([*:0]const u8, @ptrCast(name_c)));
    const is_dir = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(row)), "rb-isdir")) != 0;

    var path_buf: [4096]u8 = undefined;
    const child = if (std.mem.eql(u8, self.cur_path, "/"))
        std.fmt.bufPrint(&path_buf, "/{s}", .{name}) catch return
    else
        std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.cur_path, name }) catch return;

    const term = self.liveTerminal() orelse {
        c.gtk_label_set_text(@ptrCast(self.status), "Session closed");
        return;
    };
    if (is_dir) {
        term.requestList(child);
    } else {
        term.startDownload(child);
        c.gtk_window_destroy(@ptrCast(self.window));
    }
}

fn onUpClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Browser, user);
    const parent = parentPath(self.cur_path);
    const term = self.liveTerminal() orelse return;
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrint(&buf, "{s}", .{parent}) catch return;
    term.requestList(z);
}

fn onAddrActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Browser, user);
    const txt_c = c.gtk_editable_get_text(@ptrCast(entry)) orelse return;
    const txt = std.mem.span(@as([*:0]const u8, @ptrCast(txt_c)));
    if (txt.len == 0) return;
    const term = self.liveTerminal() orelse return;
    term.requestList(txt);
}

fn parentPath(path: []const u8) []const u8 {
    if (path.len <= 1) return "/";
    const trimmed = if (path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return "/";
    if (slash == 0) return "/";
    return trimmed[0..slash];
}

fn clearList(listbox: *c.GtkWidget) void {
    while (c.gtk_widget_get_first_child(listbox)) |child| {
        c.gtk_list_box_remove(@ptrCast(listbox), child);
    }
}
