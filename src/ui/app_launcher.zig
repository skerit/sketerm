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
const pathz = @import("../util/pathz.zig");
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
    /// Right-click context menu (parented to the listbox) and the row
    /// it was opened on.
    row_menu: *c.GtkWidget,
    menu_row: ?*c.GtkListBoxRow = null,
    /// Owned host string for spawning ("" = local).
    host: []u8,
    /// Recently launched apps (persisted), most recent first.
    recents: ?std.json.Parsed([]RecentEntry) = null,

    fn liveTerminal(self: *Launcher) ?*Terminal {
        for (self.win.panes.items) |p| {
            if (p == self.pane) return self.pane.terminal;
        }
        return null;
    }
};

// ── recent-apps persistence ($XDG_STATE_HOME/sketerm) ────────────

const RecentEntry = struct {
    host: []const u8 = "",
    name: []const u8 = "",
    exec: []const u8 = "",
    icon: []const u8 = "",
};

const max_recents = 12;

fn recentsPath(allocator: std.mem.Allocator) ![]u8 {
    const profile = @import("../util/profile.zig");
    if (profile.getenv("XDG_STATE_HOME")) |xs| {
        return std.fmt.allocPrint(allocator, "{s}/sketerm/recent-apps.json", .{xs});
    }
    if (profile.getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.local/state/sketerm/recent-apps.json", .{home});
    }
    return error.NoHome;
}

fn loadRecents(allocator: std.mem.Allocator) ?std.json.Parsed([]RecentEntry) {
    const path = recentsPath(allocator) catch return null;
    defer allocator.free(path);
    var zbuf: [4096]u8 = undefined;
    const z = pathz.pathZ(&zbuf, path) catch return null;
    const f = c.fopen(z, "rb") orelse return null;
    defer _ = c.fclose(f);
    var buf: [64 * 1024]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len, f);
    if (n == 0) return null;
    return std.json.parseFromSlice([]RecentEntry, allocator, buf[0..n], .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

/// Prepend (host, name, exec, icon), dedupe by host+exec, cap, save.
fn saveRecent(allocator: std.mem.Allocator, host: []const u8, name: []const u8, exec: []const u8, icon: []const u8) void {
    var list: std.ArrayList(RecentEntry) = .empty;
    defer list.deinit(allocator);
    list.append(allocator, .{ .host = host, .name = name, .exec = exec, .icon = icon }) catch return;
    const old = loadRecents(allocator);
    defer if (old) |o| o.deinit();
    if (old) |o| {
        for (o.value) |e| {
            if (std.mem.eql(u8, e.host, host) and std.mem.eql(u8, e.exec, exec)) continue;
            if (list.items.len >= max_recents) break;
            list.append(allocator, e) catch break;
        }
    }
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    std.json.Stringify.value(list.items, .{}, &aw.writer) catch return;
    const path = recentsPath(allocator) catch return;
    defer allocator.free(path);
    pathz.makeParentDirs(path) catch return;
    var zbuf: [4096]u8 = undefined;
    const z = pathz.pathZ(&zbuf, path) catch return;
    const f = c.fopen(z, "wb") orelse return;
    defer _ = c.fclose(f);
    _ = c.fwrite(aw.written().ptr, 1, aw.written().len, f);
}

/// 1-based recency rank of (host, exec), 0 = not recent.
fn recentRank(self: *Launcher, exec: []const u8) usize {
    const parsed = self.recents orelse return 0;
    for (parsed.value, 0..) |e, i| {
        if (std.mem.eql(u8, e.host, self.host) and std.mem.eql(u8, e.exec, exec)) return i + 1;
    }
    return 0;
}

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
    const row_menu = c.gtk_popover_new();
    self.* = .{
        .allocator = allocator,
        .win = win,
        .pane = pane,
        .window = window,
        .listbox = list,
        .search = search,
        .status = status,
        .row_menu = row_menu,
        .host = allocator.dupe(u8, host_str) catch {
            allocator.destroy(self);
            c.gtk_window_destroy(@ptrCast(window));
            return;
        },
    };

    self.recents = loadRecents(allocator);

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
    // Enter launches the first (best) visible match; Esc closes.
    _ = c.g_signal_connect_data(search, "activate", @ptrCast(&onSearchActivate), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(search, "stop-search", @ptrCast(&onStopSearch), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(root), search);
    const esc = c.gtk_shortcut_controller_new();
    c.gtk_shortcut_controller_add_shortcut(
        @ptrCast(esc),
        c.gtk_shortcut_new(
            c.gtk_keyval_trigger_new(c.GDK_KEY_Escape, 0),
            c.gtk_callback_action_new(@ptrCast(&onEscape), @ptrCast(self), null),
        ),
    );
    c.gtk_widget_add_controller(window, esc);

    const scroller = c.gtk_scrolled_window_new();
    c.gtk_widget_set_vexpand(scroller, 1);
    c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), list);
    c.gtk_list_box_set_filter_func(@ptrCast(list), @ptrCast(&filterRow), @ptrCast(self), null);
    c.gtk_list_box_set_sort_func(@ptrCast(list), @ptrCast(&sortRow), @ptrCast(self), null);
    _ = c.g_signal_connect_data(list, "row-activated", @ptrCast(&onRowActivated), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(root), scroller);

    // Right-click context menu on a row: "Launch with GPU" (the
    // activate default follows the `gpu_apps` config list). Parented
    // to the root box, NOT the listbox — clearList walks the listbox's
    // children and a non-row child would wedge it.
    c.gtk_widget_set_parent(row_menu, root);
    c.gtk_popover_set_has_arrow(@ptrCast(row_menu), 0);
    const gpu_btn = c.gtk_button_new();
    const gpu_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_box_append(@ptrCast(gpu_box), c.gtk_image_new_from_icon_name("video-display-symbolic"));
    c.gtk_box_append(@ptrCast(gpu_box), c.gtk_label_new("Launch with GPU"));
    c.gtk_button_set_child(@ptrCast(gpu_btn), gpu_box);
    c.gtk_widget_add_css_class(gpu_btn, "flat");
    _ = c.g_signal_connect_data(gpu_btn, "clicked", @ptrCast(&onGpuLaunch), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_popover_set_child(@ptrCast(row_menu), gpu_btn);
    const rclick = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(rclick), 3);
    _ = c.g_signal_connect_data(rclick, "pressed", @ptrCast(&onRowRightClick), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(list, @ptrCast(rclick));

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
    _ = c.gtk_widget_grab_focus(search);
    pane.terminal.requestApps();
}

