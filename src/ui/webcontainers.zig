//! Container manager — create, rename, recolour, delete an identity
//! context, and choose how its traffic leaves the machine.
//!
//! An ordinary transient toplevel over the window that opened it (the
//! `webuserscripts.zig` shape): one heap context per window, freed on
//! "destroy" (mechanism 1 — the widget owns the data), and that same
//! "destroy" is the `webstore.cancelFor` choke point the async store
//! replies require.
//!
//! Rows are built from the LIVE registry (`webface.containers()`)
//! rather than from a store round trip: the registry is what the engine
//! was actually told about, so a row can never show an identity the
//! helper does not have. Every mutation writes both.
//!
//! One row context serves several signals, so it is owned by the row
//! widget's qdata (freed at finalize) and BORROWED, notify-free, by the
//! individual connections — never a GDestroyNotify per connection,
//! which would free it at the first disconnect.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const webstore = @import("webstore.zig");
const webface = @import("webface.zig");
const confirm = @import("confirm.zig");
const Window = @import("window.zig").Window;

/// Selectable accents: the palette minus its last entry, which is
/// reserved for the incognito preset.
/// NULL-terminated, as `gtk_drop_down_new_from_strings` requires.
const palette_names = [_:null]?[*:0]const u8{
    "Blue", "Green", "Amber", "Red", "Purple", "Teal", "Pink",
};

/// How a container's traffic leaves. Exactly one, which is how the
/// egress/remote-host exclusion documented on `webface.Container` is
/// enforced in the UI: the two can never both be set.
const Routing = enum(c_uint) {
    direct = 0,
    egress = 1,
    remote = 2,
};

const routing_names = [_:null]?[*:0]const u8{
    "Direct",
    "Via server",
    "Browser runs on",
};

const Manager = struct {
    allocator: std.mem.Allocator,
    win: *Window,
    window: *c.GtkWidget,
    listbox: *c.GtkWidget,
    status: *c.GtkWidget,
    new_name: *c.GtkWidget,
};

const RowCtx = struct {
    allocator: std.mem.Allocator,
    mgr: *Manager,
    id: u32,
    name: *c.GtkWidget,
    color: *c.GtkWidget,
    routing: *c.GtkWidget,
    host: *c.GtkWidget,
};

fn freeRowCtx(user: ?*anyopaque) callconv(.c) void {
    const ctx: *RowCtx = @ptrCast(@alignCast(user orelse return));
    ctx.allocator.destroy(ctx);
}

pub fn openManager(win: *Window) void {
    const allocator = win.allocator;
    // Retry point: if the startup fetch failed (store not up yet, socket
    // moved), this is where a user notices an empty list, so it is where
    // a second attempt belongs. No-ops once a list has landed.
    webface.loadContainers(allocator);
    const self = allocator.create(Manager) catch return;
    const window = c.gtk_window_new();
    self.* = .{
        .allocator = allocator,
        .win = win,
        .window = window,
        .listbox = c.gtk_list_box_new(),
        .status = c.gtk_label_new(""),
        .new_name = c.gtk_entry_new(),
    };

    c.gtk_window_set_title(@ptrCast(window), "Containers");
    c.gtk_window_set_default_size(@ptrCast(window), 640, 460);
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
    c.gtk_entry_set_placeholder_text(@ptrCast(self.new_name), "New container name");
    c.gtk_widget_set_hexpand(self.new_name, 1);
    _ = c.g_signal_connect_data(self.new_name, "activate", @ptrCast(&onCreateClicked), self, null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(footer), self.new_name);
    const add = c.gtk_button_new_with_label("Create");
    c.gtk_widget_add_css_class(add, "suggested-action");
    _ = c.g_signal_connect_data(add, "clicked", @ptrCast(&onCreateClicked), self, null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(footer), add);
    c.gtk_box_append(@ptrCast(root), footer);

    c.gtk_label_set_xalign(@ptrCast(self.status), 0.0);
    c.gtk_widget_add_css_class(self.status, "dim-label");
    c.gtk_widget_set_margin_start(self.status, 10);
    c.gtk_widget_set_margin_bottom(self.status, 6);
    c.gtk_box_append(@ptrCast(root), self.status);

    c.gtk_window_set_child(@ptrCast(window), root);
    _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&onManagerDestroy), self, null, c.G_CONNECT_DEFAULT);
    c.gtk_window_present(@ptrCast(window));
    rebuild(self);
}

fn onManagerDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Manager, user);
    webstore.cancelFor(@ptrCast(self));
    // The create round trip is registered under webface's own pending
    // struct, so `cancelFor` above cannot reach it; without this the
    // reply calls `onCreated` on this freed Manager.
    webface.cancelStoredCreateFor(@ptrCast(self));
    self.allocator.destroy(self);
}

