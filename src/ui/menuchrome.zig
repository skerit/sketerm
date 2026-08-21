//! Shared chrome for the hand-built GtkPopover context menus
//! (`ui/menu.zig` for the terminal, `ui/editormenu.zig` for the editor
//! canvas, `ui/tabchrome.zig`'s tab menu for the rows).
//!
//! GTK4's GtkPopoverMenu cannot render per-item icons, so every menu in
//! this codebase builds its rows as plain buttons in a box. That idiom
//! had been written out three times, and the popover-minimum-size fix
//! below - a bug that took a while to find - twice. This module is its
//! one home: rows, the popover body wrapper, the right-click gesture and
//! the popover-unparenting destroy-notify.
//!
//! Lifetime: `attachRightClick` hands the click gesture's destroy-notify
//! ownership of the caller's context (CLAUDE.md mechanism 1, "the widget
//! owns the data"), and `destroyMenuCtx` is the notify that unparents
//! before freeing. Nothing here disconnects anything, so the notify
//! stays the single owner.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");

/// Build one flat icon+label menu-row button. `arrow` appends the
/// submenu chevron at the trailing edge.
pub fn makeRow(icon: [*:0]const u8, label: [*:0]const u8, arrow: bool) *c.GtkWidget {
    const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    const img = c.gtk_image_new_from_icon_name(icon);
    const lbl = c.gtk_label_new(label);
    c.gtk_label_set_xalign(@ptrCast(lbl), 0.0);
    c.gtk_widget_set_hexpand(lbl, 1);
    c.gtk_box_append(@ptrCast(row), img);
    c.gtk_box_append(@ptrCast(row), lbl);
    if (arrow) {
        c.gtk_box_append(@ptrCast(row), c.gtk_image_new_from_icon_name("pan-end-symbolic"));
    }
    const btn = c.gtk_button_new();
    c.gtk_button_set_child(@ptrCast(btn), row);
    c.gtk_button_set_has_frame(@ptrCast(btn), 0);
    return btn.?;
}

/// Put a built row `list` into `popover` through a scroller with natural
/// size propagation. THE reason this wrapper exists, and why no menu may
/// set a bare box as its popover child:
///
/// GTK4 silently pops down an autohide popover whose MINIMUM size does
/// not fit the space the compositor grants it (gtkpopover.c
/// gtk_popover_native_layout -> is_acceptable_size). A bare GtkBox's
/// minimum is the full list, so right-clicking mid-window - where
/// neither half of the window fits ~15 rows - made the menu vanish the
/// frame it mapped. The scroller makes the minimum tiny (the menu
/// scrolls when constrained) while natural height/width propagation
/// keeps the usual full-size rendering when there IS room.
pub fn setPopoverList(popover: *c.GtkWidget, list: *c.GtkWidget) void {
    const scroller = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(scroller), 1);
    c.gtk_scrolled_window_set_propagate_natural_width(@ptrCast(scroller), 1);
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), list);
    c.gtk_popover_set_child(@ptrCast(popover), scroller);
}

/// Signature of a menu's right-click handler ("pressed" on a
/// GtkGestureClick limited to button 3).
pub const PressedFn = *const fn (*c.GtkGestureClick, c_int, f64, f64, ?*anyopaque) callconv(.c) void;

/// Give `widget` a button-3 click gesture that runs `pressed` with
/// `ctx`, whose lifetime `notify` then owns. Use `destroyMenuCtx(T)` for
/// `notify` unless the context owns more than its popovers and itself.
pub fn attachRightClick(
    widget: *c.GtkWidget,
    pressed: PressedFn,
    ctx: *anyopaque,
    notify: *const fn (?*anyopaque) callconv(.c) void,
) void {
    const click = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(click), 3);
    _ = c.g_signal_connect_data(
        click,
        "pressed",
        @ptrCast(pressed),
        @ptrCast(ctx),
        @ptrCast(notify),
        c.G_CONNECT_DEFAULT,
    );
    c.gtk_widget_add_controller(widget, @ptrCast(click));
}