fn onEscape(_: ?*c.GtkWidget, _: ?*c.GVariant, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Launcher, user);
    c.gtk_window_destroy(@ptrCast(self.window));
    return 1;
}

fn onStopSearch(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Launcher, user);
    c.gtk_window_destroy(@ptrCast(self.window));
}

/// Enter in the search box: launch the first visible row.
fn onSearchActivate(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Launcher, user);
    var i: c_int = 0;
    while (c.gtk_list_box_get_row_at_index(@ptrCast(self.listbox), i)) |row| : (i += 1) {
        if (filterRow(@ptrCast(row), @ptrCast(self)) != 0) {
            launchRow(self, @ptrCast(row), null);
            return;
        }
    }
}

/// Right-click on a row: select it and pop the context menu at the
/// pointer.
fn onRowRightClick(_: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Launcher, user);
    const row = c.gtk_list_box_get_row_at_y(@ptrCast(self.listbox), @intFromFloat(y)) orelse return;
    self.menu_row = @ptrCast(row);
    c.gtk_list_box_select_row(@ptrCast(self.listbox), @ptrCast(row));
    // Gesture coords are listbox-relative; the popover hangs off the
    // root box (see open) — translate.
    var pt: c.graphene_point_t = undefined;
    _ = c.graphene_point_init(&pt, @floatCast(x), @floatCast(y));
    var out: c.graphene_point_t = undefined;
    const parent = c.gtk_widget_get_parent(self.row_menu);
    if (c.gtk_widget_compute_point(self.listbox, parent, &pt, &out) == 0) out = pt;
    const rect = c.GdkRectangle{
        .x = @intFromFloat(out.x),
        .y = @intFromFloat(out.y),
        .width = 1,
        .height = 1,
    };
    c.gtk_popover_set_pointing_to(@ptrCast(self.row_menu), &rect);
    c.gtk_popover_popup(@ptrCast(self.row_menu));
}

