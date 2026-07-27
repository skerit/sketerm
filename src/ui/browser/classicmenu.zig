//! Classic context menus: a GtkPopoverMenu over a GMenuModel with
//! NESTED submenus -- compact native menu rows, and submenus that
//! open to the side ON HOVER instead of click-swapping the page.
//!
//! Items dispatch through ONE "run" GSimpleAction (int target =
//! item index) into the same `fn (*GtkButton, ?*anyopaque)` handlers
//! the old button menus used; the button argument arrives null and
//! no handler reads it. The Root (model + dispatch table) rides the
//! popover as qdata and dies with it -- after a deferred unparent,
//! because GtkPopoverMenu may emit `closed` before the activation
//! that is still going to need the table.

const std = @import("std");
const c = @import("../../c.zig").c;

/// The legacy menu-handler shape, called with a null button.
pub const Handler = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

/// Cleanup for caller-owned per-item state (user-action contexts).
pub const Cleanup = *const fn (?*anyopaque) callconv(.c) void;

pub const Root = struct {
    allocator: std.mem.Allocator,
    model: *c.GMenu,
    items: std.ArrayList(Entry) = .empty,
    cleanups: std.ArrayList(Owned) = .empty,

    const Entry = struct { cb: Handler, ctx: ?*anyopaque };
    const Owned = struct { cb: Cleanup, ctx: ?*anyopaque };

    pub fn create(allocator: std.mem.Allocator) ?*Root {
        const r = allocator.create(Root) catch return null;
        r.* = .{ .allocator = allocator, .model = c.g_menu_new().? };
        return r;
    }

    /// The top-level menu to build into.
    pub fn top(self: *Root) Menu {
        return .{ .root = self, .model = self.model };
    }

    /// Register caller state to free when the menu dies.
    pub fn own(self: *Root, cb: Cleanup, ctx: ?*anyopaque) void {
        self.cleanups.append(self.allocator, .{ .cb = cb, .ctx = ctx }) catch cb(ctx);
    }

    /// Abandon a built-but-never-popped menu (allocation failure
    /// paths); popup() hands ownership to the popover instead.
    pub fn destroy(self: *Root) void {
        destroyCb(@ptrCast(self));
    }

    fn destroyCb(user: ?*anyopaque) callconv(.c) void {
        const self: *Root = @ptrCast(@alignCast(user.?));
        for (self.cleanups.items) |o| o.cb(o.ctx);
        self.cleanups.deinit(self.allocator);
        c.g_object_unref(@as(?*anyopaque, @ptrCast(self.model)));
        self.items.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn onRun(_: ?*c.GSimpleAction, param: ?*c.GVariant, user: ?*anyopaque) callconv(.c) void {
        const self: *Root = @ptrCast(@alignCast(user.?));
        const idx = c.g_variant_get_int32(param);
        if (idx < 0 or idx >= self.items.items.len) return;
        const e = self.items.items[@intCast(idx)];
        e.cb(null, e.ctx);
    }

    /// popup(), with (x, y) given in `clicked`'s coordinates but the
    /// popover anchored to `host`. A popover parented INSIDE a
    /// GtkViewport (listing rows, sidebar rows) gets its available
    /// height miscomputed and clips its last item -- anchoring to a
    /// widget outside every scroller avoids that entirely.
    pub fn popupVia(self: *Root, clicked: *c.GtkWidget, host: *c.GtkWidget, x: f64, y: f64) *c.GtkWidget {
        var src = c.graphene_point_t{ .x = @floatCast(x), .y = @floatCast(y) };
        var dst = c.graphene_point_t{ .x = 0, .y = 0 };
        if (c.gtk_widget_compute_point(clicked, host, &src, &dst) != 0)
            return self.popup(host, @floatCast(dst.x), @floatCast(dst.y));
        return self.popup(clicked, x, y);
    }

    /// Build the popover, attach the dispatch action, pop it up at
    /// (x, y) in `parent`. Ownership of the Root moves to the popover.
    pub fn popup(self: *Root, parent: *c.GtkWidget, x: f64, y: f64) *c.GtkWidget {
        const pop = c.gtk_popover_menu_new_from_model_full(@ptrCast(@alignCast(self.model)), c.GTK_POPOVER_MENU_NESTED);
        c.gtk_popover_set_has_arrow(@ptrCast(pop), 0);
        c.gtk_widget_set_halign(pop, c.GTK_ALIGN_START);

        const group = c.g_simple_action_group_new();
        const vtype = c.g_variant_type_new("i");
        const action = c.g_simple_action_new("run", vtype);
        c.g_variant_type_free(vtype);
        _ = c.g_signal_connect_data(action, "activate", @ptrCast(&onRun), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.g_action_map_add_action(@ptrCast(group), @ptrCast(action));
        c.g_object_unref(action);
        c.gtk_widget_insert_action_group(pop, "sketermmenu", @ptrCast(group));
        c.g_object_unref(group);

        c.g_object_set_data_full(@ptrCast(pop), "sketerm-classicmenu", @ptrCast(self), @ptrCast(&destroyCb));
        c.gtk_widget_set_parent(pop, parent);
        // Deferred unparent: `closed` can precede the activation that
        // still reads this Root, so tearing down inline would be a
        // use-after-free on every item click.
        _ = c.g_signal_connect_data(pop, "closed", @ptrCast(&onClosed), null, null, c.G_CONNECT_DEFAULT);
        const rect = c.GdkRectangle{ .x = @intFromFloat(x), .y = @intFromFloat(y), .width = 1, .height = 1 };
        c.gtk_popover_set_pointing_to(@ptrCast(pop), &rect);
        c.gtk_popover_popup(@ptrCast(pop));
        // AFTER the popup's first size negotiation: applied earlier
        // it is overridden by the popover's own (short) calculation.
        fixClippedHeight(pop.?, parent);
        return pop.?;
    }
};

/// GTK 4.22 sizes a model popover menu ~one row short of its natural
/// height, silently clipping the LAST item (reproduced standalone;
/// the widget tree allocates every row, the popover surface is just
/// too small). Forcing the internal scrolled window's min content
/// height to its natural height (bounded by the window) makes the
/// popover grow to fit.
fn fixClippedHeight(pop: *c.GtkWidget, parent: *c.GtkWidget) void {
    var cap: c_int = 800;
    if (c.gtk_widget_get_root(parent)) |root| {
        const rh = c.gtk_widget_get_height(@ptrCast(@alignCast(root)));
        if (rh > 260) cap = rh - 80;
    }
    // Every scrolled window in the tree: the top level AND each
    // nested submenu popover clip their own last row the same way.
    fixScrolledWindows(pop, 0, cap);
}

fn fixScrolledWindows(w: *c.GtkWidget, depth: u32, cap: c_int) void {
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(w)), c.gtk_scrolled_window_get_type()) != 0) {
        // Measure the CHILD, not the scrolled window: the scrolled
        // window's own natural height under-reports (it is where the
        // clipping bug lives).
        const child = c.gtk_scrolled_window_get_child(@ptrCast(w)) orelse return;
        var min_h: c_int = 0;
        var nat_h: c_int = 0;
        c.gtk_widget_measure(child, c.GTK_ORIENTATION_VERTICAL, -1, &min_h, &nat_h, null, null);
        c.gtk_scrolled_window_set_min_content_height(@ptrCast(w), @min(nat_h, cap));
        // Keep walking: nested submenu popovers live INSIDE this
        // scrolled window's viewport and clip the same way.
    }
    // Submenu popovers hang ~10 levels deep off their model buttons.
    if (depth > 16) return;
    var child = c.gtk_widget_get_first_child(w);
    while (child) |ch| : (child = c.gtk_widget_get_next_sibling(ch)) {
        fixScrolledWindows(ch, depth + 1, cap);
    }
}

