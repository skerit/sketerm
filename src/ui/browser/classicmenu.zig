//! Classic context menus, hand-built from real widgets.
//!
//! GTK4's model-based popover menu cannot render per-item icons: the
//! "icon" attribute is silently ignored for normal rows, and the
//! `custom`-attribute escape hatch does not reach items inside NESTED
//! submenus (verified empirically on GTK 4.22). Nemo and Dolphin both
//! put icons on their most-used verbs, so the rows here are real
//! widgets instead: flat buttons with a 16px icon slot, checkmark
//! rows, and side submenus that open on hover like a proper menu.
//!
//! Items dispatch into the same `fn (*GtkButton, ?*anyopaque)`
//! handlers the old menus used; the button argument arrives null and
//! no handler reads it. The Root (dispatch state) rides the popover
//! as qdata and dies with it -- after a deferred unparent, because
//! `closed` can precede the activation that still needs it.
//!
//! DEPTH LIMIT: submenus must hang off the TOP menu, never off
//! another submenu. A popover three surfaces deep (menu > submenu >
//! sub-submenu) renders fine but never receives pointer input while
//! the top popover holds its autohide grab (verified empirically on
//! GTK 4.22/X11) -- its items look alive and do nothing. Flatten the
//! structure instead, the way Dolphin's Create New / Compress do.

const std = @import("std");
const c = @import("../../c.zig").c;
const iconload = @import("../iconload.zig");
const cssutil = @import("../cssutil.zig");
const cast = @import("../../util/cast.zig");

/// The legacy menu-handler shape, called with a null button.
pub const Handler = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

/// Cleanup for caller-owned per-item state (user-action contexts).
pub const Cleanup = *const fn (?*anyopaque) callconv(.c) void;

/// Pixel size of the icon slot every row reserves (labels align
/// whether or not the row has an icon, like Nemo's menus).
const ICON_PX = 16;
const SHORT_MENU_MAX_PX = 96;
const CONTENT_KEY = "sketerm-cm-content";

/// One row's icon: nothing (blank slot), a themed name, or a GIcon
/// (application icons).
pub const Icon = union(enum) {
    none,
    name: [*:0]const u8,
    gicon: *c.GIcon,
};

/// Menu row styling. Breeze draws NOTHING for a `.flat` button, so
/// the hover feedback is stated outright.
fn installCss(any_widget: *c.GtkWidget) void {
    const css =
        \\button.sketerm-cm-row {
        \\  padding: 4px 8px;
        \\  margin: 0;
        \\  min-height: 0;
        \\  border: none;
        \\  border-radius: 6px;
        \\  background: none;
        \\}
        \\button.sketerm-cm-row:hover {
        \\  background: alpha(currentColor, 0.1);
        \\}
        \\popover.sketerm-cm > contents {
        \\  padding: 4px;
        \\}
        \\popover.sketerm-cm-menubar > contents {
        \\  padding: 2px;
        \\  border-radius: 3px;
        \\}
        \\popover.sketerm-cm-menubar button.sketerm-cm-row {
        \\  padding: 2px 6px;
        \\  border-radius: 3px;
        \\}
    ;
    cssutil.install("browser_classicmenu", any_widget, css);
}