fn onGpuLaunch(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Launcher, user);
    c.gtk_popover_popdown(@ptrCast(self.row_menu));
    const row = self.menu_row orelse return;
    self.menu_row = null;
    launchRow(self, row, true);
}

fn onDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Launcher, user);
    if (self.liveTerminal()) |term| {
        if (term.apps_ctx == @as(?*anyopaque, @ptrCast(self))) {
            term.on_apps = null;
            term.apps_ctx = null;
        }
    }
    if (self.recents) |r| r.deinit();
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

    // Stash exec + name (GLib-owned copies) for filtering/activation,
    // recency rank (as pointer-sized int) for sorting, and the icon
    // for the recents file.
    var exec_buf: [4096]u8 = undefined;
    if (std.fmt.bufPrintZ(&exec_buf, "{s}", .{app.exec})) |ez| {
        c.g_object_set_data_full(@ptrCast(@alignCast(row)), "al-exec", c.g_strdup(ez.ptr), c.g_free);
    } else |_| return;
    c.g_object_set_data_full(@ptrCast(@alignCast(row)), "al-name", c.g_strdup(name_z.ptr), c.g_free);
    if (app.icon.len > 0) {
        var icon_buf2: [256]u8 = undefined;
        if (std.fmt.bufPrintZ(&icon_buf2, "{s}", .{app.icon})) |iz| {
            c.g_object_set_data_full(@ptrCast(@alignCast(row)), "al-icon", c.g_strdup(iz.ptr), c.g_free);
        } else |_| {}
    }
    const rank = recentRank(self, app.exec);
    c.g_object_set_data(@ptrCast(@alignCast(row)), "al-rank", @ptrFromInt(rank));
    if (rank > 0) {
        const star = c.gtk_image_new_from_icon_name("document-open-recent-symbolic");
        c.gtk_widget_set_tooltip_text(star, "Recently launched");
        c.gtk_box_append(@ptrCast(box), star);
    }
    c.gtk_list_box_append(@ptrCast(self.listbox), row);
}

fn rowRank(row: *c.GtkListBoxRow) usize {
    return @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(row)), "al-rank"));
}

/// Recently launched first (most recent on top), then alphabetical.
fn sortRow(r1: *c.GtkListBoxRow, r2: *c.GtkListBoxRow, _: ?*anyopaque) callconv(.c) c_int {
    const a = rowRank(r1);
    const b = rowRank(r2);
    if (a != b) {
        if (a == 0) return 1;
        if (b == 0) return -1;
        return if (a < b) -1 else 1;
    }
    const n1 = c.g_object_get_data(@ptrCast(@alignCast(r1)), "al-name");
    const n2 = c.g_object_get_data(@ptrCast(@alignCast(r2)), "al-name");
    if (n1 == null or n2 == null) return 0;
    return c.g_ascii_strcasecmp(@ptrCast(n1), @ptrCast(n2));
}

fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    launchRow(cast.userData(Launcher, user), row, null);
}

/// `gpu_override` forces GPU on/off; null follows the `gpu_apps`
/// config list.
fn launchRow(self: *Launcher, row: *c.GtkListBoxRow, gpu_override: ?bool) void {
    const exec_c = c.g_object_get_data(@ptrCast(@alignCast(row)), "al-exec") orelse return;
    const exec = std.mem.span(@as([*:0]const u8, @ptrCast(exec_c)));
    if (exec.len == 0) return;
    const name: []const u8 = if (c.g_object_get_data(@ptrCast(@alignCast(row)), "al-name")) |n|
        std.mem.span(@as([*:0]const u8, @ptrCast(n)))
    else
        "";
    const icon: []const u8 = if (c.g_object_get_data(@ptrCast(@alignCast(row)), "al-icon")) |i|
        std.mem.span(@as([*:0]const u8, @ptrCast(i)))
    else
        "";

    // Spawn via the host's shell so full Exec strings work.
    const host_opt: ?[]const u8 = if (self.host.len > 0) self.host else null;
    const argv = [_][]const u8{ "/bin/sh", "-c", exec };
    const gpu = gpu_override orelse self.win.config.appWantsGpu(name, exec);
    self.win.launchRemoteAppSession(host_opt, &argv, gpu) catch {
        c.gtk_label_set_text(@ptrCast(self.status), "Launch failed (daemon refused the app session)");
        return;
    };
    saveRecent(self.allocator, self.host, name, exec, icon);
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