fn onClosed(pop: *c.GtkPopover, _: ?*anyopaque) callconv(.c) void {
    _ = c.g_object_ref(@as(?*anyopaque, @ptrCast(pop)));
    _ = c.g_idle_add(@ptrCast(&unparentIdle), @ptrCast(pop));
}

fn unparentIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const pop: *c.GtkWidget = @ptrCast(@alignCast(user.?));
    if (c.gtk_widget_get_parent(pop) != null) c.gtk_widget_unparent(pop);
    c.g_object_unref(@as(?*anyopaque, @ptrCast(pop)));
    return 0;
}

/// One menu level (the top, a section, or a submenu).
pub const Menu = struct {
    root: *Root,
    model: *c.GMenu,

    pub fn item(self: Menu, label: [*:0]const u8, cb: anytype, ctx: ?*anyopaque) void {
        const idx: i32 = @intCast(self.root.items.items.len);
        self.root.items.append(self.root.allocator, .{ .cb = @ptrCast(cb), .ctx = ctx }) catch return;
        const it = c.g_menu_item_new(label, null);
        c.g_menu_item_set_action_and_target_value(it, "sketermmenu.run", c.g_variant_new_int32(idx));
        c.g_menu_append_item(self.model, it);
        c.g_object_unref(it);
    }

    /// A hover-opening side submenu.
    pub fn submenu(self: Menu, label: [*:0]const u8) Menu {
        const m = c.g_menu_new();
        c.g_menu_append_submenu(self.model, label, @ptrCast(@alignCast(m)));
        c.g_object_unref(m);
        return .{ .root = self.root, .model = m.? };
    }

    /// A separator-delimited group.
    pub fn section(self: Menu) Menu {
        const m = c.g_menu_new();
        c.g_menu_append_section(self.model, null, @ptrCast(@alignCast(m)));
        c.g_object_unref(m);
        return .{ .root = self.root, .model = m.? };
    }
};

/// GMenu labels treat '_' as a mnemonic marker; a path or user string
/// embedded in a label must have them doubled or they vanish.
pub fn escapeLabel(text: []const u8, buf: []u8) [*:0]const u8 {
    var n: usize = 0;
    for (text) |ch| {
        if (n + 3 >= buf.len) break;
        buf[n] = ch;
        n += 1;
        if (ch == '_') {
            buf[n] = '_';
            n += 1;
        }
    }
    buf[n] = 0;
    return @ptrCast(buf[0..n :0]);
}

test "escapeLabel doubles mnemonic underscores" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("my__file.txt", std.mem.span(escapeLabel("my_file.txt", &buf)));
    try t.expectEqualStrings("plain", std.mem.span(escapeLabel("plain", &buf)));
}