pub const Root = struct {
    allocator: std.mem.Allocator,
    /// The top-level menu's row box.
    box: *c.GtkWidget,
    cleanups: std.ArrayList(Owned) = .empty,
    /// Every submenu popover, in creation order; popped down and
    /// unparented ahead of the root popover.
    subpops: std.ArrayList(*c.GtkWidget) = .empty,
    /// Set by popup(); what item activation pops down.
    pop: ?*c.GtkWidget = null,

    const Owned = struct { cb: Cleanup, ctx: ?*anyopaque };

    pub fn create(allocator: std.mem.Allocator) ?*Root {
        const r = allocator.create(Root) catch return null;
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0) orelse {
            allocator.destroy(r);
            return null;
        };
        c.gtk_widget_set_size_request(box, 180, -1);
        r.* = .{ .allocator = allocator, .box = box };
        return r;
    }

    /// The top-level menu to build into.
    pub fn top(self: *Root) Menu {
        return .{ .root = self, .box = self.box };
    }

    /// Register caller state to free when the menu dies.
    pub fn own(self: *Root, cb: Cleanup, ctx: ?*anyopaque) void {
        self.cleanups.append(self.allocator, .{ .cb = cb, .ctx = ctx }) catch cb(ctx);
    }

    /// Abandon a built-but-never-popped menu (allocation failure
    /// paths); popup() hands ownership to the popover instead.
    pub fn destroy(self: *Root) void {
        // The box tree is floating until a popover adopts it.
        _ = c.g_object_ref_sink(@as(?*anyopaque, @ptrCast(self.box)));
        c.g_object_unref(@as(?*anyopaque, @ptrCast(self.box)));
        destroyCb(@ptrCast(self));
    }

    fn destroyCb(user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Root, user);
        for (self.cleanups.items) |o| o.cb(o.ctx);
        self.cleanups.deinit(self.allocator);
        self.subpops.deinit(self.allocator);
        self.allocator.destroy(self);
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

    /// Build the popover and pop it up at (x, y) in `parent`.
    /// Ownership of the Root moves to the popover.
    pub fn popup(self: *Root, parent: *c.GtkWidget, x: f64, y: f64) *c.GtkWidget {
        return self.popupStyled(parent, x, y, null);
    }

    /// Build a popover with an optional caller-specific CSS class.
    pub fn popupStyled(self: *Root, parent: *c.GtkWidget, x: f64, y: f64, css_class: ?[*:0]const u8) *c.GtkWidget {
        installCss(parent);
        var cap: c_int = 700;
        if (c.gtk_widget_get_root(parent)) |root| {
            const rh = c.gtk_widget_get_height(@ptrCast(@alignCast(root)));
            if (rh > 260) cap = rh - 80;
        }
        tidySeparators(self.box);
        const pop = c.gtk_popover_new().?;
        c.gtk_widget_add_css_class(pop, "sketerm-cm");
        c.gtk_widget_add_css_class(pop, "menu");
        if (css_class) |class| c.gtk_widget_add_css_class(pop, class);
        c.gtk_popover_set_has_arrow(@ptrCast(pop), 0);
        c.gtk_widget_set_halign(pop, c.GTK_ALIGN_START);
        const scroll = wrapScroll(self.box, cap);
        c.gtk_popover_set_child(@ptrCast(pop), scroll);
        for (self.subpops.items) |sp| {
            if (c.gtk_popover_get_child(@ptrCast(sp))) |sw|
                c.gtk_scrolled_window_set_max_content_height(@ptrCast(sw), cap);
        }
        self.pop = pop;

        c.g_object_set_data_full(@ptrCast(pop), "sketerm-classicmenu", @ptrCast(self), @ptrCast(&destroyCb));
        c.gtk_widget_set_parent(pop, parent);
        // Deferred unparent: `closed` can precede the activation that
        // still reads this Root, so tearing down inline would be a
        // use-after-free on every item click.
        _ = c.g_signal_connect_data(pop, "closed", @ptrCast(&onClosed), null, null, c.G_CONNECT_DEFAULT);
        // GTK's scroller under-reports its natural height before the
        // first frame. Measure after parenting, while the final CSS is
        // active, so short menus do not visibly resize while opening.
        stabilizeScroll(scroll, self.box, cap);
        for (self.subpops.items) |sp| {
            const sw = c.gtk_popover_get_child(@ptrCast(sp)) orelse continue;
            const box = scrollContent(sw) orelse continue;
            stabilizeScroll(sw, box, cap);
        }
        const rect = c.GdkRectangle{ .x = @intFromFloat(x), .y = @intFromFloat(y), .width = 1, .height = 1 };
        c.gtk_popover_set_pointing_to(@ptrCast(pop), &rect);
        c.gtk_popover_popup(@ptrCast(pop));
        return pop;
    }
};