/// Destroy-notify for a menu context carrying `allocator`, `popover` and
/// a `subs` array of submenu popovers.
///
/// Popovers added via `gtk_widget_set_parent` must be explicitly
/// unparented before the host widget finalizes, otherwise GTK warns
/// "Finalizing GtkGLArea, but it still has children left". This notify
/// fires when the click controller is removed from the widget - i.e. at
/// widget destruction - which is the right hook. Submenu popovers
/// (parented to row buttons inside the main popover) go first for the
/// same reason.
pub fn destroyMenuCtx(comptime T: type) *const fn (?*anyopaque) callconv(.c) void {
    return &struct {
        fn f(user: ?*anyopaque) callconv(.c) void {
            if (user) |u| {
                const ctx: *T = @ptrCast(@alignCast(u));
                for (ctx.subs) |maybe_sub| {
                    const sub = maybe_sub orelse continue;
                    if (c.gtk_widget_get_parent(sub) != null) c.gtk_widget_unparent(sub);
                }
                if (c.gtk_widget_get_parent(ctx.popover) != null) c.gtk_widget_unparent(ctx.popover);
                ctx.allocator.destroy(ctx);
            }
        }
    }.f;
}

/// Show/hide a group of conditional rows to match `action`'s enabled
/// state (set per-popup by the menu's pre-popup hook).
pub fn setGroupVisible(group: *c.GSimpleActionGroup, action: [*:0]const u8, widgets: []const ?*c.GtkWidget) void {
    var show = false;
    if (c.g_action_map_lookup_action(@ptrCast(group), action)) |act| {
        show = c.g_action_get_enabled(@ptrCast(act)) != 0;
    }
    for (widgets) |maybe_w| {
        if (maybe_w) |w| c.gtk_widget_set_visible(w, @intFromBool(show));
    }
}

/// Click handler for a row that opens a submenu (keyboard / touch path;
/// hover has its own). `user` is the submenu popover, a child of the row
/// button, so it never outlives it and needs no destroy-notify.
pub fn onSubParentClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const sub: *c.GtkWidget = @ptrCast(@alignCast(u));
        if (c.gtk_widget_get_visible(sub) == 0) c.gtk_popover_popup(@ptrCast(sub));
    }
}

/// Pop the menu down when a row is clicked. The row's own action fires
/// as part of the same click; this just makes the menu close like a
/// menu. `user` is the popover widget (an ancestor of the row, so it
/// never outlives it - no destroy-notify needed).
pub fn onItemClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const pop: *c.GtkWidget = @ptrCast(@alignCast(u));
        c.gtk_popover_popdown(@ptrCast(pop));
    }
}

/// Classic-menu hover behaviour for top-level rows of a menu whose
/// context type is `Ctx` (needs a `subs` array of submenu popovers):
/// entering a row closes every sibling submenu and opens this row's own.
pub fn Hover(comptime Ctx: type) type {
    return struct {
        const HoverCtx = struct {
            allocator: std.mem.Allocator,
            cctx: *Ctx,
            sub: ?*c.GtkWidget,
        };

        /// Attach the motion controller to one row button. The
        /// controller's destroy-notify owns the per-row context.
        pub fn attach(allocator: std.mem.Allocator, btn: *c.GtkWidget, cctx: *Ctx, sub: ?*c.GtkWidget) !void {
            const hctx = try allocator.create(HoverCtx);
            hctx.* = .{ .allocator = allocator, .cctx = cctx, .sub = sub };
            const motion = c.gtk_event_controller_motion_new();
            _ = c.g_signal_connect_data(
                motion,
                "enter",
                @ptrCast(&onRowEnter),
                @ptrCast(hctx),
                @ptrCast(cast.destroyCtx(HoverCtx)),
                c.G_CONNECT_DEFAULT,
            );
            c.gtk_widget_add_controller(btn, motion);
        }

        fn onRowEnter(_: *c.GtkEventControllerMotion, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
            const hctx = cast.userData(HoverCtx, user);
            for (hctx.cctx.subs) |maybe_sub| {
                const sub = maybe_sub orelse continue;
                if (hctx.sub == sub) continue;
                if (c.gtk_widget_get_visible(sub) != 0) c.gtk_popover_popdown(@ptrCast(sub));
            }
            if (hctx.sub) |sub| {
                if (c.gtk_widget_get_visible(sub) == 0) c.gtk_popover_popup(@ptrCast(sub));
            }
        }
    };
}