fn colorIndex(rgb: [3]u8) c_uint {
    for (webface.container_palette[0 .. webface.container_palette.len - 1], 0..) |p, i| {
        if (p[0] == rgb[0] and p[1] == rgb[1] and p[2] == rgb[2]) return @intCast(i);
    }
    return 0;
}

fn rebuild(self: *Manager) void {
    while (c.gtk_list_box_get_row_at_index(@ptrCast(self.listbox), 0)) |row|
        c.gtk_list_box_remove(@ptrCast(self.listbox), @ptrCast(row));

    var shown: usize = 0;
    for (webface.containers()) |*ctn| {
        // Incognito jars are throwaway and unnamed by the user; they are
        // not identities to manage, and nothing about them persists.
        if (ctn.ephemeral) continue;
        shown += 1;

        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
        c.gtk_widget_set_margin_start(row, 10);
        c.gtk_widget_set_margin_end(row, 10);
        c.gtk_widget_set_margin_top(row, 4);
        c.gtk_widget_set_margin_bottom(row, 4);

        const color = c.gtk_drop_down_new_from_strings(@ptrCast(&palette_names));
        c.gtk_drop_down_set_selected(@ptrCast(color), colorIndex(ctn.color));
        c.gtk_widget_set_tooltip_text(color, "Accent colour");
        c.gtk_box_append(@ptrCast(row), color);

        const name = c.gtk_entry_new();
        var nz: [160]u8 = undefined;
        const nb = std.fmt.bufPrintZ(&nz, "{s}", .{ctn.name[0..@min(ctn.name.len, 128)]}) catch "";
        c.gtk_editable_set_text(@ptrCast(name), nb.ptr);
        c.gtk_widget_set_hexpand(name, 1);
        c.gtk_box_append(@ptrCast(row), name);

        const routing = c.gtk_drop_down_new_from_strings(@ptrCast(&routing_names));
        const mode: Routing = if (ctn.remote_host.len != 0)
            .remote
        else if (ctn.egress_host.len != 0) .egress else .direct;
        c.gtk_drop_down_set_selected(@ptrCast(routing), @intFromEnum(mode));
        c.gtk_box_append(@ptrCast(row), routing);

        const host = c.gtk_entry_new();
        c.gtk_entry_set_placeholder_text(@ptrCast(host), "host");
        const cur_host = if (ctn.remote_host.len != 0) ctn.remote_host else ctn.egress_host;
        var hz: [160]u8 = undefined;
        const hb = std.fmt.bufPrintZ(&hz, "{s}", .{cur_host[0..@min(cur_host.len, 128)]}) catch "";
        c.gtk_editable_set_text(@ptrCast(host), hb.ptr);
        c.gtk_widget_set_sensitive(host, if (mode == .direct) 0 else 1);
        c.gtk_box_append(@ptrCast(row), host);

        const rm = c.gtk_button_new_from_icon_name("user-trash-symbolic");
        c.gtk_widget_set_tooltip_text(rm, "Delete container");
        c.gtk_widget_add_css_class(rm, "flat");
        c.gtk_box_append(@ptrCast(row), rm);

        const ctx = self.allocator.create(RowCtx) catch continue;
        ctx.* = .{
            .allocator = self.allocator,
            .mgr = self,
            .id = ctn.id,
            .name = name,
            .color = color,
            .routing = routing,
            .host = host,
        };
        // Mechanism 1: the row owns the context and frees it at
        // finalize. The four connections below BORROW it with no
        // destroy-notify of their own.
        c.g_object_set_data_full(@ptrCast(row), "sketerm-container-row", @ptrCast(ctx), freeRowCtx);
        _ = c.g_signal_connect_data(name, "activate", @ptrCast(&onApply), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(host, "activate", @ptrCast(&onApply), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(color, "notify::selected", @ptrCast(&onNotifyApply), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(routing, "notify::selected", @ptrCast(&onNotifyApply), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(rm, "clicked", @ptrCast(&onRemove), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);

        c.gtk_list_box_append(@ptrCast(self.listbox), row);
    }

    var buf: [96]u8 = undefined;
    const txt = if (shown == 0)
        std.fmt.bufPrintZ(&buf, "No containers yet. Name one below to create it.", .{}) catch ""
    else
        std.fmt.bufPrintZ(&buf, "{d} container{s}. Press Enter in a field to apply.", .{
            shown,
            if (shown == 1) "" else "s",
        }) catch "";
    c.gtk_label_set_text(@ptrCast(self.status), txt.ptr);
}

fn setStatus(self: *Manager, msg: [*:0]const u8) void {
    c.gtk_label_set_text(@ptrCast(self.status), msg);
}

fn onNotifyApply(w: *c.GtkWidget, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    _ = w;
    apply(cast.userData(RowCtx, user));
}

fn onApply(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    apply(cast.userData(RowCtx, user));
}

fn apply(ctx: *RowCtx) void {
    const gpa = ctx.allocator;
    const name = std.mem.span(c.gtk_editable_get_text(@ptrCast(ctx.name)));
    const host = std.mem.span(c.gtk_editable_get_text(@ptrCast(ctx.host)));
    const mode: Routing = @enumFromInt(c.gtk_drop_down_get_selected(@ptrCast(ctx.routing)));
    const ci = c.gtk_drop_down_get_selected(@ptrCast(ctx.color));
    const rgb = webface.container_palette[@min(ci, webface.container_palette.len - 2)];

    if (name.len == 0) {
        setStatus(ctx.mgr, "A container needs a name.");
        return;
    }
    c.gtk_widget_set_sensitive(ctx.host, if (mode == .direct) 0 else 1);
    if (mode != .direct and host.len == 0) {
        setStatus(ctx.mgr, "That routing needs a host.");
        return;
    }

    // Exactly one of the two is ever non-empty: the mode picks it, so
    // the mutually exclusive pair cannot be expressed here at all.
    const egress: []const u8 = if (mode == .egress) host else "";
    const remote: []const u8 = if (mode == .remote) host else "";

    _ = webface.renameContainer(gpa, ctx.id, name);
    _ = webface.recolorContainer(ctx.id, rgb);
    _ = webstore.containerUpdate(gpa, ctx.id, name, rgb, egress, remote, @ptrCast(ctx.mgr), &onMutated);

    // Routing only takes effect for views created afterwards: a live
    // browser's request context is fixed at view_create, so saying so
    // is more honest than implying the open tab moved.
    if (mode != .direct)
        setStatus(ctx.mgr, "Saved. New tabs in this container use the new route.")
    else
        setStatus(ctx.mgr, "Saved.");
}

fn onRemove(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RowCtx, user);
    const CtxBox = struct { allocator: std.mem.Allocator, mgr: *Manager, id: u32 };
    const box = ctx.allocator.create(CtxBox) catch return;
    box.* = .{ .allocator = ctx.allocator, .mgr = ctx.mgr, .id = ctx.id };
    const S = struct {
        fn done(user2: ?*anyopaque, response: []const u8) void {
            const b: *CtxBox = @ptrCast(@alignCast(user2 orelse return));
            defer b.allocator.destroy(b);
            if (!std.mem.eql(u8, response, "delete")) return;
            _ = webface.destroyContainer(b.allocator, b.id);
            _ = webstore.containerRemove(b.allocator, b.id, @ptrCast(b.mgr), &onMutated);
        }
    };
    if (confirm.present(ctx.mgr.window, .{
        .heading = "Delete this container?",
        .body = "Its cookies and cache stay on disk until the browser is restarted, but the identity and every \"always open here\" rule pointing at it are forgotten.",
        .responses = &.{
            .{ .id = "cancel", .label = "Cancel", .is_close = true },
            .{ .id = "delete", .label = "Delete", .appearance = .destructive, .is_default = true },
        },
    }, .{ .allocator = ctx.allocator, .cb = &S.done, .ctx = @ptrCast(box) }) == null) {
        ctx.allocator.destroy(box);
    }
}

fn onCreateClicked(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Manager, user);
    const name = std.mem.span(c.gtk_editable_get_text(@ptrCast(self.new_name)));
    if (name.len == 0) {
        setStatus(self, "Type a name first.");
        return;
    }
    // The colour is assigned by creation order, exactly as the palette
    // rotation elsewhere does; the row's picker changes it afterwards.
    const rgb = webface.container_palette[webface.containers().len %
        (webface.container_palette.len - 1)];
    if (!webface.createStoredContainer(self.allocator, name, rgb, "", "", @ptrCast(self), &onCreated)) {
        setStatus(self, "Store unavailable — cannot create a container.");
        return;
    }
    c.gtk_editable_set_text(@ptrCast(self.new_name), "");
    setStatus(self, "Creating…");
}

fn onCreated(ctx: ?*anyopaque, id: u32) void {
    const self = cast.userData(Manager, ctx);
    if (id == 0) {
        setStatus(self, "The container could not be stored.");
        return;
    }
    rebuild(self);
}

fn onMutated(ctx: ?*anyopaque, ok: bool, _: []const u8) void {
    const self = cast.userData(Manager, ctx);
    if (!ok) {
        setStatus(self, "The store rejected that change.");
        return;
    }
    rebuild(self);
}