/// Rows scroll rather than overflow the screen on very long menus.
fn wrapScroll(box: *c.GtkWidget, cap: c_int) *c.GtkWidget {
    const sw = c.gtk_scrolled_window_new().?;
    c.gtk_scrolled_window_set_policy(@ptrCast(sw), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_propagate_natural_width(@ptrCast(sw), 1);
    c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(sw), 1);
    c.gtk_scrolled_window_set_max_content_height(@ptrCast(sw), cap);
    c.gtk_scrolled_window_set_child(@ptrCast(sw), box);
    c.g_object_set_data(@ptrCast(@alignCast(sw)), CONTENT_KEY, @ptrCast(box));
    return sw;
}

pub fn scrollContent(scroll: *c.GtkWidget) ?*c.GtkWidget {
    const data = c.g_object_get_data(@ptrCast(@alignCast(scroll)), CONTENT_KEY) orelse return null;
    return @ptrCast(@alignCast(data));
}

fn needsVerticalScroll(natural: c_int, cap: c_int) bool {
    return natural > @min(cap, SHORT_MENU_MAX_PX);
}

fn stabilizeScroll(scroll: *c.GtkWidget, box: *c.GtkWidget, cap: c_int) void {
    var natural: c_int = 0;
    c.gtk_widget_measure(box, c.GTK_ORIENTATION_VERTICAL, -1, null, &natural, null, null);
    const height = @min(natural, cap);
    c.gtk_scrolled_window_set_min_content_height(@ptrCast(scroll), height);
    c.gtk_scrolled_window_set_max_content_height(@ptrCast(scroll), height);
    c.gtk_scrolled_window_set_policy(
        @ptrCast(scroll),
        c.GTK_POLICY_NEVER,
        if (needsVerticalScroll(natural, cap)) c.GTK_POLICY_AUTOMATIC else c.GTK_POLICY_NEVER,
    );
}

/// GMenu-style separator semantics for the eager separators
/// section() appends: none leading, none trailing, never two in a
/// row (a section that ended up with no items adds nothing).
fn tidySeparators(box: *c.GtkWidget) void {
    var seen_item = false;
    var pending: ?*c.GtkWidget = null;
    var child = c.gtk_widget_get_first_child(box);
    while (child) |w| : (child = c.gtk_widget_get_next_sibling(w)) {
        const is_sep = c.g_type_check_instance_is_a(@ptrCast(@alignCast(w)), c.gtk_separator_get_type()) != 0;
        if (is_sep) {
            c.gtk_widget_set_visible(w, 0);
            if (seen_item and pending == null) pending = w;
        } else {
            if (pending) |sep| {
                c.gtk_widget_set_visible(sep, 1);
                pending = null;
            }
            seen_item = true;
            // Submenu row boxes tidy their own popover's rows.
            if (c.g_object_get_data(@ptrCast(@alignCast(w)), "sketerm-cm-subbox")) |sb|
                tidySeparators(@ptrCast(@alignCast(sb)));
        }
    }
}

fn onClosed(pop: *c.GtkPopover, _: ?*anyopaque) callconv(.c) void {
    _ = c.g_object_ref(@as(?*anyopaque, @ptrCast(pop)));
    _ = c.g_idle_add(@ptrCast(&unparentIdle), @ptrCast(pop));
}

fn unparentIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const pop = cast.userData(c.GtkWidget, user);
    // Submenu popovers are parented to rows INSIDE this popover; they
    // must come off before their parents are disposed.
    if (c.g_object_get_data(@ptrCast(@alignCast(pop)), "sketerm-classicmenu")) |data| {
        const root: *Root = @ptrCast(@alignCast(data));
        for (root.subpops.items) |sp| {
            c.gtk_popover_popdown(@ptrCast(sp));
            if (c.gtk_widget_get_parent(sp) != null) c.gtk_widget_unparent(sp);
        }
        root.subpops.clearRetainingCapacity();
    }
    if (c.gtk_widget_get_parent(pop) != null) c.gtk_widget_unparent(pop);
    c.g_object_unref(@as(?*anyopaque, @ptrCast(pop)));
    return 0;
}

/// Heap context for one activatable row.
const ItemCtx = struct {
    allocator: std.mem.Allocator,
    root: *Root,
    cb: Handler,
    ctx: ?*anyopaque,

    fn free(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(ItemCtx, user);
        self.allocator.destroy(self);
    }
};

fn onItemClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ictx = cast.userData(ItemCtx, user);
    if (c.getenv("SKETERM_DEBUG_MENU") != null) std.debug.print("menu: item clicked\n", .{});
    // Close first: handlers open dialogs/popovers of their own, and
    // the new grab must not race this one.
    if (ictx.root.pop) |pop| c.gtk_popover_popdown(@ptrCast(pop));
    ictx.cb(null, ictx.ctx);
}

/// Hover behavior for every row: entering a row closes any open
/// sibling submenu, and opens this row's own (if it has one).
fn onRowEnter(controller: *c.GtkEventControllerMotion, _: f64, _: f64, _: ?*anyopaque) callconv(.c) void {
    const row = c.gtk_event_controller_get_widget(@ptrCast(controller)) orelse return;
    const parent = c.gtk_widget_get_parent(row) orelse return;
    var child = c.gtk_widget_get_first_child(parent);
    while (child) |w| : (child = c.gtk_widget_get_next_sibling(w)) {
        if (w == row) continue;
        if (c.g_object_get_data(@ptrCast(@alignCast(w)), "sketerm-cm-sub")) |sp|
            c.gtk_popover_popdown(@ptrCast(@alignCast(sp)));
    }
    if (c.g_object_get_data(@ptrCast(@alignCast(row)), "sketerm-cm-sub")) |sp|
        c.gtk_popover_popup(@ptrCast(@alignCast(sp)));
}

/// Keys that make the hand-built menu behave like a real one: Right
/// opens a focused submenu row, Left closes the submenu the focus is
/// in, Escape works even inside a (non-autohide) submenu popover.
fn onRowKey(controller: *c.GtkEventControllerKey, keyval: c.guint, _: c.guint, _: c.GdkModifierType, _: ?*anyopaque) callconv(.c) c.gboolean {
    const row = c.gtk_event_controller_get_widget(@ptrCast(controller)) orelse return 0;
    if (keyval == c.GDK_KEY_Right) {
        if (c.g_object_get_data(@ptrCast(@alignCast(row)), "sketerm-cm-sub")) |sp| {
            c.gtk_popover_popup(@ptrCast(@alignCast(sp)));
            if (c.g_object_get_data(@ptrCast(@alignCast(row)), "sketerm-cm-subbox")) |sb| {
                if (c.gtk_widget_get_first_child(@ptrCast(@alignCast(sb)))) |first|
                    _ = c.gtk_widget_grab_focus(first);
            }
            return 1;
        }
    }
    return 0;
}

fn onSubDebugPress(_: *c.GtkGestureClick, _: c_int, x: f64, y: f64, _: ?*anyopaque) callconv(.c) void {
    std.debug.print("menu: sub popover press at {d:.0},{d:.0}\n", .{ x, y });
}

fn onSubKey(controller: *c.GtkEventControllerKey, keyval: c.guint, _: c.guint, _: c.GdkModifierType, user: ?*anyopaque) callconv(.c) c.gboolean {
    const root = cast.userData(Root, user);
    const sp = c.gtk_event_controller_get_widget(@ptrCast(controller)) orelse return 0;
    if (keyval == c.GDK_KEY_Left) {
        c.gtk_popover_popdown(@ptrCast(@alignCast(sp)));
        if (c.gtk_widget_get_parent(sp)) |row| _ = c.gtk_widget_grab_focus(row);
        return 1;
    }
    if (keyval == c.GDK_KEY_Escape) {
        if (root.pop) |pop| c.gtk_popover_popdown(@ptrCast(pop));
        return 1;
    }
    return 0;
}

/// One menu level (the top, a section, or a submenu).
pub const Menu = struct {
    root: *Root,
    box: *c.GtkWidget,

    pub fn item(self: Menu, label: [*:0]const u8, cb: anytype, ctx: ?*anyopaque) void {
        self.itemIcon(label, .none, cb, ctx);
    }

    /// A row with an icon in its slot (themed name or app GIcon).
    pub fn itemIcon(self: Menu, label: [*:0]const u8, icon: Icon, cb: anytype, ctx: ?*anyopaque) void {
        self.itemIconEnabled(label, icon, true, cb, ctx);
    }

    /// A row that may be present but unable to act: `enabled = false`
    /// greys it out instead of hiding it, so a menu still shows what
    /// this surface CAN do while making clear that this verb has
    /// nothing to act on right now. The handler is connected either
    /// way — an insensitive GtkButton never emits `clicked`.
    pub fn itemIconEnabled(self: Menu, label: [*:0]const u8, icon: Icon, enabled: bool, cb: anytype, ctx: ?*anyopaque) void {
        const row = self.makeRow(label, icon, false);
        if (!enabled) c.gtk_widget_set_sensitive(row, 0);
        self.connectActivate(row, cb, ctx);
    }

    /// A check row (Nemo's Show Hidden Files). The mark reflects
    /// `checked` at build time; the handler flips the real state.
    pub fn check(self: Menu, label: [*:0]const u8, checked: bool, cb: anytype, ctx: ?*anyopaque) void {
        self.checkEnabled(label, checked, true, cb, ctx);
    }

    /// `check` for a state that exists but cannot be changed right now
    /// — greyed out rather than hidden, exactly like `itemIconEnabled`.
    pub fn checkEnabled(self: Menu, label: [*:0]const u8, checked: bool, enabled: bool, cb: anytype, ctx: ?*anyopaque) void {
        const row = self.makeRow(label, .none, false);
        if (!enabled) c.gtk_widget_set_sensitive(row, 0);
        const img = c.g_object_get_data(@ptrCast(@alignCast(row)), "sketerm-cm-icon");
        if (img != null) {
            c.gtk_image_set_from_icon_name(@ptrCast(@alignCast(img)), "object-select-symbolic");
            c.gtk_widget_set_opacity(@ptrCast(@alignCast(img)), if (checked) 1 else 0);
        }
        self.connectActivate(row, cb, ctx);
    }

    /// A hover-opening side submenu.
    pub fn submenu(self: Menu, label: [*:0]const u8) Menu {
        return self.submenuIcon(label, .none);
    }

    pub fn submenuIcon(self: Menu, label: [*:0]const u8, icon: Icon) Menu {
        const row = self.makeRow(label, icon, true);
        const sbox = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
        c.gtk_widget_set_size_request(sbox, 160, -1);
        const spop = c.gtk_popover_new().?;
        c.gtk_widget_add_css_class(spop, "sketerm-cm");
        c.gtk_widget_add_css_class(spop, "menu");
        c.gtk_popover_set_has_arrow(@ptrCast(spop), 0);
        c.gtk_popover_set_autohide(@ptrCast(spop), 0);
        c.gtk_popover_set_position(@ptrCast(spop), c.GTK_POS_RIGHT);
        c.gtk_popover_set_child(@ptrCast(spop), wrapScroll(sbox, 700));
        c.gtk_widget_set_parent(spop, row);
        const keys = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onSubKey), @ptrCast(self.root), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(spop, @ptrCast(keys));
        if (c.getenv("SKETERM_DEBUG_MENU") != null) {
            const dbg = c.gtk_gesture_click_new();
            c.gtk_event_controller_set_propagation_phase(@ptrCast(dbg), c.GTK_PHASE_CAPTURE);
            _ = c.g_signal_connect_data(dbg, "pressed", @ptrCast(&onSubDebugPress), null, null, c.G_CONNECT_DEFAULT);
            c.gtk_widget_add_controller(spop, @ptrCast(dbg));
        }
        c.g_object_set_data(@ptrCast(@alignCast(row)), "sketerm-cm-sub", @ptrCast(spop));
        c.g_object_set_data(@ptrCast(@alignCast(row)), "sketerm-cm-subbox", @ptrCast(sbox));
        self.root.subpops.append(self.root.allocator, spop) catch {};
        return .{ .root = self.root, .box = sbox };
    }

    /// A caller-built widget as a menu row: for the informational
    /// content a row of label text cannot carry (the image viewer's
    /// wrapped, selectable metadata block). It is a plain child of the
    /// menu box, so it counts as an item for separator tidying and
    /// dies with the popover like every other row — build it fresh per
    /// popup, never hand in a widget you keep a pointer to.
    pub fn custom(self: Menu, widget: *c.GtkWidget) void {
        c.gtk_box_append(@ptrCast(self.box), widget);
    }

    /// A separator-delimited group (same box; the separator is tidied
    /// by GMenu rules at popup time).
    pub fn section(self: Menu) Menu {
        c.gtk_box_append(@ptrCast(self.box), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL));
        return self;
    }

    fn makeRow(self: Menu, label: [*:0]const u8, icon: Icon, has_sub: bool) *c.GtkWidget {
        const btn = c.gtk_button_new().?;
        c.gtk_button_set_has_frame(@ptrCast(btn), 0);
        c.gtk_widget_add_css_class(btn, "sketerm-cm-row");
        const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
        const img = c.gtk_image_new().?;
        c.gtk_image_set_pixel_size(@ptrCast(img), ICON_PX);
        switch (icon) {
            .none => {},
            .name => |nm| iconload.setImageIcon(img, self.box, nm, ICON_PX),
            .gicon => |gi| iconload.setImageGicon(img, self.box, gi, ICON_PX),
        }
        c.g_object_set_data(@ptrCast(@alignCast(btn)), "sketerm-cm-icon", @ptrCast(img));
        c.gtk_box_append(@ptrCast(hbox), img);
        const lab = c.gtk_label_new(label);
        c.gtk_label_set_xalign(@ptrCast(lab), 0);
        c.gtk_label_set_ellipsize(@ptrCast(lab), c.PANGO_ELLIPSIZE_END);
        c.gtk_label_set_max_width_chars(@ptrCast(lab), 52);
        c.gtk_widget_set_hexpand(lab, 1);
        c.gtk_box_append(@ptrCast(hbox), lab);
        if (has_sub) {
            const arrow = c.gtk_image_new_from_icon_name("pan-end-symbolic");
            c.gtk_image_set_pixel_size(@ptrCast(arrow), 12);
            c.gtk_widget_set_halign(arrow, c.GTK_ALIGN_END);
            c.gtk_box_append(@ptrCast(hbox), arrow);
        }
        c.gtk_button_set_child(@ptrCast(btn), hbox);
        const motion = c.gtk_event_controller_motion_new();
        _ = c.g_signal_connect_data(motion, "enter", @ptrCast(&onRowEnter), null, null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(btn, @ptrCast(motion));
        const keys = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onRowKey), null, null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(btn, @ptrCast(keys));
        c.gtk_box_append(@ptrCast(self.box), btn);
        return btn;
    }

    fn connectActivate(self: Menu, row: *c.GtkWidget, cb: anytype, ctx: ?*anyopaque) void {
        const ictx = self.root.allocator.create(ItemCtx) catch return;
        ictx.* = .{ .allocator = self.root.allocator, .root = self.root, .cb = @ptrCast(cb), .ctx = ctx };
        _ = c.g_signal_connect_data(row, "clicked", @ptrCast(&onItemClicked), @ptrCast(ictx), @ptrCast(&ItemCtx.free), c.G_CONNECT_DEFAULT);
    }
};

/// Sentinel-terminate user text for a menu label. (The widget rows
/// here put text in plain GtkLabels, so unlike the old GMenu-based
/// menus nothing interprets underscores -- this is now only a
/// buffer-to-sentinel copy, kept so call sites read the same.)
pub fn escapeLabel(text: []const u8, buf: []u8) [*:0]const u8 {
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    return @ptrCast(buf[0..n :0]);
}

test "escapeLabel copies text verbatim" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("my_file.txt", std.mem.span(escapeLabel("my_file.txt", &buf)));
    try t.expectEqualStrings("plain", std.mem.span(escapeLabel("plain", &buf)));
}

test "only short fitting menus suppress vertical scrollbar negotiation" {
    const t = std.testing;
    try t.expect(!needsVerticalScroll(30, 700));
    try t.expect(needsVerticalScroll(120, 700));
    try t.expect(needsVerticalScroll(80, 60));
}
